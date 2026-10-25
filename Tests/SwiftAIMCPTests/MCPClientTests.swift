@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Test func mcpInitializationOptionsEnforceEffectiveTimeoutAndCloseTransport() async throws {
    let transport = MCPTimeoutTestTransport(hangInitialize: true)
    do {
        _ = try await MCPClient.connect(
            transport: transport,
            initializationOptions: MCPRequestOptions(
                timeoutMilliseconds: 100,
                maxTotalTimeoutMilliseconds: 5
            )
        )
        Issue.record("Expected MCP initialization timeout")
    } catch let error as MCPClientError {
        #expect(error.message == "MCP client initialization timed out after 5ms")
    }
    #expect(await transport.wasClosed())
}

@Test func mcpInitializationTimeoutBoundsHangingTransportStartAndClosesTransport() async throws {
    let transport = MCPTimeoutTestTransport(hangStart: true)
    do {
        _ = try await MCPClient.connect(
            transport: transport,
            initializationOptions: MCPRequestOptions(timeoutMilliseconds: 5)
        )
        Issue.record("Expected MCP initialization timeout")
    } catch let error as MCPClientError {
        #expect(error.message == "MCP client initialization timed out after 5ms")
    }
    #expect(await transport.wasClosed())
}

@Test func mcpInitializationClosesTransportWhenStartFails() async throws {
    let transport = MCPTimeoutTestTransport(failStart: true)
    do {
        _ = try await MCPClient.connect(transport: transport)
        Issue.record("Expected MCP transport start failure")
    } catch let error as MCPClientError {
        #expect(error.message == "MCP transport start failed")
    }
    #expect(await transport.wasClosed())
}

@Test func mcpInitializationTimeoutBoundsHangingInitializedNotificationAndClosesTransport() async throws {
    let transport = MCPTimeoutTestTransport(hangNotification: true)
    do {
        _ = try await MCPClient.connect(
            transport: transport,
            initializationOptions: MCPRequestOptions(timeoutMilliseconds: 5)
        )
        Issue.record("Expected MCP initialization timeout")
    } catch let error as MCPClientError {
        #expect(error.message == "MCP client initialization timed out after 5ms")
    }
    #expect(await transport.wasClosed())
}

@Test func mcpInitializationAbortBoundsHangingInitializedNotificationAndClosesTransport() async throws {
    let transport = MCPTimeoutTestTransport(hangNotification: true)
    let controller = AIAbortController()
    let abortTask = Task {
        while !Task.isCancelled, !(await transport.notificationWasStarted()) {
            await Task.yield()
        }
        guard !Task.isCancelled else { return }
        controller.abort(reason: "stop")
    }
    defer { abortTask.cancel() }

    do {
        _ = try await MCPClient.connect(
            transport: transport,
            initializationOptions: MCPRequestOptions(abortSignal: controller.signal)
        )
        Issue.record("Expected MCP initialization abort")
    } catch let error as MCPClientError {
        #expect(error.message == "MCP client initialization was aborted")
    }
    #expect(await transport.wasClosed())
}

@Test func mcpRequestOptionsEnforceTimeoutAndAbort() async throws {
    let transport = MCPTimeoutTestTransport(hangInitialize: false)
    let client = try await MCPClient.connect(transport: transport)

    do {
        _ = try await client.listResources(options: MCPRequestOptions(
            timeoutMilliseconds: 50,
            maxTotalTimeoutMilliseconds: 5
        ))
        Issue.record("Expected MCP request timeout")
    } catch let error as MCPClientError {
        #expect(error.message == "Request timed out after 5ms")
    }

    let controller = AIAbortController()
    controller.abort(reason: "stop")
    do {
        _ = try await client.listResources(options: MCPRequestOptions(abortSignal: controller.signal))
        Issue.record("Expected MCP request abort")
    } catch let error as MCPClientError {
        #expect(error.message == "Request was aborted")
    }
    try await client.close()
}

