@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Test func mcpOAuthRegisterClientPostsMetadataAndParsesFullInformation() async throws {
    let metadata = MCPOAuthAuthorizationServerMetadata(
        issuer: "https://auth.example.com",
        authorizationEndpoint: try requireURL("https://auth.example.com/auth"),
        tokenEndpoint: try requireURL("https://auth.example.com/token"),
        registrationEndpoint: try requireURL("https://auth.example.com/register"),
        responseTypesSupported: ["code"],
        codeChallengeMethodsSupported: ["S256"]
    )
    let transport = RecordingTransport(response: jsonResponse("""
    {
      "client_id": "registered-client",
      "client_secret": "registered-secret",
      "redirect_uris": ["http://localhost:3000/callback"],
      "client_name": "Swift MCP Client",
      "token_endpoint_auth_method": "client_secret_post"
    }
    """))

    let information = try await MCPOAuth.registerClient(
        authorizationServerURL: try requireURL("https://auth.example.com"),
        metadata: metadata,
        clientMetadata: MCPOAuthClientMetadata(
            redirectURIs: [try requireURL("http://localhost:3000/callback")],
            tokenEndpointAuthMethod: "client_secret_post",
            grantTypes: ["authorization_code", "refresh_token"],
            responseTypes: ["code"],
            clientName: "Swift MCP Client",
            scope: "read write"
        ),
        transport: transport
    )

    #expect(information.clientInformation.clientID == "registered-client")
    #expect(information.clientInformation.clientSecret == "registered-secret")
    #expect(information.clientMetadata.clientName == "Swift MCP Client")
    let request = try await #require(transport.requests().first)
    #expect(request.method == "POST")
    #expect(request.url.absoluteString == "https://auth.example.com/register")
    #expect(request.headers["Content-Type"] == "application/json")
    let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
    #expect(body["redirect_uris"]?.arrayValue?.compactMap(\.stringValue) == ["http://localhost:3000/callback"])
    #expect(body["grant_types"]?.arrayValue?.compactMap(\.stringValue) == ["authorization_code", "refresh_token"])
    #expect(body["client_name"]?.stringValue == "Swift MCP Client")
    #expect(body["scope"]?.stringValue == "read write")
}
@Test func mcpOAuthTokenEndpointThrowsParsedServerErrors() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(
        statusCode: 400,
        headers: ["content-type": "application/json"],
        body: Data("""
        {
          "error": "invalid_grant",
          "error_description": "Bad code",
          "error_uri": "https://auth.example.com/errors/invalid_grant"
        }
        """.utf8)
    ))

    do {
        _ = try await MCPOAuth.exchangeAuthorization(
            authorizationServerURL: try requireURL("https://auth.example.com"),
            clientInformation: MCPOAuthClientInformation(clientID: "public-client"),
            authorizationCode: "bad-code",
            codeVerifier: "verifier",
            redirectURI: try requireURL("http://localhost:3000/callback"),
            transport: transport
        )
        Issue.record("Expected token exchange error response to throw.")
    } catch let error as MCPOAuthServerError {
        #expect(error.statusCode == 400)
        #expect(error.code == "invalid_grant")
        #expect(error.message == "Bad code")
        #expect(error.uri == "https://auth.example.com/errors/invalid_grant")
    }
}
@Test func mcpOAuthAuthRegistersClientAndRedirectsToAuthorization() async throws {
    let provider = TestOAuthClientProvider(
        clientInformation: nil,
        state: "state123",
        supportsDynamicClientRegistration: true
    )
    let transport = RecordingTransport(responses: [
        jsonResponse("""
        {
          "resource": "https://resource.example.com/mcp",
          "authorization_servers": ["https://auth.example.com"]
        }
        """),
        oauthAuthorizationMetadataResponse(),
        jsonResponse("""
        {
          "client_id": "registered-client",
          "client_secret": "registered-secret",
          "redirect_uris": ["http://localhost:3000/callback"],
          "client_name": "Swift MCP Test"
        }
        """)
    ])

    let result = try await MCPOAuth.auth(
        provider: provider,
        serverURL: "https://resource.example.com/mcp/rpc",
        scope: "read",
        transport: transport
    )

    #expect(result == .redirect)
    #expect(await provider.savedClientInformation()?.clientID == "registered-client")
    #expect(await provider.savedClientInformation()?.authorizationServerURL?.absoluteString == "https://auth.example.com")
    #expect(await provider.savedClientInformation()?.tokenEndpoint?.absoluteString == "https://auth.example.com/token")
    #expect(await provider.savedAuthorizationServerInformation()?.authorizationServerURL.absoluteString == "https://auth.example.com")
    #expect(await provider.savedState() == "state123")
    #expect(await provider.savedCodeVerifier()?.isEmpty == false)
    let redirect = try await #require(provider.redirectedURL())
    let redirectQuery = try queryItems(redirect)
    #expect(redirect.absoluteString.hasPrefix("https://auth.example.com/authorize?"))
    #expect(redirectQuery["client_id"] == "registered-client")
    #expect(redirectQuery["state"] == "state123")
    #expect(redirectQuery["scope"] == "read")
    #expect(redirectQuery["resource"] == "https://resource.example.com/mcp")

    let requests = await transport.requests()
    #expect(requests.map(\.method) == ["GET", "GET", "POST"])
    #expect(requests.map { $0.url.absoluteString } == [
        "https://resource.example.com/.well-known/oauth-protected-resource/mcp/rpc",
        "https://auth.example.com/.well-known/oauth-authorization-server",
        "https://auth.example.com/register"
    ])
}

