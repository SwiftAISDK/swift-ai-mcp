import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


func tokenRequest(
    url: URL,
    authorizationServerURL: URL,
    clientInformation: MCPOAuthClientInformation,
    metadata: MCPOAuthAuthorizationServerMetadata?,
    parameters: [URLQueryItem],
    clientAuthentication: MCPOAuthClientAuthenticationHandler?,
    transport: any AITransport
) async throws -> AIHTTPResponse {
    var headers = [
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json"
    ]
    var parameters = parameters
    if let customized = try await clientAuthentication?(MCPOAuthClientAuthenticationRequest(
        headers: headers,
        parameters: parameters,
        tokenURL: url,
        authorizationServerURL: authorizationServerURL,
        metadata: metadata
    )) {
        headers = customized.headers
        parameters = customized.parameters
    } else {
        let authMethod = selectClientAuthMethod(
            clientInformation: clientInformation,
            supportedMethods: metadata?.tokenEndpointAuthMethodsSupported ?? []
        )
        try applyClientAuthentication(
            authMethod,
            clientInformation: clientInformation,
            headers: &headers,
            parameters: &parameters
        )
    }
    let response = try await transport.send(AIHTTPRequest(
        method: "POST",
        url: url,
        headers: headers,
        body: Data(formEncoded(parameters).utf8),
        followRedirects: false
    ))
    try throwOAuthServerErrorIfNeeded(response)
    return response
}

func validateGrantType(_ grantType: String, metadata: MCPOAuthAuthorizationServerMetadata?) throws {
    guard let metadata, !metadata.grantTypesSupported.isEmpty else { return }
    guard metadata.grantTypesSupported.contains(grantType) else {
        throw MCPClientError(message: "Incompatible auth server: does not support grant type \(grantType)")
    }
}

func selectClientAuthMethod(
    clientInformation: MCPOAuthClientInformation,
    supportedMethods: [String]
) -> MCPOAuthClientAuthMethod {
    let hasClientSecret = clientInformation.clientSecret != nil
    if supportedMethods.isEmpty {
        return hasClientSecret ? .clientSecretPost : .none
    }
    if hasClientSecret, supportedMethods.contains(MCPOAuthClientAuthMethod.clientSecretBasic.rawValue) {
        return .clientSecretBasic
    }
    if hasClientSecret, supportedMethods.contains(MCPOAuthClientAuthMethod.clientSecretPost.rawValue) {
        return .clientSecretPost
    }
    if supportedMethods.contains(MCPOAuthClientAuthMethod.none.rawValue) {
        return .none
    }
    return hasClientSecret ? .clientSecretPost : .none
}

func applyClientAuthentication(
    _ method: MCPOAuthClientAuthMethod,
    clientInformation: MCPOAuthClientInformation,
    headers: inout [String: String],
    parameters: inout [URLQueryItem]
) throws {
    switch method {
    case .clientSecretBasic:
        guard let clientSecret = clientInformation.clientSecret else {
            throw MCPClientError(message: "client_secret_basic authentication requires a client_secret")
        }
        let credentials = Data("\(clientInformation.clientID):\(clientSecret)".utf8).base64EncodedString()
        headers["Authorization"] = "Basic \(credentials)"
    case .clientSecretPost:
        parameters.set(name: "client_id", value: clientInformation.clientID)
        if let clientSecret = clientInformation.clientSecret {
            parameters.set(name: "client_secret", value: clientSecret)
        }
    case .none:
        parameters.set(name: "client_id", value: clientInformation.clientID)
    }
}

func formEncoded(_ items: [URLQueryItem]) -> String {
    items.map { item in
        "\(urlFormEncode(item.name))=\(urlFormEncode(item.value ?? ""))"
    }.joined(separator: "&")
}

func urlFormEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}