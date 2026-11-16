@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

// Translated from @ai-sdk/mcp 2.0.99 `mcp-client.test.ts`,
// `mcp-http-transport.test.ts`, `mcp-sse-transport.test.ts`,
// `mcp-apps.test.ts` and `mcp-app-fingerprint.test.ts`.

// MARK: - Upstream MockMCPTransport equivalent

private let upstreamDefaultTools: [JSONValue] = [
    [
        "name": "mock-tool",
        "description": "A mock tool for testing",
        "inputSchema": ["type": "object", "properties": ["foo": ["type": "string"]]]
    ],
    [
        "name": "mock-tool-no-args",
        "description": "A mock tool for testing",
        "inputSchema": ["type": "object"]
    ]
]

private actor UpstreamMockMCPTransport: MCPTransport {
    private let tools: [JSONValue]
    private let toolCallResults: [String: JSONValue]
    private let includePrompts: Bool
    private let includeResources: Bool
    private let failOnInvalidToolParams: Bool
    private(set) var sent: [JSONValue] = []
    private var requestHandler: (@Sendable (JSONValue) async -> JSONValue)?

    init(
        tools: [JSONValue] = upstreamDefaultTools,
        toolCallResults: [String: JSONValue] = [:],
        includePrompts: Bool = true,
        includeResources: Bool = true,
        failOnInvalidToolParams: Bool = false
    ) {
        self.tools = tools
        self.toolCallResults = toolCallResults
        self.includePrompts = includePrompts
        self.includeResources = includeResources
        self.failOnInvalidToolParams = failOnInvalidToolParams
    }

    func setRequestHandler(_ handler: (@Sendable (JSONValue) async -> JSONValue)?) async {
        requestHandler = handler
    }

    func incoming(_ message: JSONValue) async -> JSONValue? {
        await requestHandler?(message)
    }

    func start() async throws {}
    func close() async throws {}
    func notify(_ message: JSONValue) async throws { sent.append(message) }

    func request(_ message: JSONValue) async throws -> JSONValue {
        sent.append(message)
        let id = message["id"] ?? .null
        func result(_ value: JSONValue) -> JSONValue { ["jsonrpc": "2.0", "id": id, "result": value] }
        switch message["method"]?.stringValue {
        case "initialize":
            var capabilities: [String: JSONValue] = [:]
            if !tools.isEmpty { capabilities["tools"] = [:] }
            if includeResources { capabilities["resources"] = [:] }
            if includePrompts { capabilities["prompts"] = [:] }
            return result([
                "protocolVersion": .string(MCPClient.latestLegacyProtocolVersion),
                "serverInfo": ["name": "mock-mcp-server", "version": "1.0.0"],
                "capabilities": .object(capabilities)
            ])
        case "tools/list":
            return result(["tools": .array(tools)])
        case "tools/call":
            let name = message["params"]?["name"]?.stringValue ?? ""
            if failOnInvalidToolParams {
                return [
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": [
                        "code": -32602,
                        "message": "Invalid tool inputSchema",
                        "data": [
                            "expectedSchema": tools.first { $0["name"]?.stringValue == name }?["inputSchema"] ?? .null,
                            "receivedArguments": message["params"]?["arguments"] ?? .null
                        ]
                    ]
                ]
            }
            if let custom = toolCallResults[name] { return result(custom) }
            return result(["content": [["type": "text", "text": "Mock tool call result"]]])
        case "prompts/get":
            return result([
                "description": "Code review prompt",
                "messages": [["role": "user", "content": ["type": "text", "text": "Please review this code"]]]
            ])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not supported"]]
        }
    }
}

private func connectUpstreamMock(
    _ transport: UpstreamMockMCPTransport,
    clientName: String = "ai-sdk-mcp-client",
    maxRetries: Int = 0
) async throws -> MCPClient {
    try await MCPClient.connect(
        transport: transport,
        clientName: clientName,
        maxRetries: maxRetries,
        protocolVersionDiscovery: false
    )
}

// MARK: - Tool conversion metadata and title

@Test func mcpUpstreamToolsExposeExactMCPToolMetadataOnDynamicTools() async throws {
    let client = try await connectUpstreamMock(UpstreamMockMCPTransport(), clientName: "MyMCPClient")
    let tools = try await client.tools()

    #expect(tools["mock-tool"]?.metadata == [
        "clientName": "MyMCPClient",
        "toolName": "mock-tool"
    ])
    #expect(tools["mock-tool"]?.dynamic == true)
    #expect(tools["mock-tool"]?.title == nil)
}

@Test func mcpUpstreamToolsExposeMCPAppsMetadataOnTools() async throws {
    let transport = UpstreamMockMCPTransport(tools: [[
        "name": "showDashboard",
        "description": "Show dashboard",
        "inputSchema": ["type": "object", "properties": ["topic": ["type": "string"]]],
        "_meta": ["ui": ["resourceUri": "ui://ai-sdk-e2e/dashboard", "visibility": ["model", "app"]]]
    ]])
    let client = try await connectUpstreamMock(transport, clientName: "MyMCPClient")
    let tools = try await client.tools()

    #expect(tools["showDashboard"]?.metadata == [
        "app": [
            "mimeType": "text/html;profile=mcp-app",
            "resourceUri": "ui://ai-sdk-e2e/dashboard",
            "visibility": ["model", "app"]
        ],
        "clientName": "MyMCPClient",
        "toolName": "showDashboard"
    ])
    // `_meta` stays reachable through the MCP provider metadata.
    #expect(tools["showDashboard"]?.providerMetadata["mcp"]?["_meta"]?["ui"]?["resourceUri"] == "ui://ai-sdk-e2e/dashboard")
}

