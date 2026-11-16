import Foundation
import CryptoKit
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public enum MCPApps {
    public static let extensionName = "io.modelcontextprotocol/ui"
    public static let appMIMEType = "text/html;profile=mcp-app"
    public static let legacyResourceURIMetadataKey = "ui/resourceUri"

    public static let clientCapabilities: JSONValue = .object([
        "extensions": .object([
            extensionName: .object([
                "mimeTypes": .array([.string(appMIMEType)])
            ])
        ])
    ])

    public static func toolMeta(from tool: MCPToolDefinition) throws -> MCPAppToolMeta? {
        let uiMeta = tool.metadata?["ui"]?.objectValue
        let resourceValue = uiMeta?["resourceUri"] ?? tool.metadata?[legacyResourceURIMetadataKey]
        let visibility = uiMeta?["visibility"]?.arrayValue?.compactMap(\.stringValue).filter { $0 == "model" || $0 == "app" }

        // Upstream returns `{ ...ui, resourceUri?, visibility? }` where the
        // visibility list keeps only `model`/`app` entries.
        var normalized = uiMeta ?? [:]
        if let visibility {
            normalized["visibility"] = .array(visibility.map(JSONValue.string))
        }

        if let resourceValue {
            guard let resourceURI = resourceValue.stringValue, resourceURI.hasPrefix("ui://") else {
                throw MCPClientError(message: "Invalid MCP App resource URI: \(resourceValue)")
            }
            normalized["resourceUri"] = .string(resourceURI)
            return MCPAppToolMeta(
                resourceURI: resourceURI,
                visibility: visibility,
                rawValue: .object(normalized)
            )
        }

        guard uiMeta != nil else { return nil }
        return MCPAppToolMeta(
            resourceURI: nil,
            visibility: visibility,
            rawValue: .object(normalized)
        )
    }

    public static func resourceURI(from tool: MCPToolDefinition) throws -> String? {
        try toolMeta(from: tool)?.resourceURI
    }

    public static func isAppTool(_ tool: MCPToolDefinition) throws -> Bool {
        try resourceURI(from: tool) != nil
    }

    public static func splitTools(_ definitions: MCPListToolsResult) throws -> MCPAppToolSplit {
        var modelVisible: [MCPToolDefinition] = []
        var appVisible: [MCPToolDefinition] = []

        for tool in definitions.tools {
            let visibility = try toolMeta(from: tool)?.visibility
            if visibility == nil || visibility?.contains(.model) == true {
                modelVisible.append(tool)
            }
            if visibility?.contains(.app) == true {
                appVisible.append(tool)
            }
        }

        return MCPAppToolSplit(
            modelVisible: MCPListToolsResult(tools: modelVisible, nextCursor: definitions.nextCursor),
            appVisible: MCPListToolsResult(tools: appVisible, nextCursor: definitions.nextCursor)
        )
    }

    public static func resourceURIs(from definitions: MCPListToolsResult) throws -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for tool in definitions.tools {
            guard let uri = try resourceURI(from: tool), !seen.contains(uri) else { continue }
            seen.insert(uri)
            output.append(uri)
        }
        return output
    }

    public static func resource(uri: String, from readResult: MCPReadResourceResult) throws -> MCPAppResource {
        guard let content = readResult.contents.first(where: { $0.uri == uri }) else {
            throw MCPClientError(message: "MCP App resource not found in read result: \(uri)")
        }
        guard content.mimeType == appMIMEType else {
            throw MCPClientError(message: "Unsupported MCP App resource MIME type: \(content.mimeType ?? "nil")")
        }

        let html: String?
        if let text = content.text {
            html = text
        } else if let blob = content.blob, let data = Data(base64Encoded: blob) {
            html = String(data: data, encoding: .utf8)
        } else {
            html = nil
        }
        guard let html else {
            throw MCPClientError(message: "Unsupported MCP App resource content format: \(uri)")
        }

        return MCPAppResource(
            uri: uri,
            html: html,
            metadata: normalizedAppMetadata(content.rawValue["_meta"]?["ui"])
        )
    }

    public static func readResource(client: MCPClient, uri: String, options: MCPRequestOptions? = nil) async throws -> MCPAppResource {
        guard uri.hasPrefix("ui://") else {
            throw MCPClientError(message: "Unsupported MCP App resource URI: \(uri)")
        }
        let readResult = try await client.readResource(uri: uri, options: options)
        return try resource(uri: uri, from: readResult)
    }
}

public struct MCPAppToolMeta: Equatable, Hashable, Sendable {
    public enum Visibility: String, Sendable {
        case model
        case app
    }

