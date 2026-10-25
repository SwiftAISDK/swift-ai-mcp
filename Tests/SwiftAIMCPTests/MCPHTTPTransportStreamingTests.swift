@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Test func mcpHTTPTransportRejectsUnsuccessfulPOSTSSEResponsesWithHTTPDetailsLikeUpstream() async throws {
    let http = StreamingRecordingTransport(responses: [
        streamResponse(
            statusCode: 500,
            headers: ["content-type": "text/plain"],
            chunks: ["Internal Server Error"]
        )
    ])
    let transport = try MCPHTTPTransport(
        url: "https://mcp.example.com/messages",
        transport: http
    )

    do {
        _ = try await transport.request([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        ])
        Issue.record("Expected the unsuccessful MCP POST response to reject.")
    } catch let error as MCPClientError {
        #expect(error.message == "MCP HTTP Transport Error: POST https://mcp.example.com/messages failed with HTTP 500: Internal Server Error")
        #expect(error.statusCode == 500)
        #expect(error.url == "https://mcp.example.com/messages")
        #expect(error.responseBody == "Internal Server Error")
    }

    let requests = await http.requests()
    #expect(requests.count == 1)
    #expect(requests[0].method == "POST")
    #expect(requests[0].headers["accept"] == "application/json, text/event-stream")
}

