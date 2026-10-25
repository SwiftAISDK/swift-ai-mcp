import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public enum MCPOAuth {
    public static func auth(
        provider: any MCPOAuthClientProvider,
        serverURL: URL,
        authorizationCode: String? = nil,
        callbackState: String? = nil,
        callbackIssuer: String? = nil,
        scope: String? = nil,
        resourceMetadataURL: URL? = nil,
        protocolVersion: String = MCPClient.latestProtocolVersion,
        transport: any AITransport = URLSessionTransport.shared
    ) async throws -> MCPOAuthAuthResult {
        let refreshAttempt = MCPOAuthRefreshAttempt()
        do {
            return try await authInternal(
                provider: provider,
                serverURL: serverURL,
                authorizationCode: authorizationCode,
                callbackState: callbackState,
                callbackIssuer: callbackIssuer,
                scope: scope,
                resourceMetadataURL: resourceMetadataURL,
                protocolVersion: protocolVersion,
                transport: transport,
                refreshAttempt: refreshAttempt
            )
        } catch let error as MCPOAuthServerError {
            var retryAuthorizationServerInformation: MCPOAuthAuthorizationServerInformation?
            switch error.code {
            case "invalid_client", "unauthorized_client":
                // A callback exchange cannot be restarted safely, and a
                // pre-registered client is owned by the application rather
                // than the SDK. Only dynamically registered clients may be
                // invalidated and registered again automatically.
                let isDynamicallyRegistered = await provider.isClientInformationDynamicallyRegistered()
                if authorizationCode != nil || !isDynamicallyRegistered {
                    throw error
                }
                await provider.invalidateCredentials(.all)
            case "invalid_grant":
                guard let context = await refreshAttempt.context else { throw error }
                retryAuthorizationServerInformation = context.tokens.authorizationServerInformation
                await provider.invalidateCredentials(.tokens, context: context)
            default:
                throw error
            }
            return try await authInternal(
                provider: provider,
                serverURL: serverURL,
                authorizationCode: authorizationCode,
                callbackState: callbackState,
                callbackIssuer: callbackIssuer,
                scope: scope,
                resourceMetadataURL: resourceMetadataURL,
                protocolVersion: protocolVersion,
                transport: transport,
                retryAuthorizationServerInformation: retryAuthorizationServerInformation
            )
        }
    }

    public static func auth(
        provider: any MCPOAuthClientProvider,
        serverURL: String,
        authorizationCode: String? = nil,
        callbackState: String? = nil,
        callbackIssuer: String? = nil,
        scope: String? = nil,
        resourceMetadataURL: String? = nil,
        protocolVersion: String = MCPClient.latestProtocolVersion,
        transport: any AITransport = URLSessionTransport.shared
    ) async throws -> MCPOAuthAuthResult {
        try await auth(
            provider: provider,
            serverURL: requireURL(serverURL),
            authorizationCode: authorizationCode,
            callbackState: callbackState,
            callbackIssuer: callbackIssuer,
            scope: scope,
            resourceMetadataURL: try resourceMetadataURL.map(requireURL),
            protocolVersion: protocolVersion,
            transport: transport
        )
    }

    public static func selectResourceURL(
        serverURL: URL,
        provider: any MCPOAuthClientProvider,
        resourceMetadata: MCPOAuthProtectedResourceMetadata?
    ) async throws -> URL? {
        let defaultResource = resourceURLFromServerURL(serverURL)
        if let validated = try await provider.validateResourceURL(
            serverURL: defaultResource,
            resource: resourceMetadata?.resource
        ) {
            return validated
        }
        guard let resourceMetadata else { return nil }
        guard checkResourceAllowed(requestedResource: defaultResource, configuredResource: resourceMetadata.resource) else {
            throw MCPClientError(
                message: "Protected resource \(resourceMetadata.resource.absoluteString) does not match expected \(defaultResource.absoluteString) (or origin)"
            )
        }
        return resourceMetadata.resource
    }

    public static func startAuthorization(
        authorizationServerURL: URL,
        metadata: MCPOAuthAuthorizationServerMetadata? = nil,
        clientInformation: MCPOAuthClientInformation,
        redirectURL: URL,
        scope: String? = nil,
        state: String? = nil,
        resource: URL? = nil,
        codeVerifier: String? = nil
    ) throws -> MCPOAuthStartAuthorizationResult {
        let responseType = "code"
        let codeChallengeMethod = "S256"

        let authorizationURL: URL
        if let metadata {
            guard metadata.responseTypesSupported.contains(responseType) else {
                throw MCPClientError(message: "Incompatible auth server: does not support response type \(responseType)")
            }
            guard metadata.codeChallengeMethodsSupported.contains(codeChallengeMethod) else {
                throw MCPClientError(message: "Incompatible auth server: does not support code challenge method \(codeChallengeMethod)")
            }
            authorizationURL = metadata.authorizationEndpoint
        } else {
            authorizationURL = URL(string: "/authorize", relativeTo: authorizationServerURL)?.absoluteURL ?? authorizationServerURL
        }

        let verifier = codeVerifier ?? generateCodeVerifier()
        let challenge = codeChallenge(for: verifier)
        var components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        var queryItems = components.queryItems ?? []
        queryItems.set(name: "response_type", value: responseType)
        queryItems.set(name: "client_id", value: clientInformation.clientID)
        queryItems.set(name: "code_challenge", value: challenge)
        queryItems.set(name: "code_challenge_method", value: codeChallengeMethod)
        queryItems.set(name: "redirect_uri", value: redirectURL.absoluteString)
        if let state {
            queryItems.set(name: "state", value: state)
        }
        if let scope {
            queryItems.set(name: "scope", value: scope)
            if scope.contains("offline_access") {
                queryItems.append(URLQueryItem(name: "prompt", value: "consent"))
            }
        }
        if let resource {
            queryItems.set(name: "resource", value: resourceURLStripSlash(resource))
        }
        components.queryItems = queryItems
        return MCPOAuthStartAuthorizationResult(
            authorizationURL: components.url ?? authorizationURL,
            codeVerifier: verifier
        )
    }

    public static func startAuthorization(
        authorizationServerURL: String,
        metadata: MCPOAuthAuthorizationServerMetadata? = nil,
        clientInformation: MCPOAuthClientInformation,
        redirectURL: String,
        scope: String? = nil,
        state: String? = nil,
        resource: String? = nil,
        codeVerifier: String? = nil
    ) throws -> MCPOAuthStartAuthorizationResult {
        try startAuthorization(
            authorizationServerURL: requireURL(authorizationServerURL),
            metadata: metadata,
            clientInformation: clientInformation,
            redirectURL: requireURL(redirectURL),
            scope: scope,
            state: state,
            resource: try resource.map(requireURL),
            codeVerifier: codeVerifier
        )
    }

    public static func exchangeAuthorization(
        authorizationServerURL: URL,
        metadata: MCPOAuthAuthorizationServerMetadata? = nil,
        clientInformation: MCPOAuthClientInformation,
        authorizationCode: String,
        codeVerifier: String,
        redirectURI: URL,
        resource: URL? = nil,
        clientAuthentication: MCPOAuthClientAuthenticationHandler? = nil,
        transport: any AITransport = URLSessionTransport.shared
    ) async throws -> MCPOAuthTokens {
        let grantType = "authorization_code"
        try validateGrantType(grantType, metadata: metadata)
        let tokenURL = metadata?.tokenEndpoint ?? (URL(string: "/token", relativeTo: authorizationServerURL)?.absoluteURL ?? authorizationServerURL)
        try assertSafeMCPOAuthEndpoint(
            tokenURL,
            trustedOrigin: trustedMCPOAuthCredentialOrigin(authorizationServerURL)
        )
        var parameters = [
            URLQueryItem(name: "grant_type", value: grantType),
            URLQueryItem(name: "code", value: authorizationCode),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString)
        ]
        if let resource {
            parameters.set(name: "resource", value: resourceURLStripSlash(resource))
        }
        let response = try await tokenRequest(
            url: tokenURL,
            authorizationServerURL: authorizationServerURL,
            clientInformation: clientInformation,
            metadata: metadata,
            parameters: parameters,
            clientAuthentication: clientAuthentication,
            transport: transport
        )
        return try MCPOAuthTokens(json: response.jsonValue())
    }

    public static func refreshAuthorization(
        authorizationServerURL: URL,
        metadata: MCPOAuthAuthorizationServerMetadata? = nil,
        clientInformation: MCPOAuthClientInformation,
        refreshToken: String,
        resource: URL? = nil,
        clientAuthentication: MCPOAuthClientAuthenticationHandler? = nil,
        transport: any AITransport = URLSessionTransport.shared
    ) async throws -> MCPOAuthTokens {
        let grantType = "refresh_token"
        try validateGrantType(grantType, metadata: metadata)
        let tokenURL = metadata?.tokenEndpoint ?? (URL(string: "/token", relativeTo: authorizationServerURL)?.absoluteURL ?? authorizationServerURL)
        try assertSafeMCPOAuthEndpoint(
            tokenURL,
            trustedOrigin: trustedMCPOAuthCredentialOrigin(authorizationServerURL)
        )
        var parameters = [
            URLQueryItem(name: "grant_type", value: grantType),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        if let resource {
            parameters.set(name: "resource", value: resourceURLStripSlash(resource))
        }
        let response = try await tokenRequest(
            url: tokenURL,
            authorizationServerURL: authorizationServerURL,
            clientInformation: clientInformation,
            metadata: metadata,
            parameters: parameters,
            clientAuthentication: clientAuthentication,
            transport: transport
        )
        var raw = try response.jsonValue()
        if raw["refresh_token"]?.stringValue == nil, var object = raw.objectValue {
            object["refresh_token"] = .string(refreshToken)
            raw = .object(object)
        }
        return try MCPOAuthTokens(json: raw)
    }

    public static func registerClient(
        authorizationServerURL: URL,
        metadata: MCPOAuthAuthorizationServerMetadata? = nil,
        clientMetadata: MCPOAuthClientMetadata,
        transport: any AITransport = URLSessionTransport.shared
    ) async throws -> MCPOAuthClientInformationFull {
        let registrationURL: URL
        if let metadata {
            guard let endpoint = metadata.registrationEndpoint else {
                throw MCPClientError(message: "Incompatible auth server: does not support dynamic client registration")
            }
            registrationURL = endpoint
        } else {
            registrationURL = URL(string: "/register", relativeTo: authorizationServerURL)?.absoluteURL ?? authorizationServerURL
        }
        try assertSafeMCPOAuthEndpoint(
            registrationURL,
            trustedOrigin: trustedMCPOAuthCredentialOrigin(authorizationServerURL)
        )
        var registrationMetadata = clientMetadata.jsonValue.objectValue ?? [:]
        registrationMetadata["application_type"] = .string(
            (clientMetadata.applicationType ?? inferMCPOAuthApplicationType(clientMetadata.redirectURIs)).rawValue
        )
        let body = try JSONEncoder().encode(JSONValue.object(registrationMetadata))
        let response = try await transport.send(AIHTTPRequest(
            method: "POST",
            url: registrationURL,
            headers: ["Content-Type": "application/json"],
            body: body,
            followRedirects: false
        ))
        try throwOAuthServerErrorIfNeeded(response)
        return try MCPOAuthClientInformationFull(json: response.jsonValue())
    }
}

