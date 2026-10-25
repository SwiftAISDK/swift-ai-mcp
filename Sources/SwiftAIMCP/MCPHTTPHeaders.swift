import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


struct MCPToolHeaderBinding: Equatable, Sendable {
    enum ValueType: String, Sendable {
        case boolean
        case integer
        case string
    }

    var headerName: String
    var path: [String]
    var valueType: ValueType
}

enum MCPToolHeaderBindingsResult: Equatable, Sendable {
    case success([MCPToolHeaderBinding])
    case failure(String)
}

func encodeMCPHeaderValue(_ value: String) -> String {
    let isPlainASCII = value.unicodeScalars.allSatisfy { scalar in
        scalar.value == 0x09 || (scalar.value >= 0x20 && scalar.value <= 0x7e)
    }
    let isTrimmed = value.trimmingCharacters(in: .whitespacesAndNewlines) == value
    let looksEncoded = value.hasPrefix("=?base64?") && value.hasSuffix("?=")
    guard isPlainASCII, isTrimmed, !looksEncoded else {
        return "=?base64?\(Data(value.utf8).base64EncodedString())?="
    }
    return value
}

func mcpToolHeaderBindings(from inputSchema: JSONValue) -> MCPToolHeaderBindingsResult {
    guard inputSchema.objectValue != nil else {
        return .failure("inputSchema must be a JSON Schema object")
    }

    var bindings: [MCPToolHeaderBinding] = []
    var normalizedHeaderNames: Set<String> = []
    var error: String?

    func visit(_ value: JSONValue, path: [String], staticallyReachable: Bool) {
        guard error == nil, let object = value.objectValue else { return }

        if let annotation = object["x-mcp-header"] {
            guard staticallyReachable, !path.isEmpty else {
                error = "x-mcp-header is not on a statically reachable property"
                return
            }
            guard let headerName = annotation.stringValue,
                  !headerName.isEmpty,
                  mcpIsHTTPToken(headerName) else {
                error = "x-mcp-header must be a non-empty HTTP token"
                return
            }
            let normalized = headerName.lowercased()
            guard normalizedHeaderNames.insert(normalized).inserted else {
                error = "x-mcp-header value \"\(headerName)\" is not unique"
                return
            }
            guard let rawType = object["type"]?.stringValue,
                  let valueType = MCPToolHeaderBinding.ValueType(rawValue: rawType) else {
                error = "x-mcp-header can only annotate boolean, integer, or string properties"
                return
            }
            bindings.append(MCPToolHeaderBinding(
                headerName: headerName,
                path: path,
                valueType: valueType
            ))
        }

        for (key, child) in object where key != "x-mcp-header" {
            if key == "properties", let properties = child.objectValue {
                for (propertyName, propertySchema) in properties {
                    visit(
                        propertySchema,
                        path: path + [propertyName],
                        staticallyReachable: staticallyReachable
                    )
                }
            } else {
                visit(child, path: path, staticallyReachable: false)
            }
        }
    }

    visit(inputSchema, path: [], staticallyReachable: true)
    return error.map(MCPToolHeaderBindingsResult.failure) ?? .success(bindings)
}

func createMCPToolHeaders(
    bindings: [MCPToolHeaderBinding],
    arguments: JSONValue
) throws -> [String: String] {
    guard let arguments = arguments.objectValue else { return [:] }
    var headers: [String: String] = [:]

    for binding in bindings {
        guard let value = mcpValue(at: binding.path, in: arguments), value != .null else {
            continue
        }
        let encodedValue: String
        switch binding.valueType {
        case .string:
            guard let string = value.stringValue else {
                throw MCPClientError(message: "Tool argument \"\(binding.path.joined(separator: "."))\" does not match its x-mcp-header type")
            }
            encodedValue = string
        case .boolean:
            guard let boolean = value.boolValue else {
                throw MCPClientError(message: "Tool argument \"\(binding.path.joined(separator: "."))\" does not match its x-mcp-header type")
            }
            encodedValue = boolean ? "true" : "false"
        case .integer:
            guard let number = value.doubleValue,
                  number.isFinite,
                  number.rounded(.towardZero) == number,
                  abs(number) <= 9_007_199_254_740_991 else {
                throw MCPClientError(message: "Tool argument \"\(binding.path.joined(separator: "."))\" does not match its x-mcp-header type")
            }
            encodedValue = String(format: "%.0f", number)
        }
        headers["Mcp-Param-\(binding.headerName)"] = encodeMCPHeaderValue(encodedValue)
    }
    return headers
}

private func mcpValue(at path: [String], in root: [String: JSONValue]) -> JSONValue? {
    var current: JSONValue = .object(root)
    for segment in path {
        guard let object = current.objectValue, let next = object[segment] else { return nil }
        current = next
    }
    return current
}

private func mcpIsHTTPToken(_ value: String) -> Bool {
    let allowed = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".unicodeScalars)
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
}