import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


/// Legacy HTTP+SSE MCP transport (upstream `{ type: 'sse' }`).
///
/// `start()` opens a long-lived `GET` event stream and waits for the server's
/// `endpoint` event. Requests are `POST`ed to that same-origin endpoint and
/// their JSON-RPC responses arrive on the event stream.
public final class MCPSSETransport: MCPTransport, @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let transport: any AITransport
    private let authProvider: (any MCPOAuthProvider)?
    private let followRedirects: Bool
    private let onError: (@Sendable (any Error) -> Void)?
    private let authorizationRecovery = MCPAuthorizationRecoveryCoordinator()
    private let state = MCPSSETransportState()

    var eventEndpoint: URL { url }

    public init(
        url: URL,
        headers: [String: String] = [:],
        transport: any AITransport = URLSessionTransport.shared,
        authProvider: (any MCPOAuthProvider)? = nil,
        followRedirects: Bool = false,
        onError: (@Sendable (any Error) -> Void)? = nil
    ) {
        self.url = url
        self.headers = headers
        self.transport = transport
        self.authProvider = authProvider
        self.followRedirects = followRedirects
        self.onError = onError
    }

    public convenience init(
        url: String,
        headers: [String: String] = [:],
        transport: any AITransport = URLSessionTransport.shared,
        authProvider: (any MCPOAuthProvider)? = nil,
        followRedirects: Bool = false,
        onError: (@Sendable (any Error) -> Void)? = nil
    ) throws {
        try self.init(
            url: requireURL(url),
            headers: headers,
            transport: transport,
            authProvider: authProvider,
            followRedirects: followRedirects,
            onError: onError
        )
    }

    public func setRequestHandler(_ handler: (@Sendable (JSONValue) async -> JSONValue)?) async {
        await state.setRequestHandler(handler)
    }

    public func setProtocolVersion(_ protocolVersion: String?) async {
        await state.setProtocolVersion(protocolVersion)
    }

    public func start() async throws {
        if await state.isConnected { return }
        guard let streamingTransport = transport as? any AIStreamingTransport else {
            throw MCPClientError(message: "MCP SSE Transport Error: the configured transport does not support streaming responses")
        }
        do {
            try await establishConnection(streamingTransport, triedAuth: false)
        } catch {
            reportError(error)
            throw error
        }
    }

    private func establishConnection(_ streamingTransport: any AIStreamingTransport, triedAuth: Bool) async throws {
        let requestHeaders = try await commonHeaders(["accept": "text/event-stream"])
        let response = try await streamingTransport.stream(AIHTTPRequest(
            method: "GET",
            url: url,
            headers: requestHeaders,
            followRedirects: followRedirects
        ))

        if response.statusCode == 401, let authProvider, !triedAuth {
            response.cancelBody()
            let parameters = mcpOAuthWWWAuthenticateParameters(from: response.headers)
            let authorized = try await authorizationRecovery.recover(
                provider: authProvider,
                failedAuthorization: mcpAuthorizationHeader(in: requestHeaders),
                resourceMetadataURL: parameters.resourceMetadataURL,
                scope: parameters.scope
            )
            guard authorized else {
                throw MCPClientError(message: "Unauthorized", statusCode: 401, url: url.absoluteString)
            }
            return try await establishConnection(streamingTransport, triedAuth: true)
        }

        guard (200..<300).contains(response.statusCode), response.bodyAvailable else {
            var body = Data()
            do {
                for try await chunk in response.body { body.append(chunk) }
            } catch {}
            let text = body.isEmpty ? nil : String(data: body, encoding: .utf8)
            var message = "MCP SSE Transport Error: \(mcpHTTPStatusLine(response.statusCode))"
            if let text { message += ": \(text)" }
            if response.statusCode == 405 {
                message += ". This server does not support SSE transport. Try using `http` transport instead"
            }
            throw MCPClientError(
                message: message,
                statusCode: response.statusCode,
                url: url.absoluteString,
                responseBody: text
            )
        }

        let state = self.state
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reader = Task { [weak self] in
                guard let self else { return }
                await self.readEvents(response)
            }
            Task {
                await state.beginConnecting(
                    continuation: continuation,
                    reader: reader,
                    cancelBody: { response.cancelBody() }
                )
            }
        }
    }

    private func readEvents(_ response: AIHTTPStreamResponse) async {
        // Wait until `beginConnecting` stored the start continuation.
        await state.waitUntilConnecting()
        var parser = ServerSentEventParser()
        do {
            for try await chunk in response.body {
                try Task.checkCancellation()
                for event in try parser.append(chunk) {
                    try await handle(event)
                }
            }
            for event in try parser.finish() {
                try await handle(event)
            }
            try Task.checkCancellation()
            if await state.isClosing { return }
            if await state.isConnected {
                await state.disconnect()
                throw MCPClientError(message: "MCP SSE Transport Error: Connection closed unexpectedly")
            }
            throw MCPClientError(message: "MCP SSE Transport Error: Connection closed before endpoint event was received")
        } catch {
            let closing = await state.isClosing
            if error is CancellationError || closing { return }
            reportError(error)
            await state.fail(error)
        }
    }

    private func handle(_ event: ServerSentEvent) async throws {
        if event.event == "endpoint" {
            guard await state.endpoint == nil else { return }
            guard let endpoint = URL(string: event.data, relativeTo: url)?.absoluteURL else {
                throw MCPClientError(message: "MCP SSE Transport Error: Invalid endpoint URL: \(event.data)")
            }
            guard mcpSSEOrigin(endpoint) == mcpSSEOrigin(url) else {
                await state.disconnect()
                throw MCPClientError(
                    message: "MCP SSE Transport Error: Endpoint origin does not match connection origin: \(mcpSSEOrigin(endpoint))"
                )
            }
            await state.connect(endpoint: endpoint)
            return
        }
        guard event.event == nil || event.event == "message" else { return }

        let message: JSONValue
        do {
            message = try decodeJSONBody(Data(event.data.utf8))
            try mcpValidateJSONRPCMessage(message)
        } catch {
            // Upstream reports parse failures and keeps reading the stream.
            reportError(MCPClientError(message: "MCP SSE Transport Error: Failed to parse message", cause: error))
            return
        }

        if message["method"]?.stringValue != nil {
            guard message["id"] != nil else { return }
            Task { [weak self] in
                guard let self, let handler = await self.state.requestHandler else { return }
                let response = await handler(message)
                do {
                    try await self.post(response, abortSignal: nil)
                } catch {
                    self.reportError(error)
                }
            }
            return
        }
        if let id = message["id"] {
            await state.resolve(id: id, with: message)
        }
    }

    public func request(_ message: JSONValue) async throws -> JSONValue {
        try await request(message, options: nil)
    }

    public func request(_ message: JSONValue, options: MCPRequestOptions?) async throws -> JSONValue {
        try options?.abortSignal?.throwIfAborted()
        guard let id = message["id"] else {
            try await post(message, abortSignal: options?.abortSignal)
            return .object([:])
        }
        let pending = MCPSSEPendingResponse()
        await state.register(id: id, pending: pending)
        do {
            try await post(message, abortSignal: options?.abortSignal)
        } catch {
            await state.unregister(id: id)
            throw error
        }
        let abortRegistration = options?.abortSignal?.addAbortHandler { _ in
            pending.resolve(.failure(MCPClientError(message: "Request was aborted")))
        }
        defer { abortRegistration?.cancel() }
        return try await withTaskCancellationHandler {
            do {
                let result = try await pending.value()
                await state.unregister(id: id)
                return result
            } catch {
                await state.unregister(id: id)
                throw error
            }
        } onCancel: {
            pending.resolve(.failure(CancellationError()))
        }
    }

    public func notify(_ message: JSONValue) async throws {
        try await post(message, abortSignal: nil)
    }

    public func close() async throws {
        await state.close(error: MCPClientError(message: "Connection closed"))
    }

    private func post(_ message: JSONValue, abortSignal: AIAbortSignal?, triedAuth: Bool = false) async throws {
        try abortSignal?.throwIfAborted()
        guard let endpoint = await state.endpoint, await state.isConnected else {
            throw MCPClientError(message: "MCP SSE Transport Error: Not connected")
        }
        do {
            let requestHeaders = try await commonHeaders(["content-type": "application/json"])
            let response = try await transport.send(AIHTTPRequest(
                method: "POST",
                url: endpoint,
                headers: requestHeaders,
                body: try encodeJSONBody(message),
                abortSignal: abortSignal,
                followRedirects: followRedirects
            ))

            if response.statusCode == 401, let authProvider, !triedAuth {
                let parameters = mcpOAuthWWWAuthenticateParameters(from: response.headers)
                let authorized = try await authorizationRecovery.recover(
                    provider: authProvider,
                    failedAuthorization: mcpAuthorizationHeader(in: requestHeaders),
                    resourceMetadataURL: parameters.resourceMetadataURL,
                    scope: parameters.scope
                )
                guard authorized else {
                    throw MCPClientError(message: "Unauthorized", statusCode: 401, url: endpoint.absoluteString)
                }
                return try await post(message, abortSignal: abortSignal, triedAuth: true)
            }

            guard (200..<300).contains(response.statusCode) else {
                throw MCPClientError(
                    message: "MCP SSE Transport Error: POSTing to endpoint (HTTP \(response.statusCode)): \(response.bodyText)",
                    statusCode: response.statusCode,
                    url: endpoint.absoluteString,
                    responseBody: response.bodyText
                )
            }
        } catch {
            if abortSignal?.isAborted != true {
                reportError(error)
            }
            throw error
        }
    }

    private func commonHeaders(_ base: [String: String]) async throws -> [String: String] {
        var requestHeaders = headers
        requestHeaders.merge(base) { _, new in new }
        requestHeaders["mcp-protocol-version"] = await state.protocolVersion ?? MCPClient.latestLegacyProtocolVersion
        if let token = try await authProvider?.accessToken(), !token.isEmpty {
            if let existing = requestHeaders.keys.first(where: { $0.caseInsensitiveCompare("authorization") == .orderedSame }) {
                requestHeaders.removeValue(forKey: existing)
            }
            requestHeaders["authorization"] = "Bearer \(token)"
        }
        return mcpWithUserAgentSuffix(requestHeaders)
    }

    private func reportError(_ error: any Error) {
        onError?(error)
    }
}