private actor MCPOAuthRefreshAttempt {
    var context: MCPOAuthCredentialInvalidationContext?
    func record(_ tokens: MCPOAuthTokens) { context = MCPOAuthCredentialInvalidationContext(tokens: tokens) }
}

private func authInternal(
    provider: any MCPOAuthClientProvider,
    serverURL: URL,
    authorizationCode: String?,
    callbackState: String?,
    callbackIssuer: String?,
    scope: String?,
    resourceMetadataURL: URL?,
    protocolVersion: String,
    transport: any AITransport,
    refreshAttempt: MCPOAuthRefreshAttempt? = nil,
    retryAuthorizationServerInformation: MCPOAuthAuthorizationServerInformation? = nil
) async throws -> MCPOAuthAuthResult {
    var resourceMetadata: MCPOAuthProtectedResourceMetadata?
    var authorizationServerURL: URL?
    if let resourceMetadataURL, resourceMetadataURL.originText != serverURL.originText {
        throw MCPClientError(message: "OAuth protected resource metadata URL \(resourceMetadataURL.absoluteString) must have the same origin as the MCP server URL \(serverURL.originText)")
    }
    do {
        resourceMetadata = try await MCPOAuthDiscovery.discoverProtectedResourceMetadata(
            serverURL: serverURL,
            protocolVersion: protocolVersion,
            resourceMetadataURL: resourceMetadataURL,
            transport: transport
        )
        authorizationServerURL = resourceMetadata?.authorizationServers.first
    } catch {}

    // A callback can arrive after protected-resource discovery becomes
    // unavailable. Prefer the authorization server pinned with the client over
    // incorrectly treating the MCP resource server as a legacy OAuth server.
    var clientInformation = try await provider.clientInformation()
    let currentTokens = authorizationCode == nil ? try await provider.tokens() : nil
    let storedServerInformation: MCPOAuthAuthorizationServerInformation?
    if let clientInformation {
        storedServerInformation = try await storedAuthorizationServerInformation(
            provider: provider,
            clientInformation: clientInformation,
            tokens: currentTokens
        ) ?? retryAuthorizationServerInformation
    } else {
        storedServerInformation = try await provider.authorizationServerInformation()?.normalized
    }
    let resolvedAuthorizationServerURL = authorizationServerURL
        ?? storedServerInformation?.authorizationServerURL
        ?? serverURL
    let resource = try await MCPOAuth.selectResourceURL(
        serverURL: serverURL,
        provider: provider,
        resourceMetadata: resourceMetadata
    )
    try await provider.validateAuthorizationServerURL(
        serverURL: serverURL,
        authorizationServerURL: resolvedAuthorizationServerURL
    )
    let trustedAuthorizationOrigin: URL?
    if isSameOrigin(
        resolvedAuthorizationServerURL.absoluteString,
        serverURL.absoluteString
    ) {
        trustedAuthorizationOrigin = serverURL
    } else if isLoopbackMCPOAuthURL(serverURL),
              isLoopbackMCPOAuthURL(resolvedAuthorizationServerURL) {
        // Local development servers commonly advertise an authorization server
        // on a different loopback port. Trust that advertised loopback origin,
        // while keeping remote MCP server -> loopback authorization redirects
        // behind the SSRF guard.
        trustedAuthorizationOrigin = resolvedAuthorizationServerURL
    } else {
        trustedAuthorizationOrigin = nil
    }
    try assertSafeMCPOAuthEndpoint(
        resolvedAuthorizationServerURL,
        trustedOrigin: trustedAuthorizationOrigin
    )
    let metadata = try await MCPOAuthDiscovery.discoverAuthorizationServerMetadata(
        authorizationServerURL: resolvedAuthorizationServerURL,
        protocolVersion: protocolVersion,
        trustedOrigin: trustedAuthorizationOrigin,
        transport: transport
    )
    let currentAuthorizationServerInformation = mcpOAuthAuthorizationServerInformation(
        authorizationServerURL: resolvedAuthorizationServerURL,
        metadata: metadata
    )
    let selectedScope = selectedAuthorizationScope(
        challengeScope: scope,
        resourceMetadata: resourceMetadata,
        clientScope: provider.clientMetadata.scope
    )

    if let retryAuthorizationServerInformation {
        try assertAuthorizationServerInformationMatches(retryAuthorizationServerInformation, currentAuthorizationServerInformation)
    }
    if let clientInformation {
        if let issuer = clientInformation.issuer, issuer != currentAuthorizationServerInformation.issuer {
            throw MCPOAuthAuthorizationServerMismatchError(message: "OAuth authorization server does not match the issuer of the client credentials")
        }
        if let credentialInformation = clientInformation.authorizationServerInformation {
            try assertAuthorizationServerInformationMatches(credentialInformation, currentAuthorizationServerInformation)
        }
        if let storedServerInformation {
            try assertAuthorizationServerInformationMatches(storedServerInformation, currentAuthorizationServerInformation)
        }
        if (clientInformation.clientSecret != nil || provider.usesCustomClientAuthentication),
           clientInformation.issuer == nil, storedServerInformation == nil {
            throw MCPOAuthAuthorizationServerMismatchError(message: "OAuth client credentials must be bound to an authorization server: configure their issuer or store authorization server information")
        }
    }
    if clientInformation == nil {
        if authorizationCode != nil {
            throw MCPClientError(message: "Existing OAuth client information is required when exchanging an authorization code")
        }
        guard provider.supportsDynamicClientRegistration else {
            throw MCPClientError(message: "OAuth client information must be saveable for dynamic registration")
        }
        var clientMetadata = provider.clientMetadata
        clientMetadata.scope = selectedScope
        let fullInformation = try await MCPOAuth.registerClient(
            authorizationServerURL: resolvedAuthorizationServerURL,
            metadata: metadata,
            clientMetadata: clientMetadata,
            transport: transport
        )
        let pinnedClientInformation = fullInformation.clientInformation.withAuthorizationServerInformation(currentAuthorizationServerInformation)
        try await provider.saveClientInformation(pinnedClientInformation)
        clientInformation = pinnedClientInformation
    }
    guard let clientInformation else {
        throw MCPClientError(message: "OAuth client information is unavailable.")
    }

    if let authorizationCode {
        let expectedState = try await provider.storedState()
        if expectedState != nil, expectedState != callbackState {
            throw MCPClientError(message: "OAuth state parameter mismatch - possible CSRF attack")
        }
        guard let storedAuthorizationServerInformation = try await storedAuthorizationServerInformation(provider: provider, clientInformation: clientInformation) else {
            throw MCPClientError(message: "Stored OAuth authorization server metadata is required when exchanging an authorization code")
        }
        try validateAuthorizationResponseIssuer(
            callbackIssuer,
            expectedIssuer: storedAuthorizationServerInformation.issuer
                ?? metadata?.issuer
                ?? resolvedAuthorizationServerURL.absoluteString
        )
        try assertAuthorizationServerInformationMatches(storedAuthorizationServerInformation, currentAuthorizationServerInformation)
        let tokens = try await MCPOAuth.exchangeAuthorization(
            authorizationServerURL: resolvedAuthorizationServerURL,
            metadata: metadata,
            clientInformation: clientInformation,
            authorizationCode: authorizationCode,
            codeVerifier: try await provider.codeVerifier(),
            redirectURI: provider.redirectURL,
            resource: resource,
            clientAuthentication: { request in
                try await provider.authenticateTokenRequest(request)
            },
            transport: transport
        )
        try await provider.saveTokens(tokens.withAuthorizationServerInformation(currentAuthorizationServerInformation))
        return .authorized
    }

    if let currentTokens, let refreshToken = currentTokens.refreshToken {
        if let storedAuthorizationServerInformation = try await storedAuthorizationServerInformation(provider: provider, clientInformation: clientInformation, tokens: currentTokens) {
            try assertAuthorizationServerInformationMatches(storedAuthorizationServerInformation, currentAuthorizationServerInformation)
        } else {
            await provider.invalidateCredentials(.tokens, context: MCPOAuthCredentialInvalidationContext(tokens: currentTokens))
        }
        do {
            if try await storedAuthorizationServerInformation(provider: provider, clientInformation: clientInformation, tokens: currentTokens) != nil {
                await refreshAttempt?.record(currentTokens)
                let tokens = try await MCPOAuth.refreshAuthorization(
                    authorizationServerURL: resolvedAuthorizationServerURL,
                    metadata: metadata,
                    clientInformation: clientInformation,
                    refreshToken: refreshToken,
                    resource: resource,
                    clientAuthentication: { request in
                        try await provider.authenticateTokenRequest(request)
                    },
                    transport: transport
                )
                try await provider.saveTokens(tokens.withAuthorizationServerInformation(currentAuthorizationServerInformation))
                return .authorized
            }
        } catch let error as MCPOAuthServerError {
            if let code = error.code, code != "server_error" {
                throw error
            }
        } catch {}
    }

    let state = try await provider.state()
    if let state {
        try await provider.saveState(state)
    }
    let started = try MCPOAuth.startAuthorization(
        authorizationServerURL: resolvedAuthorizationServerURL,
        metadata: metadata,
        clientInformation: clientInformation,
        redirectURL: provider.redirectURL,
        scope: selectedScope,
        state: state,
        resource: resource
    )
    try await saveAuthorizationServerInformation(provider: provider, clientInformation: clientInformation, information: currentAuthorizationServerInformation)
    try await provider.saveCodeVerifier(started.codeVerifier)
    try await provider.redirectToAuthorization(started.authorizationURL)
    return .redirect
}

