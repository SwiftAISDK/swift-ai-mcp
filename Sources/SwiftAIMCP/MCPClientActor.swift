import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


private enum MCPProtocolEra: Sendable {
    case legacy
    case modern
}

public actor MCPClient {
    public static let latestProtocolVersion = "2026-07-28"
    public static let latestLegacyProtocolVersion = "2025-11-25"
    public static let supportedProtocolVersions: Set<String> = [
        "2026-07-28",
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05"
    ]

    public private(set) var serverInfo = MCPImplementation(name: "", version: "")
    public private(set) var instructions: String?
    public private(set) var serverCapabilities: JSONValue = .object([:])
    public private(set) var initializeResult: JSONValue = .object([
        "protocolVersion": .string(MCPClient.latestLegacyProtocolVersion),
        "capabilities": .object([:]),
        "serverInfo": .object([
            "name": .string(""),
            "version": .string("")
        ])
    ])

    private let transport: any MCPTransport
    private let clientInfo: MCPImplementation
    private let clientCapabilities: JSONValue
    private let initialInitializeResult: JSONValue?
    private let initializationOptions: MCPRequestOptions?
    private let maxRetries: Int
    private let protocolVersionDiscovery: Bool
    private let onUncaughtError: (@Sendable (any Error) -> Void)?
    private let eventsConfiguration: MCPEventsConfiguration
    private let eventOperations: (any MCPEventOperations)?
    private var requestID = 0
    private var isClosed = true
    private let closeController = AIAbortController()
    private var elicitationRequestHandler: MCPElicitationHandler?
    private var protocolEra: MCPProtocolEra = .legacy
    private var protocolVersion = MCPClient.latestLegacyProtocolVersion
    private var toolHeaderBindings: [String: [MCPToolHeaderBinding]] = [:]

    private init(
        transport: any MCPTransport,
        clientName: String,
        clientVersion: String,
        clientCapabilities: JSONValue,
        initialInitializeResult: JSONValue?,
        initializationOptions: MCPRequestOptions?,
        maxRetries: Int,
        protocolVersionDiscovery: Bool,
        onUncaughtError: (@Sendable (any Error) -> Void)?,
        events: MCPEventsConfiguration = .direct()
    ) throws {
        self.eventsConfiguration = events
        if case let .managed(adapter) = events {
            let metadata: MCPEventTransportMetadata = (transport as? MCPHTTPTransport).map { .http(url: $0.eventEndpoint) } ?? .custom
            self.eventOperations = try adapter.createAdapter(transport: metadata)
        } else {
            self.eventOperations = nil
        }
        self.transport = transport
        self.clientInfo = MCPImplementation(name: clientName, version: clientVersion)
        self.clientCapabilities = clientCapabilities
        self.initialInitializeResult = initialInitializeResult
        self.initializationOptions = initializationOptions
        self.maxRetries = maxRetries
        self.protocolVersionDiscovery = protocolVersionDiscovery
        self.onUncaughtError = onUncaughtError
    }

    public static func connect(
        transport: any MCPTransport,
        clientName: String = "swift-ai-sdk-mcp-client",
        clientVersion: String = "1.0.0",
        clientCapabilities: JSONValue = .object([:]),
        initialInitializeResult: JSONValue? = nil,
        initializationOptions: MCPRequestOptions? = nil,
        maxRetries: Int = 0,
        protocolVersionDiscovery: Bool = true,
        onUncaughtError: (@Sendable (any Error) -> Void)? = nil
    ) async throws -> MCPClient {
        guard maxRetries >= 0 else {
            throw MCPClientError(message: "maxRetries must be >= 0")
        }
        let client = try MCPClient(
            transport: transport,
            clientName: clientName,
            clientVersion: clientVersion,
            clientCapabilities: clientCapabilities,
            initialInitializeResult: initialInitializeResult,
            initializationOptions: initializationOptions,
            maxRetries: maxRetries,
            protocolVersionDiscovery: protocolVersionDiscovery,
            onUncaughtError: onUncaughtError
        )
        try await client.initialize()
        return client
    }

    public static func connect(
        transport: any MCPTransport,
        events: MCPEventsConfiguration,
        clientName: String = "swift-ai-sdk-mcp-client",
        clientVersion: String = "1.0.0",
        clientCapabilities: JSONValue = .object([:]),
        initialInitializeResult: JSONValue? = nil,
        initializationOptions: MCPRequestOptions? = nil,
        maxRetries: Int = 0,
        protocolVersionDiscovery: Bool = true,
        onUncaughtError: (@Sendable (any Error) -> Void)? = nil
    ) async throws -> MCPClient {
        guard maxRetries >= 0 else { throw MCPClientError(message: "maxRetries must be >= 0") }
        let client = try MCPClient(transport: transport, clientName: clientName, clientVersion: clientVersion, clientCapabilities: clientCapabilities, initialInitializeResult: initialInitializeResult, initializationOptions: initializationOptions, maxRetries: maxRetries, protocolVersionDiscovery: protocolVersionDiscovery, onUncaughtError: onUncaughtError, events: events)
        try await client.initialize()
        return client
    }

    public var experimentalEvents: MCPEvents {
        MCPEvents(client: self, configuration: eventsConfiguration, managedOperations: eventOperations)
    }

    func eventRequest(method: String, params: JSONValue?, options: MCPRequestOptions?) async throws -> JSONValue {
        try await request(method: method, params: params, options: options)
    }

    public func close() async throws {
        await transport.setRequestHandler(nil)
        guard !isClosed else { return }
        isClosed = true
        closeController.abort(reason: "Connection closed")
        try await transport.close()
    }

    public func listTools(cursor: String? = nil) async throws -> MCPListToolsResult {
        try assertCapability("tools", method: "tools/list")
        let result = try await request(
            method: "tools/list",
            params: cursor.map { .object(["cursor": .string($0)]) }
        )
        return prepareToolDefinitions(
            try MCPListToolsResult(json: result),
            resetHeaderBindings: cursor == nil
        )
    }

    public func callTool(name: String, arguments: JSONValue = .object([:]), options: MCPRequestOptions? = nil) async throws -> MCPCallToolResult {
        try assertCapability("tools", method: "tools/call")
        let result = try await callToolWithRetry(options: options) {
            try await self.request(
                method: "tools/call",
                params: .object([
                    "name": .string(name),
                    "arguments": arguments
                ]),
                options: options
            )
        }
        return try MCPCallToolResult(json: result)
    }

    public func tools() async throws -> [String: AITool] {
        var definitions = try await listTools()
        var allTools = definitions.tools

        while let nextCursor = definitions.nextCursor {
            definitions = try await listTools(cursor: nextCursor)
            allTools.append(contentsOf: definitions.tools)
        }

        return toolsFromDefinitions(MCPListToolsResult(tools: allTools))
    }

    public func toolsFromDefinitions(_ definitions: MCPListToolsResult) -> [String: AITool] {
        prepareToolDefinitions(definitions).tools.reduce(into: [String: AITool]()) { output, definition in
            output[definition.name] = tool(from: definition)
        }
    }

    public func listResources(cursor: String? = nil, options: MCPRequestOptions? = nil) async throws -> MCPListResourcesResult {
        let result = try await request(
            method: "resources/list",
            params: cursor.map { .object(["cursor": .string($0)]) },
            options: options
        )
        return try MCPListResourcesResult(json: result)
    }

    public func readResource(uri: String, options: MCPRequestOptions? = nil) async throws -> MCPReadResourceResult {
        let result = try await request(
            method: "resources/read",
            params: .object(["uri": .string(uri)]),
            options: options
        )
        return try MCPReadResourceResult(json: result)
    }

    public func listResourceTemplates(options: MCPRequestOptions? = nil) async throws -> MCPListResourceTemplatesResult {
        let result = try await request(method: "resources/templates/list", options: options)
        return try MCPListResourceTemplatesResult(json: result)
    }

    public func listPrompts(cursor: String? = nil, options: MCPRequestOptions? = nil) async throws -> MCPListPromptsResult {
        let result = try await request(
            method: "prompts/list",
            params: cursor.map { .object(["cursor": .string($0)]) },
            options: options
        )
        return try MCPListPromptsResult(json: result)
    }

    public func getPrompt(name: String, arguments: JSONValue = .object([:]), options: MCPRequestOptions? = nil) async throws -> MCPGetPromptResult {
        let result = try await request(
            method: "prompts/get",
            params: .object([
                "name": .string(name),
                "arguments": arguments
            ]),
            options: options
        )
        return try MCPGetPromptResult(json: result)
    }

    @available(*, deprecated, renamed: "listPrompts(cursor:options:)")
    public func experimentalListPrompts(cursor: String? = nil, options: MCPRequestOptions? = nil) async throws -> MCPListPromptsResult {
        try await listPrompts(cursor: cursor, options: options)
    }

    @available(*, deprecated, renamed: "getPrompt(name:arguments:options:)")
    public func experimentalGetPrompt(name: String, arguments: JSONValue = .object([:]), options: MCPRequestOptions? = nil) async throws -> MCPGetPromptResult {
        try await getPrompt(name: name, arguments: arguments, options: options)
    }

    public func complete(
        ref: JSONValue,
        argument: MCPCompleteArgument,
        contextArguments: [String: String]? = nil,
        metadata: JSONValue? = nil,
        options: MCPRequestOptions? = nil
    ) async throws -> MCPCompleteResult {
        var params: [String: JSONValue] = [
            "ref": ref,
            "argument": argument.rawValue
        ]
        if let contextArguments {
            params["context"] = .object([
                "arguments": .object(contextArguments.mapValues(JSONValue.string))
            ])
        }
        if let metadata {
            params["_meta"] = metadata
        }
        let result = try await request(
            method: "completion/complete",
            params: .object(params),
            options: options
        )
        return try MCPCompleteResult(json: result)
    }

    public func onElicitationRequest(_ handler: MCPElicitationHandler?) {
        elicitationRequestHandler = handler
    }

    private func initialize() async throws {
        let externalSignal = initializationOptions?.abortSignal
        let timeout = initializationOptions?.effectiveTimeoutMilliseconds
        let timeoutController = timeout.map { _ in AIAbortController() }
        let timeoutTask: Task<Void, Never>? = if let timeout, let timeoutController {
            Task {
                let milliseconds = UInt64(max(0, timeout))
                let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
                do {
                    try await Task.sleep(nanoseconds: overflow ? UInt64.max : nanoseconds)
                    timeoutController.abort(reason: "MCP client initialization timed out after \(timeout)ms", reasonName: "TimeoutError")
                } catch {}
            }
        } else {
            nil
        }
        defer { timeoutTask?.cancel() }
        let effectiveOptions = MCPRequestOptions(abortSignal: mergeAbortSignals(externalSignal, timeoutController?.signal))

        do {
            if externalSignal?.isAborted == true {
                throw MCPClientError(message: "MCP client initialization was aborted")
            }
            await transport.setRequestHandler { [weak self] request in
                guard let self else {
                    return mcpJSONRPCErrorResponse(
                        id: request["id"],
                        code: -32603,
                        message: "MCP client has been released."
                    )
                }
                return await self.handleIncomingRequest(request)
            }
            try effectiveOptions.abortSignal?.throwIfAborted()
            isClosed = false
            try await mcpRunWithRequestOptions(
                effectiveOptions,
                timeoutMessage: { timeout in "MCP client initialization timed out after \(timeout)ms" },
                abortMessage: "MCP client initialization was aborted"
            ) { [transport] _ in
                try await transport.start()
            }

            if let initialInitializeResult {
                try await applyInitializeResult(initialInitializeResult)
                return
            }

            if protocolVersionDiscovery, transport.supportsProtocolVersionDiscovery {
                let discovered = try await tryProtocolDiscovery(options: effectiveOptions)
                if discovered {
                    return
                }
            }

            protocolEra = .legacy
            protocolVersion = Self.latestLegacyProtocolVersion
            await transport.setProtocolVersion(protocolVersion)
            let result = try await request(
                method: "initialize",
                params: .object([
                    "protocolVersion": .string(Self.latestLegacyProtocolVersion),
                    "capabilities": clientCapabilities,
                    "clientInfo": clientInfo.jsonValue
                ]),
                skipCapabilityCheck: true,
                options: effectiveOptions
            )
            try await applyInitializeResult(result)
            try effectiveOptions.abortSignal?.throwIfAborted()
            try await notify(method: "notifications/initialized", options: effectiveOptions)
            try effectiveOptions.abortSignal?.throwIfAborted()
        } catch {
            try? await close()
            if timeoutController?.signal.isAborted == true, let timeout {
                throw MCPClientError(message: "MCP client initialization timed out after \(timeout)ms")
            }
            if externalSignal?.isAborted == true {
                throw MCPClientError(message: "MCP client initialization was aborted")
            }
            throw error
        }
    }

    private func tryProtocolDiscovery(options: MCPRequestOptions) async throws -> Bool {
        protocolEra = .modern
        protocolVersion = Self.latestProtocolVersion
        await transport.setProtocolVersion(protocolVersion)

        do {
            let result = try await request(
                method: "server/discover",
                skipCapabilityCheck: true,
                options: MCPRequestOptions(
                    abortSignal: options.abortSignal,
                    timeoutMilliseconds: transport.waitsForProtocolVersionDiscovery ? nil : 1_000
                )
            )
            try applyDiscoverResult(result)
            return true
        } catch let error as MCPClientError {
            if let code = error.code, [-32020, -32021, -32022].contains(code) {
                if code == -32022, let values = error.data?["supported"]?.arrayValue,
                   values.allSatisfy({ $0.stringValue != nil }) {
                    let supported = values.compactMap(\.stringValue)
                    if !supported.contains(protocolVersion), supported.contains(where: { $0 <= Self.latestLegacyProtocolVersion && Self.supportedProtocolVersions.contains($0) }) {
                        throw MCPClientError(message: "MCP server rejected protocol version \(protocolVersion) during discovery. Server-supported versions: \(supported.joined(separator: ", ")). The client does not automatically switch to legacy initialization after this error. If this is a known legacy server, set protocolVersionDiscovery: false to use initialize.", code: error.code, data: error.data, statusCode: error.statusCode, url: error.url, responseBody: error.responseBody, cause: error)
                    }
                }
                throw error
            }
            return false
        } catch {
            return false
        }
    }

    private func applyDiscoverResult(_ result: JSONValue) throws {
        guard let supportedVersions = result["supportedVersions"]?.arrayValue?.compactMap(\.stringValue),
              result["supportedVersions"]?.arrayValue?.count == supportedVersions.count,
              let capabilities = result["capabilities"]?.objectValue else {
            throw MCPClientError(message: "Server sent invalid protocol discovery result.")
        }
        guard supportedVersions.contains(protocolVersion) else {
            throw MCPClientError(
                message: "Server does not support the requested protocol version: \(protocolVersion)"
            )
        }

        if let serverInfoValue = result["_meta"]?["io.modelcontextprotocol/serverInfo"] {
            serverInfo = try MCPImplementation(json: serverInfoValue)
        }
        serverCapabilities = .object(capabilities)
        instructions = result["instructions"]?.stringValue
        initializeResult = .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": serverCapabilities,
            "serverInfo": serverInfo.jsonValue,
            "instructions": instructions.map(JSONValue.string)
        ])
    }

    private func applyInitializeResult(_ result: JSONValue) async throws {
        guard let protocolVersion = result["protocolVersion"]?.stringValue else {
            throw MCPClientError(message: "Server sent invalid initialize result.")
        }
        guard Self.supportedProtocolVersions.contains(protocolVersion) else {
            throw MCPClientError(message: "Server protocol version is not supported: \(protocolVersion)")
        }
        serverCapabilities = result["capabilities"] ?? .object([:])
        protocolEra = .legacy
        self.protocolVersion = protocolVersion
        serverInfo = try MCPImplementation(json: result["serverInfo"] ?? .object([:]))
        initializeResult = result
        instructions = result["instructions"]?.stringValue
        await transport.setProtocolVersion(protocolVersion)
    }

    private func handleIncomingRequest(_ message: JSONValue) async -> JSONValue {
        let id = message["id"]
        guard let method = message["method"]?.stringValue else {
            return mcpJSONRPCErrorResponse(id: id, code: -32600, message: "Invalid MCP request.")
        }

        if method == "ping" {
            return mcpJSONRPCResultResponse(id: id, result: .object([:]))
        }

        guard method == "elicitation/create" else {
            return mcpJSONRPCErrorResponse(
                id: id,
                code: -32601,
                message: "Unsupported request method: \(method)"
            )
        }

        guard let elicitationRequestHandler else {
            return mcpJSONRPCErrorResponse(
                id: id,
                code: -32601,
                message: "No elicitation handler registered on client"
            )
        }

        do {
            let request = try MCPElicitationRequest(params: message["params"] ?? .object([:]))
            let result = try await elicitationRequestHandler(request)
            return mcpJSONRPCResultResponse(id: id, result: result.rawValue)
        } catch let error as MCPClientError {
            return mcpJSONRPCErrorResponse(
                id: id,
                code: -32602,
                message: "Invalid elicitation request: \(error.message)",
                data: error.data
            )
        } catch {
            return mcpJSONRPCErrorResponse(
                id: id,
                code: -32603,
                message: String(describing: error)
            )
        }
    }

    private func request(
        method: String,
        params: JSONValue? = nil,
        skipCapabilityCheck: Bool = false,
        options: MCPRequestOptions? = nil
    ) async throws -> JSONValue {
        guard !isClosed else {
            throw MCPClientError(message: "Attempted to send a request from a closed client.")
        }
        if !skipCapabilityCheck {
            try assertCapability(capabilityName(for: method), method: method)
        }
        let scopedOptions = MCPRequestOptions(
            abortSignal: mergeAbortSignals(options?.abortSignal, closeController.signal),
            maxTotalTimeoutMilliseconds: options?.maxTotalTimeoutMilliseconds
        )
        return try await mcpRunWithRequestOptions(
            scopedOptions,
            timeoutMessage: { timeout in "Request timed out after \(timeout)ms" },
            abortMessage: "Request was aborted",
            abortError: { [closed = closeController.signal] in MCPClientError(message: closed.isAborted ? "Connection closed" : "Request was aborted") }
        ) { effectiveOptions in
            try await self.requestRounds(method: method, params: params, options: effectiveOptions, roundTimeout: options?.timeoutMilliseconds)
        }
    }

    private enum InputRound: Sendable {
        case complete(JSONValue)
        case next([String: JSONValue])
    }

    /// Continuations always rebuild from the original request. Answers and
    /// opaque state from an earlier round never leak into a later one.
    private func requestRounds(method: String, params: JSONValue?, options: MCPRequestOptions, roundTimeout: Int?) async throws -> JSONValue {
        var nextParams = params?.objectValue ?? [:]
        for round in 0...10 {
            let callParams = nextParams
            let outcome: InputRound
            do {
                outcome = try await mcpRunWithRequestOptions(
                    MCPRequestOptions(abortSignal: options.abortSignal, timeoutMilliseconds: roundTimeout),
                    timeoutMessage: { "Request timed out after \($0)ms" },
                    abortMessage: "Request was aborted",
                    abortError: { [closed = closeController.signal] in MCPClientError(message: closed.isAborted ? "Connection closed" : "Request was aborted") }
                ) { roundOptions in
                    try await self.requestRound(method: method, originalParams: params, params: callParams, round: round, options: roundOptions)
                }
            } catch let error as MCPClientError {
                throw error
            } catch {
                throw MCPClientError(message: "Failed to process server response", cause: error)
            }
            switch outcome {
            case let .complete(value): return value
            case let .next(params): nextParams = params
            }
        }
        throw MCPClientError(message: "Request still requires input after 10 rounds")
    }

    private func requestRound(method: String, originalParams: JSONValue?, params: [String: JSONValue], round: Int, options: MCPRequestOptions) async throws -> InputRound {
        try Task.checkCancellation(); try options.abortSignal?.throwIfAborted()
        guard !isClosed else { throw MCPClientError(message: "MCP client closed during request.") }
        let id = requestID; requestID += 1
        let prepared = modernRequestParams(from: originalParams == nil && params.isEmpty ? nil : .object(params))
        let message = JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": prepared])
        var requestOptions = options
        requestOptions.transportHeaders = try toolRequestHeaders(method: method, params: prepared)
        let response = try await transport.request(message, options: requestOptions)
        let value = try result(from: response, expectedID: id)
        guard protocolEra == .modern, value["resultType"]?.stringValue == "input_required" else { return .complete(value) }
        guard ["tools/call", "resources/read", "prompts/get"].contains(method) else {
            throw MCPClientError(message: "Input-required results are not supported for \(method) on protocol \(protocolVersion)")
        }
        guard round < 10 else { throw MCPClientError(message: "Request still requires input after 10 rounds") }
        let state = value["requestState"]
        let input = value["inputRequests"]
        guard (state == nil || state?.stringValue != nil), (input == nil || input?.objectValue != nil), input != nil || state != nil else {
            throw MCPClientError(message: "Failed to process server response: invalid input_required result")
        }
        let requests = input?.objectValue ?? [:]
        var answers: [String: JSONValue] = [:]
        for (key, request) in requests.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation(); try options.abortSignal?.throwIfAborted()
            let method = request["method"]?.stringValue ?? "unknown"
            guard method == "elicitation/create", request["params"]?["mode"] == nil || request["params"]?["mode"] == "form" else {
                throw MCPClientError(message: "Unsupported input request: \(method). Only form elicitation is supported.")
            }
            guard let handler = elicitationRequestHandler else {
                throw MCPClientError(message: "Server requested input, but no handler is registered. Use onElicitationRequest to handle elicitation.")
            }
            guard request["params"]?["requestedSchema"]?["type"] == "object" else {
                throw MCPClientError(message: "Failed to process server response: form requestedSchema must be an object schema")
            }
            let answer = try await handler(MCPElicitationRequest(params: request["params"] ?? .object([:])))
            try Task.checkCancellation(); try options.abortSignal?.throwIfAborted()
            guard ["accept", "decline", "cancel"].contains(answer.rawValue["action"]?.stringValue ?? ""),
                  answer.rawValue["content"] == nil || answer.rawValue["content"]?.objectValue != nil else {
                throw MCPClientError(message: "Failed to process elicitation response")
            }
            answers[key] = answer.rawValue
        }
        if answers.isEmpty { try await Task.sleep(nanoseconds: 250_000_000) }
        try options.abortSignal?.throwIfAborted()
        guard !isClosed else { throw MCPClientError(message: "Connection closed") }
        var next = originalParams?.objectValue ?? [:]
        if !answers.isEmpty { next["inputResponses"] = .object(answers) }
        if let state { next["requestState"] = state }
        return .next(next)
    }

    private func notify(
        method: String,
        params: JSONValue? = nil,
        options: MCPRequestOptions? = nil
    ) async throws {
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params
        ])
        try await mcpRunWithRequestOptions(
            options,
            timeoutMessage: { timeout in "Request timed out after \(timeout)ms" },
            abortMessage: "Request was aborted"
        ) { [transport] effectiveOptions in
            try effectiveOptions.abortSignal?.throwIfAborted()
            try await transport.notify(message)
        }
    }

    private func result(from response: JSONValue, expectedID: Int) throws -> JSONValue {
        if let responseID = response["id"]?.intValue, responseID != expectedID {
            throw MCPClientError(message: "Protocol error: received response for id \(responseID), expected \(expectedID).")
        }
        if let error = response["error"] {
            throw MCPClientError(
                message: error["message"]?.stringValue ?? "Unknown MCP error.",
                code: error["code"]?.intValue,
                data: error["data"]
            )
        }
        guard let result = response["result"] else {
            throw MCPClientError(message: "Expected MCP JSON-RPC response with result.")
        }
        if protocolEra == .modern {
            guard let resultType = result["resultType"]?.stringValue else {
                throw MCPClientError(message: "Modern MCP result is missing resultType")
            }
            guard ["complete", "input_required"].contains(resultType) else { throw MCPClientError(message: "Unknown modern MCP resultType.") }
        }
        return result
    }

    private func assertCapability(_ capability: String, method: String) throws {
        guard capability != "initialize" else { return }
        if serverCapabilities[capability] == nil {
            throw MCPClientError(message: "Server does not support \(capability) for \(method).")
        }
    }

    private func capabilityName(for method: String) -> String {
        if method.hasPrefix("tools/") { return "tools" }
        if method.hasPrefix("resources/") { return "resources" }
        if method.hasPrefix("prompts/") { return "prompts" }
        if method.hasPrefix("events/") { return "events" }
        if method == "completion/complete" { return "completions" }
        return method
    }

    private func modernRequestParams(from params: JSONValue?) -> JSONValue? {
        guard protocolEra == .modern else { return params }
        var object = params?.objectValue ?? [:]
        var metadata = object["_meta"]?.objectValue ?? [:]
        metadata["io.modelcontextprotocol/protocolVersion"] = .string(protocolVersion)
        metadata["io.modelcontextprotocol/clientCapabilities"] = clientCapabilities
        metadata["io.modelcontextprotocol/clientInfo"] = clientInfo.jsonValue
        object["_meta"] = .object(metadata)
        return .object(object)
    }

    private func toolRequestHeaders(method: String, params: JSONValue?) throws -> [String: String]? {
        guard protocolEra == .modern,
              method == "tools/call",
              let toolName = params?["name"]?.stringValue,
              let bindings = toolHeaderBindings[toolName],
              !bindings.isEmpty,
              let arguments = params?["arguments"] else {
            return nil
        }
        do {
            return try createMCPToolHeaders(bindings: bindings, arguments: arguments)
        } catch {
            throw MCPClientError(message: "Failed to create MCP headers for tool \"\(toolName)\"")
        }
    }

    private func prepareToolDefinitions(
        _ definitions: MCPListToolsResult,
        resetHeaderBindings: Bool = false
    ) -> MCPListToolsResult {
        guard protocolEra == .modern, transport.supportsMCPToolParameterHeaders else {
            return definitions
        }
        if resetHeaderBindings {
            toolHeaderBindings.removeAll()
        }

        let tools = definitions.tools.filter { definition in
            switch mcpToolHeaderBindings(from: definition.inputSchema) {
            case let .success(bindings):
                toolHeaderBindings[definition.name] = bindings
                return true
            case let .failure(error):
                onUncaughtError?(MCPClientError(
                    message: "Ignoring MCP tool \"\(definition.name)\": \(error)"
                ))
                return false
            }
        }
        var rawValue = definitions.rawValue.objectValue ?? [:]
        rawValue["tools"] = .array(tools.map(\.jsonValue))
        return MCPListToolsResult(
            tools: tools,
            nextCursor: definitions.nextCursor,
            metadata: definitions.metadata,
            resultType: definitions.resultType,
            rawValue: .object(rawValue)
        )
    }

    private func callToolWithRetry(
        options: MCPRequestOptions?,
        execute: () async throws -> JSONValue
    ) async throws -> JSONValue {
        guard maxRetries > 0 else {
            return try await execute()
        }
        var errors: [Error] = []
        for attempt in 0...maxRetries {
            try options?.abortSignal?.throwIfAborted()
            do {
                return try await execute()
            } catch {
                errors.append(error)
                guard attempt < maxRetries, mcpShouldRetryToolCall(error) else {
                    throw error
                }
            }
        }
        throw errors.last ?? MCPClientError(message: "MCP tool call failed.")
    }

    private func tool(from definition: MCPToolDefinition) -> AITool {
        var inputSchema = definition.inputSchema.objectValue ?? ["type": .string("object")]
        if inputSchema["properties"] == nil {
            inputSchema["properties"] = .object([:])
        }
        if inputSchema["additionalProperties"] == nil {
            inputSchema["additionalProperties"] = .bool(false)
        }

        let resolvedTitle = definition.title ?? definition.annotations?["title"]?.stringValue
        var metadata: [String: JSONValue] = [
            "clientName": .string(clientInfo.name),
            "toolName": .string(definition.name)
        ]
        if let resolvedTitle {
            metadata["title"] = .string(resolvedTitle)
        }
        if let mcpMetadata = definition.metadata {
            metadata["_meta"] = mcpMetadata
        }
        if let annotations = definition.toolAnnotations {
            metadata["annotations"] = annotations.jsonValue
        }

        return AITool.dynamic(
            name: definition.name,
            description: definition.description,
            parameters: .object(inputSchema),
            providerMetadata: ["mcp": .object(metadata)],
            toModelOutput: { context in
                mcpToolModelOutput(from: context.output)
            }
        ) { [weak self] arguments, context in
            guard let self else {
                throw MCPClientError(message: "MCP client has been released.")
            }
            try context.abortSignal?.throwIfAborted()
            return try await self.callTool(
                name: definition.name,
                arguments: arguments,
                options: MCPRequestOptions(abortSignal: context.abortSignal)
            ).rawValue
        } execute: { [weak self] arguments in
            guard let self else {
                throw MCPClientError(message: "MCP client has been released.")
            }
            return try await self.callTool(name: definition.name, arguments: arguments).rawValue
        }
    }
}