private actor MCPSSETransportState {
    private(set) var endpoint: URL?
    private(set) var isConnected = false
    private(set) var isClosing = false
    private(set) var protocolVersion: String?
    private(set) var requestHandler: (@Sendable (JSONValue) async -> JSONValue)?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var connectingWaiters: [CheckedContinuation<Void, Never>] = []
    private var isConnecting = false
    private var reader: Task<Void, Never>?
    private var cancelBody: (@Sendable () -> Void)?
    private var pending: [JSONValue: MCPSSEPendingResponse] = [:]

    func setRequestHandler(_ handler: (@Sendable (JSONValue) async -> JSONValue)?) {
        requestHandler = handler
    }

    func setProtocolVersion(_ version: String?) {
        protocolVersion = version
    }

    func beginConnecting(
        continuation: CheckedContinuation<Void, Error>,
        reader: Task<Void, Never>,
        cancelBody: @escaping @Sendable () -> Void
    ) {
        isClosing = false
        startContinuation = continuation
        self.reader = reader
        self.cancelBody = cancelBody
        isConnecting = true
        let waiters = connectingWaiters
        connectingWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilConnecting() async {
        guard !isConnecting else { return }
        await withCheckedContinuation { connectingWaiters.append($0) }
    }

    func connect(endpoint: URL) {
        self.endpoint = endpoint
        isConnected = true
        startContinuation?.resume()
        startContinuation = nil
    }

    func disconnect() {
        isConnected = false
        endpoint = nil
    }

    func fail(_ error: any Error) {
        isConnected = false
        endpoint = nil
        cancelBody?()
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: error)
        }
        let waiting = pending.values
        pending.removeAll()
        waiting.forEach { $0.resolve(.failure(error)) }
    }

    func close(error: any Error) {
        isClosing = true
        isConnected = false
        endpoint = nil
        reader?.cancel()
        reader = nil
        cancelBody?()
        cancelBody = nil
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: error)
        }
        let waiting = pending.values
        pending.removeAll()
        waiting.forEach { $0.resolve(.failure(error)) }
    }

    func register(id: JSONValue, pending response: MCPSSEPendingResponse) {
        pending[id] = response
    }

    func unregister(id: JSONValue) {
        pending.removeValue(forKey: id)
    }

    func resolve(id: JSONValue, with message: JSONValue) {
        pending.removeValue(forKey: id)?.resolve(.success(message))
    }
}