@Test func mcpOAuthAuthSelectsProtectedResourceScopesBeforeClientDefaultsLikeUpstream() async throws {
    let provider = TestOAuthClientProvider(
        clientInformation: try oauthClientInformation(),
        state: "state123"
    )
    let transport = RecordingTransport(responses: [
        jsonResponse("""
        {
          "resource": "https://resource.example.com/mcp",
          "authorization_servers": ["https://auth.example.com"],
          "scopes_supported": ["tools:read", "tools:write"]
        }
        """),
        oauthAuthorizationMetadataResponse()
    ])

    let result = try await MCPOAuth.auth(
        provider: provider,
        serverURL: "https://resource.example.com/mcp/rpc",
        transport: transport
    )

    #expect(result == .redirect)
    let redirect = try await #require(provider.redirectedURL())
    #expect(try queryItems(redirect)["scope"] == "tools:read tools:write")
}
@Test func mcpOAuthAuthValidatesAuthorizationServerURLBeforeMetadataDiscovery() async throws {
    struct BlockedAuthorizationServer: Error {}

    let provider = TestOAuthClientProvider(
        clientInformation: nil,
        supportsDynamicClientRegistration: true,
        customAuthorizationServerValidator: { serverURL, authorizationServerURL in
            #expect(serverURL.absoluteString == "https://resource.example.com/mcp/rpc")
            #expect(authorizationServerURL.absoluteString == "https://auth.example.com")
            throw BlockedAuthorizationServer()
        }
    )
    let transport = RecordingTransport(responses: [
        jsonResponse("""
        {
          "resource": "https://resource.example.com/mcp",
          "authorization_servers": ["https://auth.example.com"]
        }
        """),
        oauthAuthorizationMetadataResponse()
    ])

    do {
        _ = try await MCPOAuth.auth(
            provider: provider,
            serverURL: "https://resource.example.com/mcp/rpc",
            transport: transport
        )
        Issue.record("Expected authorization server URL validator to throw.")
    } catch is BlockedAuthorizationServer {
        let validated = await provider.validatedAuthorizationServerURLs()
        #expect(validated.map { $0.authorizationServerURL.absoluteString } == ["https://auth.example.com"])
        let requests = await transport.requests()
        #expect(requests.map(\.url.absoluteString) == [
            "https://resource.example.com/.well-known/oauth-protected-resource/mcp/rpc"
        ])
    }
}
@Test func mcpOAuthAuthExchangesCallbackCodeAndValidatesState() async throws {
    let provider = TestOAuthClientProvider(
        clientInformation: try oauthClientInformation(),
        codeVerifier: "verifier123",
        storedState: "state123"
    )
    let transport = RecordingTransport(responses: [
        jsonResponse("""
        {
          "resource": "https://resource.example.com/mcp",
          "authorization_servers": ["https://auth.example.com"]
        }
        """),
        oauthAuthorizationMetadataResponse(),
        jsonResponse("""
        {
          "access_token": "access-123",
          "token_type": "Bearer",
          "refresh_token": "refresh-123"
        }
        """)
    ])

    let result = try await MCPOAuth.auth(
        provider: provider,
        serverURL: "https://resource.example.com/mcp/rpc",
        authorizationCode: "code123",
        callbackState: "state123",
        transport: transport
    )

    #expect(result == .authorized)
    #expect(await provider.savedTokens()?.accessToken == "access-123")
    #expect(await provider.savedTokens()?.authorizationServerURL?.absoluteString == "https://auth.example.com")
    #expect(await provider.savedTokens()?.tokenEndpoint?.absoluteString == "https://auth.example.com/token")
    let request = try await #require(transport.requests().last)
    let form = try formItems(request)
    #expect(request.url.absoluteString == "https://auth.example.com/token")
    #expect(form["grant_type"] == "authorization_code")
    #expect(form["code"] == "code123")
    #expect(form["code_verifier"] == "verifier123")
    #expect(form["resource"] == "https://resource.example.com/mcp")
}
@Test func mcpOAuthAuthRejectsMismatchedCallbackState() async throws {
    let provider = TestOAuthClientProvider(
        clientInformation: MCPOAuthClientInformation(clientID: "client123"),
        codeVerifier: "verifier123",
        storedState: "expected-state"
    )
    let transport = RecordingTransport(responses: [
        AIHTTPResponse(statusCode: 404),
        oauthAuthorizationMetadataResponse()
    ])

    do {
        _ = try await MCPOAuth.auth(
            provider: provider,
            serverURL: "https://auth.example.com",
            authorizationCode: "code123",
            callbackState: "callback-state",
            transport: transport
        )
        Issue.record("Expected mismatched OAuth state to throw.")
    } catch let error as MCPClientError {
        #expect(error.message == "OAuth state parameter mismatch - possible CSRF attack")
    }
}
@Test func mcpOAuthAuthRefreshesExistingTokens() async throws {
    let provider = TestOAuthClientProvider(
        clientInformation: try oauthClientInformation(),
        tokens: try oauthTokens(accessToken: "old-access", refreshToken: "old-refresh")
    )
    let transport = RecordingTransport(responses: [
        jsonResponse("""
        {
          "resource": "https://resource.example.com/mcp",
          "authorization_servers": ["https://auth.example.com"]
        }
        """),
        oauthAuthorizationMetadataResponse(),
        jsonResponse("""
        {
          "access_token": "new-access",
          "token_type": "Bearer"
        }
        """)
    ])

    let result = try await MCPOAuth.auth(
        provider: provider,
        serverURL: "https://resource.example.com/mcp/rpc",
        transport: transport
    )

    #expect(result == .authorized)
    #expect(await provider.savedTokens()?.accessToken == "new-access")
    #expect(await provider.savedTokens()?.refreshToken == "old-refresh")
    #expect(await provider.redirectedURL() == nil)
    let request = try await #require(transport.requests().last)
    let form = try formItems(request)
    #expect(form["grant_type"] == "refresh_token")
    #expect(form["refresh_token"] == "old-refresh")
}
@Test func mcpOAuthAuthRejectsMismatchedProtectedResource() async throws {
    let provider = TestOAuthClientProvider(clientInformation: MCPOAuthClientInformation(clientID: "client123"))
    let transport = RecordingTransport(response: jsonResponse("""
    {
      "resource": "https://other.example.com/mcp",
      "authorization_servers": ["https://auth.example.com"]
    }
    """))

    do {
        _ = try await MCPOAuth.auth(
            provider: provider,
            serverURL: "https://resource.example.com/mcp/rpc",
            transport: transport
        )
        Issue.record("Expected protected-resource mismatch to throw.")
    } catch let error as MCPClientError {
        #expect(error.message.contains("does not match expected https://resource.example.com/mcp/rpc"))
    }
}
@Test func mcpOAuthAuthCodeInvalidGrantPreservesCredentialsAndDoesNotRetry() async throws {
    let provider = TestOAuthClientProvider(
        clientInformation: try oauthClientInformation(),
        codeVerifier: "verifier123",
        storedState: "state123"
    )
    let transport = RecordingTransport(responses: [
        jsonResponse("""
        {
          "resource": "https://resource.example.com/mcp",
          "authorization_servers": ["https://auth.example.com"]
        }
        """),
        oauthAuthorizationMetadataResponse(),
        AIHTTPResponse(statusCode: 400, headers: ["content-type": "application/json"], body: Data("""
        {
          "error": "invalid_grant",
          "error_description": "Bad code"
        }
        """.utf8)),
        jsonResponse("""
        {
          "resource": "https://resource.example.com/mcp",
          "authorization_servers": ["https://auth.example.com"]
        }
        """),
        oauthAuthorizationMetadataResponse(),
        jsonResponse("""
        {
          "access_token": "access-after-retry",
          "token_type": "Bearer"
        }
        """)
    ])

    do {
        _ = try await MCPOAuth.auth(
            provider: provider,
            serverURL: "https://resource.example.com/mcp/rpc",
            authorizationCode: "code123",
            callbackState: "state123",
            transport: transport
        )
        Issue.record("Expected invalid authorization code")
    } catch let error as MCPOAuthServerError {
        #expect(error.code == "invalid_grant")
    }
    #expect(await provider.invalidations().isEmpty)
    #expect(await provider.savedTokens() == nil)
    #expect(await transport.requests().count == 3)
}
@Test func mcpOAuthAuthUsesProviderCustomClientAuthentication() async throws {
    let information = try oauthAuthorizationServerInformation()
    let provider = TestOAuthClientProvider(
        clientInformation: MCPOAuthClientInformation(
            clientID: "client123",
            clientSecret: "secret123",
            authorizationServerURL: information.authorizationServerURL,
            tokenEndpoint: information.tokenEndpoint
        ),
        codeVerifier: "verifier123",
        storedState: "state123",
        customAuthentication: { request in
            var customized = request
            customized.headers["X-Provider-Auth"] = request.metadata?.issuer
            customized.parameters.append(URLQueryItem(name: "client_assertion", value: "provider-token"))
            return customized
        }
    )
    let transport = RecordingTransport(responses: [
        jsonResponse("""
        {
          "resource": "https://resource.example.com/mcp",
          "authorization_servers": ["https://auth.example.com"]
        }
        """),
        oauthAuthorizationMetadataResponse(),
        jsonResponse("""
        {
          "access_token": "access-123",
          "token_type": "Bearer"
        }
        """)
    ])

    let result = try await MCPOAuth.auth(
        provider: provider,
        serverURL: "https://resource.example.com/mcp/rpc",
        authorizationCode: "code123",
        callbackState: "state123",
        transport: transport
    )

    #expect(result == .authorized)
    let request = try await #require(transport.requests().last)
    #expect(request.headers["Authorization"] == nil)
    #expect(request.headers["X-Provider-Auth"] == "https://auth.example.com")
    let form = try formItems(request)
    #expect(form["client_assertion"] == "provider-token")
    #expect(form["client_secret"] == nil)
}