@Test func mcpHTTPTransportStartHandlesBufferedInboundSSERequests() async throws {
    let http = RecordingTransport(responses: [
        AIHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "text/event-stream"],
            body: Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"ping\"}\n\n".utf8)
        ),
        AIHTTPResponse(statusCode: 202)
    ])
    let transport = try MCPHTTPTransport(url: "https://mcp.example.com/rpc", transport: http)
    await transport.setRequestHandler { request in
        [
            "jsonrpc": "2.0",
            "id": request["id"] ?? .null,
            "result": [:]
        ]
    }

    try await transport.start()

    let requests = try await waitForRecordedRequests(http, count: 2)
    #expect(requests.count == 2)
    #expect(requests[0].method == "GET")
    #expect(requests[0].headers["accept"] == "text/event-stream")
    #expect(requests[1].method == "POST")
    let body = try #require(requests[1].body).jsonValueForTest()
    #expect(body["id"]?.intValue == 11)
    #expect(body["result"]?.objectValue?.isEmpty == true)
}
@Test func mcpHTTPTransportStreamsPOSTSSEResponseBeforeStreamEnds() async throws {
    let http = StreamingRecordingTransport(responses: [
        streamResponse(
            headers: ["content-type": "text/event-stream"],
            chunks: ["event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"ok\":true}}\n\n"],
            finishes: false
        )
    ])
    let transport = try MCPHTTPTransport(url: "https://mcp.example.com/rpc", transport: http)

    let response = try await transport.request([
        "jsonrpc": "2.0",
        "id": 4,
        "method": "initialize",
        "params": [:]
    ])

    #expect(response["result"]?["ok"]?.boolValue == true)
    let requests = await http.requests()
    #expect(requests.count == 1)
    #expect(requests[0].method == "POST")
    #expect(requests[0].headers["accept"] == "application/json, text/event-stream")
}
@Test func mcpHTTPTransportUsesSharedSSEGrammarAcrossUTF8ByteChunksAndBareCR() async throws {
    let payload = Data("\u{FEFF}: ping\rid: cursor-jp\revent: message\rdata: {\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"text\":\"こんにちは 👋\"}}\r\r".utf8)
    let response = AIHTTPStreamResponse(
        statusCode: 200,
        headers: ["content-type": "text/event-stream"],
        body: AsyncThrowingStream { continuation in
            let task = Task {
                for byte in payload {
                    try Task.checkCancellation()
                    continuation.yield(Data([byte]))
                }
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    )
    let http = StreamingRecordingTransport(responses: [response])
    let transport = try MCPHTTPTransport(url: "https://mcp.example.com/rpc", transport: http)

    let result = try await transport.request([
        "jsonrpc": "2.0",
        "id": 5,
        "method": "initialize",
        "params": [:]
    ])

    #expect(result["result"]?["text"]?.stringValue == "こんにちは 👋")
}
@Test func mcpHTTPTransportUsesStreamingInboundSSEWithoutBlockingStart() async throws {
    let http = StreamingRecordingTransport(responses: [
        streamResponse(
            headers: ["content-type": "text/event-stream"],
            chunks: ["event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"ping\"}\n\n"],
            finishes: false
        ),
        streamResponse(statusCode: 202)
    ])
    let transport = try MCPHTTPTransport(url: "https://mcp.example.com/rpc", transport: http)
    await transport.setRequestHandler { request in
        [
            "jsonrpc": "2.0",
            "id": request["id"] ?? .null,
            "result": [:]
        ]
    }

    try await transport.start()

    let requests = try await waitForStreamingRequests(http, count: 2)
    #expect(requests[0].method == "GET")
    #expect(requests[0].headers["accept"] == "text/event-stream")
    #expect(requests[1].method == "POST")
    let body = try #require(requests[1].body).jsonValueForTest()
    #expect(body["id"]?.intValue == 21)
    #expect(body["result"]?.objectValue?.isEmpty == true)

    try await transport.close()
}
@Test func mcpHTTPTransportReconnectsInboundSSEWithLastEventID() async throws {
    let http = StreamingRecordingTransport(responses: [
        streamResponse(
            headers: ["content-type": "text/event-stream"],
            chunks: ["id: cursor-1\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"ping\"}\n\n"],
            errorAfterChunks: TestStreamFailure()
        ),
        streamResponse(statusCode: 202),
        streamResponse(
            headers: ["content-type": "text/event-stream"],
            chunks: [],
            finishes: false
        )
    ])
    let transport = try MCPHTTPTransport(
        url: "https://mcp.example.com/rpc",
        transport: http,
        inboundReconnectDelayNanoseconds: 1_000_000
    )
    await transport.setRequestHandler { request in
        [
            "jsonrpc": "2.0",
            "id": request["id"] ?? .null,
            "result": [:]
        ]
    }

    try await transport.start()

    let requests = try await waitForStreamingRequests(http, count: 3)
    #expect(requests[0].method == "GET")
    #expect(requests[1].method == "POST")
    #expect(requests[2].method == "GET")
    #expect(requests[2].headers["last-event-id"] == "cursor-1")

    try await transport.close()
}

@Test(arguments: [WeeklyMCP401Timing.simultaneous, .afterSave])
func mcpHTTPTransportSharesOneRefreshForConcurrentAndLateStale401s(
    _ timing: WeeklyMCP401Timing
) async throws {
    let bothOldRequestsStarted = WeeklyMCPAsyncLatch()
    let refreshSaved = WeeklyMCPAsyncLatch()
    let http = WeeklyMCP401RaceTransport(
        timing: timing,
        bothOldRequestsStarted: bothOldRequestsStarted,
        refreshSaved: refreshSaved
    )
    let auth = WeeklyMCPRaceOAuthProvider(
        timing: timing,
        refreshSaved: refreshSaved
    )
    let transport = try MCPHTTPTransport(
        url: "https://mcp.example.com/rpc",
        transport: http,
        authProvider: auth
    )

    async let first = transport.request([
        "jsonrpc": "2.0",
        "id": 1,
        "method": "resources/list"
    ])
    async let second = transport.request([
        "jsonrpc": "2.0",
        "id": 2,
        "method": "resources/list"
    ])
    let firstResult = try await first
    let secondResult = try await second

    #expect(firstResult["result"]?["ok"]?.boolValue == true)
    #expect(secondResult["result"]?["ok"]?.boolValue == true)
    #expect(await auth.authorizationCount() == 1)
    #expect(await auth.invalidationCount() == 1)
    #expect(await http.oldTokenRequestCount() == 2)
    #expect(await http.refreshedTokenRequestCount() == 2)
}

enum WeeklyMCP401Timing: Sendable {
    case simultaneous
    case afterSave
}

private actor WeeklyMCPAsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor WeeklyMCPRaceOAuthProvider: MCPOAuthProvider {
    private let timing: WeeklyMCP401Timing
    private let refreshSaved: WeeklyMCPAsyncLatch
    private var token: String? = "access-old"
    private var authorizations = 0
    private var invalidations = 0

    init(timing: WeeklyMCP401Timing, refreshSaved: WeeklyMCPAsyncLatch) {
        self.timing = timing
        self.refreshSaved = refreshSaved
    }

    func accessToken() -> String? {
        token
    }

    func authorize(resourceMetadataURL: URL?) async throws -> Bool {
        authorizations += 1
        if timing == .simultaneous {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        token = "access-new"
        await refreshSaved.open()
        return true
    }

    func invalidateCredentials(_ scope: MCPOAuthCredentialScope) {
        invalidations += 1
        if scope == .all || scope == .tokens {
            token = nil
        }
    }

    func authorizationCount() -> Int { authorizations }
    func invalidationCount() -> Int { invalidations }
}

private actor WeeklyMCP401RaceTransport: AITransport {
    private let timing: WeeklyMCP401Timing
    private let bothOldRequestsStarted: WeeklyMCPAsyncLatch
    private let refreshSaved: WeeklyMCPAsyncLatch
    private var oldRequests = 0
    private var refreshedRequests = 0

    init(
        timing: WeeklyMCP401Timing,
        bothOldRequestsStarted: WeeklyMCPAsyncLatch,
        refreshSaved: WeeklyMCPAsyncLatch
    ) {
        self.timing = timing
        self.bothOldRequestsStarted = bothOldRequestsStarted
        self.refreshSaved = refreshSaved
    }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        let authorization = request.headers.first {
            $0.key.caseInsensitiveCompare("authorization") == .orderedSame
        }?.value

        if authorization == "Bearer access-old" {
            oldRequests += 1
            let requestNumber = oldRequests
            if oldRequests == 2 {
                await bothOldRequestsStarted.open()
            }
            switch timing {
            case .simultaneous:
                await bothOldRequestsStarted.wait()
            case .afterSave where requestNumber == 1:
                await bothOldRequestsStarted.wait()
            case .afterSave:
                await refreshSaved.wait()
            }
            return AIHTTPResponse(statusCode: 401)
        }

        guard authorization == "Bearer access-new" else {
            return AIHTTPResponse(statusCode: 401)
        }
        refreshedRequests += 1
        let requestJSON = try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data())
        let responseJSON: JSONValue = [
            "jsonrpc": "2.0",
            "id": requestJSON["id"] ?? .null,
            "result": ["ok": true]
        ]
        return AIHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: try JSONEncoder().encode(responseJSON)
        )
    }

    func oldTokenRequestCount() -> Int { oldRequests }
    func refreshedTokenRequestCount() -> Int { refreshedRequests }
}
