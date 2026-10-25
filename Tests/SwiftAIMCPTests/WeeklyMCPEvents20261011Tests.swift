@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import CryptoKit
import Testing

@Suite("WeeklyMCPEvents20261011Tests")
struct WeeklyMCPEvents20261011Tests {
    @Test func pendingSubscriptionAuthenticatesVerificationBeforeResponseAndNormalizesCursor() async throws {
        let store = WeeklyEventStore()
        let transport = WeeklyEventTransport(beforeSubscribe: { message in
            let callback = try #require(message["params"]?["delivery"]?["url"]?.stringValue.flatMap(URL.init(string:)))
            let key = try #require(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == MCPEventCallbackKey }?.value)
            let saved = try #require(await store.get(key: key))
            #expect(saved.status == .pending)
            #expect(saved.id == nil || saved.id == "sub_1")
            #expect(message["params"]?["ttlMs"] == .null)
            #expect(message["params"]?["maxAgeMs"] == 0)
            let handler = MCPEventWebhook(store: store, onEvent: { _, _ in Issue.record("Unexpected event") }, now: { weeklyEventNow })
            let verified = await handler.handle(try weeklySignedRequest(saved, ["type": "verification", "challenge": "challenge_1"]))
            #expect(verified.statusCode == 200)
            #expect(try verified.jsonValue() == ["challenge": "challenge_1"])
            var unsigned = try weeklySignedRequest(saved, ["type": "verification", "challenge": "unsigned"])
            unsigned.headers["webhook-signature"] = "v1,invalid"
            #expect(await handler.handle(unsigned).statusCode == 401)
        })
        let client = try await MCPClient.connect(transport: transport, events: .direct(store: store))
        let events = await client.experimentalEvents
        let result = try await events.subscribe(.init(name: "comment.created", arguments: ["document_id": "doc_1"], callbackURL: URL(string: "https://app.example/events?tenant=one")!, lifetime: .indefinite, maxAgeMilliseconds: 0))
        #expect(result.cursor == nil)
        let saved = try #require(await store.getById(result.id))
        #expect(saved.status == .active && saved.cursor == nil)
        #expect(saved.delivery.url.query?.contains("tenant=one") == true)
        #expect(try decodeMCPEventSecret(saved.delivery.secret).count == 32)
        try await store.update(key: saved.key, patch: .init(["cursor": "cursor_from_delivery"]))
        _ = try await events.refresh(.id(result.id))
        #expect(await transport.lastRequest()["params"]?["cursor"] == "cursor_from_delivery")
        #expect(await store.get(key: saved.key)?.delivery.secret == saved.delivery.secret)
        try await events.unsubscribe(.key(saved.key))
        #expect(await store.get(key: saved.key) == nil)
        #expect(await transport.lastRequest()["params"]?["delivery"]?["secret"] == nil)
        try await client.close()
    }

    @Test func uncertainCreateAndRenewKeepRecoverablePendingState() async throws {
        let store = WeeklyEventStore()
        let transport = WeeklyEventTransport()
        let client = try await MCPClient.connect(transport: transport, events: .direct(store: store))
        let events = await client.experimentalEvents
        await transport.failSubscribe(true)
        await #expect(throws: MCPClientError.self) { try await events.subscribe(weeklySubscribeInput()) }
        let pending = try #require(await store.records().first)
        #expect(pending.status == .pending && pending.id == nil)
        await transport.failSubscribe(false)
        _ = try await events.refresh(.key(pending.key))
        await transport.failSubscribe(true)
        await #expect(throws: MCPClientError.self) { try await events.refresh(.key(pending.key)) }
        #expect(await store.get(key: pending.key)?.status == .pending)
        await transport.failUnsubscribe(true)
        await #expect(throws: MCPClientError.self) { try await events.unsubscribe(.key(pending.key)) }
        #expect(await store.get(key: pending.key) != nil)
        try await client.close()
    }

    @Test func paginationAndArgumentValidationRunBeforePersistence() async throws {
        let store = WeeklyEventStore()
        let transport = WeeklyEventTransport(paginate: true)
        let client = try await MCPClient.connect(transport: transport, events: .direct(store: store, validateArguments: { definition, arguments in
            #expect(definition.name == "comment.created")
            guard arguments["document_id"]?.stringValue != nil else { throw MCPClientError(message: "document_id is required") }
        }))
        let events = await client.experimentalEvents
        await #expect(throws: MCPClientError.self) { try await events.subscribe(weeklySubscribeInput()) }
        #expect(await store.records().isEmpty)
        #expect(await transport.methods().filter { $0 == "events/list" }.count == 2)
        #expect(!((await transport.methods()).contains("events/subscribe")))
        _ = try await events.subscribe(weeklySubscribeInput(arguments: ["document_id": "doc_1"]))
        try await client.close()
    }