private actor MCPTimeoutTestTransport: MCPTransport {
    private let hangStart: Bool
    private let failStart: Bool
    private let hangInitialize: Bool
    private let hangNotification: Bool
    private var notificationStarted = false
    private var closed = false

    init(
        hangStart: Bool = false,
        failStart: Bool = false,
        hangInitialize: Bool = false,
        hangNotification: Bool = false
    ) {
        self.hangStart = hangStart
        self.failStart = failStart
        self.hangInitialize = hangInitialize
        self.hangNotification = hangNotification
    }

    func start() async throws {
        if failStart {
            throw MCPClientError(message: "MCP transport start failed")
        }
        if hangStart {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    func request(_ message: JSONValue) async throws -> JSONValue {
        let id = message["id"] ?? 0
        switch message["method"]?.stringValue {
        case "initialize" where hangInitialize:
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return .null
        case "initialize":
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "protocolVersion": .string(MCPClient.latestLegacyProtocolVersion),
                    "capabilities": ["resources": [:]],
                    "serverInfo": ["name": "timeout-test", "version": "1"]
                ]
            ]
        case "resources/list":
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return .null
        default:
            return ["jsonrpc": "2.0", "id": id, "result": [:]]
        }
    }

    func notify(_ message: JSONValue) async throws {
        notificationStarted = true
        if hangNotification {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    func close() async throws {
        closed = true
    }

    func wasClosed() -> Bool { closed }
    func notificationWasStarted() -> Bool { notificationStarted }
}

@Test func mcpClientInitializesAndBuildsDynamicTools() async throws {
    let transport = MockMCPTransport()
    let client = try await MCPClient.connect(
        transport: transport,
        clientName: "TestMCPClient",
        clientVersion: "1.2.3"
    )

    #expect(await client.serverInfo == MCPImplementation(name: "mock-server", version: "0.1.0"))
    #expect(await client.instructions == "Use these mock tools carefully.")

    let tools = try await client.tools()
    let search = try #require(tools["search"])
    #expect(search.dynamic)
    #expect(search.name == "search")
    #expect(search.description == "Search documents")
    #expect(search.parameters["properties"]?["query"]?["type"]?.stringValue == "string")
    #expect(search.parameters["additionalProperties"]?.boolValue == false)
    #expect(search.providerMetadata["mcp"]?["clientName"]?.stringValue == "TestMCPClient")
    #expect(search.providerMetadata["mcp"]?["toolName"]?.stringValue == "search")
    #expect(search.providerMetadata["mcp"]?["title"]?.stringValue == "Search")

    let result = try await search.execute(["query": "swift"])
    #expect(result["content"]?[0]?["text"]?.stringValue == "Result for swift")
    #expect(result["isError"]?.boolValue == false)
    let modelOutput = try await #require(search.toModelOutput?(
        AIToolModelOutputContext(toolCallID: "call-1", input: ["query": "swift"], output: result)
    ))
    #expect(modelOutput["type"]?.stringValue == "content")
    #expect(modelOutput["value"]?[0]?["type"]?.stringValue == "text")
    #expect(modelOutput["value"]?[0]?["text"]?.stringValue == "Result for swift")

    let sent = await transport.sentMessages()
    #expect(sent.map { $0["method"]?.stringValue } == [
        "initialize",
        "notifications/initialized",
        "tools/list",
        "tools/call"
    ])
    #expect(sent[0]["params"]?["clientInfo"]?["name"]?.stringValue == "TestMCPClient")
    #expect(sent[3]["params"]?["name"]?.stringValue == "search")
    #expect(sent[3]["params"]?["arguments"]?["query"]?.stringValue == "swift")
}

