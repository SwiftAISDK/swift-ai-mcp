import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public struct MCPOAuthDiscovery {
    public static func discoverProtectedResourceMetadata(
        serverURL: URL,
        protocolVersion: String = MCPClient.latestProtocolVersion,
        resourceMetadataURL: URL? = nil,
        transport: any AITransport = URLSessionTransport.shared
    ) async throws -> MCPOAuthProtectedResourceMetadata {
        let discoveryURL = resourceMetadataURL ?? mcpWellKnownURL(
            for: serverURL,
            wellKnownName: "oauth-protected-resource",
            includePath: true
        )
        var response = try await discoveryGETWithHeaderRetry(
            url: discoveryURL,
            protocolVersion: protocolVersion,
            trustedOrigin: serverURL,
            transport: transport
        )

        if resourceMetadataURL == nil,
           shouldFallbackToRoot(response: response, originalURL: serverURL) {
            response = try await discoveryGETWithHeaderRetry(
                url: mcpWellKnownURL(for: serverURL, wellKnownName: "oauth-protected-resource", includePath: false),
                protocolVersion: protocolVersion,
                trustedOrigin: serverURL,
                transport: transport
            )
        }

        guard let response else {
            throw MCPClientError(message: "Resource server does not implement OAuth 2.0 Protected Resource Metadata.")
        }
        if response.statusCode == 404 {
            throw MCPClientError(message: "Resource server does not implement OAuth 2.0 Protected Resource Metadata.")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MCPClientError(message: "HTTP \(response.statusCode) trying to load well-known OAuth protected resource metadata.")
        }
        return try MCPOAuthProtectedResourceMetadata(json: response.jsonValue())
    }

    public static func discoverProtectedResourceMetadata(
        serverURL: String,
        protocolVersion: String = MCPClient.latestProtocolVersion,
        resourceMetadataURL: String? = nil,
        transport: any AITransport = URLSessionTransport.shared
    ) async throws -> MCPOAuthProtectedResourceMetadata {
        try await discoverProtectedResourceMetadata(
            serverURL: requireURL(serverURL),
            protocolVersion: protocolVersion,
            resourceMetadataURL: try resourceMetadataURL.map(requireURL),
            transport: transport
        )
    }

    public static func buildAuthorizationServerDiscoveryURLs(_ authorizationServerURL: URL) -> [URL] {
        mcpAuthorizationServerDiscoveryURLs(authorizationServerURL).map(\.url)
    }

    public static func discoverAuthorizationServerMetadata(
        authorizationServerURL: URL,
        protocolVersion: String = MCPClient.latestProtocolVersion,
        transport: any AITransport = URLSessionTransport.shared
    ) async throws -> MCPOAuthAuthorizationServerMetadata? {
        try await discoverAuthorizationServerMetadata(
            authorizationServerURL: authorizationServerURL,
            protocolVersion: protocolVersion,
            trustedOrigin: trustedMCPOAuthCredentialOrigin(authorizationServerURL),
            transport: transport
        )
    }

    static func discoverAuthorizationServerMetadata(
        authorizationServerURL: URL,
        protocolVersion: String,
        trustedOrigin: URL?,
        transport: any AITransport
    ) async throws -> MCPOAuthAuthorizationServerMetadata? {
        try assertSafeMCPOAuthEndpoint(authorizationServerURL, trustedOrigin: trustedOrigin)
        for discoveryURL in mcpAuthorizationServerDiscoveryURLs(authorizationServerURL) {
            guard let response = try await discoveryGETWithHeaderRetry(
                url: discoveryURL.url,
                protocolVersion: protocolVersion,
                trustedOrigin: trustedOrigin,
                transport: transport
            ) else {
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                if (400..<500).contains(response.statusCode) {
                    continue
                }
                throw MCPClientError(
                    message: "HTTP \(response.statusCode) trying to load \(discoveryURL.kind == .oauth ? "OAuth" : "OpenID provider") metadata from \(discoveryURL.url.absoluteString)"
                )
            }
            return try MCPOAuthAuthorizationServerMetadata(
                json: response.jsonValue(),
                sourceURL: discoveryURL.url,
                sourceType: discoveryURL.kind,
                expectedIssuer: discoveryURL.expectedIssuer
            )
        }
        return nil
    }

    public static func discoverAuthorizationServerMetadata(
        authorizationServerURL: String,
        protocolVersion: String = MCPClient.latestProtocolVersion,
        transport: any AITransport = URLSessionTransport.shared
    ) async throws -> MCPOAuthAuthorizationServerMetadata? {
        try await discoverAuthorizationServerMetadata(
            authorizationServerURL: requireURL(authorizationServerURL),
            protocolVersion: protocolVersion,
            transport: transport
        )
    }
}

struct MCPOAuthDiscoveryURL {
    enum Kind {
        case oauth
        case oidc
    }

