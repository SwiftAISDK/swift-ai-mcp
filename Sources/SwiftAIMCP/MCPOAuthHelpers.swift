import Foundation
import CryptoKit
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


func throwOAuthServerErrorIfNeeded(_ response: AIHTTPResponse) throws {
    guard !(200..<300).contains(response.statusCode) else { return }
    if let raw = try? response.jsonValue(), let error = raw["error"]?.stringValue {
        throw MCPOAuthServerError(
            statusCode: response.statusCode,
            code: error,
            message: raw["error_description"]?.stringValue ?? "",
            uri: raw["error_uri"]?.stringValue
        )
    }
    throw MCPOAuthServerError(
        statusCode: response.statusCode,
        message: "HTTP \(response.statusCode): Invalid OAuth error response. Raw body: \(response.bodyText)"
    )
}

func generateCodeVerifier() -> String {
    var bytes = [UInt8]()
    bytes.reserveCapacity(32)
    for _ in 0..<32 {
        bytes.append(UInt8.random(in: UInt8.min...UInt8.max))
    }
    return mcpOAuthBase64URL(Data(bytes))
}

func codeChallenge(for verifier: String) -> String {
    mcpOAuthBase64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
}

func mcpOAuthBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func resourceURLStripSlash(_ resource: URL) -> String {
    let href = resource.absoluteString
    if resource.path == "/", href.hasSuffix("/") {
        return String(href.dropLast())
    }
    return href
}

func resourceURLFromServerURL(_ url: URL) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = nil
    return components?.url ?? url
}

func checkResourceAllowed(requestedResource: URL, configuredResource: URL) -> Bool {
    guard requestedResource.scheme == configuredResource.scheme,
          requestedResource.host == configuredResource.host,
          requestedResource.port == configuredResource.port else {
        return false
    }
    let requestedPath = requestedResource.path.hasSuffix("/") ? requestedResource.path : "\(requestedResource.path)/"
    let configuredPath = configuredResource.path.hasSuffix("/") ? configuredResource.path : "\(configuredResource.path)/"
    guard requestedPath.count >= configuredPath.count else { return false }
    return requestedPath.hasPrefix(configuredPath)
}

func assertSafeMCPOAuthEndpoint(_ endpointURL: URL, trustedOrigin: URL? = nil) throws {
    let scheme = endpointURL.scheme?.lowercased()
    if let trustedOrigin,
       isSameOrigin(endpointURL.absoluteString, trustedOrigin.absoluteString),
       (scheme == "http" || scheme == "https"),
       endpointURL.host?.isEmpty == false {
        return
    }

    do {
        guard scheme == "http" || scheme == "https" else {
            throw AIError.invalidArgument(
                argument: "url",
                message: "URL scheme must be http or https."
            )
        }
        _ = try validateDownloadURL(endpointURL.absoluteString)
    } catch {
        throw MCPClientError(
            message: "OAuth endpoint URL is not allowed: \(endpointURL.absoluteString)"
        )
    }
}

func isLoopbackMCPOAuthURL(_ url: URL) -> Bool {
    guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty else { return false }
    let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
    if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]" {
        return true
    }
    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    return octets.count == 4
        && octets.first == "127"
        && octets.allSatisfy { UInt8($0) != nil }
}

func trustedMCPOAuthCredentialOrigin(_ authorizationServerURL: URL) -> URL? {
    isLoopbackMCPOAuthURL(authorizationServerURL) ? authorizationServerURL : nil
}

extension String {
    var trimmedTrailingSlashForOAuthDiscovery: String {
        var value = self == "/" ? "" : self
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}


extension Array where Element == URLQueryItem {
    mutating func set(name: String, value: String) {
        removeAll { $0.name == name }
        append(URLQueryItem(name: name, value: value))
    }
}
