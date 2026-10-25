@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Test func mcpOAuthProtectedResourceDiscoveryUsesPathAndPreservesQuery() async throws {
    let transport = RecordingTransport(response: jsonResponse("""
    {
      "resource": "https://resource.example.com",
      "authorization_servers": ["https://auth.example.com"],
      "scopes_supported": ["email", "mcp"]
    }
    """))

    let metadata = try await MCPOAuthDiscovery.discoverProtectedResourceMetadata(
        serverURL: "https://resource.example.com/path?param=value",
        transport: transport
    )

    #expect(metadata.resource.absoluteString == "https://resource.example.com")
    #expect(metadata.authorizationServers.map(\.absoluteString) == ["https://auth.example.com"])
    #expect(metadata.scopesSupported == ["email", "mcp"])

    let request = try await #require(transport.requests().first)
    #expect(request.method == "GET")
    #expect(request.url.absoluteString == "https://resource.example.com/.well-known/oauth-protected-resource/path?param=value")
    #expect(request.headers["MCP-Protocol-Version"] == MCPClient.latestProtocolVersion)
}
@Test func mcpOAuthProtectedResourceDiscoveryFallsBackToRootOnPath4xx() async throws {
    let transport = RecordingTransport(responses: [
        AIHTTPResponse(statusCode: 404),
        jsonResponse("""
        {
          "resource": "https://resource.example.com",
          "authorization_servers": ["https://auth.example.com"]
        }
        """)
    ])

    let metadata = try await MCPOAuthDiscovery.discoverProtectedResourceMetadata(
        serverURL: "https://resource.example.com/path/name",
        transport: transport
    )

    #expect(metadata.authorizationServers.first?.absoluteString == "https://auth.example.com")
    let requests = await transport.requests()
    #expect(requests.map { $0.url.absoluteString } == [
        "https://resource.example.com/.well-known/oauth-protected-resource/path/name",
        "https://resource.example.com/.well-known/oauth-protected-resource"
    ])
}
@Test func mcpOAuthProtectedResourceDiscoveryRetriesWithoutProtocolHeaderAfterTransportError() async throws {
    let transport = FailingDiscoveryTransport(actions: [
        .fail,
        .respond(jsonResponse("""
        {
          "resource": "https://resource.example.com",
          "authorization_servers": ["https://auth.example.com"]
        }
        """))
    ])

    let metadata = try await MCPOAuthDiscovery.discoverProtectedResourceMetadata(
        serverURL: "https://resource.example.com",
        transport: transport
    )

    #expect(metadata.resource.absoluteString == "https://resource.example.com")
    let requests = await transport.requests()
    #expect(requests.map { $0.url.absoluteString } == [
        "https://resource.example.com/.well-known/oauth-protected-resource",
        "https://resource.example.com/.well-known/oauth-protected-resource"
    ])
    #expect(requests[0].headers["MCP-Protocol-Version"] == MCPClient.latestProtocolVersion)
    #expect(requests[1].headers["MCP-Protocol-Version"] == nil)
}
@Test func mcpOAuthProtectedResourceDiscoveryFallsBackToRootAfterCORSRetry404() async throws {
    let transport = FailingDiscoveryTransport(actions: [
        .fail,
        .respond(AIHTTPResponse(statusCode: 404)),
        .respond(jsonResponse("""
        {
          "resource": "https://resource.example.com",
          "authorization_servers": ["https://auth.example.com"]
        }
        """))
    ])

    let metadata = try await MCPOAuthDiscovery.discoverProtectedResourceMetadata(
        serverURL: "https://resource.example.com/path/name",
        transport: transport
    )

    #expect(metadata.authorizationServers.map(\.absoluteString) == ["https://auth.example.com"])
    let requests = await transport.requests()
    #expect(requests.map { $0.url.absoluteString } == [
        "https://resource.example.com/.well-known/oauth-protected-resource/path/name",
        "https://resource.example.com/.well-known/oauth-protected-resource/path/name",
        "https://resource.example.com/.well-known/oauth-protected-resource"
    ])
    #expect(requests[0].headers["MCP-Protocol-Version"] != nil)
    #expect(requests[1].headers["MCP-Protocol-Version"] == nil)
    #expect(requests[2].headers["MCP-Protocol-Version"] != nil)
}
@Test func mcpOAuthProtectedResourceDiscoveryThrowsForMissingMetadata() async throws {
    let transport = RecordingTransport(responses: [
        AIHTTPResponse(statusCode: 404),
        AIHTTPResponse(statusCode: 404)
    ])

    do {
        _ = try await MCPOAuthDiscovery.discoverProtectedResourceMetadata(
            serverURL: "https://resource.example.com/path/name",
            transport: transport
        )
        Issue.record("Expected protected-resource discovery to throw.")
    } catch let error as MCPClientError {
        #expect(error.message == "Resource server does not implement OAuth 2.0 Protected Resource Metadata.")
    }
}
@Test func mcpOAuthAuthorizationServerDiscoveryTriesPathAwareThenRoot() async throws {
    let transport = RecordingTransport(responses: [
        AIHTTPResponse(statusCode: 404),
        jsonResponse("""
        {
          "issuer": "https://auth.example.com",
          "authorization_endpoint": "https://auth.example.com/authorize",
          "token_endpoint": "https://auth.example.com/token",
          "registration_endpoint": "https://auth.example.com/register",
          "response_types_supported": ["code"],
          "code_challenge_methods_supported": ["S256"]
        }
        """)
    ])

    let metadata = try await MCPOAuthDiscovery.discoverAuthorizationServerMetadata(
        authorizationServerURL: "https://auth.example.com/tenant1",
        transport: transport
    )

    #expect(metadata?.issuer == "https://auth.example.com")
    #expect(metadata?.authorizationEndpoint.absoluteString == "https://auth.example.com/authorize")
    #expect(metadata?.registrationEndpoint?.absoluteString == "https://auth.example.com/register")
    let requests = await transport.requests()
    #expect(requests.map { $0.url.absoluteString } == [
        "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
        "https://auth.example.com/.well-known/oauth-authorization-server"
    ])
}
@Test func mcpOAuthAuthorizationServerDiscoveryRejectsMismatchedIssuerLikeUpstream() async throws {
    let transport = RecordingTransport(response: jsonResponse("""
    {
      "issuer": "https://evil.example.com",
      "authorization_endpoint": "https://auth.example.com/authorize",
      "token_endpoint": "https://auth.example.com/token",
      "response_types_supported": ["code"],
      "code_challenge_methods_supported": ["S256"]
    }
    """))

    do {
        _ = try await MCPOAuthDiscovery.discoverAuthorizationServerMetadata(
            authorizationServerURL: "https://auth.example.com/tenant1",
            transport: transport
        )
        Issue.record("Expected mismatched OAuth metadata issuer to throw.")
    } catch let error as MCPClientError {
        #expect(error.message == "OAuth authorization server metadata issuer https://evil.example.com does not match expected issuer https://auth.example.com/tenant1")
    }
}