@Test func mcpClientCanResumeFromInitialInitializeResultAndCompleteLikeUpstreamV2() async throws {
    let transport = MockMCPTransport(capabilities: fullMCPCapabilities())
    let initializeResult: JSONValue = [
        "protocolVersion": .string(MCPClient.latestProtocolVersion),
        "capabilities": fullMCPCapabilities(),
        "serverInfo": [
            "name": "cached-server",
            "version": "2.0.0",
            "title": "Cached Server"
        ],
        "instructions": "Use cached initialization."
    ]
    let client = try await MCPClient.connect(
        transport: transport,
        initialInitializeResult: initializeResult
    )

    #expect(await client.serverInfo == MCPImplementation(name: "cached-server", version: "2.0.0", title: "Cached Server"))
    #expect(await client.instructions == "Use cached initialization.")
    #expect(await client.initializeResult["serverInfo"]?["name"]?.stringValue == "cached-server")

    let completion = try await client.complete(
        ref: ["type": "ref/prompt", "name": "summarize"],
        argument: MCPCompleteArgument(name: "topic", value: "swift"),
        contextArguments: ["locale": "en"]
    )
    #expect(completion.values == ["swift-one", "swift-two"])
    #expect(completion.total == 2)
    #expect(completion.hasMore == false)

    let sent = await transport.sentMessages()
    #expect(sent.map { $0["method"]?.stringValue } == ["completion/complete"])
    #expect(sent[0]["params"]?["ref"]?["type"]?.stringValue == "ref/prompt")
    #expect(sent[0]["params"]?["argument"]?["name"]?.stringValue == "topic")
    #expect(sent[0]["params"]?["context"]?["arguments"]?["locale"]?.stringValue == "en")
}

@Test func mcpClientRetriesTransientToolCallFailuresLikeUpstreamV2() async throws {
    let transport = MockMCPTransport(
        capabilities: fullMCPCapabilities(),
        transientToolFailures: 1
    )
    let client = try await MCPClient.connect(transport: transport, maxRetries: 1)

    let result = try await client.callTool(name: "search", arguments: ["query": "retry"])
    #expect(result.content.first?["text"]?.stringValue == "Result for retry")

    let sent = await transport.sentMessages()
    #expect(sent.map { $0["method"]?.stringValue } == [
        "initialize",
        "notifications/initialized",
        "tools/call",
        "tools/call"
    ])
}

@Test func mcpToolModelOutputConvertsImagesAndUnknownContent() async throws {
    let transport = MockMCPTransport(
        capabilities: fullMCPCapabilities(),
        toolResult: [
            "content": [
                [
                    "type": "image",
                    "data": "aW1hZ2U=",
                    "mimeType": "image/png"
                ],
                [
                    "type": "custom",
                    "data": ["foo": "bar"]
                ]
            ]
        ]
    )
    let client = try await MCPClient.connect(transport: transport)
    let tool = try await #require(client.tools()["search"])
    let result = try await tool.execute(["query": "image"])

    let modelOutput = try await #require(tool.toModelOutput?(
        AIToolModelOutputContext(toolCallID: "call-1", input: ["query": "image"], output: result)
    ))
    #expect(modelOutput["type"]?.stringValue == "content")
    #expect(modelOutput["value"]?[0]?["type"]?.stringValue == "file")
    #expect(modelOutput["value"]?[0]?["mediaType"]?.stringValue == "image/png")
    #expect(modelOutput["value"]?[0]?["data"]?["type"]?.stringValue == "data")
    #expect(modelOutput["value"]?[0]?["data"]?["data"]?.stringValue == "aW1hZ2U=")
    #expect(modelOutput["value"]?[1]?["type"]?.stringValue == "text")
    #expect(modelOutput["value"]?[1]?["text"]?.stringValue?.contains("\"custom\"") == true)
}
@Test func mcpToolModelOutputNormalizesStructuredContentToText() async throws {
    let transport = MockMCPTransport(
        capabilities: fullMCPCapabilities(),
        toolResult: ["structuredContent": ["ok": true]]
    )
    let client = try await MCPClient.connect(transport: transport)
    let tool = try await #require(client.tools()["search"])
    let result = try await tool.execute(["query": "json"])

    let modelOutput = try await #require(tool.toModelOutput?(
        AIToolModelOutputContext(toolCallID: "call-1", input: ["query": "json"], output: result)
    ))
    #expect(modelOutput["type"]?.stringValue == "content")
    #expect(modelOutput["value"]?[0]?["type"]?.stringValue == "text")
    #expect(modelOutput["value"]?[0]?["text"]?.stringValue == #"{"ok":true}"#)
}

