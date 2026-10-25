@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

actor MockMCPTransport: MCPTransport {
    private var messages: [JSONValue] = []
    private let capabilities: JSONValue
    private let toolResult: JSONValue?
    private var transientToolFailuresRemaining: Int
    private var requestHandler: (@Sendable (JSONValue) async -> JSONValue)?

    init(
        capabilities: JSONValue = .object(["tools": .object(["listChanged": .bool(false)])]),
        toolResult: JSONValue? = nil,
        transientToolFailures: Int = 0
    ) {
        self.capabilities = capabilities
        self.toolResult = toolResult
        self.transientToolFailuresRemaining = transientToolFailures
    }

    func setRequestHandler(_ handler: (@Sendable (JSONValue) async -> JSONValue)?) async {
        requestHandler = handler
    }

    func start() async throws {}

    func request(_ message: JSONValue) async throws -> JSONValue {
        messages.append(message)
        let id = message["id"] ?? .number(0)
        switch message["method"]?.stringValue {
        case "initialize":
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "protocolVersion": .string(MCPClient.latestLegacyProtocolVersion),
                    "capabilities": capabilities,
                    "serverInfo": [
                        "name": "mock-server",
                        "version": "0.1.0"
                    ],
                    "instructions": "Use these mock tools carefully."
                ]
            ]
        case "tools/list":
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "tools": [
                        [
                            "name": "search",
                            "title": "Search",
                            "description": "Search documents",
                            "inputSchema": [
                                "type": "object",
                                "properties": [
                                    "query": ["type": "string"]
                                ]
                            ],
                            "_meta": [
                                "source": "mock"
                            ]
                        ]
                    ]
                ]
            ]
        case "tools/call":
            if transientToolFailuresRemaining > 0 {
                transientToolFailuresRemaining -= 1
                throw MCPClientError(message: "MCP HTTP Transport Error: POST failed with HTTP 503", statusCode: 503)
            }
            let query = message["params"]?["arguments"]?["query"]?.stringValue ?? ""
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": toolResult ?? [
                    "content": [
                        [
                            "type": "text",
                            "text": .string("Result for \(query)")
                        ]
                    ],
                    "isError": false
                ]
            ]
        case "completion/complete":
            let value = message["params"]?["argument"]?["value"]?.stringValue ?? ""
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "completion": [
                        "values": [
                            .string("\(value)-one"),
                            .string("\(value)-two")
                        ],
                        "total": 2,
                        "hasMore": false
                    ]
                ]
            ]
        case "resources/list":
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "nextCursor": "cursor-2",
                    "resources": [
                        [
                            "uri": "file:///docs/intro.md",
                            "name": "intro",
                            "title": "Intro",
                            "description": "Intro docs",
                            "mimeType": "text/markdown",
                            "size": 128
                        ]
                    ]
                ]
            ]
        case "resources/read":
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "contents": [
                        [
                            "uri": "file:///docs/intro.md",
                            "mimeType": "text/markdown",
                            "text": "# Intro"
                        ]
                    ]
                ]
            ]
        case "resources/templates/list":
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "resourceTemplates": [
                        [
                            "uriTemplate": "file:///docs/{slug}.md",
                            "name": "doc",
                            "title": "Doc",
                            "description": "Documentation page",
                            "mimeType": "text/markdown"
                        ]
                    ]
                ]
            ]
        case "prompts/list":
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "nextCursor": "prompt-cursor-2",
                    "prompts": [
                        [
                            "name": "summarize",
                            "title": "Summarize",
                            "description": "Summarize a topic.",
                            "arguments": [
                                [
                                    "name": "topic",
                                    "description": "Topic to summarize",
                                    "required": true
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        case "prompts/get":
            let topic = message["params"]?["arguments"]?["topic"]?.stringValue ?? "topic"
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "description": "Summarize a topic.",
                    "messages": [
                        [
                            "role": "user",
                            "content": [
                                "type": "text",
                                "text": .string("Summarize \(topic)")
                            ]
                        ]
                    ]
                ]
            ]
        default:
            return [
                "jsonrpc": "2.0",
                "id": id,
                "error": [
                    "code": -32601,
                    "message": "Unknown method"
                ]
            ]
        }
    }

    func notify(_ message: JSONValue) async throws {
        messages.append(message)
    }

    func close() async throws {}

    func sentMessages() -> [JSONValue] {
        messages
    }

    func reset() {
        messages = []
    }

    func simulateIncomingRequest(_ request: JSONValue) async -> JSONValue {
        guard let requestHandler else {
            return [
                "jsonrpc": "2.0",
                "id": request["id"] ?? .null,
                "error": [
                    "code": -32603,
                    "message": "No request handler registered."
                ]
            ]
        }
        return await requestHandler(request)
    }
}
func fullMCPCapabilities() -> JSONValue {
    .object([
        "tools": .object(["listChanged": .bool(false)]),
        "resources": .object(["listChanged": .bool(false)]),
        "prompts": .object(["listChanged": .bool(false)]),
        "completions": .object([:]),
        "elicitation": .object(["applyDefaults": .bool(true)])
    ])
}
actor MCPElicitationRecorder {
    private var recordedRequest: MCPElicitationRequest?

    func record(_ request: MCPElicitationRequest) {
        recordedRequest = request
    }

    func request() -> MCPElicitationRequest? {
        recordedRequest
    }
}