private func selectedAuthorizationScope(
    challengeScope: String?,
    resourceMetadata: MCPOAuthProtectedResourceMetadata?,
    clientScope: String?
) -> String? {
    if let challengeScope, !challengeScope.isEmpty {
        return challengeScope
    }
    let resourceScope = resourceMetadata?.scopesSupported.joined(separator: " ")
    if let resourceScope, !resourceScope.isEmpty {
        return resourceScope
    }
    return clientScope
}

private func mcpOAuthAuthorizationServerInformation(
    authorizationServerURL: URL,
    metadata: MCPOAuthAuthorizationServerMetadata?
) -> MCPOAuthAuthorizationServerInformation {
    MCPOAuthAuthorizationServerInformation(
        authorizationServerURL: authorizationServerURL.absoluteURL,
        tokenEndpoint: metadata?.tokenEndpoint ?? (URL(string: "/token", relativeTo: authorizationServerURL)?.absoluteURL ?? authorizationServerURL),
        issuer: metadata?.issuer ?? authorizationServerURL.absoluteString
    )
}

private func storedAuthorizationServerInformation(
    provider: any MCPOAuthClientProvider,
    clientInformation: MCPOAuthClientInformation,
    tokens: MCPOAuthTokens? = nil
) async throws -> MCPOAuthAuthorizationServerInformation? {
    if let information = tokens?.authorizationServerInformation {
        return information
    }
    if let information = try await provider.authorizationServerInformation() {
        return information.normalized
    }
    return clientInformation.authorizationServerInformation
}

