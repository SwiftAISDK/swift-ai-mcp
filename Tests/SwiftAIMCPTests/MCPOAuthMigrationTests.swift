import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

// Ported from @ai-sdk/mcp 2.0.81 oauth.test.ts credential-binding and invalid_grant scenarios.
@Suite("MCP OAuth migration")
struct MCPOAuthMigrationTests {
    private let serverURL = "https://resource.example.com/mcp"
    private let issuer = "https://auth.example.com"

    @Test(arguments: ["client_secret_basic", "client_secret_post"])
    func issuerBoundSecretCompletesRedirectAndCodeExchange(method: String) async throws {
        let provider = TestOAuthClientProvider(
            clientInformation: .init(clientID: "migration-client", clientSecret: "dummy-secret", issuer: issuer),
            state: "migration-state"
        )
        let metadata = authorizationMetadata(method: method)
        let transport = RecordingTransport(responses: [resource(), metadata, resource(), metadata, issuedTokens()])

        #expect(try await MCPOAuth.auth(provider: provider, serverURL: serverURL, transport: transport) == .redirect)
        let redirect = try await #require(provider.redirectedURL())
        let query = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "state" }?.value == "migration-state")
        #expect(query.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(!redirect.absoluteString.contains("dummy-secret"))
        #expect(await provider.savedAuthorizationServerInformation()?.issuer == issuer)
        #expect(await transport.requests().allSatisfy { $0.method == "GET" })

        #expect(try await MCPOAuth.auth(
            provider: provider, serverURL: serverURL, authorizationCode: "dummy-code",
            callbackState: "migration-state", callbackIssuer: issuer, transport: transport
        ) == .authorized)

        let requests = await transport.requests()
        let post = try #require(requests.last)
        let form = try formItems(post)
        #expect(requests.map(\.method) == ["GET", "GET", "GET", "GET", "POST"])
        #expect(post.url.absoluteString == "\(issuer)/token")
        #expect(!post.followRedirects)
        #expect(form["code_verifier"] == (await provider.savedCodeVerifier()))
        #expect(form["code"] == "dummy-code")
        #expect(form["resource"] == serverURL)
        if method == "client_secret_basic" {
            #expect(post.headers["Authorization"] == "Basic \(Data("migration-client:dummy-secret".utf8).base64EncodedString())")
            #expect(form["client_secret"] == nil)
        } else {
            #expect(form["client_id"] == "migration-client")
            #expect(form["client_secret"] == "dummy-secret")
        }
        #expect(await provider.savedTokens()?.issuer == issuer)
        #expect(await provider.savedTokens()?.tokenEndpoint?.absoluteString == "\(issuer)/token")
    }

    @Test func storedBindingEnablesExplicitCustomAuthentication() async throws {
        let recorder = MigrationAuthenticationRecorder()
        let binding = MCPOAuthAuthorizationServerInformation(
            authorizationServerURL: try migrationURL(issuer),
            tokenEndpoint: try migrationURL("\(issuer)/token"),
            issuer: issuer
        )
        let provider = TestOAuthClientProvider(
            clientInformation: .init(clientID: "migration-client"),
            authorizationServerInformation: binding,
            state: "migration-state",
            customAuthentication: { request in await recorder.authenticate(request) }
        )
        let transport = RecordingTransport(responses: discovery(method: "private_key_jwt") + discovery(method: "private_key_jwt") + [issuedTokens()])
        #expect(provider.usesCustomClientAuthentication)
        #expect(try await MCPOAuth.auth(provider: provider, serverURL: serverURL, transport: transport) == .redirect)
        #expect(await recorder.calls.isEmpty)
        #expect(try await MCPOAuth.auth(
            provider: provider, serverURL: serverURL, authorizationCode: "dummy-code",
            callbackState: "migration-state", callbackIssuer: issuer, transport: transport
        ) == .authorized)

        let authentication = try await #require(recorder.calls.first)
        #expect(await recorder.calls.count == 1)
        #expect(authentication.authorizationServerURL == binding.authorizationServerURL)
        #expect(authentication.tokenURL == binding.tokenEndpoint)
        #expect(authentication.metadata?.issuer == issuer)
        let post = try await #require(transport.requests().last)
        let form = try formItems(post)
        #expect(form["client_assertion"] == "dummy-assertion")
        #expect(form["client_secret"] == nil)
        #expect(!post.followRedirects)
        #expect(await provider.savedTokens()?.issuer == issuer)
    }

    @Test(arguments: [false, true])
    func allowlistingDoesNotBindExistingSecretOrCustomAuthenticator(custom: Bool) async throws {
        let recorder = MigrationAuthenticationRecorder()
        let authenticator: MCPOAuthClientAuthenticationHandler?
        if custom {
            authenticator = { request in await recorder.authenticate(request) }
        } else {
            authenticator = nil
        }
        let provider = TestOAuthClientProvider(
            clientInformation: .init(clientID: "migration-client", clientSecret: custom ? nil : "dummy-secret"),
            customAuthentication: authenticator,
            customAuthorizationServerValidator: { _, server in
                // An approved destination still does not establish where an existing credential belongs.
                #expect(server.host == "auth.example.com")
            }
        )
        let transport = RecordingTransport(responses: discovery())
        await #expect(throws: MCPOAuthAuthorizationServerMismatchError.self) {
            try await MCPOAuth.auth(provider: provider, serverURL: serverURL, transport: transport)
        }
        #expect(await provider.validatedAuthorizationServerURLs().count == 1)
        #expect(await recorder.calls.isEmpty)
        #expect(await provider.redirectedURL() == nil)
        #expect(await provider.savedAuthorizationServerInformation() == nil)
        #expect(await provider.invalidations().isEmpty)
        #expect(await transport.requests().map(\.method) == ["GET", "GET"])
    }

    @Test(arguments: [false, true])
    func tokenOnlyCustomBindingSurvivesInvalidGrantAndRejectsChangedServer(changeServer: Bool) async throws {
        let recorder = MigrationAuthenticationRecorder()
        let provider = TestOAuthClientProvider(
            clientInformation: .init(clientID: "migration-client"),
            tokens: MCPOAuthTokens(
                accessToken: "expired-dummy-token", tokenType: "Bearer", refreshToken: "rejected-dummy-refresh",
                issuer: issuer, authorizationServerURL: try migrationURL(issuer),
                tokenEndpoint: try migrationURL("\(issuer)/token")
            ),
            state: "migration-state",
            customAuthentication: { request in await recorder.authenticate(request) }
        )
        let selectedIssuer = changeServer ? "https://changed.example.com" : issuer
        let rejectedRefresh = AIHTTPResponse(statusCode: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
        let transport = RecordingTransport(responses: discovery(method: "private_key_jwt") + [rejectedRefresh] + discovery(issuer: selectedIssuer, method: "private_key_jwt"))
        if changeServer {
            await #expect(throws: MCPOAuthAuthorizationServerMismatchError.self) {
                try await MCPOAuth.auth(provider: provider, serverURL: serverURL, transport: transport)
            }
            #expect(await provider.redirectedURL() == nil)
            #expect(await provider.savedAuthorizationServerInformation() == nil)
        } else {
            #expect(try await MCPOAuth.auth(provider: provider, serverURL: serverURL, transport: transport) == .redirect)
            #expect(await provider.redirectedURL()?.host == "auth.example.com")
        }
        #expect(await provider.invalidations() == [.tokens])
        #expect(try await provider.tokens() == nil)
        #expect(await recorder.calls.count == 1)
        let posts = await transport.requests().filter { $0.method == "POST" }
        #expect(posts.map(\.url.absoluteString) == ["\(issuer)/token"])
        #expect(try formItems(#require(posts.first))["grant_type"] == "refresh_token")

        if !changeServer {
            let savedBinding = try await #require(provider.savedAuthorizationServerInformation())
            #expect(savedBinding.authorizationServerURL.absoluteString == issuer)
            #expect(savedBinding.tokenEndpoint.absoluteString == "\(issuer)/token")
            let callback = RecordingTransport(responses: discovery(method: "private_key_jwt") + [issuedTokens()])
            #expect(try await MCPOAuth.auth(
                provider: provider, serverURL: serverURL, authorizationCode: "replacement-code",
                callbackState: "migration-state", callbackIssuer: issuer, transport: callback
            ) == .authorized)
            #expect(await recorder.calls.count == 2)
            #expect(await provider.savedTokens()?.issuer == issuer)
            #expect(await provider.savedTokens()?.accessToken == "new-dummy-token")
            #expect(await callback.requests().filter { $0.method == "POST" }.map(\.url.absoluteString) == ["\(issuer)/token"])
        }
    }

    private func resource(issuer: String = "https://auth.example.com") -> AIHTTPResponse {
        jsonResponse("""
        {"resource":"https://resource.example.com/mcp","authorization_servers":["\(issuer)"]}
        """)
    }

    private func authorizationMetadata(issuer: String = "https://auth.example.com", method: String = "client_secret_post") -> AIHTTPResponse {
        jsonResponse("""
        {
          "issuer":"\(issuer)","authorization_endpoint":"\(issuer)/authorize","token_endpoint":"\(issuer)/token",
          "response_types_supported":["code"],"code_challenge_methods_supported":["S256"],
          "grant_types_supported":["authorization_code","refresh_token"],"token_endpoint_auth_methods_supported":["\(method)"]
        }
        """)
    }

    private func discovery(issuer: String = "https://auth.example.com", method: String = "client_secret_post") -> [AIHTTPResponse] {
        [resource(issuer: issuer), authorizationMetadata(issuer: issuer, method: method)]
    }

    private func issuedTokens() -> AIHTTPResponse {
        jsonResponse(#"{"access_token":"new-dummy-token","token_type":"Bearer"}"#)
    }
}

private func migrationURL(_ value: String) throws -> URL {
    try #require(URL(string: value))
}

private actor MigrationAuthenticationRecorder {
    private(set) var calls: [MCPOAuthClientAuthenticationRequest] = []

    func authenticate(_ request: MCPOAuthClientAuthenticationRequest) -> MCPOAuthClientAuthenticationRequest {
        calls.append(request)
        var authenticated = request
        authenticated.parameters.append(URLQueryItem(name: "client_id", value: "migration-client"))
        authenticated.parameters.append(URLQueryItem(name: "client_assertion_type", value: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"))
        authenticated.parameters.append(URLQueryItem(name: "client_assertion", value: "dummy-assertion"))
        return authenticated
    }
}