@Test func mcpUpstreamToolAnnotationsAndTitlesFollowTopLevelThenAnnotationTitle() async throws {
    let transport = UpstreamMockMCPTransport(tools: [
        ["name": "top-level", "title": "Top Level", "inputSchema": ["type": "object"]],
        ["name": "annotated", "annotations": ["title": "Annotated", "readOnlyHint": true, "custom": "x"], "inputSchema": ["type": "object"]],
        ["name": "both", "title": "Preferred", "annotations": ["title": "Fallback"], "inputSchema": ["type": "object"]],
        ["name": "untitled", "inputSchema": ["type": "object"]]
    ])
    let client = try await connectUpstreamMock(transport)
    let tools = try await client.tools()

    #expect(tools["top-level"]?.title == "Top Level")
    #expect(tools["top-level"]?.metadata?["title"] == "Top Level")
    #expect(tools["annotated"]?.title == "Annotated")
    #expect(tools["annotated"]?.metadata == [
        "clientName": "ai-sdk-mcp-client",
        "toolName": "annotated",
        "title": "Annotated",
        "annotations": ["title": "Annotated", "readOnlyHint": true]
    ])
    #expect(tools["both"]?.title == "Preferred")
    #expect(tools["untitled"]?.title == nil)
    #expect(tools["untitled"]?.metadata?["title"] == nil)
}

@Test func mcpUpstreamDynamicToolSchemasAreClosedAndZeroArgumentToolsGetProperties() async throws {
    let transport = UpstreamMockMCPTransport(tools: upstreamDefaultTools + [[
        "name": "open-schema",
        "inputSchema": ["type": "object", "properties": [:], "additionalProperties": true]
    ]])
    let client = try await connectUpstreamMock(transport)
    let tools = try await client.tools()

    #expect(tools["mock-tool-no-args"]?.parameters == [
        "type": "object",
        "properties": [:],
        "additionalProperties": false
    ])
    #expect(tools["open-schema"]?.parameters["additionalProperties"] == false)

    let output = try await #require(tools["mock-tool-no-args"]).execute([:])
    #expect(output == [
        "content": [["type": "text", "text": "Mock tool call result"]],
        "isError": false
    ])
}

// MARK: - Prompts, capabilities and protocol errors

@Test func mcpUpstreamGetPromptOmitsArgumentsWhenNotProvided() async throws {
    let transport = UpstreamMockMCPTransport()
    let client = try await connectUpstreamMock(transport)

    _ = try await client.getPrompt(name: "code_review")
    _ = try await client.getPrompt(name: "code_review", arguments: ["code": "print(42)"])

    let prompts = await transport.sent.filter { $0["method"] == "prompts/get" }
    #expect(prompts[0]["params"] == ["name": "code_review"])
    #expect(prompts[1]["params"] == ["name": "code_review", "arguments": ["code": "print(42)"]])
}

@Test func mcpUpstreamCapabilityErrorsUseUpstreamMessagesAndSendNothing() async throws {
    let transport = UpstreamMockMCPTransport(includePrompts: false, includeResources: false)
    let client = try await connectUpstreamMock(transport)

    await #expect(throws: MCPClientError.self) {
        _ = try await client.complete(ref: ["type": "ref/prompt", "name": "code_review"], argument: MCPCompleteArgument(name: "language", value: "py"))
    }
    do {
        _ = try await client.listPrompts()
        Issue.record("Expected prompts capability error")
    } catch let error as MCPClientError {
        #expect(error.message == "Server does not support prompts")
    }
    do {
        _ = try await client.getPrompt(name: "code_review")
        Issue.record("Expected prompts capability error")
    } catch let error as MCPClientError {
        #expect(error.message == "Server does not support prompts")
    }
    do {
        _ = try await client.listResources()
        Issue.record("Expected resources capability error")
    } catch let error as MCPClientError {
        #expect(error.message == "Server does not support resources")
    }
    let methods = await transport.sent.compactMap { $0["method"]?.stringValue }
    #expect(methods == ["initialize", "notifications/initialized"])
}

@Test func mcpUpstreamIncludesJSONRPCErrorDataInMCPClientError() async throws {
    let client = try await connectUpstreamMock(UpstreamMockMCPTransport(failOnInvalidToolParams: true))
    do {
        _ = try await client.callTool(name: "mock-tool", arguments: ["bar": "bar"])
        Issue.record("Expected tool call error")
    } catch let error as MCPClientError {
        #expect(error.code == -32602)
        #expect(error.data == [
            "expectedSchema": ["type": "object", "properties": ["foo": ["type": "string"]]],
            "receivedArguments": ["bar": "bar"]
        ])
    }
}

// MARK: - Elicitation handler failures

@Test func mcpUpstreamElicitationHandlerFailureReturnsInternalErrorAndReportsUncaughtError() async throws {
    let transport = UpstreamMockMCPTransport()
    let reported = LockedValues<String>()
    let client = try await MCPClient.connect(
        transport: transport,
        clientCapabilities: ["elicitation": [:]],
        protocolVersionDiscovery: false,
        onUncaughtError: { error in reported.append((error as? MCPClientError)?.message ?? "\(error)") }
    )
    await client.onElicitationRequest { _ in
        throw MCPClientError(message: "user closed the dialog")
    }

    let response = try #require(await transport.incoming([
        "jsonrpc": "2.0",
        "id": 42,
        "method": "elicitation/create",
        "params": ["message": "Please provide your GitHub username", "requestedSchema": ["type": "object"]]
    ]))

    #expect(response["error"]?["code"] == -32603)
    #expect(response["error"]?["message"] == "user closed the dialog")
    #expect(reported.values == ["user closed the dialog"])
}