actor MCPSessionRecorder {
    private var changes: [String?] = []
    private var expirations: [String] = []

    func recordChange(_ sessionID: String?) {
        changes.append(sessionID)
    }

    func recordExpiration(_ sessionID: String) {
        expirations.append(sessionID)
    }

    func changedSessionIDs() -> [String?] {
        changes
    }

    func expiredSessionIDs() -> [String] {
        expirations
    }
}

actor MockMCPOAuthProvider: MCPOAuthProvider {
    private var token: String?
    private let authorizedToken: String?
    private var metadataURLs: [URL] = []
    private var authorizationScopes: [String?] = []
    private var invalidations: [MCPOAuthCredentialScope] = []

    init(initialToken: String?, authorizedToken: String?) {
        self.token = initialToken
        self.authorizedToken = authorizedToken
    }

    func accessToken() async throws -> String? {
        token
    }

    func authorize(resourceMetadataURL: URL?) async throws -> Bool {
        try await authorize(resourceMetadataURL: resourceMetadataURL, scope: nil)
    }

    func authorize(resourceMetadataURL: URL?, scope: String?) async throws -> Bool {
        if let resourceMetadataURL {
            metadataURLs.append(resourceMetadataURL)
        }
        authorizationScopes.append(scope)
        token = authorizedToken
        return authorizedToken != nil
    }

    func invalidateCredentials(_ scope: MCPOAuthCredentialScope) async {
        invalidations.append(scope)
    }

    func resourceMetadataURLs() -> [URL] {
        metadataURLs
    }

    func scopes() -> [String?] {
        authorizationScopes
    }

    func invalidatedScopes() -> [MCPOAuthCredentialScope] {
        invalidations
    }
}
actor StreamingRecordingTransport: AIStreamingTransport {
    private var recordedRequests: [AIHTTPRequest] = []
    private var responses: [AIHTTPStreamResponse]

    init(responses: [AIHTTPStreamResponse]) {
        self.responses = responses
    }

    func requests() -> [AIHTTPRequest] {
        recordedRequests
    }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        let response = try await stream(request)
        var body = Data()
        for try await chunk in response.body {
            body.append(chunk)
        }
        return AIHTTPResponse(statusCode: response.statusCode, headers: response.headers, body: body)
    }

    func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        recordedRequests.append(request)
        guard !responses.isEmpty else {
            return streamResponse(statusCode: 202)
        }
        return responses.removeFirst()
    }
}
func streamResponse(
    statusCode: Int = 200,
    headers: [String: String] = [:],
    chunks: [String] = [],
    finishes: Bool = true,
    errorAfterChunks: Error? = nil
) -> AIHTTPStreamResponse {
    AIHTTPStreamResponse(
        statusCode: statusCode,
        headers: headers,
        body: AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in chunks {
                    try Task.checkCancellation()
                    continuation.yield(Data(chunk.utf8))
                }
                if let errorAfterChunks {
                    continuation.finish(throwing: errorAfterChunks)
                    return
                }
                if finishes {
                    continuation.finish()
                } else {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    )
}
struct TestStreamFailure: Error {}
extension Data {
    func jsonValueForTest() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: self)
    }
}
func waitForRecordedRequests(_ transport: RecordingTransport, count: Int) async throws -> [AIHTTPRequest] {
    for _ in 0..<50 {
        let requests = await transport.requests()
        if requests.count >= count {
            return requests
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return await transport.requests()
}
func waitForStreamingRequests(_ transport: StreamingRecordingTransport, count: Int) async throws -> [AIHTTPRequest] {
    for _ in 0..<50 {
        let requests = await transport.requests()
        if requests.count >= count {
            return requests
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return await transport.requests()
}
