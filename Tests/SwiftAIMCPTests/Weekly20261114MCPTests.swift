import Foundation
import Testing
@testable import SwiftAIMCP
import SwiftAIProvider
import SwiftAITransport

private struct DiscoveryOffline: Error, Equatable { let marker = "original-network-error" }
private actor NetworkFailureDiscoveryTransport: MCPTransport {
    nonisolated let supportsProtocolVersionDiscovery = true
    nonisolated let waitsForProtocolVersionDiscovery = true
    var methods: [String] = []
    func start() {}
    func close() {}
    func notify(_ message: JSONValue) {}
    func request(_ message: JSONValue) async throws -> JSONValue {
        methods.append(message["method"]?.stringValue ?? "")
        throw DiscoveryOffline()
    }
}

private actor HTTPFailureDiscoveryTransport: AITransport {
    var postMethods: [String] = []
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        if request.method == "POST" {
            let value = try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data())
            postMethods.append(value["method"]?.stringValue ?? "")
            throw DiscoveryOffline()
        }
        return .init(statusCode: request.method == "GET" ? 405 : 200)
    }
}

@Suite("Weekly20261114 MCP discovery and CSP")
struct Weekly20261114MCPTests {
    @Test func networkFailureDoesNotFallBackToLegacyInitialize() async throws {
        let transport = NetworkFailureDiscoveryTransport()
        await #expect(throws: DiscoveryOffline.self) { try await MCPClient.connect(transport: transport) }
        #expect(await transport.methods == ["server/discover"])
    }

    @Test func streamableHTTPPreservesOriginalNetworkFailure() async throws {
        let http = HTTPFailureDiscoveryTransport()
        let transport = MCPHTTPTransport(url: URL(string: "https://mcp.example.com/rpc")!, transport: http)
        await #expect(throws: DiscoveryOffline.self) { try await MCPClient.connect(transport: transport) }
        #expect(await http.postMethods == ["server/discover"])
    }

    @Test func appCSPSanitizesBaseUriDomainsAndOtherKnownStringArrays() throws {
        let raw: JSONValue = ["contents": [["uri": "ui://app", "mimeType": .string(MCPApps.appMIMEType), "text": "<p>app</p>", "_meta": ["ui": ["csp": ["connectDomains": ["https://ok.example", 42, .null], "resourceDomains": "wrong", "baseUriDomains": ["https://base.example", false], "custom": "preserved"], "extra": "kept"]]]]]
        let result = try MCPReadResourceResult(json: raw)
        let app = try MCPApps.resource(uri: "ui://app", from: result)
        #expect(app.metadata?["csp"]?["baseUriDomains"] == ["https://base.example"])
        #expect(app.metadata?["csp"]?["connectDomains"] == ["https://ok.example"])
        #expect(app.metadata?["csp"]?["resourceDomains"] == nil)
        #expect(app.metadata?["csp"]?["custom"] == "preserved")
        #expect(app.metadata?["extra"] == "kept")
        #expect(result.contents.first?.rawValue["_meta"]?["ui"]?["csp"]?["baseUriDomains"] == ["https://base.example", false])
    }

    @Test func untrustedNativeCredentialEndpointIsBlockedBeforeNetwork() async throws {
        let endpoint = URL(string: "https://authorization.example.com/token")!
        await #expect(throws: MCPClientError.self) {
            try await sendMCPOAuthEndpoint(.init(method: "POST", url: endpoint), trustedOrigin: nil, transport: URLSessionTransport.shared)
        }
    }

    @Test func customSessionCannotMasqueradeAsDNSPinnedDiscovery() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await sendMCPOAuthEndpoint(.init(method: "GET", url: URL(string: "https://authorization.example.com/metadata")!), trustedOrigin: nil, transport: URLSessionTransport(session: session))
            Issue.record("Expected missing native pinning")
        } catch let error as MCPClientError {
            #expect(error.message.contains("DNS-pinned"))
            #expect(error.message.contains("custom URLSession"))
        }
    }

    @Test func explicitConfiguredOriginAndCustomTransportRemainUsable() async throws {
        let response = jsonResponse(#"{"access_token":"token","token_type":"Bearer"}"#)
        let transport = RecordingTransport(response: response)
        let issuer = URL(string: "https://configured.example.com")!
        let client = MCPOAuthClientInformation(clientID: "client")
        let tokens = try await MCPOAuth.exchangeAuthorization(authorizationServerURL: issuer, clientInformation: client, authorizationCode: "code", codeVerifier: "verifier", redirectURI: URL(string: "https://app.example.com/callback")!, trustedOrigin: issuer, transport: transport)
        #expect(tokens.accessToken == "token")
        #expect(await transport.requests().count == 1)
        #expect(await transport.requests().first?.followRedirects == false)
    }
}