// MARK: - Tool-call retries (retryWithExponentialBackoff)

private actor FailsFirstToolCallTransport: MCPTransport {
    enum Failure: Sendable { case transientHTTP, unlistedHTTP, network, invalidParams, auth, toolResultError, alwaysTransient }
    let failure: Failure
    private(set) var toolCallAttempts = 0

    init(_ failure: Failure) { self.failure = failure }

    func start() async throws {}
    func close() async throws {}
    func notify(_ message: JSONValue) async throws {}

    func request(_ message: JSONValue) async throws -> JSONValue {
        let id = message["id"] ?? .null
        switch message["method"]?.stringValue {
        case "initialize":
            return ["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": .string(MCPClient.latestLegacyProtocolVersion),
                "serverInfo": ["name": "retry-test-server", "version": "1.0.0"],
                "capabilities": ["tools": [:]]
            ]]
        case "tools/call":
            toolCallAttempts += 1
            if toolCallAttempts == 1 || failure == .alwaysTransient {
                switch failure {
                case .transientHTTP, .alwaysTransient: throw MCPClientError(message: "temporary overload", statusCode: 503)
                case .unlistedHTTP: throw MCPClientError(message: "not retryable by default", statusCode: 418)
                case .network: throw URLError(.networkConnectionLost)
                case .invalidParams:
                    return ["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Invalid params"]]
                case .auth: throw MCPClientError(message: "Unauthorized", statusCode: 401)
                case .toolResultError:
                    return ["jsonrpc": "2.0", "id": id, "result": [
                        "content": [["type": "text", "text": "tool-level error"]],
                        "isError": true
                    ]]
                }
            }
            return ["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": "retried successfully"]]]]
        default:
            return ["jsonrpc": "2.0", "id": id, "result": [:]]
        }
    }
}

private func retryClient(_ transport: FailsFirstToolCallTransport, maxRetries: Int) async throws -> MCPClient {
    let client = try await MCPClient.connect(transport: transport, maxRetries: maxRetries, protocolVersionDiscovery: false)
    await client.setToolCallRetryInitialDelayMilliseconds(0)
    return client
}

@Test func mcpUpstreamToolCallRetriesFollowRetryWithExponentialBackoff() async throws {
    let transient = FailsFirstToolCallTransport(.transientHTTP)
    let noRetry = try await MCPClient.connect(transport: transient, protocolVersionDiscovery: false)
    await #expect(throws: MCPClientError.self) { _ = try await noRetry.callTool(name: "retry-tool") }
    #expect(await transient.toolCallAttempts == 1)

    for failure in [FailsFirstToolCallTransport.Failure.transientHTTP, .network] {
        let transport = FailsFirstToolCallTransport(failure)
        let client = try await retryClient(transport, maxRetries: 1)
        let result = try await client.callTool(name: "retry-tool", arguments: ["value": "test"])
        #expect(result.rawValue == ["content": [["type": "text", "text": "retried successfully"]], "isError": false])
        #expect(await transport.toolCallAttempts == 2)
    }

    let unlisted = FailsFirstToolCallTransport(.unlistedHTTP)
    do {
        _ = try await retryClient(unlisted, maxRetries: 2).callTool(name: "retry-tool")
        Issue.record("Expected 418 failure")
    } catch let error as MCPClientError {
        #expect(error.statusCode == 418)
        #expect(error.message == "not retryable by default")
    }
    #expect(await unlisted.toolCallAttempts == 1)

    let invalid = FailsFirstToolCallTransport(.invalidParams)
    do {
        _ = try await retryClient(invalid, maxRetries: 2).callTool(name: "retry-tool")
        Issue.record("Expected invalid params failure")
    } catch let error as MCPClientError {
        #expect(error.code == -32602)
    }
    #expect(await invalid.toolCallAttempts == 1)

    let auth = FailsFirstToolCallTransport(.auth)
    do {
        _ = try await retryClient(auth, maxRetries: 2).callTool(name: "retry-tool")
        Issue.record("Expected auth failure")
    } catch let error as MCPClientError {
        #expect(error.statusCode == 401)
    }
    #expect(await auth.toolCallAttempts == 1)

    let toolError = FailsFirstToolCallTransport(.toolResultError)
    let toolErrorResult = try await retryClient(toolError, maxRetries: 2).callTool(name: "retry-tool")
    #expect(toolErrorResult.isError)
    #expect(await toolError.toolCallAttempts == 1)

    // provider-utils wraps an exhausted retry budget.
    let exhausted = FailsFirstToolCallTransport(.alwaysTransient)
    do {
        _ = try await retryClient(exhausted, maxRetries: 1).callTool(name: "retry-tool")
        Issue.record("Expected exhausted retries")
    } catch let error as MCPClientError {
        #expect(error.message == "Failed after 2 attempts. Last error: temporary overload")
        #expect((error.cause as? MCPClientError)?.statusCode == 503)
    }
    #expect(await exhausted.toolCallAttempts == 2)
}

// MARK: - Streamable HTTP transport