@Test func mcpAppsHelpersMirrorUpstreamV2MetadataAndResources() throws {
    let definitions = MCPListToolsResult(tools: [
        MCPToolDefinition(
            name: "model_search",
            inputSchema: ["type": "object"],
            metadata: [
                "ui": [
                    "resourceUri": "ui://app/search.html",
                    "visibility": ["model", "app"],
                    "theme": "dark"
                ]
            ]
        ),
        MCPToolDefinition(
            name: "app_only",
            inputSchema: ["type": "object"],
            metadata: [
                "ui": [
                    "resourceUri": "ui://app/panel.html",
                    "visibility": ["app"]
                ]
            ]
        ),
        MCPToolDefinition(
            name: "legacy",
            inputSchema: ["type": "object"],
            metadata: [
                "ui/resourceUri": "ui://app/legacy.html"
            ]
        )
    ])

    let maybeMeta = try MCPApps.toolMeta(from: definitions.tools[0])
    let meta = try #require(maybeMeta)
    #expect(meta.resourceURI == "ui://app/search.html")
    #expect(meta.visibility == [.model, .app])
    #expect(try MCPApps.resourceURIs(from: definitions) == [
        "ui://app/search.html",
        "ui://app/panel.html",
        "ui://app/legacy.html"
    ])

    let split = try MCPApps.splitTools(definitions)
    #expect(split.modelVisible.tools.map(\.name) == ["model_search", "legacy"])
    #expect(split.appVisible.tools.map(\.name) == ["model_search", "app_only"])

    let html = "<main>Hello</main>"
    let read = MCPReadResourceResult(contents: [
        MCPResourceContent(
            uri: "ui://app/search.html",
            mimeType: MCPApps.appMIMEType,
            text: html,
            rawValue: [
                "uri": "ui://app/search.html",
                "mimeType": .string(MCPApps.appMIMEType),
                "text": .string(html),
                "_meta": [
                    "ui": [
                        "prefersBorder": true,
                        "permissions": ["clipboard": true]
                    ]
                ]
            ]
        )
    ])
    let resource = try MCPApps.resource(uri: "ui://app/search.html", from: read)
    #expect(resource.html == html)
    #expect(resource.mimeType == MCPApps.appMIMEType)
    #expect(resource.metadata?["prefersBorder"]?.boolValue == true)
    #expect(MCPApps.clientCapabilities["extensions"]?[MCPApps.extensionName]?["mimeTypes"]?[0]?.stringValue == MCPApps.appMIMEType)
}