private func saveAuthorizationServerInformation(
    provider: any MCPOAuthClientProvider,
    clientInformation: MCPOAuthClientInformation,
    information: MCPOAuthAuthorizationServerInformation
) async throws {
    try await provider.saveAuthorizationServerInformation(information.normalized)
    try await provider.saveClientInformation(clientInformation.withAuthorizationServerInformation(information))
}

private func assertAuthorizationServerInformationMatches(
    _ stored: MCPOAuthAuthorizationServerInformation,
    _ current: MCPOAuthAuthorizationServerInformation
) throws {
    let normalizedStored = stored.normalized
    let normalizedCurrent = current.normalized
    let issuerMatches = normalizedStored.issuer == nil
        || normalizedCurrent.issuer == nil
        || normalizedStored.issuer == normalizedCurrent.issuer
    guard issuerMatches,
          normalizedStored.authorizationServerURL == normalizedCurrent.authorizationServerURL,
          normalizedStored.tokenEndpoint == normalizedCurrent.tokenEndpoint else {
        throw MCPOAuthAuthorizationServerMismatchError(message: "OAuth authorization server metadata does not match the metadata that issued the stored credentials")
    }
}

private func validateAuthorizationResponseIssuer(
    _ callbackIssuer: String?,
    expectedIssuer: String
) throws {
    guard let callbackIssuer, callbackIssuer != expectedIssuer else { return }
    throw MCPClientError(
        message: "OAuth authorization response issuer \(callbackIssuer) does not match expected issuer \(expectedIssuer)"
    )
}

