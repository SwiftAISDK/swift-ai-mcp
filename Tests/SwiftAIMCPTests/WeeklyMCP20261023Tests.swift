@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Suite("WeeklyMCP20261023")
struct WeeklyMCP20261023Tests {
    @Test(arguments: [false, true]) func discoveryTimeoutDependsOnTransportCapability(wait: Bool) async throws {
        let transport = WeeklyDiscoveryTransport(wait: wait, delay: 1_050_000_000)
        let client = try await MCPClient.connect(transport: transport)
        let expectedMethods = wait ? ["server/discover"] : ["server/discover", "initialize"]
        #expect(await transport.methods == expectedMethods)
        try await client.close()
        let http = try MCPHTTPTransport(url: "https://example.com/mcp")
        #expect(http.waitsForProtocolVersionDiscovery)
    }

    @Test func waitingDiscoveryStillHonorsOverallInitializationDeadline() async throws {
        let transport = WeeklyDiscoveryTransport(wait: true, delay: 5_000_000_000)
        await #expect(throws: MCPClientError.self) {
            try await MCPClient.connect(transport: transport, initializationOptions: .init(timeoutMilliseconds: 20))
        }
        #expect(await transport.closed)
    }

    private var resource: AIHTTPResponse {
        jsonResponse(#"{"resource":"https://resource.example.com/mcp","authorization_servers":["https://auth.example.com"]}"#)
    }

    @Test(arguments: [false, true]) func unboundSecretOrCustomAuthenticatorRejectsBeforeRedirect(custom: Bool) async throws {
        let authenticator: MCPOAuthClientAuthenticationHandler?
        if custom { authenticator = { request in request } } else { authenticator = nil }
        let provider = TestOAuthClientProvider(
            clientInformation: .init(clientID: "client", clientSecret: custom ? nil : "secret"),
            customAuthentication: authenticator
        )
        let transport = RecordingTransport(responses: [resource, oauthAuthorizationMetadataResponse()])
        await #expect(throws: MCPOAuthAuthorizationServerMismatchError.self) {
            try await MCPOAuth.auth(provider: provider, serverURL: "https://resource.example.com/mcp", transport: transport)
        }
        #expect(await provider.redirectedURL() == nil)
        #expect(await provider.savedClientInformation() == nil)
        #expect(await transport.requests().map(\.method) == ["GET", "GET"])
    }

    @Test func storedFlowPinCannotOverrideCredentialIssuer() async throws {
        let provider = TestOAuthClientProvider(clientInformation: .init(clientID: "client", clientSecret: "secret", issuer: "https://different.example.com"), authorizationServerInformation: try oauthAuthorizationServerInformation())
        let transport = RecordingTransport(responses: [resource, oauthAuthorizationMetadataResponse()])
        await #expect(throws: MCPOAuthAuthorizationServerMismatchError.self) {
            try await MCPOAuth.auth(provider: provider, serverURL: "https://resource.example.com/mcp", transport: transport)
        }
        #expect(await provider.redirectedURL() == nil)
        #expect(await transport.requests().allSatisfy { $0.method == "GET" })
    }

    @Test func credentialEndpointsAreCheckedEvenWhenStoredFlowPinMatches() async throws {
        let provider = TestOAuthClientProvider(clientInformation: .init(clientID: "client", clientSecret: "secret", authorizationServerURL: try requireURL("https://auth.example.com"), tokenEndpoint: try requireURL("https://different.example.com/token")), authorizationServerInformation: try oauthAuthorizationServerInformation())
        let transport = RecordingTransport(responses: [resource, oauthAuthorizationMetadataResponse()])
        await #expect(throws: MCPOAuthAuthorizationServerMismatchError.self) {
            try await MCPOAuth.auth(provider: provider, serverURL: "https://resource.example.com/mcp", transport: transport)
        }
        #expect(await transport.requests().count == 2)
    }

    @Test func pinnedSecretAndUnboundPublicClientCanStartAuthorization() async throws {
        for client in [MCPOAuthClientInformation(clientID: "public"), .init(clientID: "secret", clientSecret: "secret", issuer: "https://auth.example.com")] {
            let provider = TestOAuthClientProvider(clientInformation: client)
            let transport = RecordingTransport(responses: [resource, oauthAuthorizationMetadataResponse()])
            #expect(try await MCPOAuth.auth(provider: provider, serverURL: "https://resource.example.com/mcp", transport: transport) == .redirect)
            #expect(await provider.redirectedURL()?.host == "auth.example.com")
        }
    }

    @Test func invalidGrantRetryKeepsValidatedTokenBindingAfterInvalidation() async throws {
        let provider = TestOAuthClientProvider(clientInformation: .init(clientID: "client", clientSecret: "secret"), tokens: try oauthTokens(accessToken: "old", refreshToken: "refresh"))
        let changedResource = jsonResponse(#"{"resource":"https://resource.example.com/mcp","authorization_servers":["https://changed.example.com"]}"#)
        let changedMetadata = jsonResponse(#"{"issuer":"https://changed.example.com","authorization_endpoint":"https://changed.example.com/authorize","token_endpoint":"https://changed.example.com/token","response_types_supported":["code"],"code_challenge_methods_supported":["S256"]}"#)
        let transport = RecordingTransport(responses: [resource, oauthAuthorizationMetadataResponse(), AIHTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8)), changedResource, changedMetadata])
        await #expect(throws: MCPOAuthAuthorizationServerMismatchError.self) {
            try await MCPOAuth.auth(provider: provider, serverURL: "https://resource.example.com/mcp", transport: transport)
        }
        #expect(await provider.invalidations() == [.tokens])
        #expect(await provider.redirectedURL() == nil)
        let requests = await transport.requests()
        #expect(requests.filter { $0.method == "POST" }.map { $0.url.host } == ["auth.example.com"])
        #expect(requests.count == 5)
    }

    @Test func invalidGrantRetryToSameServerCanRedirectAndExchangeCode() async throws {
        let provider = TestOAuthClientProvider(clientInformation: .init(clientID: "client", clientSecret: "secret"), tokens: try oauthTokens(accessToken: "old", refreshToken: "refresh"))
        let transport = RecordingTransport(responses: [resource, oauthAuthorizationMetadataResponse(),
            AIHTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8)),
            resource, oauthAuthorizationMetadataResponse()])
        #expect(try await MCPOAuth.auth(provider: provider, serverURL: "https://resource.example.com/mcp", transport: transport) == .redirect)
        #expect(await provider.invalidations() == [.tokens])
        #expect(await provider.savedAuthorizationServerInformation()?.authorizationServerURL.host == "auth.example.com")
        let callback = RecordingTransport(responses: [resource, oauthAuthorizationMetadataResponse(), jsonResponse(#"{"access_token":"new","token_type":"Bearer"}"#)])
        #expect(try await MCPOAuth.auth(provider: provider, serverURL: "https://resource.example.com/mcp", authorizationCode: "code", transport: callback) == .authorized)
        #expect(await provider.savedTokens()?.accessToken == "new")
        #expect(await callback.requests().last?.url.absoluteString == "https://auth.example.com/token")
    }

    #if os(macOS) || os(Linux)
    @Test(arguments: [MCPStdioShell.system, .executable("/bin/sh")])
    func explicitShellRunsShellSyntaxAndEnvironmentExpansion(shell: MCPStdioShell) async throws {
        let command = #"while IFS= read -r line; do printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"shell\":\"$WEEKLY_SHELL_VALUE\"}}"; done"#
        let transport = MCPStdioTransport(command: command, env: ["WEEKLY_SHELL_VALUE": "expanded"], shell: shell)
        try await transport.start()
        do {
            let response = try await transport.request(["jsonrpc": "2.0", "id": 7, "method": "echo"], options: .init(timeoutMilliseconds: 2_000))
            #expect(response["result"]?["shell"] == "expanded")
            try await transport.close()
        } catch { try? await transport.close(); throw error }
    }
    #endif
}

private actor WeeklyDiscoveryTransport: MCPTransport {
    nonisolated let supportsProtocolVersionDiscovery = true
    nonisolated let waitsForProtocolVersionDiscovery: Bool
    let delay: UInt64
    var methods: [String] = []
    var closed = false
    init(wait: Bool, delay: UInt64) { waitsForProtocolVersionDiscovery = wait; self.delay = delay }
    func start() async throws {}
    func request(_ message: JSONValue) async throws -> JSONValue { try await request(message, options: nil) }
    func request(_ message: JSONValue, options: MCPRequestOptions?) async throws -> JSONValue {
        let method = message["method"]?.stringValue ?? ""
        methods.append(method)
        if method == "server/discover" {
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            return ["jsonrpc": "2.0", "id": message["id"] ?? 0, "result": ["resultType": "complete", "supportedVersions": [.string(MCPClient.latestProtocolVersion)], "capabilities": [:]]]
        }
        if method == "initialize" {
            return ["jsonrpc": "2.0", "id": message["id"] ?? 0, "result": ["protocolVersion": .string(MCPClient.latestLegacyProtocolVersion), "capabilities": [:], "serverInfo": ["name": "legacy", "version": "1"]]]
        }
        throw MCPClientError(message: "Unexpected method")
    }
    func notify(_ message: JSONValue) async throws {}
    func close() async throws { closed = true }
}