@Test func mcpOAuthIssuerAllowsTrailingSlashOnlyForOriginLikeUpstream() throws {
    let baseMetadata: JSONValue = [
        "authorization_endpoint": "https://auth.example.com/authorize",
        "token_endpoint": "https://auth.example.com/token",
        "response_types_supported": ["code"],
        "code_challenge_methods_supported": ["S256"]
    ]

    var originMetadata = try #require(baseMetadata.objectValue)
    originMetadata["issuer"] = "https://auth.example.com/"
    let accepted = try MCPOAuthAuthorizationServerMetadata(
        json: .object(originMetadata),
        sourceURL: try requireURL("https://auth.example.com/.well-known/oauth-authorization-server"),
        sourceType: .oauth,
        expectedIssuer: "https://auth.example.com"
    )
    #expect(accepted.issuer == "https://auth.example.com/")

    var tenantMetadata = try #require(baseMetadata.objectValue)
    tenantMetadata["issuer"] = "https://auth.example.com/tenant1/"
    #expect(throws: MCPClientError.self) {
        _ = try MCPOAuthAuthorizationServerMetadata(
            json: .object(tenantMetadata),
            sourceURL: try requireURL("https://auth.example.com/.well-known/oauth-authorization-server/tenant1"),
            sourceType: .oauth,
            expectedIssuer: "https://auth.example.com/tenant1"
        )
    }
}
@Test func mcpOAuthAuthorizationServerDiscoveryRetriesWithoutProtocolHeaderAfterTransportError() async throws {
    let transport = FailingDiscoveryTransport(actions: [
        .fail,
        .respond(jsonResponse("""
        {
          "issuer": "https://auth.example.com",
          "authorization_endpoint": "https://auth.example.com/authorize",
          "token_endpoint": "https://auth.example.com/token",
          "response_types_supported": ["code"],
          "code_challenge_methods_supported": ["S256"]
        }
        """))
    ])

    let metadata = try await MCPOAuthDiscovery.discoverAuthorizationServerMetadata(
        authorizationServerURL: "https://auth.example.com",
        transport: transport
    )

    #expect(metadata?.issuer == "https://auth.example.com")
    let requests = await transport.requests()
    #expect(requests.map { $0.url.absoluteString } == [
        "https://auth.example.com/.well-known/oauth-authorization-server",
        "https://auth.example.com/.well-known/oauth-authorization-server"
    ])
    #expect(requests[0].headers["MCP-Protocol-Version"] != nil)
    #expect(requests[1].headers["MCP-Protocol-Version"] == nil)
}
@Test func mcpOAuthAuthorizationServerDiscoveryReturnsNilWhenAllCORSRetriesFail() async throws {
    let transport = FailingDiscoveryTransport(actions: Array(repeating: .fail, count: 8))

    let metadata = try await MCPOAuthDiscovery.discoverAuthorizationServerMetadata(
        authorizationServerURL: "https://auth.example.com/tenant1",
        transport: transport
    )

    #expect(metadata == nil)
    let requests = await transport.requests()
    #expect(requests.count == 8)
    #expect(requests.map { $0.headers["MCP-Protocol-Version"] != nil } == [
        true, false,
        true, false,
        true, false,
        true, false
    ])
    #expect(requests.map { $0.url.absoluteString } == [
        "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
        "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
        "https://auth.example.com/.well-known/oauth-authorization-server",
        "https://auth.example.com/.well-known/oauth-authorization-server",
        "https://auth.example.com/.well-known/openid-configuration/tenant1",
        "https://auth.example.com/.well-known/openid-configuration/tenant1",
        "https://auth.example.com/tenant1/.well-known/openid-configuration",
        "https://auth.example.com/tenant1/.well-known/openid-configuration"
    ])
}
@Test func mcpOAuthAuthorizationServerDiscoveryRejectsOIDCWithoutS256() async throws {
    let transport = RecordingTransport(responses: [
        AIHTTPResponse(statusCode: 404),
        jsonResponse("""
        {
          "issuer": "https://auth.example.com",
          "authorization_endpoint": "https://auth.example.com/authorize",
          "token_endpoint": "https://auth.example.com/token",
          "jwks_uri": "https://auth.example.com/jwks",
          "subject_types_supported": ["public"],
          "id_token_signing_alg_values_supported": ["RS256"],
          "response_types_supported": ["code"],
          "code_challenge_methods_supported": ["plain"]
        }
        """)
    ])

    do {
        _ = try await MCPOAuthDiscovery.discoverAuthorizationServerMetadata(
            authorizationServerURL: "https://auth.example.com",
            transport: transport
        )
        Issue.record("Expected OIDC metadata without S256 to throw.")
    } catch let error as MCPClientError {
        #expect(error.message.contains("does not support S256 code challenge method"))
    }
}
@Test func mcpOAuthAuthorizationServerDiscoveryReturnsNilWhenAllCandidatesAre4xx() async throws {
    let transport = RecordingTransport(responses: [
        AIHTTPResponse(statusCode: 404),
        AIHTTPResponse(statusCode: 404),
        AIHTTPResponse(statusCode: 404),
        AIHTTPResponse(statusCode: 404)
    ])

    let metadata = try await MCPOAuthDiscovery.discoverAuthorizationServerMetadata(
        authorizationServerURL: "https://auth.example.com/tenant1",
        transport: transport
    )

    #expect(metadata == nil)
    let requests = await transport.requests()
    #expect(requests.map { $0.url.absoluteString } == [
        "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
        "https://auth.example.com/.well-known/oauth-authorization-server",
        "https://auth.example.com/.well-known/openid-configuration/tenant1",
        "https://auth.example.com/tenant1/.well-known/openid-configuration"
    ])
}
@Test func mcpOAuthAuthorizationServerDiscoveryBuildsRootURLs() throws {
    let urls = MCPOAuthDiscovery.buildAuthorizationServerDiscoveryURLs(try requireURL("https://auth.example.com"))
    #expect(urls.map(\.absoluteString) == [
        "https://auth.example.com/.well-known/oauth-authorization-server",
        "https://auth.example.com/.well-known/openid-configuration"
    ])
}
@Test func mcpOAuthStartAuthorizationBuildsPKCEURL() throws {
    let metadata = MCPOAuthAuthorizationServerMetadata(
        issuer: "https://auth.example.com",
        authorizationEndpoint: try requireURL("https://auth.example.com/auth?existing=1"),
        tokenEndpoint: try requireURL("https://auth.example.com/token"),
        responseTypesSupported: ["code"],
        codeChallengeMethodsSupported: ["S256"]
    )

    let result = try MCPOAuth.startAuthorization(
        authorizationServerURL: "https://auth.example.com",
        metadata: metadata,
        clientInformation: MCPOAuthClientInformation(clientID: "client123"),
        redirectURL: "http://localhost:3000/callback",
        scope: "read offline_access",
        state: "state123",
        resource: "https://api.example.com/mcp-server",
        codeVerifier: "test_verifier"
    )

    let query = try queryItems(result.authorizationURL)
    #expect(result.codeVerifier == "test_verifier")
    #expect(result.authorizationURL.absoluteString.hasPrefix("https://auth.example.com/auth?"))
    #expect(query["existing"] == "1")
    #expect(query["response_type"] == "code")
    #expect(query["client_id"] == "client123")
    #expect(query["code_challenge"] == "0Ku4rR8EgR1w3HyHLBCxVLtPsAAks5HOlpmTEt0XhVA")
    #expect(query["code_challenge_method"] == "S256")
    #expect(query["redirect_uri"] == "http://localhost:3000/callback")
    #expect(query["scope"] == "read offline_access")
    #expect(query["state"] == "state123")
    #expect(query["prompt"] == "consent")
    #expect(query["resource"] == "https://api.example.com/mcp-server")
}
@Test func mcpOAuthStartAuthorizationValidatesMetadataCapabilities() throws {
    let metadata = MCPOAuthAuthorizationServerMetadata(
        issuer: "https://auth.example.com",
        authorizationEndpoint: try requireURL("https://auth.example.com/auth"),
        tokenEndpoint: try requireURL("https://auth.example.com/token"),
        responseTypesSupported: ["token"],
        codeChallengeMethodsSupported: ["S256"]
    )

    do {
        _ = try MCPOAuth.startAuthorization(
            authorizationServerURL: "https://auth.example.com",
            metadata: metadata,
            clientInformation: MCPOAuthClientInformation(clientID: "client123"),
            redirectURL: "http://localhost:3000/callback"
        )
        Issue.record("Expected authorization metadata validation to throw.")
    } catch let error as MCPClientError {
        #expect(error.message == "Incompatible auth server: does not support response type code")
    }
}
@Test func mcpOAuthExchangeAuthorizationPostsFormWithBasicClientAuth() async throws {
    let metadata = MCPOAuthAuthorizationServerMetadata(
        issuer: "https://auth.example.com",
        authorizationEndpoint: try requireURL("https://auth.example.com/auth"),
        tokenEndpoint: try requireURL("https://auth.example.com/token"),
        responseTypesSupported: ["code"],
        codeChallengeMethodsSupported: ["S256"],
        grantTypesSupported: ["authorization_code"],
        tokenEndpointAuthMethodsSupported: ["client_secret_basic"]
    )
    let transport = RecordingTransport(response: jsonResponse("""
    {
      "access_token": "access-123",
      "token_type": "Bearer",
      "expires_in": 3600,
      "refresh_token": "refresh-123"
    }
    """))

    let tokens = try await MCPOAuth.exchangeAuthorization(
        authorizationServerURL: try requireURL("https://auth.example.com"),
        metadata: metadata,
        clientInformation: MCPOAuthClientInformation(clientID: "client123", clientSecret: "secret123"),
        authorizationCode: "code123",
        codeVerifier: "verifier123",
        redirectURI: try requireURL("http://localhost:3000/callback"),
        resource: try requireURL("https://api.example.com"),
        transport: transport
    )

    #expect(tokens.accessToken == "access-123")
    #expect(tokens.refreshToken == "refresh-123")
    let request = try await #require(transport.requests().first)
    #expect(request.method == "POST")
    #expect(request.url.absoluteString == "https://auth.example.com/token")
    #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
    #expect(request.headers["Accept"] == "application/json")
    #expect(request.headers["Authorization"] == "Basic Y2xpZW50MTIzOnNlY3JldDEyMw==")
    let form = try formItems(request)
    #expect(form["grant_type"] == "authorization_code")
    #expect(form["code"] == "code123")
    #expect(form["code_verifier"] == "verifier123")
    #expect(form["redirect_uri"] == "http://localhost:3000/callback")
    #expect(form["resource"] == "https://api.example.com")
    #expect(form["client_id"] == nil)
}
@Test func mcpOAuthExchangeAuthorizationUsesCustomClientAuthentication() async throws {
    let metadata = MCPOAuthAuthorizationServerMetadata(
        issuer: "https://auth.example.com",
        authorizationEndpoint: try requireURL("https://auth.example.com/auth"),
        tokenEndpoint: try requireURL("https://auth.example.com/token"),
        responseTypesSupported: ["code"],
        codeChallengeMethodsSupported: ["S256"],
        grantTypesSupported: ["authorization_code"],
        tokenEndpointAuthMethodsSupported: ["client_secret_basic"]
    )
    let transport = RecordingTransport(response: jsonResponse("""
    {
      "access_token": "access-123",
      "token_type": "Bearer"
    }
    """))

    _ = try await MCPOAuth.exchangeAuthorization(
        authorizationServerURL: try requireURL("https://auth.example.com"),
        metadata: metadata,
        clientInformation: MCPOAuthClientInformation(clientID: "client123", clientSecret: "secret123"),
        authorizationCode: "code123",
        codeVerifier: "verifier123",
        redirectURI: try requireURL("http://localhost:3000/callback"),
        clientAuthentication: { request in
            var customized = request
            customized.headers["X-Client-Assertion"] = "assertion-123"
            customized.parameters.append(URLQueryItem(name: "client_assertion_type", value: "jwt-bearer"))
            customized.parameters.append(URLQueryItem(name: "client_assertion", value: "jwt-token"))
            return customized
        },
        transport: transport
    )

    let request = try await #require(transport.requests().first)
    #expect(request.headers["Authorization"] == nil)
    #expect(request.headers["X-Client-Assertion"] == "assertion-123")
    let form = try formItems(request)
    #expect(form["client_id"] == nil)
    #expect(form["client_secret"] == nil)
    #expect(form["client_assertion_type"] == "jwt-bearer")
    #expect(form["client_assertion"] == "jwt-token")
}
@Test func mcpOAuthRefreshAuthorizationPreservesRefreshTokenAndUsesPublicClientAuth() async throws {
    let metadata = MCPOAuthAuthorizationServerMetadata(
        issuer: "https://auth.example.com",
        authorizationEndpoint: try requireURL("https://auth.example.com/auth"),
        tokenEndpoint: try requireURL("https://auth.example.com/token"),
        responseTypesSupported: ["code"],
        codeChallengeMethodsSupported: ["S256"],
        grantTypesSupported: ["refresh_token"],
        tokenEndpointAuthMethodsSupported: ["none"]
    )
    let transport = RecordingTransport(response: jsonResponse("""
    {
      "access_token": "new-access",
      "token_type": "Bearer"
    }
    """))

    let tokens = try await MCPOAuth.refreshAuthorization(
        authorizationServerURL: try requireURL("https://auth.example.com"),
        metadata: metadata,
        clientInformation: MCPOAuthClientInformation(clientID: "public-client"),
        refreshToken: "old-refresh",
        resource: try requireURL("https://api.example.com/"),
        transport: transport
    )

    #expect(tokens.accessToken == "new-access")
    #expect(tokens.refreshToken == "old-refresh")
    let request = try await #require(transport.requests().first)
    let form = try formItems(request)
    #expect(form["grant_type"] == "refresh_token")
    #expect(form["refresh_token"] == "old-refresh")
    #expect(form["client_id"] == "public-client")
    #expect(form["resource"] == "https://api.example.com")
}
