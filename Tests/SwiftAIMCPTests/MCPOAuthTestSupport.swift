@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

func oauthAuthorizationMetadataResponse() -> AIHTTPResponse {
    jsonResponse("""
    {
      "issuer": "https://auth.example.com",
      "authorization_endpoint": "https://auth.example.com/authorize",
      "token_endpoint": "https://auth.example.com/token",
      "registration_endpoint": "https://auth.example.com/register",
      "response_types_supported": ["code"],
      "code_challenge_methods_supported": ["S256"],
      "grant_types_supported": ["authorization_code", "refresh_token"],
      "token_endpoint_auth_methods_supported": ["none", "client_secret_post"]
    }
    """)
}

func oauthAuthorizationServerInformation(
    authorizationServerURL: String = "https://auth.example.com",
    tokenEndpoint: String = "https://auth.example.com/token"
) throws -> MCPOAuthAuthorizationServerInformation {
    MCPOAuthAuthorizationServerInformation(
        authorizationServerURL: try requireURL(authorizationServerURL),
        tokenEndpoint: try requireURL(tokenEndpoint)
    )
}

func oauthClientInformation(clientID: String = "client123") throws -> MCPOAuthClientInformation {
    let information = try oauthAuthorizationServerInformation()
    return MCPOAuthClientInformation(
        clientID: clientID,
        authorizationServerURL: information.authorizationServerURL,
        tokenEndpoint: information.tokenEndpoint
    )
}

func oauthTokens(
    accessToken: String,
    tokenType: String = "Bearer",
    refreshToken: String? = nil
) throws -> MCPOAuthTokens {
    let information = try oauthAuthorizationServerInformation()
    return MCPOAuthTokens(
        accessToken: accessToken,
        tokenType: tokenType,
        refreshToken: refreshToken,
        authorizationServerURL: information.authorizationServerURL,
        tokenEndpoint: information.tokenEndpoint
    )
}