func inferMCPOAuthApplicationType(_ redirectURIs: [URL]) -> MCPOAuthApplicationType {
    let everyRedirectIsNative = redirectURIs.allSatisfy { redirectURI in
        guard let scheme = redirectURI.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return true }
        let rawHost = redirectURI.host?.lowercased() ?? ""
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "127.0.0.1"
            || host == "::1"
            || host == "[::1]"
    }
    return everyRedirectIsNative ? .native : .web
}

private extension MCPOAuthTokens {
    var authorizationServerInformation: MCPOAuthAuthorizationServerInformation? {
        guard let authorizationServerURL, let tokenEndpoint else { return nil }
        return MCPOAuthAuthorizationServerInformation(
            authorizationServerURL: authorizationServerURL,
            tokenEndpoint: tokenEndpoint,
            issuer: issuer
        ).normalized
    }

    func withAuthorizationServerInformation(_ information: MCPOAuthAuthorizationServerInformation) -> MCPOAuthTokens {
        var copy = self
        copy.authorizationServerURL = information.normalized.authorizationServerURL
        copy.tokenEndpoint = information.normalized.tokenEndpoint
        copy.issuer = information.issuer
        if var object = copy.rawValue.objectValue {
            object["authorization_server"] = .string(information.normalized.authorizationServerURL.absoluteString)
            object["token_endpoint"] = .string(information.normalized.tokenEndpoint.absoluteString)
            object["issuer"] = information.issuer.map(JSONValue.string)
            copy.rawValue = .object(object)
        }
        return copy
    }
}


