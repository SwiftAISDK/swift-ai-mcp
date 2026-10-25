@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

private actor PaginatedToolsMCPTransport: MCPTransport {
    private var messages: [JSONValue] = []

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
                    "capabilities": ["tools": .object([:])],
                    "serverInfo": ["name": "paginated-tools", "version": "1"]
                ]
            ]
        case "tools/list":
            if message["params"]?["cursor"]?.stringValue == "page-2" {
                return [
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": [
                        "tools": [[
                            "name": "second",
                            "description": "Second page",
                            "inputSchema": ["type": "object"]
                        ]]
                    ]
                ]
            }
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "nextCursor": "page-2",
                    "tools": [[
                        "name": "first",
                        "description": "First page",
                        "inputSchema": ["type": "object"]
                    ]]
                ]
            ]
        default:
            return [
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32601, "message": "Unknown method"]
            ]
        }
    }

    func notify(_ message: JSONValue) async throws {
        messages.append(message)
    }

    func close() async throws {}

    func sentMessages() -> [JSONValue] { messages }
}

@Test func mcpToolsLoadsEveryCursorPageLikeUpstream() async throws {
    let transport = PaginatedToolsMCPTransport()
    let client = try await MCPClient.connect(transport: transport)

    let tools = try await client.tools()

    #expect(Set(tools.keys) == ["first", "second"])
    let requests = await transport.sentMessages().filter {
        $0["method"]?.stringValue == "tools/list"
    }
    #expect(requests.count == 2)
    #expect(requests[0]["params"] == nil)
    #expect(requests[1]["params"]?["cursor"]?.stringValue == "page-2")
}

@Test func mcpOAuthRejectsPrivateTokenAndRegistrationEndpointsBeforeSendingCredentials() async throws {
    let transport = RecordingTransport(response: jsonResponse(#"{"access_token":"should-not-be-used"}"#))
    let unsafeTokenMetadata = MCPOAuthAuthorizationServerMetadata(
        issuer: "https://auth.example.com",
        authorizationEndpoint: try requireURL("https://auth.example.com/authorize"),
        tokenEndpoint: try requireURL("http://169.254.169.254/latest/token"),
        responseTypesSupported: ["code"],
        codeChallengeMethodsSupported: ["S256"]
    )

    await #expect(throws: MCPClientError.self) {
        _ = try await MCPOAuth.exchangeAuthorization(
            authorizationServerURL: try requireURL("https://auth.example.com"),
            metadata: unsafeTokenMetadata,
            clientInformation: try oauthClientInformation(),
            authorizationCode: "secret-code",
            codeVerifier: "secret-verifier",
            redirectURI: try requireURL("http://localhost:3000/callback"),
            transport: transport
        )
    }
    #expect(await transport.requests().isEmpty)

    let unsafeRegistrationMetadata = MCPOAuthAuthorizationServerMetadata(
        issuer: "https://auth.example.com",
        authorizationEndpoint: try requireURL("https://auth.example.com/authorize"),
        tokenEndpoint: try requireURL("https://auth.example.com/token"),
        registrationEndpoint: try requireURL("http://169.254.169.254/latest/register"),
        responseTypesSupported: ["code"],
        codeChallengeMethodsSupported: ["S256"]
    )
    await #expect(throws: MCPClientError.self) {
        _ = try await MCPOAuth.registerClient(
            authorizationServerURL: try requireURL("https://auth.example.com"),
            metadata: unsafeRegistrationMetadata,
            clientMetadata: MCPOAuthClientMetadata(
                redirectURIs: [try requireURL("http://localhost:3000/callback")]
            ),
            transport: transport
        )
    }
    #expect(await transport.requests().isEmpty)
}

@Test func mcpOAuthRegistrationAndTokenPostsRejectRedirects() async throws {
    let registrationTransport = RecordingTransport(response: jsonResponse(#"{"client_id":"registered","redirect_uris":["http://localhost:3000/callback"]}"#))
    _ = try await MCPOAuth.registerClient(
        authorizationServerURL: try requireURL("https://auth.example.com"),
        metadata: MCPOAuthAuthorizationServerMetadata(
            issuer: "https://auth.example.com",
            authorizationEndpoint: try requireURL("https://auth.example.com/authorize"),
            tokenEndpoint: try requireURL("https://auth.example.com/token"),
            registrationEndpoint: try requireURL("https://auth.example.com/register"),
            responseTypesSupported: ["code"],
            codeChallengeMethodsSupported: ["S256"]
        ),
        clientMetadata: MCPOAuthClientMetadata(
            redirectURIs: [try requireURL("http://localhost:3000/callback")]
        ),
        transport: registrationTransport
    )
    #expect(await registrationTransport.requests().first?.followRedirects == false)

    let tokenTransport = RecordingTransport(response: jsonResponse(#"{"access_token":"access","token_type":"Bearer"}"#))
    _ = try await MCPOAuth.exchangeAuthorization(
        authorizationServerURL: try requireURL("https://auth.example.com"),
        metadata: MCPOAuthAuthorizationServerMetadata(
            issuer: "https://auth.example.com",
            authorizationEndpoint: try requireURL("https://auth.example.com/authorize"),
            tokenEndpoint: try requireURL("https://auth.example.com/token"),
            responseTypesSupported: ["code"],
            codeChallengeMethodsSupported: ["S256"]
        ),
        clientInformation: try oauthClientInformation(),
        authorizationCode: "code",
        codeVerifier: "verifier",
        redirectURI: try requireURL("http://localhost:3000/callback"),
        transport: tokenTransport
    )
    #expect(await tokenTransport.requests().first?.followRedirects == false)
}

@Test func mcpOAuthDynamicRegistrationUsesTheSelectedAuthorizationScope() async throws {
    let provider = TestOAuthClientProvider(
        clientInformation: nil,
        supportsDynamicClientRegistration: true
    )
    let transport = RecordingTransport(responses: [
        jsonResponse(#"{"resource":"https://resource.example.com/mcp","authorization_servers":["https://auth.example.com"],"scopes_supported":["tools:read","tools:write"]}"#),
        oauthAuthorizationMetadataResponse(),
        jsonResponse(#"{"client_id":"registered","redirect_uris":["http://localhost:3000/callback"]}"#)
    ])

    #expect(try await MCPOAuth.auth(
        provider: provider,
        serverURL: "https://resource.example.com/mcp/rpc",
        transport: transport
    ) == .redirect)

    let registrationRequest = try await #require(transport.requests().last)
    let registrationBody = try #require(registrationRequest.body).jsonValueForTest()
    #expect(registrationBody["scope"]?.stringValue == "tools:read tools:write")
    let redirect = try await #require(provider.redirectedURL())
    #expect(try queryItems(redirect)["scope"] == "tools:read tools:write")
}