private final class MCPRequestRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var abortRegistration: AIAbortHandlerRegistration?
    private var completed = false

    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func install(
        timeoutTask: Task<Void, Never>?,
        operationTask: Task<Void, Never>,
        abortRegistration: AIAbortHandlerRegistration?
    ) {
        lock.lock()
        if completed {
            lock.unlock()
            timeoutTask?.cancel()
            operationTask.cancel()
            abortRegistration?.cancel()
            return
        }
        self.timeoutTask = timeoutTask
        self.operationTask = operationTask
        self.abortRegistration = abortRegistration
        lock.unlock()
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        completed = true
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        let operationTask = self.operationTask
        let abortRegistration = self.abortRegistration
        self.timeoutTask = nil
        self.operationTask = nil
        self.abortRegistration = nil
        lock.unlock()

        timeoutTask?.cancel()
        operationTask?.cancel()
        abortRegistration?.cancel()
        continuation.resume(with: result)
    }
}

private func mcpRunWithRequestOptions<Value: Sendable>(
    _ options: MCPRequestOptions?,
    timeoutMessage: @escaping @Sendable (Int) -> String,
    abortMessage: String,
    abortError: (@Sendable () -> MCPClientError)? = nil,
    operation: @escaping @Sendable (MCPRequestOptions) async throws -> Value
) async throws -> Value {
    let externalSignal = options?.abortSignal
    if externalSignal?.isAborted == true {
        throw abortError?() ?? MCPClientError(message: abortMessage)
    }
    let timeout = options?.effectiveTimeoutMilliseconds
    if let timeout, timeout <= 0 { throw MCPClientError(message: timeoutMessage(timeout)) }
    guard externalSignal != nil || timeout != nil else {
        return try await operation(options ?? MCPRequestOptions())
    }

    let timeoutController = timeout.map { _ in AIAbortController() }
    let combinedSignal = mergeAbortSignals(externalSignal, timeoutController?.signal)
    let effectiveOptions = MCPRequestOptions(
        abortSignal: combinedSignal,
        transportHeaders: options?.transportHeaders
    )

    return try await withCheckedThrowingContinuation { continuation in
        let race = MCPRequestRace<Value>(continuation: continuation)
        let abortRegistration = externalSignal?.addAbortHandler { _ in
            race.resolve(.failure(abortError?() ?? MCPClientError(message: abortMessage)))
        }
        let timeoutTask: Task<Void, Never>? = if let timeout, let timeoutController {
            Task {
                let milliseconds = UInt64(max(0, timeout))
                let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
                do {
                    try await Task.sleep(nanoseconds: overflow ? UInt64.max : nanoseconds)
                    let message = timeoutMessage(timeout)
                    timeoutController.abort(reason: message, reasonName: "TimeoutError")
                    race.resolve(.failure(MCPClientError(message: message)))
                } catch {}
            }
        } else {
            nil
        }

        let operationTask = Task {
            do {
                try effectiveOptions.abortSignal?.throwIfAborted()
                let value = try await operation(effectiveOptions)
                if externalSignal?.isAborted == true {
                    race.resolve(.failure(abortError?() ?? MCPClientError(message: abortMessage)))
                } else if timeoutController?.signal.isAborted == true, let timeout {
                    race.resolve(.failure(MCPClientError(message: timeoutMessage(timeout))))
                } else {
                    race.resolve(.success(value))
                }
            } catch {
                if externalSignal?.isAborted == true {
                    race.resolve(.failure(abortError?() ?? MCPClientError(message: abortMessage)))
                } else if timeoutController?.signal.isAborted == true, let timeout {
                    race.resolve(.failure(MCPClientError(message: timeoutMessage(timeout))))
                } else {
                    race.resolve(.failure(error))
                }
            }
        }
        race.install(
            timeoutTask: timeoutTask,
            operationTask: operationTask,
            abortRegistration: abortRegistration
        )
    }
}

private func mcpShouldRetryToolCall(_ error: Error) -> Bool {
    if let error = error as? MCPClientError {
        if let status = error.statusCode {
            return status == 408 || status == 409 || status == 429 || status >= 500
        }
        if error.code != nil {
            return false
        }
    }
    let text = String(describing: error)
    return ["ConnectionRefused", "ConnectionClosed", "FailedToOpenSocket", "ECONNRESET", "ECONNREFUSED", "ETIMEDOUT", "EPIPE"].contains { text.contains($0) }
}