private extension MCPOAuthClientInformation {
    var authorizationServerInformation: MCPOAuthAuthorizationServerInformation? {
        guard let authorizationServerURL, let tokenEndpoint else { return nil }
        return MCPOAuthAuthorizationServerInformation(
            authorizationServerURL: authorizationServerURL,
            tokenEndpoint: tokenEndpoint,
            issuer: issuer
        ).normalized
    }

    func withAuthorizationServerInformation(_ information: MCPOAuthAuthorizationServerInformation) -> MCPOAuthClientInformation {
        var copy = self
        copy.authorizationServerURL = information.normalized.authorizationServerURL
        copy.tokenEndpoint = information.normalized.tokenEndpoint
        copy.issuer = information.issuer
        if var object = copy.rawValue.objectValue {
            object["authorization_server"] = .string(information.normalized.authorizationServerURL.absoluteString)
            object["token_endpoint"] = .string(information.normalized.tokenEndpoint.absoluteString)
            object["issuer"] = information.issuer.map(JSONValue.string)
            copy.rawValue = .object(object)
        }
        return copy
    }
}


private extension MCPOAuthAuthorizationServerInformation {
    var normalized: MCPOAuthAuthorizationServerInformation {
        MCPOAuthAuthorizationServerInformation(
            authorizationServerURL: authorizationServerURL.absoluteURL,
            tokenEndpoint: tokenEndpoint.absoluteURL,
            issuer: issuer
        )
    }
}


private extension URL {
    var originText: String {
        guard let scheme, let host else { return absoluteString }
        let portText = port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(portText)"
    }
}