@Test func mcpClientCreatesToolsFromCachedDefinitionsWithoutListingAgain() async throws {
    let transport = MockMCPTransport()
    let client = try await MCPClient.connect(transport: transport)
    let definitions = try await client.listTools()
    await transport.reset()

    let tools = await client.toolsFromDefinitions(definitions)
    let search = try #require(tools["search"])
    _ = try await search.execute(["query": "cached"])

    let sent = await transport.sentMessages()
    #expect(sent.map { $0["method"]?.stringValue } == ["tools/call"])
}
@Test func mcpDynamicToolHonorsAbortedExecutionContextBeforeToolCall() async throws {
    let transport = MockMCPTransport()
    let client = try await MCPClient.connect(transport: transport)
    let search = try await #require(client.tools()["search"])
    await transport.reset()
    let controller = AIAbortController()
    controller.abort(reason: "user cancelled")

    do {
        _ = try await search.executeWithContext(
            ["query": "cancelled"],
            AIToolExecutionContext(toolCallID: "call-1", abortSignal: controller.signal)
        )
        Issue.record("Expected aborted MCP tool execution to throw.")
    } catch let error as AIAbortError {
        #expect(error.reason == "user cancelled")
    }

    let sent = await transport.sentMessages()
    #expect(sent.isEmpty)
}
@Test func mcpClientRejectsToolCallsWhenServerHasNoToolCapability() async throws {
    let transport = MockMCPTransport(capabilities: .object([:]))
    let client = try await MCPClient.connect(transport: transport)

    do {
        _ = try await client.listTools()
        Issue.record("Expected missing tool capability to throw.")
    } catch let error as MCPClientError {
        #expect(error.description.contains("does not support tools"))
    }
}
@Test func mcpHTTPTransportForwardsAbortSignalToRequests() async throws {
    let controller = AIAbortController()
    let http = RecordingTransport(response: jsonResponse(#"{"jsonrpc":"2.0","id":7,"result":{}}"#))
    let transport = try MCPHTTPTransport(url: "https://mcp.example.com/rpc", transport: http)

    _ = try await transport.request(
        [
            "jsonrpc": "2.0",
            "id": 7,
            "method": "ping"
        ],
        options: MCPRequestOptions(abortSignal: controller.signal)
    )

    let request = try #require(await http.requests().first)
    #expect(request.abortSignal === controller.signal)
}
@Test func mcpClientListsReadsResourcesAndTemplates() async throws {
    let transport = MockMCPTransport(capabilities: fullMCPCapabilities())
    let client = try await MCPClient.connect(transport: transport)

    let resources = try await client.listResources(cursor: "cursor-1")
    #expect(resources.nextCursor == "cursor-2")
    #expect(resources.resources.first?.uri == "file:///docs/intro.md")
    #expect(resources.resources.first?.title == "Intro")
    #expect(resources.resources.first?.mimeType == "text/markdown")

    let content = try await client.readResource(uri: "file:///docs/intro.md")
    #expect(content.contents.first?.text == "# Intro")
    #expect(content.contents.first?.mimeType == "text/markdown")

    let templates = try await client.listResourceTemplates()
    #expect(templates.resourceTemplates.first?.uriTemplate == "file:///docs/{slug}.md")
    #expect(templates.resourceTemplates.first?.name == "doc")

    let sent = await transport.sentMessages()
    #expect(sent.map { $0["method"]?.stringValue } == [
        "initialize",
        "notifications/initialized",
        "resources/list",
        "resources/read",
        "resources/templates/list"
    ])
    #expect(sent[2]["params"]?["cursor"]?.stringValue == "cursor-1")
    #expect(sent[3]["params"]?["uri"]?.stringValue == "file:///docs/intro.md")
}
@Test func mcpClientListsAndGetsPrompts() async throws {
    let transport = MockMCPTransport(capabilities: fullMCPCapabilities())
    let client = try await MCPClient.connect(transport: transport)

    let prompts = try await client.experimentalListPrompts(cursor: "prompt-cursor")
    #expect(prompts.nextCursor == "prompt-cursor-2")
    #expect(prompts.prompts.first?.name == "summarize")
    #expect(prompts.prompts.first?.arguments.first?.name == "topic")
    #expect(prompts.prompts.first?.arguments.first?.required == true)

    let prompt = try await client.experimentalGetPrompt(name: "summarize", arguments: ["topic": "Swift"])
    #expect(prompt.description == "Summarize a topic.")
    #expect(prompt.messages.first?.role == "user")
    #expect(prompt.messages.first?.content["text"]?.stringValue == "Summarize Swift")

    let sent = await transport.sentMessages()
    #expect(sent.map { $0["method"]?.stringValue } == [
        "initialize",
        "notifications/initialized",
        "prompts/list",
        "prompts/get"
    ])
    #expect(sent[2]["params"]?["cursor"]?.stringValue == "prompt-cursor")
    #expect(sent[3]["params"]?["name"]?.stringValue == "summarize")
    #expect(sent[3]["params"]?["arguments"]?["topic"]?.stringValue == "Swift")
}
@Test func mcpClientHandlesElicitationRequests() async throws {
    let transport = MockMCPTransport(capabilities: fullMCPCapabilities())
    let client = try await MCPClient.connect(
        transport: transport,
        clientCapabilities: .object(["elicitation": .object(["applyDefaults": .bool(true)])])
    )
    let recorder = MCPElicitationRecorder()
    await client.onElicitationRequest { request in
        await recorder.record(request)
        return MCPElicitResult(
            action: .accept,
            content: ["city": .string("Tokyo"), "days": .number(3)]
        )
    }

    let response = await transport.simulateIncomingRequest([
        "jsonrpc": "2.0",
        "id": 99,
        "method": "elicitation/create",
        "params": [
            "message": "Choose travel settings.",
            "requestedSchema": [
                "type": "object",
                "properties": [
                    "city": ["type": "string"],
                    "days": ["type": "integer"]
                ],
                "required": ["city"]
            ],
            "_meta": ["trace": "elicitation"]
        ]
    ])

    let request = try await #require(recorder.request())
    #expect(request.message == "Choose travel settings.")
    #expect(request.requestedSchema["properties"]?["city"]?["type"]?.stringValue == "string")
    #expect(request.metadata?["trace"]?.stringValue == "elicitation")
    #expect(response["id"]?.intValue == 99)
    #expect(response["result"]?["action"]?.stringValue == "accept")
    #expect(response["result"]?["content"]?["city"]?.stringValue == "Tokyo")
    #expect(response["result"]?["content"]?["days"]?.intValue == 3)

    let sent = await transport.sentMessages()
    #expect(sent[0]["params"]?["capabilities"]?["elicitation"]?["applyDefaults"]?.boolValue == true)
}
@Test func mcpClientRejectsElicitationWithoutHandler() async throws {
    let transport = MockMCPTransport(capabilities: fullMCPCapabilities())
    let client = try await MCPClient.connect(
        transport: transport,
        clientCapabilities: .object(["elicitation": .object([:])])
    )
    _ = await client.serverInfo

    let response = await transport.simulateIncomingRequest([
        "jsonrpc": "2.0",
        "id": 7,
        "method": "elicitation/create",
        "params": [
            "message": "Need input.",
            "requestedSchema": ["type": "object"]
        ]
    ])

    #expect(response["error"]?["code"]?.intValue == -32601)
    #expect(response["error"]?["message"]?.stringValue == "No elicitation handler registered on client")
}
@Test func mcpClientHandlesPingAndUnsupportedIncomingRequests() async throws {
    let transport = MockMCPTransport(capabilities: fullMCPCapabilities())
    let client = try await MCPClient.connect(transport: transport)
    _ = await client.serverInfo

    let ping = await transport.simulateIncomingRequest([
        "jsonrpc": "2.0",
        "id": 1,
        "method": "ping"
    ])
    #expect(ping["result"]?.objectValue?.isEmpty == true)

    let unsupported = await transport.simulateIncomingRequest([
        "jsonrpc": "2.0",
        "id": 2,
        "method": "sampling/createMessage"
    ])
    #expect(unsupported["error"]?["code"]?.intValue == -32601)
    #expect(unsupported["error"]?["message"]?.stringValue == "Unsupported request method: sampling/createMessage")
}
@Test func mcpClientRejectsInvalidElicitationRequest() async throws {
    let transport = MockMCPTransport(capabilities: fullMCPCapabilities())
    let client = try await MCPClient.connect(
        transport: transport,
        clientCapabilities: .object(["elicitation": .object([:])])
    )
    await client.onElicitationRequest { _ in
        MCPElicitResult(action: .decline)
    }

    let response = await transport.simulateIncomingRequest([
        "jsonrpc": "2.0",
        "id": 8,
        "method": "elicitation/create",
        "params": [
            "requestedSchema": ["type": "object"]
        ]
    ])

    #expect(response["error"]?["code"]?.intValue == -32602)
    #expect(response["error"]?["message"]?.stringValue?.contains("message and requestedSchema") == true)
}
@Test func mcpClientRejectsResourcesWhenServerHasNoResourceCapability() async throws {
    let transport = MockMCPTransport(capabilities: .object(["tools": .object([:])]))
    let client = try await MCPClient.connect(transport: transport)

    do {
        _ = try await client.listResources()
        Issue.record("Expected missing resource capability to throw.")
    } catch let error as MCPClientError {
        #expect(error.description.contains("does not support resources"))
    }
}
@Test func mcpOAuthChallengeRejectsRelativeResourceMetadataURLLikeUpstream() {
    let parameters = mcpOAuthWWWAuthenticateParameters(from: [
        "WWW-Authenticate": #"Bearer resource_metadata="/oauth/protected-resource", scope="tools:read""#
    ])

    #expect(parameters.resourceMetadataURL == nil)
    #expect(parameters.scope == "tools:read")
}
@Test func mcpHTTPTransportPostsJSONRPCMessages() async throws {
    let http = RecordingTransport(responses: [
        jsonResponse(#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#),
        AIHTTPResponse(statusCode: 202)
    ])
    let transport = try MCPHTTPTransport(url: "https://mcp.example.com/rpc", headers: ["authorization": "Bearer token"], transport: http)

    let response = try await transport.request([
        "jsonrpc": "2.0",
        "id": 7,
        "method": "ping"
    ])
    try await transport.notify([
        "jsonrpc": "2.0",
        "method": "notifications/initialized"
    ])

    #expect(response["result"]?["ok"]?.boolValue == true)
    let requests = await http.requests()
    let request = try #require(requests.first)
    #expect(request.method == "POST")
    #expect(request.url.absoluteString == "https://mcp.example.com/rpc")
    #expect(request.headers["authorization"] == "Bearer token")
    #expect(request.headers["accept"] == "application/json, text/event-stream")
    #expect(request.headers["mcp-protocol-version"] == MCPClient.latestLegacyProtocolVersion)
    let body = try #require(request.body).jsonValueForTest()
    #expect(body["method"]?.stringValue == "ping")
    #expect(requests.count == 2)
}
@Test func mcpHTTPTransportAuthorizesAndRetriesAfter401() async throws {
    let auth = MockMCPOAuthProvider(initialToken: "old-token", authorizedToken: "new-token")
    let http = RecordingTransport(responses: [
        AIHTTPResponse(
            statusCode: 401,
            headers: ["WWW-Authenticate": #"Bearer resource_metadata="https://auth.example.com/.well-known/oauth-protected-resource", scope="tools:read tools:write""#],
            body: Data("Unauthorized".utf8)
        ),
        jsonResponse(#"{"jsonrpc":"2.0","id":12,"result":{"ok":true}}"#)
    ])
    let transport = try MCPHTTPTransport(
        url: "https://mcp.example.com/rpc",
        transport: http,
        authProvider: auth
    )

    let response = try await transport.request([
        "jsonrpc": "2.0",
        "id": 12,
        "method": "ping"
    ])

    #expect(response["result"]?["ok"]?.boolValue == true)
    let requests = await http.requests()
    #expect(requests.count == 2)
    #expect(requests[0].headers["authorization"] == "Bearer old-token")
    #expect(requests[1].headers["authorization"] == "Bearer new-token")
    #expect(await auth.invalidatedScopes() == [.tokens])
    #expect(await auth.resourceMetadataURLs().map(\.absoluteString) == ["https://auth.example.com/.well-known/oauth-protected-resource"])
    #expect(await auth.scopes() == ["tools:read tools:write"])
}
@Test func mcpHTTPTransportStreamingAuthorizesAndRetriesAfter401() async throws {
    let auth = MockMCPOAuthProvider(initialToken: "old-stream-token", authorizedToken: "new-stream-token")
    let http = StreamingRecordingTransport(responses: [
        streamResponse(
            statusCode: 401,
            headers: ["www-authenticate": #"Bearer scope="stream:read", resource_metadata="https://auth.example.com/resource""#],
            chunks: ["Unauthorized"]
        ),
        streamResponse(
            headers: ["content-type": "application/json"],
            chunks: [#"{"jsonrpc":"2.0","id":13,"result":{"ok":true}}"#]
        )
    ])
    let transport = try MCPHTTPTransport(
        url: "https://mcp.example.com/rpc",
        transport: http,
        authProvider: auth
    )

    let response = try await transport.request([
        "jsonrpc": "2.0",
        "id": 13,
        "method": "ping"
    ])

    #expect(response["result"]?["ok"]?.boolValue == true)
    let requests = await http.requests()
    #expect(requests.count == 2)
    #expect(requests[0].headers["authorization"] == "Bearer old-stream-token")
    #expect(requests[1].headers["authorization"] == "Bearer new-stream-token")
    #expect(await auth.resourceMetadataURLs().map(\.absoluteString) == ["https://auth.example.com/resource"])
    #expect(await auth.scopes() == ["stream:read"])
}
@Test func mcpHTTPTransportParsesSSEResponsesAndTerminatesSession() async throws {
    let http = RecordingTransport(responses: [
        AIHTTPResponse(
            statusCode: 200,
            headers: [
                "content-type": "text/event-stream",
                "mcp-session-id": "session-1"
            ],
            body: Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true}}\n\n".utf8)
        ),
        AIHTTPResponse(statusCode: 200)
    ])
    let transport = try MCPHTTPTransport(url: "https://mcp.example.com/rpc", transport: http)

    let response = try await transport.request([
        "jsonrpc": "2.0",
        "id": 3,
        "method": "initialize",
        "params": [:]
    ])
    try await transport.close()

    #expect(response["result"]?["ok"]?.boolValue == true)
    let requests = await http.requests()
    #expect(requests.count == 2)
    #expect(requests[1].method == "DELETE")
    #expect(requests[1].headers["mcp-session-id"] == "session-1")
}

@Test func mcpHTTPTransportSupportsSessionResumeCallbacksAndNoTerminateLikeUpstreamV2() async throws {
    let recorder = MCPSessionRecorder()
    let http = RecordingTransport(responses: [
        jsonResponse(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#, headers: ["mcp-session-id": "session-2"]),
        AIHTTPResponse(statusCode: 404, body: Data("expired".utf8))
    ])
    let transport = try MCPHTTPTransport(
        url: "https://mcp.example.com/rpc",
        transport: http,
        initialSessionID: "session-1",
        initialProtocolVersion: "2025-06-18",
        terminateSessionOnClose: false,
        onSessionIDChange: { sessionID in
            Task { await recorder.recordChange(sessionID) }
        },
        onSessionExpired: { sessionID in
            Task { await recorder.recordExpiration(sessionID) }
        }
    )

    _ = try await transport.request([
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [:]
    ])

    do {
        _ = try await transport.request([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "ping"
        ])
        Issue.record("Expected expired MCP session request to throw.")
    } catch let error as MCPClientError {
        #expect(error.statusCode == 404)
        #expect(error.message.contains("session expired"))
    }

    try await transport.close()
    try await Task.sleep(nanoseconds: 20_000_000)

    let requests = await http.requests()
    #expect(requests.count == 2)
    #expect(requests[0].headers["mcp-session-id"] == nil)
    #expect(requests[0].headers["mcp-protocol-version"] == "2025-06-18")
    #expect(requests[1].headers["mcp-session-id"] == "session-2")
    #expect(await recorder.changedSessionIDs().compactMap { $0 } == ["session-2"])
    #expect(await recorder.expiredSessionIDs() == ["session-2"])
}
