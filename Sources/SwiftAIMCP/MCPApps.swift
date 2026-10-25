import Foundation
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

        if let resourceValue {
            guard let resourceURI = resourceValue.stringValue, resourceURI.hasPrefix("ui://") else {
                throw MCPClientError(message: "Invalid MCP App resource URI: \(resourceValue)")
            }
            return MCPAppToolMeta(
                resourceURI: resourceURI,
                visibility: visibility,
                rawValue: .object((uiMeta ?? [:]).merging(["resourceUri": .string(resourceURI)]) { _, new in new })
            )
        }

        guard let uiMeta else { return nil }
        return MCPAppToolMeta(
            resourceURI: nil,
            visibility: visibility,
            rawValue: .object(uiMeta)
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
            metadata: content.rawValue["_meta"]?["ui"] ?? content.rawValue["_meta"]
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