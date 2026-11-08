import Foundation
import Testing
@testable import SwiftAIMCP
import SwiftAIProvider
import SwiftAITransport

private struct WeeklyResourceProvider: MCPOAuthClientProvider {
    let redirectURL = URL(string: "http://localhost/callback")!
    var clientMetadata: MCPOAuthClientMetadata { .init(redirectURIs: [redirectURL]) }
    var resource: URL?
    func tokens() async throws -> MCPOAuthTokens? { nil }
    func saveTokens(_ tokens: MCPOAuthTokens) async throws {}
    func redirectToAuthorization(_ authorizationURL: URL) async throws {}
    func saveCodeVerifier(_ codeVerifier: String) async throws {}
    func codeVerifier() async throws -> String { "verifier" }
    func validateResourceURL(serverURL: URL, resource: URL?) async throws -> URL? { self.resource }
}

@Suite("Weekly20261108 MCP OAuth resource and token binding")
struct Weekly20261108OAuthTests {
    @Test(arguments: [false, true])
    func discoveryRejectsHTTPDowngradesBeforeTheNextRequest(_ authorization: Bool) async throws {
        let host = authorization ? "auth.example.com" : "resource.example.com"
        let transport = RecordingTransport(response: .init(statusCode: 302, headers: ["location": "http://\(host)/metadata"]))
        do {
            if authorization { _ = try await MCPOAuthDiscovery.discoverAuthorizationServerMetadata(authorizationServerURL: "https://\(host)", transport: transport) }
            else { _ = try await MCPOAuthDiscovery.discoverProtectedResourceMetadata(serverURL: "https://\(host)/mcp", transport: transport) }
            Issue.record("Expected blocked OAuth discovery downgrade")
        } catch { #expect(String(describing: error).contains("Redirect from HTTPS to HTTP was blocked")) }
        #expect(await transport.requests().count == 1)
        #expect(await transport.requests().allSatisfy { !$0.followRedirects && $0.url.scheme == "https" })
    }

    @Test(arguments: ["https://api.example.com", "https://api.example.com/mcp?tenant=1#fragment"])
    func canonicalResourceAlwaysPresent(_ server: String) async throws {
        let provider = TestOAuthClientProvider(clientInformation: nil)
        let expected = server.contains("tenant") ? "https://api.example.com/mcp?tenant=1" : "https://api.example.com/"
        #expect(try await MCPOAuth.selectResourceURL(serverURL: URL(string: server)!, provider: provider, resourceMetadata: nil)?.absoluteString == expected)
    }

    @Test func customNilValidationUsesCanonicalWithoutRevalidatingMetadata() async throws {
        let server = URL(string: "https://api.example.com/mcp?tenant=1#fragment")!
        let metadata = MCPOAuthProtectedResourceMetadata(resource: URL(string: "https://another.example.com")!)
        let provider = WeeklyResourceProvider(resource: nil)
        #expect(try await MCPOAuth.selectResourceURL(serverURL: server, provider: provider, resourceMetadata: metadata)?.absoluteString == "https://api.example.com/mcp?tenant=1")
        let custom = URL(string: "https://custom.example.com/mcp")!
        #expect(try await MCPOAuth.selectResourceURL(serverURL: server, provider: WeeklyResourceProvider(resource: custom), resourceMetadata: metadata) == custom)
    }

    @Test(arguments: [false, true])
    func unboundRefreshTokenCannotAcquireNewRegistrationPin(_ clears: Bool) async throws {
        let provider = TestOAuthClientProvider(
            clientInformation: nil,
            tokens: .init(accessToken: "unbound", tokenType: "Bearer", refreshToken: "unbound-refresh"),
            supportsDynamicClientRegistration: true,
            invalidationClearsTokens: clears
        )
        let transport = RecordingTransport(responses: [
            jsonResponse(#"{"resource":"https://resource.example.com/mcp","authorization_servers":["https://auth.example.com"]}"#),
            oauthAuthorizationMetadataResponse(),
            jsonResponse(#"{"client_id":"registered","redirect_uris":["http://localhost:3000/callback"]}"#)
        ])
        if clears {
            #expect(try await MCPOAuth.auth(provider: provider, serverURL: "https://resource.example.com/mcp", transport: transport) == .redirect)
            #expect(await provider.savedClientInformation()?.clientID == "registered")
            #expect(try await provider.tokens() == nil)
            #expect(await provider.savedTokens() == nil)
            #expect(await transport.requests().filter { $0.method == "POST" }.map { $0.url.path } == ["/register"])
        } else {
            do { _ = try await MCPOAuth.auth(provider: provider, serverURL: "https://resource.example.com/mcp", transport: transport); Issue.record("Expected unbound-token rejection") }
            catch { #expect(String(describing: error).contains("must be cleared before starting authorization")) }
            #expect(await provider.savedClientInformation() == nil)
            #expect(await provider.savedAuthorizationServerInformation() == nil)
            #expect(await provider.redirectedURL() == nil)
            #expect(await transport.requests().allSatisfy { $0.method == "GET" })
        }
        #expect(await provider.invalidations() == [.tokens])
    }
}