@Test func mcpUpstreamHTTPTransportDefaultsToStatelessProtocolWithoutInboundGET() async throws {
    let http = RecordingTransport(response: jsonResponse(#"{"jsonrpc":"2.0","id":0,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}}"#))
    let transport = try MCPHTTPTransport(url: "https://mcp.example.com/mcp", transport: http)
    let client = try await MCPClient.connect(transport: transport)

    let requests = await http.requests()
    #expect(requests.map(\.method) == ["POST"])
    #expect(requests[0].headers["mcp-protocol-version"] == MCPClient.latestProtocolVersion)
    #expect(requests[0].headers["user-agent"]?.contains("ai-sdk/") == true)
    #expect(requests[0].followRedirects == false)
    try await client.close()
}

@Test func mcpUpstreamHTTPTransportPostsJSONWithUpstreamHeaders() async throws {
    let http = RecordingTransport(response: jsonResponse(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#, headers: ["mcp-session-id": "abc123"]))
    let transport = try MCPHTTPTransport(
        url: "https://mcp.example.com/mcp",
        headers: ["authorization": "Bearer test-token", "x-custom-header": "test-value"],
        transport: http,
        initialProtocolVersion: MCPClient.latestLegacyProtocolVersion,
        maxInboundReconnectAttempts: 0
    )
    _ = try await transport.request(["jsonrpc": "2.0", "method": "initialize", "id": 1, "params": [:]])

    let post = try #require(await http.requests().first { $0.method == "POST" })
    var headers = post.headers
    #expect(headers.removeValue(forKey: "user-agent")?.hasPrefix("ai-sdk/") == true)
    #expect(headers == [
        "mcp-protocol-version": MCPClient.latestLegacyProtocolVersion,
        "accept": "application/json, text/event-stream",
        "content-type": "application/json",
        "authorization": "Bearer test-token",
        "x-custom-header": "test-value"
    ])
}

@Test func mcpUpstreamHTTPTransportReportsPOSTAnd404Errors() async throws {
    let http = RecordingTransport(responses: [AIHTTPResponse(statusCode: 404, body: Data("Not Found".utf8))])
    let transport = try MCPHTTPTransport(url: "https://mcp.example.com/mcp", transport: http, initialProtocolVersion: MCPClient.latestLegacyProtocolVersion, maxInboundReconnectAttempts: 0)
    do {
        _ = try await transport.request(["jsonrpc": "2.0", "method": "initialize", "id": 1, "params": [:]])
        Issue.record("Expected 404")
    } catch let error as MCPClientError {
        #expect(error.message.contains("POSTing to endpoint"))
        #expect(error.message.contains("does not support HTTP transport"))
        #expect(error.statusCode == 404)
        #expect(error.url == "https://mcp.example.com/mcp")
        #expect(error.responseBody == "Not Found")
    }
}

@Test func mcpUpstreamHTTPTransportReopensInboundSSEAfter202Accepted() async throws {
    let http = StreamingRecordingTransport(responses: [
        streamResponse(statusCode: 405),
        streamResponse(statusCode: 202),
        streamResponse(headers: ["content-type": "text/event-stream"], finishes: false)
    ])
    let transport = try MCPHTTPTransport(url: "https://mcp.example.com/mcp", transport: http, initialProtocolVersion: MCPClient.latestLegacyProtocolVersion)
    try await transport.start()
    _ = try await waitForStreamingRequests(http, count: 1)
    try await transport.notify(["jsonrpc": "2.0", "method": "notifications/initialized"])

    let requests = try await waitForStreamingRequests(http, count: 3)
    #expect(requests.map(\.method) == ["GET", "POST", "GET"])
    #expect(requests[2].headers["accept"] == "text/event-stream")
    try await transport.close()
}

@Test func mcpUpstreamHTTPTransportClearsSessionWhenInboundSSEReturns404() async throws {
    let recorder = MCPSessionRecorder()
    let http = StreamingRecordingTransport(responses: [streamResponse(statusCode: 404, chunks: ["missing"])])
    let transport = try MCPHTTPTransport(
        url: "https://mcp.example.com/mcp",
        transport: http,
        initialSessionID: "stale-session",
        initialProtocolVersion: MCPClient.latestLegacyProtocolVersion,
        onSessionIDChange: { id in Task { await recorder.recordChange(id) } },
        onSessionExpired: { id in Task { await recorder.recordExpiration(id) } },
        maxInboundReconnectAttempts: 0
    )
    try await transport.start()
    for _ in 0..<50 where await recorder.expiredSessionIDs().isEmpty {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(await recorder.expiredSessionIDs() == ["stale-session"])
    #expect(await recorder.changedSessionIDs() == [nil])
    try await transport.close()
}

// MARK: - Legacy SSE transport

private actor ControlledSSEServer: AIStreamingTransport {
    private(set) var requests: [AIHTTPRequest] = []
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private let getStatus: Int
    private let getBody: String
    private let postStatus: Int
    private let postBody: String
    private let respondOnStream: Bool

    init(getStatus: Int = 200, getBody: String = "", postStatus: Int = 202, postBody: String = "", respondOnStream: Bool = false) {
        self.getStatus = getStatus
        self.getBody = getBody
        self.postStatus = postStatus
        self.postBody = postBody
        self.respondOnStream = respondOnStream
    }

    func write(_ text: String) {
        continuation?.yield(Data(text.utf8))
    }

    func finish() {
        continuation?.finish()
    }

    func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        requests.append(request)
        guard getStatus == 200 else {
            return streamResponse(statusCode: getStatus, chunks: [getBody])
        }
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.continuation = continuation
        return AIHTTPStreamResponse(
            statusCode: 200,
            headers: ["content-type": "text/event-stream"],
            body: stream,
            cancelBody: { continuation.finish() }
        )
    }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        requests.append(request)
        if respondOnStream, let body = request.body, let message = try? body.jsonValueForTest(),
           let id = message["id"], let method = message["method"]?.stringValue {
            let result: JSONValue
            switch method {
            case "initialize":
                result = [
                    "protocolVersion": .string(MCPClient.latestLegacyProtocolVersion),
                    "serverInfo": ["name": "sse-server", "version": "1.0.0"],
                    "capabilities": ["tools": [:]]
                ]
            case "tools/list":
                result = ["tools": [["name": "echo", "inputSchema": ["type": "object"]]]]
            default:
                result = ["content": [["type": "text", "text": "echoed"]]]
            }
            let response: JSONValue = ["jsonrpc": "2.0", "id": id, "result": result]
            let text = String(data: try encodeJSONBody(response), encoding: .utf8) ?? ""
            continuation?.yield(Data("event: message\ndata: \(text)\n\n".utf8))
        }
        return AIHTTPResponse(statusCode: postStatus, body: Data(postBody.utf8))
    }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ value: Value) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return storage }
}