    @Test func repeatedPaginationAndUnsupportedCapabilityAreRejected() async throws {
        let store = WeeklyEventStore()
        let transport = WeeklyEventTransport(repeatedCursor: true)
        let client = try await MCPClient.connect(transport: transport, events: .direct(store: store))
        let events = await client.experimentalEvents
        await #expect(throws: MCPClientError.self) { try await events.subscribe(weeklySubscribeInput()) }
        #expect(await store.records().isEmpty)
        try await client.close()
        let unsupported = try await MCPClient.connect(transport: WeeklyEventTransport(supportsEvents: false))
        let unsupportedEvents = await unsupported.experimentalEvents
        await #expect(throws: MCPClientError.self) { try await unsupportedEvents.list() }
        try await unsupported.close()
    }

    @Test(arguments: ["http://localhost/events", "http://example.com/events", "https://user:password@app.example/events", "https://app.example/events#fragment", "ftp://127.0.0.1/events"])
    func unsafeCallbacksAreRejectedBeforeNetwork(_ address: String) async throws {
        let transport = WeeklyEventTransport()
        let store = WeeklyEventStore()
        let client = try await MCPClient.connect(transport: transport, events: .direct(store: store))
        let events = await client.experimentalEvents
        await #expect(throws: MCPClientError.self) { try await events.subscribe(.init(name: "comment.created", callbackURL: URL(string: address)!, allowInsecureLocalhost: true)) }
        #expect(await transport.methods() == ["server/discover"])
        #expect(await store.records().isEmpty)
        try await client.close()
    }

    @Test(arguments: ["http://127.0.0.1:3000/events", "http://[::1]:3000/events"])
    func explicitlyAllowedLiteralLoopbackWorks(_ address: String) async throws {
        let client = try await MCPClient.connect(transport: WeeklyEventTransport(), events: .direct(store: WeeklyEventStore()))
        let events = await client.experimentalEvents
        _ = try await events.subscribe(.init(name: "comment.created", callbackURL: URL(string: address)!, allowInsecureLocalhost: true))
        try await client.close()
    }

    @Test func signatureRotationRawBytesAndStaleTimestamp() throws {
        let subscription = weeklySubscription()
        var request = try weeklySignedRequest(subscription, ["text": "a\nb"])
        request.headers["webhook-signature"] = "v0,ignored v1,!!! " + (request.headers["webhook-signature"] ?? "")
        #expect(try verifyMCPEventSignature(headers: request.headers, body: request.body!, secret: subscription.delivery.secret, now: weeklyEventNow))
        #expect(try !verifyMCPEventSignature(headers: request.headers, body: request.body! + Data(" ".utf8), secret: subscription.delivery.secret, now: weeklyEventNow))
        #expect(try !verifyMCPEventSignature(headers: request.headers, body: request.body!, secret: subscription.delivery.secret, now: weeklyEventNow.addingTimeInterval(301)))
        request.headers["webhook-timestamp"] = "+1791676800"
        #expect(try !verifyMCPEventSignature(headers: request.headers, body: request.body!, secret: subscription.delivery.secret, now: weeklyEventNow))
    }