    public var resourceURI: String?
    public var visibility: [Visibility]?
    public var rawValue: JSONValue

    public init(resourceURI: String? = nil, visibility: [String]? = nil, rawValue: JSONValue = .object([:])) {
        self.resourceURI = resourceURI
        self.visibility = visibility?.compactMap(Visibility.init(rawValue:))
        self.rawValue = rawValue
    }
}

public struct MCPAppToolSplit: Equatable, Hashable, Sendable {
    public var modelVisible: MCPListToolsResult
    public var appVisible: MCPListToolsResult

    public init(modelVisible: MCPListToolsResult, appVisible: MCPListToolsResult) {
        self.modelVisible = modelVisible
        self.appVisible = appVisible
    }
}

public struct MCPAppResource: Equatable, Hashable, Sendable {
    public var uri: String
    public var mimeType: String
    public var html: String
    public var metadata: JSONValue?

    public init(uri: String, mimeType: String = MCPApps.appMIMEType, html: String, metadata: JSONValue? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.html = html
        self.metadata = metadata
    }
}
/// Mirrors upstream `MCPAppResourceMetaSchema`: only an object `_meta.ui` is
/// read; malformed known fields are dropped and unknown keys pass through.
private func normalizedAppMetadata(_ metadata: JSONValue?) -> JSONValue? {
    guard var object = metadata?.objectValue else { return nil }
    if let prefersBorder = object["prefersBorder"], prefersBorder.boolValue == nil {
        object.removeValue(forKey: "prefersBorder")
    }
    if let permissions = object["permissions"], permissions.objectValue == nil {
        object.removeValue(forKey: "permissions")
    }
    if let cspValue = object["csp"] {
        if var csp = cspValue.objectValue {
            for key in ["connectDomains", "resourceDomains", "frameDomains", "baseUriDomains"] {
                if let value = csp[key] {
                    if let array = value.arrayValue { csp[key] = .array(array.compactMap { $0.stringValue.map(JSONValue.string) }) }
                    else { csp.removeValue(forKey: key) }
                }
            }
            object["csp"] = .object(csp)
        } else {
            object.removeValue(forKey: "csp")
        }
    }
    return .object(object)
}

public extension MCPApps {
    /// Stable SHA-256 digest (base64url, unpadded) over an MCP App resource's
    /// `html`, `csp` and `permissions`, matching upstream
    /// `fingerprintMCPAppResource`. Object keys are sorted so key order does
    /// not change the fingerprint.
    static func fingerprint(_ resource: MCPAppResource) -> String {
        let input: JSONValue = .object([
            "html": .string(resource.html),
            "csp": resource.metadata?["csp"] ?? .null,
            "permissions": resource.metadata?["permissions"] ?? .null
        ])
        let digest = SHA256.hash(data: Data(mcpCanonicalJSON(input).utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Returns true when the current fingerprint differs from its baseline
    /// (upstream `detectMCPAppResourceDrift`).
    static func detectResourceDrift(current: String, baseline: String) -> Bool {
        current != baseline
    }
}

/// JavaScript-compatible canonical JSON: sorted object keys and
/// `JSON.stringify` string escaping.
func mcpCanonicalJSON(_ value: JSONValue) -> String {
    switch value {
    case .null:
        return "null"
    case let .bool(bool):
        return bool ? "true" : "false"
    case let .number(number):
        return mcpJavaScriptNumber(number)
    case let .string(string):
        return mcpJavaScriptString(string)
    case let .array(array):
        return "[" + array.map(mcpCanonicalJSON).joined(separator: ",") + "]"
    case let .object(object):
        let keys = object.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
        return "{" + keys.map { "\(mcpJavaScriptString($0)):\(mcpCanonicalJSON(object[$0] ?? .null))" }.joined(separator: ",") + "}"
    }
}

private func mcpJavaScriptNumber(_ number: Double) -> String {
    guard number.isFinite else { return "null" }
    if number == number.rounded(), abs(number) < 1e21 {
        return number == 0 ? "0" : String(format: "%.0f", number)
    }
    return "\(number)"
}

private func mcpJavaScriptString(_ string: String) -> String {
    var output = "\""
    for scalar in string.unicodeScalars {
        switch scalar.value {
        case 0x22: output += "\\\""
        case 0x5C: output += "\\\\"
        case 0x08: output += "\\b"
        case 0x0C: output += "\\f"
        case 0x0A: output += "\\n"
        case 0x0D: output += "\\r"
        case 0x09: output += "\\t"
        case 0x00..<0x20: output += String(format: "\\u%04x", scalar.value)
        default: output.unicodeScalars.append(scalar)
        }
    }
    output += "\""
    return output
}