actor TestOAuthClientProvider: MCPOAuthClientProvider {
    nonisolated let redirectURL: URL
    nonisolated let clientMetadata: MCPOAuthClientMetadata
    nonisolated let supportsDynamicClientRegistration: Bool
    nonisolated let usesCustomClientAuthentication: Bool

    private var currentTokens: MCPOAuthTokens?
    private var currentClientInformation: MCPOAuthClientInformation?
    private var currentAuthorizationServerInformation: MCPOAuthAuthorizationServerInformation?
    private var currentCodeVerifier: String
    private var currentState: String?
    private var currentStoredState: String?
    private var savedTokenValue: MCPOAuthTokens?
    private var savedClientInformationValue: MCPOAuthClientInformation?
    private var savedAuthorizationServerInformationValue: MCPOAuthAuthorizationServerInformation?
    private var savedStateValue: String?
    private var savedCodeVerifierValue: String?
    private var redirectedURLValue: URL?
    private var invalidationValues: [MCPOAuthCredentialScope] = []
    private var validatedAuthorizationServerURLValues: [(serverURL: URL, authorizationServerURL: URL)] = []
    private let customAuthentication: MCPOAuthClientAuthenticationHandler?
    private let customAuthorizationServerValidator: (@Sendable (URL, URL) async throws -> Void)?

    init(
        redirectURL: URL = URL(string: "http://localhost:3000/callback")!,
        clientMetadata: MCPOAuthClientMetadata = MCPOAuthClientMetadata(
            redirectURIs: [URL(string: "http://localhost:3000/callback")!],
            clientName: "Swift MCP Test",
            scope: "default-scope"
        ),
        clientInformation: MCPOAuthClientInformation?,
        tokens: MCPOAuthTokens? = nil,
        authorizationServerInformation: MCPOAuthAuthorizationServerInformation? = nil,
        codeVerifier: String = "stored-verifier",
        state: String? = nil,
        storedState: String? = nil,
        supportsDynamicClientRegistration: Bool = false,
        customAuthentication: MCPOAuthClientAuthenticationHandler? = nil,
        customAuthorizationServerValidator: (@Sendable (URL, URL) async throws -> Void)? = nil
    ) {
        self.redirectURL = redirectURL
        self.clientMetadata = clientMetadata
        self.supportsDynamicClientRegistration = supportsDynamicClientRegistration
        self.currentClientInformation = clientInformation
        self.currentTokens = tokens
        self.currentAuthorizationServerInformation = authorizationServerInformation
        self.currentCodeVerifier = codeVerifier
        self.currentState = state
        self.currentStoredState = storedState
        self.customAuthentication = customAuthentication
        self.usesCustomClientAuthentication = customAuthentication != nil
        self.customAuthorizationServerValidator = customAuthorizationServerValidator
    }

    func tokens() async throws -> MCPOAuthTokens? {
        currentTokens
    }

    func saveTokens(_ tokens: MCPOAuthTokens) async throws {
        currentTokens = tokens
        savedTokenValue = tokens
    }

    func redirectToAuthorization(_ authorizationURL: URL) async throws {
        redirectedURLValue = authorizationURL
    }

    func saveCodeVerifier(_ codeVerifier: String) async throws {
        currentCodeVerifier = codeVerifier
        savedCodeVerifierValue = codeVerifier
    }

    func codeVerifier() async throws -> String {
        currentCodeVerifier
    }

    func invalidateCredentials(_ scope: MCPOAuthCredentialScope) async {
        invalidationValues.append(scope)
        if scope == .all || scope == .tokens {
            currentTokens = nil
        }
        if scope == .all || scope == .client {
            currentClientInformation = nil
        }
    }

    func clientInformation() async throws -> MCPOAuthClientInformation? {
        currentClientInformation
    }

    func authorizationServerInformation() async throws -> MCPOAuthAuthorizationServerInformation? {
        currentAuthorizationServerInformation
    }

    func saveAuthorizationServerInformation(_ information: MCPOAuthAuthorizationServerInformation) async throws {
        currentAuthorizationServerInformation = information
        savedAuthorizationServerInformationValue = information
    }

    func saveClientInformation(_ clientInformation: MCPOAuthClientInformation) async throws {
        currentClientInformation = clientInformation
        savedClientInformationValue = clientInformation
    }

    func state() async throws -> String? {
        currentState
    }

    func saveState(_ state: String) async throws {
        currentStoredState = state
        savedStateValue = state
    }

    func storedState() async throws -> String? {
        currentStoredState
    }

    func authenticateTokenRequest(_ request: MCPOAuthClientAuthenticationRequest) async throws -> MCPOAuthClientAuthenticationRequest? {
        try await customAuthentication?(request)
    }

    func validateAuthorizationServerURL(serverURL: URL, authorizationServerURL: URL) async throws {
        validatedAuthorizationServerURLValues.append((serverURL: serverURL, authorizationServerURL: authorizationServerURL))
        try await customAuthorizationServerValidator?(serverURL, authorizationServerURL)
    }

    func savedTokens() -> MCPOAuthTokens? {
        savedTokenValue
    }

    func savedClientInformation() -> MCPOAuthClientInformation? {
        savedClientInformationValue
    }

    func savedAuthorizationServerInformation() -> MCPOAuthAuthorizationServerInformation? {
        savedAuthorizationServerInformationValue
    }

    func savedState() -> String? {
        savedStateValue
    }

    func savedCodeVerifier() -> String? {
        savedCodeVerifierValue
    }

    func redirectedURL() -> URL? {
        redirectedURLValue
    }

    func invalidations() -> [MCPOAuthCredentialScope] {
        invalidationValues
    }

    func validatedAuthorizationServerURLs() -> [(serverURL: URL, authorizationServerURL: URL)] {
        validatedAuthorizationServerURLValues
    }
}
enum DiscoveryTransportAction: Sendable {
    case fail
    case respond(AIHTTPResponse)
}
struct DiscoveryTransportError: Error {}
actor FailingDiscoveryTransport: AITransport {
    private var recordedRequests: [AIHTTPRequest] = []
    private var actions: [DiscoveryTransportAction]

    init(actions: [DiscoveryTransportAction]) {
        self.actions = actions
    }

    func requests() -> [AIHTTPRequest] {
        recordedRequests
    }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        recordedRequests.append(request)
        guard !actions.isEmpty else {
            throw DiscoveryTransportError()
        }
        switch actions.removeFirst() {
        case .fail:
            throw DiscoveryTransportError()
        case let .respond(response):
            return response
        }
    }
}
func queryItems(_ url: URL) throws -> [String: String] {
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })
}
func formItems(_ request: AIHTTPRequest) throws -> [String: String] {
    let body = String(data: try #require(request.body), encoding: .utf8) ?? ""
    return Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair in
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        let name = parts[0].removingPercentEncoding ?? parts[0]
        let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
        return (name, value)
    })
}
