@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Suite("WeeklyMCPCore20261011Tests")
struct WeeklyMCPCore20261011Tests {
    @Test func refreshInvalidGrantInvalidatesOnlyFailedTokensAndRestartsAuthorization() async throws {
        let provider = TestOAuthClientProvider(clientInformation: try oauthClientInformation(), tokens: try oauthTokens(accessToken: "old", refreshToken: "expired"))
        let resource = jsonResponse(#"{"resource":"https://resource.example.com/mcp","authorization_servers":["https://auth.example.com"]}"#)
        let transport = RecordingTransport(responses: [resource, oauthAuthorizationMetadataResponse(),
            AIHTTPResponse(statusCode: 400, body: Data(#"{"error":"invalid_grant","error_description":"Refresh expired"}"#.utf8)),
            resource, oauthAuthorizationMetadataResponse()
        ])
        let result = try await MCPOAuth.auth(provider: provider, serverURL: "https://resource.example.com/mcp", transport: transport)
        #expect(result == .redirect)
        #expect(await provider.invalidations() == [.tokens])
        #expect(try await provider.clientInformation()?.clientID == "client123")
        let requests = await transport.requests()
        #expect(requests.filter { $0.url.path == "/token" }.count == 1)
        #expect(await provider.redirectedURL()?.host == "auth.example.com")
    }

    @Test(arguments: ["https://auth.example.com//evil.example.com", "https://auth.example.com:8443////evil.example.com/issuer", "https://auth.example.com/a//b"])
    func oauthDiscoveryRetainsOriginalOriginForDoubleSlashPaths(_ string: String) throws {
        let original = try requireURL(string)
        let urls = mcpAuthorizationServerDiscoveryURLs(original)
        #expect(urls.count == 4)
        #expect(urls.allSatisfy { $0.url.scheme == original.scheme && $0.url.host == original.host && $0.url.port == original.port })
    }

    @Test(arguments: ["2026-02-29T00:00:00Z", "2026-04-31T00:00:00Z", "2026-01-01T24:00:00Z", "2026-01-01T00:00:60Z", "2026-01-01T00:00:00+24:00", "2026-01-01", "2026-01-01T00:00:00"])
    func eventDatesRejectCalendarNormalizationAndIncompleteValues(_ string: String) {
        #expect(mcpEventDate(string) == nil)
        #expect(throws: MCPClientError.self) { _ = try MCPSubscribeEventResult(json: ["id": "sub", "refreshBefore": .string(string), "truncated": false]) }
    }

    @Test(arguments: ["2024-02-29T00:00:00Z", "2026-10-11T01:02:03.123456Z", "2026-10-11T01:02:03+09:00"])
    func eventDatesAcceptLeapDaysFractionalSecondsAndOffsets(_ string: String) {
        #expect(mcpEventDate(string) != nil)
    }

    @Test func subscriptionPatchesMergeRatherThanReplacingDeliveryIdentity() throws {
        let secret = createMCPEventSecret()
        let original = MCPEventSubscription(key: "key", id: "sub", name: "change", definition: .init(name: "change", delivery: [.webhook], inputSchema: true, payloadSchema: true), delivery: .init(url: try requireURL("https://example.com/events"), secret: secret), refreshBefore: "2026-10-12T00:00:00Z", cursor: "old", status: .active)
        let updated = try MCPEventSubscriptionPatch(["cursor": .null, "status": "pending"]).applying(to: original)
        #expect(updated.cursor == nil && updated.status == .pending)
        #expect(updated.delivery == original.delivery && updated.key == original.key && updated.id == original.id && updated.refreshBefore == original.refreshBefore)
    }

    @Test func signatureMatchesIndependentHmacFixtureAndAuthenticatesRawBytes() throws {
        let secret = "whsec_" + Data(repeating: 7, count: 32).base64EncodedString()
        let headers = ["Webhook-Id": "evt_1", "Webhook-Timestamp": "1791676800", "Webhook-Signature": "v1,UTSpJ+UY8AXhR1dENIPt0zH/4VRat0Twtqe3pGrFqbE="]
        let now = Date(timeIntervalSince1970: 1_791_676_800)
        #expect(try verifyMCPEventSignature(headers: headers, body: Data(#"{"message":"hello"}"#.utf8), secret: secret, now: now))
        #expect(try !verifyMCPEventSignature(headers: headers, body: Data(#"{ "message": "hello" }"#.utf8), secret: secret, now: now))
    }
}
