import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


func mcpToolModelOutput(from result: JSONValue) -> JSONValue {
    if let text = result.stringValue {
        return ["type": "text", "value": .string(text)]
    }
    guard let content = result["content"]?.arrayValue else {
        return .object([
            "type": .string("json"),
            "value": result
        ])
    }

    return .object([
        "type": .string("content"),
        "value": .array(content.map(mcpToolModelOutputPart))
    ])
}

func mcpToolModelOutputPart(_ part: JSONValue) -> JSONValue {
    if part["type"]?.stringValue == "text", let text = part["text"]?.stringValue {
        return .object([
            "type": .string("text"),
            "text": .string(text)
        ])
    }
    if part["type"]?.stringValue == "image",
       let data = part["data"]?.stringValue,
       let mimeType = part["mimeType"]?.stringValue {
        return .object([
            "type": .string("file"),
            "mediaType": .string(mimeType),
            "data": .object([
                "type": .string("data"),
                "data": .string(data)
            ])
        ])
    }
    return .object([
        "type": .string("text"),
        "text": .string(mcpJSONString(part) ?? "")
    ])
}

func mcpJSONString(_ value: JSONValue) -> String? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}

func mcpOAuthWWWAuthenticateParameters(
    from headers: [String: String]
) -> (resourceMetadataURL: URL?, scope: String?) {
    guard let header = headers.first(where: { $0.key.caseInsensitiveCompare("www-authenticate") == .orderedSame })?.value else {
        return (nil, nil)
    }
    let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
    guard parts.first?.lowercased() == "bearer", parts.count == 2 else {
        return (nil, nil)
    }

    func quotedParameter(_ name: String) -> String? {
        guard let range = parts[1].range(
            of: #"(?:^|[,\s])\#(name)="([^"]*)""#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        let matched = String(parts[1][range])
        guard let separator = matched.firstIndex(of: "=") else { return nil }
        return String(matched[matched.index(after: separator)...]).dropFirst().dropLast().description
    }

    let resourceMetadataURL = quotedParameter("resource_metadata").flatMap { value -> URL? in
        guard let url = URL(string: value), url.scheme != nil else { return nil }
        return url
    }
    return (resourceMetadataURL, quotedParameter("scope"))
}

func mcpOAuthResourceMetadataURL(from headers: [String: String]) -> URL? {
    mcpOAuthWWWAuthenticateParameters(from: headers).resourceMetadataURL
}

func mcpJSONRPCResultResponse(id: JSONValue?, result: JSONValue) -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "result": result
    ])
}

func mcpJSONRPCErrorResponse(id: JSONValue?, code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "error": .object([
            "code": .number(Double(code)),
            "message": .string(message),
            "data": data
        ])
    ])
}

extension MCPToolDefinition {
    var jsonValue: JSONValue {
        .object([
            "name": .string(name),
            "title": title.map(JSONValue.string),
            "description": description.map(JSONValue.string),
            "inputSchema": inputSchema,
            "outputSchema": outputSchema,
            "annotations": annotations,
            "_meta": metadata
        ])
    }
}