private func connectedSSETransport(
    _ server: ControlledSSEServer,
    headers: [String: String] = [:],
    errors: LockedValues<String>? = nil
) async throws -> MCPSSETransport {
    let transport = try MCPSSETransport(
        url: "http://localhost:3000/sse",
        headers: headers,
        transport: server,
        onError: { error in errors?.append((error as? MCPClientError)?.message ?? "\(error)") }
    )
    async let started: Void = transport.start()
    for _ in 0..<100 where await server.requests.isEmpty {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    await server.write("event: endpoint\ndata: http://localhost:3000/messages\n\n")
    try await started
    return transport
}

@Test func mcpUpstreamSSETransportEstablishesConnectionWithUpstreamHeaders() async throws {
    let server = ControlledSSEServer()
    let transport = try await connectedSSETransport(server, headers: ["authorization": "Bearer test-token", "x-custom-header": "test-value"])
    try await transport.notify(["jsonrpc": "2.0", "method": "test", "params": ["foo": "bar"]])

    let requests = await server.requests
    #expect(requests.count == 2)
    #expect(requests[0].method == "GET")
    #expect(requests[0].url.absoluteString == "http://localhost:3000/sse")
    var getHeaders = requests[0].headers
    #expect(getHeaders.removeValue(forKey: "user-agent")?.contains("ai-sdk/") == true)
    #expect(getHeaders == [
        "mcp-protocol-version": MCPClient.latestLegacyProtocolVersion,
        "accept": "text/event-stream",
        "authorization": "Bearer test-token",
        "x-custom-header": "test-value"
    ])
    #expect(requests[1].method == "POST")
    #expect(requests[1].url.absoluteString == "http://localhost:3000/messages")
    #expect(try requests[1].body?.jsonValueForTest() == ["jsonrpc": "2.0", "method": "test", "params": ["foo": "bar"]])
    var postHeaders = requests[1].headers
    #expect(postHeaders.removeValue(forKey: "user-agent")?.contains("ai-sdk/") == true)
    #expect(postHeaders == [
        "content-type": "application/json",
        "mcp-protocol-version": MCPClient.latestLegacyProtocolVersion,
        "authorization": "Bearer test-token",
        "x-custom-header": "test-value"
    ])
    #expect(requests.allSatisfy { !$0.followRedirects })
    try await transport.close()
}

@Test func mcpUpstreamSSETransportRejectsNon200ConnectionWithHTTPDetails() async throws {
    let errors = LockedValues<String>()
    let server = ControlledSSEServer(getStatus: 500, getBody: "Internal Server Error")
    let transport = try MCPSSETransport(url: "http://localhost:3000/sse", transport: server, onError: { errors.append(($0 as? MCPClientError)?.message ?? "") })
    do {
        try await transport.start()
        Issue.record("Expected connection failure")
    } catch let error as MCPClientError {
        #expect(error.statusCode == 500)
        #expect(error.url == "http://localhost:3000/sse")
        #expect(error.responseBody == "Internal Server Error")
        #expect(error.message.contains("MCP SSE Transport Error: 500 Internal Server Error"))
    }
    #expect(errors.values.count == 1)
}

