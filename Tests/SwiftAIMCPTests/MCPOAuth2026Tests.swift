@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

private func mcpOAuth2026RegistrationBody(
    redirectURL: String,
    applicationType: MCPOAuthApplicationType? = nil
) async throws -> JSONValue {
    let transport = RecordingTransport(response: jsonResponse("""
    {
      "client_id": "registered-client",
      "redirect_uris": ["http://localhost:3000/callback"]
    }
    """))
    _ = try await MCPOAuth.registerClient(
        authorizationServerURL: try requireURL("https://auth.example.com"),
        clientMetadata: MCPOAuthClientMetadata(
            redirectURIs: [try requireURL(redirectURL)],
            applicationType: applicationType
        ),
        transport: transport
    )
    let request = try await #require(transport.requests().first)
    return try #require(request.body).jsonValueForTest()
}

private func mcpOAuth2026PinnedClientInformation() throws -> MCPOAuthClientInformation {
    MCPOAuthClientInformation(
        clientID: "client123",
        issuer: "https://auth.example.com",
        authorizationServerURL: try requireURL("https://auth.example.com"),
        tokenEndpoint: try requireURL("https://auth.example.com/token")
    )
}

private func mcpOAuth2026ProtectedResourceResponse() -> AIHTTPResponse {
    jsonResponse("""
    {
      "resource": "https://resource.example.com/mcp",
      "authorization_servers": ["https://auth.example.com"]
    }
    """)
}

@Test func mcpOAuth2026RegistrationInfersAndPreservesApplicationType() async throws {
    let loopback = try await mcpOAuth2026RegistrationBody(
        redirectURL: "http://localhost:3000/callback"
    )
    #expect(loopback["application_type"]?.stringValue == "native")

    let trailingDotLoopback = try await mcpOAuth2026RegistrationBody(
        redirectURL: "http://localhost./callback"
    )
    #expect(trailingDotLoopback["application_type"]?.stringValue == "native")

    let customScheme = try await mcpOAuth2026RegistrationBody(
        redirectURL: "swift-ai-sdk://oauth/callback"
    )
    #expect(customScheme["application_type"]?.stringValue == "native")

    let remote = try await mcpOAuth2026RegistrationBody(
        redirectURL: "https://app.example.com/oauth/callback"
    )
    #expect(remote["application_type"]?.stringValue == "web")

    let explicit = try await mcpOAuth2026RegistrationBody(
        redirectURL: "http://localhost:3000/callback",
        applicationType: .web
    )
    #expect(explicit["application_type"]?.stringValue == "web")
}

@Test func mcpOAuth2026RejectsMismatchedCallbackIssuerBeforeTokenExchange() async throws {
    let provider = TestOAuthClientProvider(
        clientInformation: try mcpOAuth2026PinnedClientInformation(),
        codeVerifier: "verifier123",
        storedState: "state123"
    )
    let transport = RecordingTransport(responses: [
        mcpOAuth2026ProtectedResourceResponse(),
        oauthAuthorizationMetadataResponse()
    ])

    do {
        _ = try await MCPOAuth.auth(
            provider: provider,
            serverURL: "https://resource.example.com/mcp/rpc",
            authorizationCode: "code123",
            callbackState: "state123",
            callbackIssuer: "https://evil.example",
            transport: transport
        )
        Issue.record("Expected a mismatched OAuth callback issuer to throw.")
    } catch let error as MCPClientError {
        #expect(error.message.contains("does not match expected issuer https://auth.example.com"))
    }

    let requests = await transport.requests()
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.url.absoluteString != "https://auth.example.com/token" })
}

@Test func mcpOAuth2026AcceptsMatchingIssuerAndPinsItToTokens() async throws {
    let provider = TestOAuthClientProvider(
        clientInformation: try mcpOAuth2026PinnedClientInformation(),
        codeVerifier: "verifier123",
        storedState: "state123"
    )
    let transport = RecordingTransport(responses: [
        mcpOAuth2026ProtectedResourceResponse(),
        oauthAuthorizationMetadataResponse(),
        jsonResponse("""
        {
          "access_token": "access-2026",
          "token_type": "Bearer"
        }
        """)
    ])

    let result = try await MCPOAuth.auth(
        provider: provider,
        serverURL: "https://resource.example.com/mcp/rpc",
        authorizationCode: "code123",
        callbackState: "state123",
        callbackIssuer: "https://auth.example.com",
        transport: transport
    )

    #expect(result == .authorized)
    #expect(await provider.savedTokens()?.issuer == "https://auth.example.com")
    #expect(await provider.savedTokens()?.authorizationServerURL?.absoluteString == "https://auth.example.com")
    #expect(await provider.savedTokens()?.tokenEndpoint?.absoluteString == "https://auth.example.com/token")
    #expect(await provider.savedTokens()?.rawValue["issuer"]?.stringValue == "https://auth.example.com")
    #expect((await transport.requests()).last?.url.absoluteString == "https://auth.example.com/token")
}

@Test func mcpOAuth2026ParsesIssuerCapabilityMetadataAndValidatesApplicationType() async throws {
    let transport = RecordingTransport(response: jsonResponse("""
    {
      "issuer": "https://auth.example.com",
      "authorization_endpoint": "https://auth.example.com/authorize",
      "token_endpoint": "https://auth.example.com/token",
      "authorization_response_iss_parameter_supported": true,
      "client_id_metadata_document_supported": false,
      "response_types_supported": ["code"],
      "code_challenge_methods_supported": ["S256"]
    }
    """))
    let metadata = try await #require(MCPOAuthDiscovery.discoverAuthorizationServerMetadata(
        authorizationServerURL: "https://auth.example.com",
        transport: transport
    ))

    #expect(metadata.authorizationResponseIssuerParameterSupported == true)
    #expect(metadata.clientIDMetadataDocumentSupported == false)

    do {
        _ = try MCPOAuthClientMetadata(json: [
            "redirect_uris": ["http://localhost:3000/callback"],
            "application_type": "confidential"
        ])
        Issue.record("Expected an invalid OAuth application_type to throw.")
    } catch let error as MCPClientError {
        #expect(error.message.contains("application_type to be native or web"))
    }
}