@Test func mcpOAuthCallbackUsesStoredAuthorizationServerWhenResourceRediscoveryFails() async throws {
    let authorizationServerURL = try requireURL("https://login.example.com/tenant/v2.0")
    let tokenEndpoint = try requireURL("https://login.example.com/tenant/oauth2/v2.0/token")
    let storedInformation = MCPOAuthAuthorizationServerInformation(
        authorizationServerURL: authorizationServerURL,
        tokenEndpoint: tokenEndpoint,
        issuer: authorizationServerURL.absoluteString
    )
    let provider = TestOAuthClientProvider(
        clientInformation: MCPOAuthClientInformation(
            clientID: "test-client",
            issuer: authorizationServerURL.absoluteString,
            authorizationServerURL: authorizationServerURL,
            tokenEndpoint: tokenEndpoint
        ),
        authorizationServerInformation: storedInformation,
        codeVerifier: "test-verifier"
    )
    let transport = RecordingTransport(responses: [
        AIHTTPResponse(statusCode: 401),
        AIHTTPResponse(statusCode: 401),
        AIHTTPResponse(statusCode: 404),
        AIHTTPResponse(statusCode: 404),
        AIHTTPResponse(statusCode: 404),
        jsonResponse("""
        {
          "issuer": "https://login.example.com/tenant/v2.0",
          "authorization_endpoint": "https://login.example.com/tenant/oauth2/v2.0/authorize",
          "token_endpoint": "https://login.example.com/tenant/oauth2/v2.0/token",
          "response_types_supported": ["code"],
          "code_challenge_methods_supported": ["S256"]
        }
        """),
        jsonResponse("""
        {
          "access_token": "access123",
          "token_type": "Bearer"
        }
        """)
    ])

    let result = try await MCPOAuth.auth(
        provider: provider,
        serverURL: "https://mcp.example.com/mcp",
        authorizationCode: "auth-code-123",
        transport: transport
    )

    #expect(result == .authorized)
    #expect(await provider.savedTokens()?.accessToken == "access123")
    #expect(await provider.savedTokens()?.authorizationServerURL == authorizationServerURL)
    #expect(await provider.savedTokens()?.tokenEndpoint == tokenEndpoint)

    let requests = await transport.requests()
    #expect(requests.map { $0.url.absoluteString } == [
        "https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
        "https://mcp.example.com/.well-known/oauth-protected-resource",
        "https://login.example.com/.well-known/oauth-authorization-server/tenant/v2.0",
        "https://login.example.com/.well-known/oauth-authorization-server",
        "https://login.example.com/.well-known/openid-configuration/tenant/v2.0",
        "https://login.example.com/tenant/v2.0/.well-known/openid-configuration",
        "https://login.example.com/tenant/oauth2/v2.0/token"
    ])
    let tokenRequest = try #require(requests.last)
    let form = try formItems(tokenRequest)
    #expect(form["code"] == "auth-code-123")
    #expect(form["code_verifier"] == "test-verifier")
}