@Test func mcpUpstreamSSETransportRejectsWhenConnectionClosesBeforeEndpoint() async throws {
    let server = ControlledSSEServer()
    let transport = try MCPSSETransport(url: "http://localhost:3000/sse", transport: server)
    async let started: Void = transport.start()
    for _ in 0..<100 where await server.requests.isEmpty {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    await server.finish()
    do {
        try await started
        Issue.record("Expected start failure")
    } catch let error as MCPClientError {
        #expect(error.message == "MCP SSE Transport Error: Connection closed before endpoint event was received")
    }
}

@Test func mcpUpstreamSSETransportRejectsCrossOriginEndpointsAndIgnoresLaterEndpoints() async throws {
    let server = ControlledSSEServer()
    let transport = try MCPSSETransport(url: "http://localhost:3000/sse", transport: server)
    async let started: Void = transport.start()
    for _ in 0..<100 where await server.requests.isEmpty {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    await server.write("event: endpoint\ndata: http://localhost:3333/messages\n\n")
    do {
        try await started
        Issue.record("Expected cross-origin failure")
    } catch let error as MCPClientError {
        #expect(error.message.contains("Endpoint origin does not match connection origin: http://localhost:3333"))
    }
    do {
        try await transport.notify(["jsonrpc": "2.0", "method": "test", "params": [:]])
        Issue.record("Expected not connected")
    } catch let error as MCPClientError {
        #expect(error.message.contains("Not connected"))
    }

    let connectedServer = ControlledSSEServer()
    let connected = try await connectedSSETransport(connectedServer)
    await connectedServer.write("event: endpoint\ndata: http://localhost:3333/messages\n\n")
    try await Task.sleep(nanoseconds: 20_000_000)
    try await connected.notify(["jsonrpc": "2.0", "method": "test", "params": ["foo": "bar"]])
    let posts = await connectedServer.requests.filter { $0.method == "POST" }
    #expect(posts.map(\.url.absoluteString) == ["http://localhost:3000/messages"])
    try await connected.close()
}

@Test func mcpUpstreamSSETransportRejectsNon2xxPOSTWithHTTPDetails() async throws {
    let errors = LockedValues<String>()
    let server = ControlledSSEServer(postStatus: 500, postBody: "Internal Server Error")
    let transport = try await connectedSSETransport(server, errors: errors)
    do {
        _ = try await transport.request(["jsonrpc": "2.0", "method": "test", "params": ["foo": "bar"], "id": "1"])
        Issue.record("Expected POST failure")
    } catch let error as MCPClientError {
        #expect(error.message == "MCP SSE Transport Error: POSTing to endpoint (HTTP 500): Internal Server Error")
        #expect(error.statusCode == 500)
        #expect(error.url == "http://localhost:3000/messages")
        #expect(error.responseBody == "Internal Server Error")
    }
    #expect(errors.values == ["MCP SSE Transport Error: POSTing to endpoint (HTTP 500): Internal Server Error"])
    try await transport.close()
}

@Test func mcpUpstreamSSETransportReportsInvalidMessagesAndKeepsReading() async throws {
    let errors = LockedValues<String>()
    let server = ControlledSSEServer()
    let transport = try await connectedSSETransport(server, errors: errors)
    await server.write("event: message\ndata: {\"foo\":\"bar\"}\n\n")
    await server.write("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"__proto__\":{\"polluted\":true}}}\n\n")
    for _ in 0..<100 where errors.values.count < 2 {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(errors.values == [
        "MCP SSE Transport Error: Failed to parse message",
        "MCP SSE Transport Error: Failed to parse message"
    ])
    try await transport.close()
}

@Test func mcpUpstreamSSETransportUsesNegotiatedProtocolVersionInPOSTHeaders() async throws {
    let server = ControlledSSEServer()
    let transport = try await connectedSSETransport(server)
    await transport.setProtocolVersion("2025-06-18")
    try await transport.notify(["jsonrpc": "2.0", "method": "test"])
    let post = try #require(await server.requests.last)
    #expect(post.headers["mcp-protocol-version"] == "2025-06-18")
    try await transport.close()
}

@Test func mcpUpstreamSSETransportRoutesResponsesAndServerRequestsForMCPClient() async throws {
    let server = ControlledSSEServer(respondOnStream: true)
    let transport = try MCPSSETransport(url: "http://localhost:3000/sse", transport: server)
    async let connecting = MCPClient.connect(transport: transport, protocolVersionDiscovery: false)
    for _ in 0..<100 where await server.requests.isEmpty {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    await server.write("event: endpoint\ndata: /messages\n\n")
    let client = try await connecting

    #expect(await client.serverInfo.name == "sse-server")
    let result = try await client.callTool(name: "echo")
    #expect(result.content.first?["text"] == "echoed")

    await server.write("data: {\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"ping\"}\n\n")
    for _ in 0..<100 {
        let answered = await server.requests.contains { (try? $0.body?.jsonValueForTest()["id"]) == 99 }
        if answered { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    let ping = await server.requests.compactMap { try? $0.body?.jsonValueForTest() }.first { $0["id"] == 99 }
    #expect(ping == ["jsonrpc": "2.0", "id": 99, "result": [:]])
    let methods = await server.requests.compactMap { try? $0.body?.jsonValueForTest()["method"]?.stringValue }
    #expect(methods == ["initialize", "notifications/initialized", "tools/call"])
    try await client.close()
}

// MARK: - MCP Apps

@Test func mcpUpstreamAppResourcesReadOnlyUIMetadataAndDropMalformedFields() throws {
    let read = try MCPReadResourceResult(json: ["contents": [[
        "uri": "ui://app/dashboard",
        "mimeType": "text/html;profile=mcp-app",
        "text": "<html></html>",
        "_meta": ["ui": [
            "prefersBorder": "yes",
            "permissions": ["camera"],
            "csp": ["connectDomains": ["https://api.example", 42], "frameDomains": "bad"],
            "custom": true
        ]]
    ]]])
    let resource = try MCPApps.resource(uri: "ui://app/dashboard", from: read)
    #expect(resource.metadata == [
        "csp": ["connectDomains": ["https://api.example"]],
        "custom": true
    ])

    let withoutUI = try MCPReadResourceResult(json: ["contents": [[
        "uri": "ui://app/plain",
        "mimeType": "text/html;profile=mcp-app",
        "text": "<html></html>",
        "_meta": ["other": "value"]
    ]]])
    #expect(try MCPApps.resource(uri: "ui://app/plain", from: withoutUI).metadata == nil)
}

private func fingerprintResource(html: String = "<!doctype html><html></html>", metadata: JSONValue? = [
    "csp": ["connectDomains": ["https://api.example"]],
    "permissions": ["microphone": [:]]
]) -> MCPAppResource {
    MCPAppResource(uri: "ui://app/dashboard", html: html, metadata: metadata)
}

@Test func mcpUpstreamFingerprintMCPAppResourceIsStableAndDetectsChanges() {
    #expect(MCPApps.fingerprint(fingerprintResource()) == MCPApps.fingerprint(fingerprintResource()))

    let a = MCPApps.fingerprint(fingerprintResource(metadata: [
        "csp": ["connectDomains": ["https://api.example"], "frameDomains": []],
        "permissions": ["microphone": [:], "camera": [:]]
    ]))
    let b = MCPApps.fingerprint(fingerprintResource(metadata: [
        "permissions": ["camera": [:], "microphone": [:]],
        "csp": ["frameDomains": [], "connectDomains": ["https://api.example"]]
    ]))
    #expect(a == b)

    let baseline = MCPApps.fingerprint(fingerprintResource())
    #expect(MCPApps.fingerprint(fingerprintResource(html: "<html>evil</html>")) != baseline)
    #expect(MCPApps.fingerprint(fingerprintResource(metadata: ["csp": ["connectDomains": ["https://evil.example"]]])) != baseline)
    #expect(MCPApps.fingerprint(fingerprintResource(metadata: ["permissions": ["camera": [:]]])) != baseline)
    #expect(!baseline.contains("=") && !baseline.contains("+") && !baseline.contains("/"))

    #expect(MCPApps.detectResourceDrift(current: "a", baseline: "b"))
    #expect(!MCPApps.detectResourceDrift(current: "a", baseline: "a"))
}

@Test func mcpUpstreamCanonicalJSONMatchesJavaScriptSerialization() {
    #expect(mcpCanonicalJSON(["b": 1, "a": ["x": "line\n\"q\"", "n": 2.5], "c": .null]) == #"{"a":{"n":2.5,"x":"line\n\"q\""},"b":1,"c":null}"#)
}

// MARK: - OAuth token request wire format (oauth.test.ts)

@Test func mcpUpstreamExchangeAuthorizationSerializesFormLikeURLSearchParams() async throws {
    let transport = RecordingTransport(response: jsonResponse(#"{"access_token":"access123","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh123"}"#))
    let tokens = try await MCPOAuth.exchangeAuthorization(
        authorizationServerURL: try requireURL("https://auth.example.com"),
        clientInformation: MCPOAuthClientInformation(clientID: "client123", clientSecret: "secret123"),
        authorizationCode: "code123",
        codeVerifier: "verifier123",
        redirectURI: try requireURL("http://localhost:3000/callback"),
        resource: try requireURL("https://api.example.com/mcp-server"),
        transport: transport
    )

    #expect(tokens.accessToken == "access123")
    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://auth.example.com/token")
    #expect(request.followRedirects == false)
    #expect(String(data: try #require(request.body), encoding: .utf8) ==
        "grant_type=authorization_code&code=code123&code_verifier=verifier123&redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Fcallback&client_id=client123&client_secret=secret123&resource=https%3A%2F%2Fapi.example.com%2Fmcp-server")
}

@Test func mcpUpstreamCustomClientAuthenticationRunsBeforeResourceIsAdded() async throws {
    let seen = LockedValues<[String]>()
    let transport = RecordingTransport(response: jsonResponse(#"{"access_token":"new","token_type":"Bearer"}"#))
    _ = try await MCPOAuth.refreshAuthorization(
        authorizationServerURL: try requireURL("https://auth.example.com"),
        clientInformation: MCPOAuthClientInformation(clientID: "client123"),
        refreshToken: "refresh123",
        resource: try requireURL("https://api.example.com/mcp-server"),
        clientAuthentication: { request in
            seen.append(request.parameters.map(\.name))
            var request = request
            request.parameters.append(URLQueryItem(name: "client_id", value: "set-by-provider"))
            return request
        },
        transport: transport
    )

    #expect(seen.values == [["grant_type", "refresh_token"]])
    let request = try #require(await transport.requests().first)
    #expect(String(data: try #require(request.body), encoding: .utf8) ==
        "grant_type=refresh_token&refresh_token=refresh123&client_id=set-by-provider&resource=https%3A%2F%2Fapi.example.com%2Fmcp-server")
}

@Test func mcpUpstreamStartAuthorizationSkipsEmptyStateAndScope() throws {
    let result = try MCPOAuth.startAuthorization(
        authorizationServerURL: try requireURL("https://auth.example.com"),
        clientInformation: MCPOAuthClientInformation(clientID: "client123"),
        redirectURL: try requireURL("http://localhost:3000/callback"),
        scope: "",
        state: "",
        codeVerifier: "verifier"
    )
    let names = (URLComponents(url: result.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
    #expect(names == ["response_type", "client_id", "code_challenge", "code_challenge_method", "redirect_uri"])
    #expect(result.authorizationURL.absoluteString.hasPrefix("https://auth.example.com/authorize?"))
}

// MARK: - json-rpc-message.test.ts

@Test func mcpUpstreamValidateJSONRPCMessage() throws {
    #expect(try MCPJSONRPC.validateMessage(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]) == ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
    #expect(try MCPJSONRPC.validateMessage(["jsonrpc": "2.0", "id": 1, "result": ["tools": []]]) == ["jsonrpc": "2.0", "id": 1, "result": ["tools": []]])
    #expect(throws: MCPClientError.self) { try MCPJSONRPC.validateMessage(["jsonrpc": "1.0", "id": 1, "result": ["tools": []]]) }
    #expect(throws: MCPClientError.self) { try MCPJSONRPC.validateMessage(["jsonrpc": "2.0", "id": 1.5, "method": "x"]) }
    #expect(throws: MCPClientError.self) { try MCPJSONRPC.validateMessage(["jsonrpc": "2.0", "id": 1, "result": [:], "extra": true]) }
    #expect(try MCPJSONRPC.validateMessage(["jsonrpc": "2.0", "error": ["code": -32600, "message": "Invalid"]])["error"]?["code"] == -32600)
}

// MARK: - Typed tools and outputSchema support

private let weatherOutputSchema: JSONValue = [
    "type": "object",
    "properties": ["temperature": ["type": "number"], "conditions": ["type": "string"]],
    "required": ["temperature", "conditions"]
]

private func typedWeatherTool(result: JSONValue) async throws -> AITool {
    let transport = UpstreamMockMCPTransport(
        tools: [["name": "get-weather", "description": "Get the weather", "inputSchema": ["type": "object", "properties": ["location": ["type": "string"]]]]],
        toolCallResults: ["get-weather": result]
    )
    let client = try await connectUpstreamMock(transport)
    let tools = try await client.tools(schemas: [
        "get-weather": MCPToolSchema(
            inputSchema: ["type": "object", "properties": ["location": ["type": "string"]], "required": ["location"]],
            outputSchema: weatherOutputSchema
        )
    ])
    return try #require(tools["get-weather"])
}

@Test func mcpUpstreamTypedToolsUseExplicitSchemasAndSkipUnlistedTools() async throws {
    let client = try await connectUpstreamMock(UpstreamMockMCPTransport(), clientName: "MyMCPClient")
    let tools = try await client.tools(schemas: [
        "mock-tool": MCPToolSchema(inputSchema: ["type": "object", "properties": ["foo": ["type": "string"]], "required": ["foo"]]),
        "nonexistent": MCPToolSchema(inputSchema: ["type": "object"])
    ])

    #expect(Array(tools.keys) == ["mock-tool"])
    let tool = try #require(tools["mock-tool"])
    #expect(tool.dynamic == false)
    #expect(tool.parameters == ["type": "object", "properties": ["foo": ["type": "string"]], "required": ["foo"]])
    #expect(tool.metadata == ["clientName": "MyMCPClient", "toolName": "mock-tool"])
    // Without an outputSchema the CallToolResult is returned unchanged.
    #expect(try await tool.execute(["foo": "bar"]) == [
        "content": [["type": "text", "text": "Mock tool call result"]],
        "isError": false
    ])
}

@Test func mcpUpstreamOutputSchemaReturnsValidatedStructuredContentOrParsedText() async throws {
    let structured = try await typedWeatherTool(result: [
        "content": [["type": "text", "text": "{\"temperature\":22.5,\"conditions\":\"Sunny\"}"]],
        "structuredContent": ["temperature": 22.5, "conditions": "Sunny"],
        "isError": false
    ])
    #expect(try await structured.execute(["location": "New York"]) == ["temperature": 22.5, "conditions": "Sunny"])

    let textFallback = try await typedWeatherTool(result: [
        "content": [["type": "text", "text": "{\"temperature\":18,\"conditions\":\"Cloudy\"}"]],
        "isError": false
    ])
    #expect(try await textFallback.execute(["location": "London"]) == ["temperature": 18, "conditions": "Cloudy"])
}

@Test func mcpUpstreamOutputSchemaMismatchesThrowUpstreamMessages() async throws {
    let cases: [(JSONValue, String)] = [
        (["content": [["type": "text", "text": "{}"]], "structuredContent": ["temperature": "hot"], "isError": false],
         "Tool \"get-weather\" returned structuredContent that does not match the expected outputSchema"),
        (["content": [["type": "text", "text": "not valid json"]], "isError": false],
         "Tool \"get-weather\" returned content that does not match the expected outputSchema"),
        (["content": [["type": "text", "text": "{\"temperature\":\"hot\"}"]], "isError": false],
         "Tool \"get-weather\" returned content that does not match the expected outputSchema"),
        (["content": [["type": "image", "data": "AAAA", "mimeType": "image/png"]], "isError": false],
         "Tool \"get-weather\" did not return structuredContent or parseable text content")
    ]
    for (result, message) in cases {
        let tool = try await typedWeatherTool(result: result)
        do {
            _ = try await tool.execute(["location": "Paris"])
            Issue.record("Expected outputSchema failure")
        } catch let error as MCPClientError {
            #expect(error.message == message)
        }
    }
}

@Test func mcpUpstreamOutputSchemaIsBypassedForToolErrors() async throws {
    let errorText: JSONValue = ["content": [["type": "text", "text": "Error: location not found"]], "isError": true]
    #expect(try await typedWeatherTool(result: errorText).execute(["location": "Atlantis"]) == errorText)

    let errorStructured: JSONValue = [
        "content": [["type": "text", "text": "Error"]],
        "structuredContent": ["error": "NOT_FOUND"],
        "isError": true
    ]
    #expect(try await typedWeatherTool(result: errorStructured).execute(["location": "Atlantis"]) == errorStructured)
}