    var url: URL
    var kind: Kind
    var expectedIssuer: String
}

func discoveryGET(
    url: URL,
    protocolVersion: String,
    trustedOrigin: URL?,
    transport: any AITransport
) async throws -> AIHTTPResponse {
    var currentURL = url
    var headers = protocolVersion.isEmpty ? [:] : ["MCP-Protocol-Version": protocolVersion]
    let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]
    for _ in 0...10 {
        try assertSafeMCPOAuthEndpoint(currentURL, trustedOrigin: trustedOrigin)
        let response = try await transport.send(AIHTTPRequest(
            method: "GET",
            url: currentURL,
            headers: headers,
            followRedirects: false
        ))
        if redirectStatuses.contains(response.statusCode),
           let location = response.headerValue("location"),
           let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL {
            try assertSafeMCPOAuthEndpoint(nextURL, trustedOrigin: trustedOrigin)
            if !isSameOrigin(currentURL.absoluteString, nextURL.absoluteString) {
                // Protocol metadata is safe on the untrusted first hop, but
                // follows provider-utils by withholding it after a redirect
                // crosses origins.
                headers = [:]
            }
            currentURL = nextURL
            continue
        }
        if let finalURL = response.url, finalURL != currentURL {
            try assertSafeMCPOAuthEndpoint(finalURL, trustedOrigin: trustedOrigin)
        }
        return response
    }
    throw MCPClientError(message: "Too many OAuth discovery redirects (max 10).")
}

func discoveryGETWithHeaderRetry(
    url: URL,
    protocolVersion: String,
    trustedOrigin: URL?,
    transport: any AITransport
) async throws -> AIHTTPResponse? {
    do {
        return try await discoveryGET(
            url: url,
            protocolVersion: protocolVersion,
            trustedOrigin: trustedOrigin,
            transport: transport
        )
    } catch let error as MCPClientError {
        throw error
    } catch {
        do {
            return try await discoveryGET(
                url: url,
                protocolVersion: "",
                trustedOrigin: trustedOrigin,
                transport: transport
            )
        } catch let error as MCPClientError {
            throw error
        } catch {
            return nil
        }
    }
}

func shouldFallbackToRoot(response: AIHTTPResponse?, originalURL: URL) -> Bool {
    guard originalURL.path != "" && originalURL.path != "/" else { return false }
    guard let response else { return true }
    return (400..<500).contains(response.statusCode)
}

func mcpWellKnownURL(for url: URL, wellKnownName: String, includePath: Bool) -> URL {
    var components = URLComponents()
    components.scheme = url.scheme
    components.host = url.host
    components.port = url.port
    let path = includePath ? url.path.trimmedTrailingSlashForOAuthDiscovery : ""
    components.path = "/.well-known/\(wellKnownName)\(path)"
    if includePath {
        components.query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query
    }
    return components.url ?? url
}

func mcpAuthorizationServerDiscoveryURLs(_ url: URL) -> [MCPOAuthDiscoveryURL] {
    let path = url.path.trimmedTrailingSlashForOAuthDiscovery
    let rootIssuer = mcpOriginText(url)
    guard !path.isEmpty else {
        return [
            MCPOAuthDiscoveryURL(url: mcpURL(origin: url, path: "/.well-known/oauth-authorization-server"), kind: .oauth, expectedIssuer: rootIssuer),
            MCPOAuthDiscoveryURL(url: mcpURL(origin: url, path: "/.well-known/openid-configuration"), kind: .oidc, expectedIssuer: rootIssuer)
        ]
    }
    let pathIssuer = "\(mcpOriginText(url))\(path)"
    return [
        MCPOAuthDiscoveryURL(url: mcpURL(origin: url, path: "/.well-known/oauth-authorization-server\(path)"), kind: .oauth, expectedIssuer: pathIssuer),
        MCPOAuthDiscoveryURL(url: mcpURL(origin: url, path: "/.well-known/oauth-authorization-server"), kind: .oauth, expectedIssuer: rootIssuer),
        MCPOAuthDiscoveryURL(url: mcpURL(origin: url, path: "/.well-known/openid-configuration\(path)"), kind: .oidc, expectedIssuer: pathIssuer),
        MCPOAuthDiscoveryURL(url: mcpURL(origin: url, path: "\(path)/.well-known/openid-configuration"), kind: .oidc, expectedIssuer: pathIssuer)
    ]
}

private func mcpOriginText(_ url: URL) -> String {
    guard let scheme = url.scheme, let host = url.host else { return url.absoluteString }
    let portText = url.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(portText)"
}

func mcpURL(origin: URL, path: String) -> URL {
    var components = URLComponents()
    components.scheme = origin.scheme
    components.host = origin.host
    components.port = origin.port
    components.path = path
    return components.url ?? origin
}