    @Test(arguments: [0, 23, 24, 32, 64, 65])
    func signingSecretLengthBounds(_ size: Int) throws {
        let secret = "whsec_" + Data(repeating: 1, count: size).base64EncodedString()
        if (24...64).contains(size) { #expect(try decodeMCPEventSecret(secret).count == size) }
        else { #expect(throws: MCPClientError.self) { try decodeMCPEventSecret(secret) } }
    }

    @Test func cursorAdvancesOnlyAfterDurableAcceptanceAndPendingRenewalsRetry() async throws {
        let store = WeeklyEventStore()
        let subscription = weeklySubscription()
        await store.set(subscription)
        let failing = MCPEventWebhook(store: store, onEvent: { _, _ in throw MCPClientError(message: "storage unavailable") }, now: { weeklyEventNow })
        let request = try weeklySignedRequest(subscription, weeklyEventValue(cursor: "new"))
        #expect(await failing.handle(request).statusCode == 503)
        #expect(await store.get(key: subscription.key)?.cursor == "old")
        let accepting = MCPEventWebhook(store: store, onEvent: { info, event in
            #expect(info.id == "sub_1" && event.eventId == "evt_1")
            #expect(info.arguments == ["document_id": "doc_1"])
        }, now: { weeklyEventNow })
        #expect(await accepting.handle(request).statusCode == 204)
        #expect(await store.get(key: subscription.key)?.cursor == "new")
        #expect(await accepting.handle(try weeklySignedRequest(subscription, weeklyEventValue(cursor: .null))).statusCode == 204)
        #expect(await store.get(key: subscription.key)?.cursor == nil)
        await store.set(subscription)
        try await store.update(key: subscription.key, patch: .init(["status": "pending"]))
        #expect(await accepting.handle(request).statusCode == 503)
        #expect(await store.get(key: subscription.key)?.cursor == "old")
    }

    @Test func gapAndTerminationPersistOnlyAfterCallbacksAndTerminationEndsPendingRenewal() async throws {
        let store = WeeklyEventStore()
        let subscription = weeklySubscription()
        await store.set(subscription)
        let gap = try weeklySignedRequest(subscription, ["type": "gap", "cursor": "fresh"])
        let failGap = MCPEventWebhook(store: store, onEvent: { _, _ in }, onGap: { _, _, _ in throw MCPClientError(message: "reconcile failed") }, now: { weeklyEventNow })
        #expect(await failGap.handle(gap).statusCode == 503)
        #expect(await store.get(key: subscription.key)?.cursor == "old")
        let handler = MCPEventWebhook(store: store, onEvent: { _, _ in }, onGap: { _, id, gap in #expect(id == "evt_1" && gap.truncated) }, now: { weeklyEventNow })
        #expect(await handler.handle(gap).statusCode == 204)
        #expect(await store.get(key: subscription.key)?.truncated == true)
        #expect(await store.get(key: subscription.key)?.cursor == "fresh")
        try await store.update(key: subscription.key, patch: .init(["status": "pending"]))
        let termination = try weeklySignedRequest(subscription, ["type": "terminated", "error": ["code": -32001, "message": "Access revoked"]])
        let failing = MCPEventWebhook(store: store, onEvent: { _, _ in }, onTerminated: { _, _, _ in throw MCPClientError(message: "retry") }, now: { weeklyEventNow })
        #expect(await failing.handle(termination).statusCode == 503)
        #expect(await store.get(key: subscription.key) != nil)
        #expect(await handler.handle(termination).statusCode == 204)
        #expect(await store.get(key: subscription.key) == nil)
    }

    @Test func malformedPayloadExpiryAndHTTPBodyBounds() async throws {
        let store = WeeklyEventStore()
        var subscription = weeklySubscription()
        await store.set(subscription)
        let handler = MCPEventWebhook(store: store, validatePayload: { _, data in
            guard data["text"]?.stringValue != nil else { throw MCPClientError(message: "text required") }
        }, onEvent: { _, _ in }, now: { weeklyEventNow })
        var missing = weeklyEventValue(); missing["data"] = [:]
        #expect(await handler.handle(try weeklySignedRequest(subscription, .object(missing))).statusCode == 400)
        var mismatched = weeklyEventValue(); mismatched["eventId"] = "another"
        #expect(await handler.handle(try weeklySignedRequest(subscription, .object(mismatched))).statusCode == 400)
        var get = try weeklySignedRequest(subscription, weeklyEventValue()); get.method = "GET"
        #expect(await handler.handle(get).statusCode == 405)
        var wrongType = get; wrongType.method = "POST"; wrongType.headers["content-type"] = "text/plain"
        #expect(await handler.handle(wrongType).statusCode == 415)
        let oversized = AIHTTPRequest(url: subscription.delivery.url, headers: (try weeklySignedRequest(subscription, weeklyEventValue())).headers, body: Data(repeating: 0, count: MCPEventWebhook.maxBodyBytes + 1))
        #expect(await handler.handle(oversized).statusCode == 413)
        let probe = WeeklyEventCounter()
        let stream = AsyncThrowingStream<Data, Error> { $0.yield(Data(repeating: 0, count: MCPEventWebhook.maxBodyBytes)); $0.yield(Data([1])); $0.finish() }
        let streamed = AIHTTPRequest(url: subscription.delivery.url, headers: oversized.headers, bodyStream: stream, cancelBodyStream: { await probe.increment() })
        #expect(await handler.handle(streamed).statusCode == 413)
        #expect(await probe.count == 1)
        subscription.refreshBefore = "2026-10-10T00:00:00Z"; await store.set(subscription)
        #expect(await handler.handle(try weeklySignedRequest(subscription, weeklyEventValue())).statusCode == 410)
    }

    @Test func managedAdapterBindsBeforeStartAndOwnsLifecycle() async throws {
        let transport = WeeklyEventTransport()
        await #expect(throws: MCPClientError.self) { try await MCPClient.connect(transport: transport, events: .managed(WeeklyFailingEventAdapter())) }
        #expect(await transport.started == false)
        let operations = WeeklyManagedOperations()
        let client = try await MCPClient.connect(transport: transport, events: .managed(WeeklyManagedAdapter(operations: operations)))
        let events = await client.experimentalEvents
        _ = try await events.list()
        let input = MCPManagedSubscribeInput(name: "comment.created", arguments: [:], context: ["application": "watch"], idempotencyKey: "recover-original", lifetime: .expiresAt(nil))
        #expect(try await events.subscribe(input).id == "managed_1")
        #expect(try await events.getSubscription(id: "managed_1").status == .active)
        #expect(try await events.listSubscriptions().subscriptions.count == 1)
        #expect(try await events.unsubscribe(id: "managed_1").status == .stopped)
        #expect(await transport.methods() == ["server/discover", "events/list"])
        try await client.close()
        #expect(await operations.calls == ["subscribe", "get", "list", "unsubscribe"])
    }
}

private let weeklyEventNow = Date(timeIntervalSince1970: 1_791_676_800)
private let weeklyEventDefinition = MCPEventDefinition(name: "comment.created", delivery: [.webhook], inputSchema: ["type": "object"], payloadSchema: ["type": "object"])
private func weeklySubscribeInput(arguments: [String: JSONValue] = [:]) -> MCPSubscribeEventOptions {
    .init(name: "comment.created", arguments: arguments, callbackURL: URL(string: "https://app.example/events")!)
}
private func weeklySubscription() -> MCPEventSubscription {
    .init(key: "key_1", id: "sub_1", name: "comment.created", arguments: ["document_id": "doc_1"], definition: weeklyEventDefinition, delivery: .init(url: URL(string: "https://app.example/events?mcp_event_subscription=key_1")!, secret: "whsec_" + Data(repeating: 7, count: 32).base64EncodedString()), refreshBefore: "2026-10-12T00:00:00Z", cursor: "old", status: .active)
}
private func weeklyEventValue(cursor: JSONValue? = nil) -> [String: JSONValue] {
    var value: [String: JSONValue] = ["eventId": "evt_1", "name": "comment.created", "timestamp": "2026-10-11T00:00:00Z", "data": ["text": "new comment"]]
    if let cursor { value["cursor"] = cursor }; return value
}
private func weeklySignedRequest(_ subscription: MCPEventSubscription, _ object: [String: JSONValue]) throws -> AIHTTPRequest {
    try weeklySignedRequest(subscription, .object(object))
}
private func weeklySignedRequest(_ subscription: MCPEventSubscription, _ value: JSONValue) throws -> AIHTTPRequest {
    let data = try JSONEncoder().encode(value)
    let timestamp = String(Int(weeklyEventNow.timeIntervalSince1970))
    let key = SymmetricKey(data: Data(base64Encoded: String(subscription.delivery.secret.dropFirst(6)))!)
    let signature = Data(HMAC<SHA256>.authenticationCode(for: Data("evt_1.\(timestamp).".utf8) + data, using: key)).base64EncodedString()
    return AIHTTPRequest(url: subscription.delivery.url, headers: ["content-type": "application/json; charset=utf-8", "webhook-id": "evt_1", "webhook-timestamp": timestamp, "webhook-signature": "v1,\(signature)", "X-MCP-Subscription-Id": subscription.id ?? "sub_1"], body: data)
}
private actor WeeklyEventStore: MCPEventStore {
    private var values: [String: MCPEventSubscription] = [:]
    func get(key: String) -> MCPEventSubscription? { values[key] }
    func getById(_ id: String) -> MCPEventSubscription? { values.values.first { $0.id == id } }
    func set(_ subscription: MCPEventSubscription) { values[subscription.key] = subscription }
    func update(key: String, patch: MCPEventSubscriptionPatch) throws {
        guard let original = values[key] else { throw MCPClientError(message: "Unknown record") }
        values[key] = try patch.applying(to: original)
    }
    func delete(key: String) { values[key] = nil }
    func records() -> [MCPEventSubscription] { Array(values.values) }
}
private actor WeeklyEventCounter { var count = 0; func increment() { count += 1 } }
private actor WeeklyEventTransport: MCPTransport {
    nonisolated let supportsProtocolVersionDiscovery = true
    var started = false
    private var requests: [JSONValue] = []
    private var subscribeFails = false
    private var unsubscribeFails = false
    let beforeSubscribe: (@Sendable (JSONValue) async throws -> Void)?
    let paginate: Bool
    let repeatedCursor: Bool
    let supportsEvents: Bool
    init(beforeSubscribe: (@Sendable (JSONValue) async throws -> Void)? = nil, paginate: Bool = false, repeatedCursor: Bool = false, supportsEvents: Bool = true) {
        self.beforeSubscribe = beforeSubscribe; self.paginate = paginate; self.repeatedCursor = repeatedCursor; self.supportsEvents = supportsEvents
    }
    func start() { started = true }
    func close() {}
    func notify(_ message: JSONValue) {}
    func failSubscribe(_ value: Bool) { subscribeFails = value }
    func failUnsubscribe(_ value: Bool) { unsubscribeFails = value }
    func methods() -> [String] { requests.compactMap { $0["method"]?.stringValue } }
    func lastRequest() -> JSONValue { requests.last ?? [:] }
    func request(_ message: JSONValue) async throws -> JSONValue {
        requests.append(message)
        var result: [String: JSONValue] = ["resultType": "complete"]
        switch message["method"]?.stringValue {
        case "server/discover":
            result["supportedVersions"] = ["2026-07-28"]; result["capabilities"] = supportsEvents ? ["events": [:]] : [:]
        case "events/list":
            if repeatedCursor || (paginate && message["params"]?["cursor"] == nil) { result["events"] = []; result["nextCursor"] = "page_2" }
            else { result["events"] = .array([weeklyEventDefinition.rawValue]) }
        case "events/subscribe":
            if subscribeFails { throw MCPClientError(message: "Uncertain subscription result") }
            try await beforeSubscribe?(message)
            result["id"] = "sub_1"; result["refreshBefore"] = .null; result["truncated"] = false
        case "events/unsubscribe":
            if unsubscribeFails { throw MCPClientError(message: "Unsubscribe failed") }
        default: break
        }
        return .object(["jsonrpc": "2.0", "id": message["id"] ?? .null, "result": .object(result)])
    }
}
private struct WeeklyFailingEventAdapter: MCPEventAdapter {
    func createAdapter(transport: MCPEventTransportMetadata) throws -> any MCPEventOperations { throw MCPClientError(message: "Adapter rejected configuration") }
}
private struct WeeklyManagedAdapter: MCPEventAdapter {
    var operations: WeeklyManagedOperations
    func createAdapter(transport: MCPEventTransportMetadata) -> any MCPEventOperations { #expect(transport == .custom); return operations }
}
private actor WeeklyManagedOperations: MCPEventOperations {
    var calls: [String] = []
    private func record(_ name: String, status: MCPManagedSubscription.Status = .active) -> MCPManagedSubscription {
        calls.append(name); return .init(id: "managed_1", name: "comment.created", status: status, expiresAt: nil)
    }
    func subscribe(_ input: MCPManagedSubscribeInput) -> MCPManagedSubscription { #expect(input.idempotencyKey == "recover-original"); return record("subscribe") }
    func getSubscription(id: String, options: MCPRequestOptions?) -> MCPManagedSubscription { record("get") }
    func listSubscriptions(cursor: String?, limit: Int?, status: MCPManagedSubscription.Status?, options: MCPRequestOptions?) -> MCPManagedSubscriptionPage { .init(subscriptions: [record("list")]) }
    func unsubscribe(id: String, options: MCPRequestOptions?) -> MCPManagedSubscription { record("unsubscribe", status: .stopped) }
}