final class MCPSSEPendingResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<JSONValue, Error>?
    private var continuation: CheckedContinuation<JSONValue, Error>?

    func resolve(_ result: Result<JSONValue, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func value() async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

private func mcpSSEOrigin(_ url: URL) -> String {
    let scheme = url.scheme?.lowercased() ?? ""
    let host = url.host?.lowercased() ?? ""
    let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
    let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)"
}

/// JSON-RPC helpers matching upstream `validateJSONRPCMessage`.
public enum MCPJSONRPC {
    /// Validates a JSON-RPC 2.0 request, notification, response or error
    /// message with upstream's strict schemas and returns it unchanged.
    @discardableResult
    public static func validateMessage(_ message: JSONValue) throws -> JSONValue {
        try mcpValidateJSONRPCMessage(message)
        return message
    }
}

/// Mirrors upstream `JSONRPCMessageSchema` (strict request, notification,
/// response and error objects with `jsonrpc: "2.0"`).
func mcpValidateJSONRPCMessage(_ message: JSONValue) throws {
    let invalid = MCPClientError(message: "Invalid JSON-RPC message")
    guard let object = message.objectValue, object["jsonrpc"] == "2.0" else { throw invalid }
    func validID(_ value: JSONValue?) -> Bool {
        switch value {
        case .string?: return true
        case let .number(number)?: return number.isFinite && number == number.rounded()
        default: return false
        }
    }
    func validBase(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        guard let object = value.objectValue else { return false }
        if let meta = object["_meta"], meta.objectValue == nil { return false }
        return true
    }
    let keys = Set(object.keys)
    if let method = object["method"] {
        guard method.stringValue != nil, validBase(object["params"]) else { throw invalid }
        if object["id"] != nil {
            guard validID(object["id"]), keys.isSubset(of: ["jsonrpc", "id", "method", "params"]) else { throw invalid }
        } else {
            guard keys.isSubset(of: ["jsonrpc", "method", "params"]) else { throw invalid }
        }
        return
    }
    if let result = object["result"] {
        guard validID(object["id"]), result.objectValue != nil, validBase(result),
              result["resultType"] == nil || result["resultType"]?.stringValue != nil,
              keys.isSubset(of: ["jsonrpc", "id", "result"]) else { throw invalid }
        return
    }
    guard let error = object["error"]?.objectValue,
          object["id"] == nil || validID(object["id"]),
          validID(error["code"]), error["code"]?.stringValue == nil,
          error["message"]?.stringValue != nil,
          keys.isSubset(of: ["jsonrpc", "id", "error"]) else { throw invalid }
}
