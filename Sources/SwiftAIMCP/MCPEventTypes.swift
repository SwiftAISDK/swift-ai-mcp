import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public enum MCPEventDeliveryMode: String, Codable, Sendable {
    case webhook, poll, push
}

public struct MCPEventDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var delivery: [MCPEventDeliveryMode]
    public var inputSchema: JSONValue
    public var payloadSchema: JSONValue
    public var rawValue: JSONValue

    public init(name: String, description: String? = nil, delivery: [MCPEventDeliveryMode], inputSchema: JSONValue, payloadSchema: JSONValue, rawValue: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.delivery = delivery
        self.inputSchema = inputSchema
        self.payloadSchema = payloadSchema
        self.rawValue = rawValue ?? .object([
            "name": .string(name), "description": description.map(JSONValue.string),
            "delivery": .array(delivery.map { .string($0.rawValue) }),
            "inputSchema": inputSchema, "payloadSchema": payloadSchema
        ])
    }

    init(json: JSONValue) throws {
        guard let name = json["name"]?.stringValue, !name.isEmpty,
              let values = json["delivery"]?.arrayValue, !values.isEmpty,
              let input = json["inputSchema"], let payload = json["payloadSchema"],
              input.boolValue != nil || input.objectValue != nil,
              payload.boolValue != nil || payload.objectValue != nil,
              mcpEventNullishString(json["description"]) else {
            throw MCPClientError(message: "Invalid MCP event definition")
        }
        let delivery = try values.map { value in
            guard let name = value.stringValue, let mode = MCPEventDeliveryMode(rawValue: name) else {
                throw MCPClientError(message: "Invalid MCP event delivery mode")
            }
            return mode
        }
        self.init(name: name, description: json["description"]?.stringValue, delivery: delivery, inputSchema: input, payloadSchema: payload, rawValue: json)
    }
}

public struct MCPListEventsResult: Equatable, Sendable {
    public var events: [MCPEventDefinition]
    public var nextCursor: String?
    public var metadata: JSONValue?
    public var rawValue: JSONValue

    init(json: JSONValue) throws {
        try mcpValidateEventResult(json)
        guard let values = json["events"]?.arrayValue, mcpEventNullishString(json["nextCursor"]) else {
            throw MCPClientError(message: "Invalid MCP events/list result")
        }
        events = try values.map(MCPEventDefinition.init(json:))
        nextCursor = json["nextCursor"]?.stringValue
        metadata = json["_meta"]
        rawValue = json
    }
}

public struct MCPSubscribeEventResult: Equatable, Sendable {
    public var id: String
    public var refreshBefore: String?
    public var cursor: String?
    public var truncated: Bool
    public var rawValue: JSONValue

    init(json: JSONValue) throws {
        try mcpValidateEventResult(json)
        guard let id = json["id"]?.stringValue, !id.isEmpty,
              let expiry = json["refreshBefore"], expiry == .null || expiry.stringValue.flatMap(mcpEventDate) != nil,
              mcpEventNullishString(json["cursor"]), let truncated = json["truncated"]?.boolValue else {
            throw MCPClientError(message: "Invalid MCP events/subscribe result")
        }
        self.id = id
        refreshBefore = expiry.stringValue
        cursor = json["cursor"]?.stringValue
        self.truncated = truncated
        var raw = json.objectValue ?? [:]
        raw["cursor"] = cursor.map(JSONValue.string) ?? .null
        rawValue = .object(raw)
    }
}

public struct MCPEvent: Equatable, Sendable {
    public var eventId: String
    public var name: String
    public var timestamp: String
    public var data: [String: JSONValue]
    /// nil means omitted; .null means explicitly reset the saved cursor.
    public var cursor: JSONValue?
    public var rawValue: JSONValue

    init(json: JSONValue) throws {
        guard let id = json["eventId"]?.stringValue, !id.isEmpty,
              let name = json["name"]?.stringValue, !name.isEmpty,
              let timestamp = json["timestamp"]?.stringValue, mcpEventDate(timestamp) != nil,
              let data = json["data"]?.objectValue, mcpEventNullishString(json["cursor"]) else {
            throw MCPClientError(message: "Invalid MCP event envelope")
        }
        eventId = id
        self.name = name
        self.timestamp = timestamp
        self.data = data
        cursor = json["cursor"]
        rawValue = json
    }
}

public struct MCPEventGap: Equatable, Sendable {
    public var cursor: String
    public let truncated = true
    public var rawValue: JSONValue
}

public struct MCPEventTermination: Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?
    public var rawValue: JSONValue
}

public enum MCPEventLifetime: Codable, Equatable, Sendable {
    case indefinite
    case milliseconds(Int)
}

public struct MCPEventDelivery: Codable, Equatable, Sendable {
    public var url: URL
    public var secret: String
    public init(url: URL, secret: String) { self.url = url; self.secret = secret }
}

/// Durable, private state scoped to an MCP server and authenticated principal.
/// Never expose delivery.secret to browsers or event callbacks.
public struct MCPEventSubscription: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, active }
    public var key: String
    public var id: String?
    public var name: String
    public var arguments: [String: JSONValue]
    public var definition: MCPEventDefinition
    public var delivery: MCPEventDelivery
    public var refreshBefore: String?
    public var cursor: String?
    public var truncated: Bool
    public var lifetime: MCPEventLifetime?
    public var maxAgeMilliseconds: Int?
    public var status: Status

    public init(key: String, id: String? = nil, name: String, arguments: [String: JSONValue] = [:], definition: MCPEventDefinition, delivery: MCPEventDelivery, refreshBefore: String? = nil, cursor: String? = nil, truncated: Bool = false, lifetime: MCPEventLifetime? = nil, maxAgeMilliseconds: Int? = nil, status: Status = .pending) {
        self.key = key; self.id = id; self.name = name; self.arguments = arguments
        self.definition = definition; self.delivery = delivery; self.refreshBefore = refreshBefore
        self.cursor = cursor; self.truncated = truncated; self.lifetime = lifetime
        self.maxAgeMilliseconds = maxAgeMilliseconds; self.status = status
    }
}

/// A partial update. Stores must merge these fields atomically; never replace a
/// record with a stale snapshot. Explicit .null clears a nullable field.
public struct MCPEventSubscriptionPatch: Equatable, Sendable {
    public let fields: [String: JSONValue]
    public init(_ fields: [String: JSONValue]) { self.fields = fields }

    public func applying(to original: MCPEventSubscription) throws -> MCPEventSubscription {
        var value = original
        for (key, field) in fields {
            switch key {
            case "id", "refreshBefore", "cursor":
                guard mcpEventNullishString(field) else { throw MCPClientError(message: "Invalid subscription patch \(key)") }
                if key == "id" { value.id = field.stringValue }
                if key == "refreshBefore" { value.refreshBefore = field.stringValue }
                if key == "cursor" { value.cursor = field.stringValue }
            case "truncated":
                guard let bool = field.boolValue else { throw MCPClientError(message: "Invalid truncated patch") }
                value.truncated = bool
            case "status":
                guard let text = field.stringValue, let status = MCPEventSubscription.Status(rawValue: text) else { throw MCPClientError(message: "Invalid status patch") }
                value.status = status
            default: throw MCPClientError(message: "Unsupported subscription patch field: \(key)")
            }
        }
        return value
    }
}

public protocol MCPEventStore: Sendable {
    func get(key: String) async throws -> MCPEventSubscription?
    func getById(_ id: String) async throws -> MCPEventSubscription?
    func set(_ subscription: MCPEventSubscription) async throws
    func update(key: String, patch: MCPEventSubscriptionPatch) async throws
    func delete(key: String) async throws
}

public struct MCPEventSubscriptionInfo: Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: [String: JSONValue]
    public var deliveryURL: URL
    public var refreshBefore: String?
}

public struct MCPSubscribeEventOptions: Sendable {
    public var name: String
    public var arguments: [String: JSONValue]
    public var callbackURL: URL
    public var allowInsecureLocalhost: Bool
    public var secret: String?
    public var cursor: String?
    public var lifetime: MCPEventLifetime?
    public var maxAgeMilliseconds: Int?
    public var options: MCPRequestOptions?

    public init(name: String, arguments: [String: JSONValue] = [:], callbackURL: URL, allowInsecureLocalhost: Bool = false, secret: String? = nil, cursor: String? = nil, lifetime: MCPEventLifetime? = nil, maxAgeMilliseconds: Int? = nil, options: MCPRequestOptions? = nil) {
        self.name = name; self.arguments = arguments; self.callbackURL = callbackURL
        self.allowInsecureLocalhost = allowInsecureLocalhost; self.secret = secret; self.cursor = cursor
        self.lifetime = lifetime; self.maxAgeMilliseconds = maxAgeMilliseconds; self.options = options
    }
}

public enum MCPEventSubscriptionReference: Sendable { case id(String), key(String) }
public typealias MCPEventArgumentValidator = @Sendable (MCPEventDefinition, [String: JSONValue]) async throws -> Void
public enum MCPEventsConfiguration: Sendable {
    case direct(store: (any MCPEventStore)? = nil, validateArguments: MCPEventArgumentValidator? = nil)
    case managed(any MCPEventAdapter)
}

func mcpEventNullishString(_ value: JSONValue?) -> Bool {
    value == nil || value == .null || value?.stringValue != nil
}

func mcpEventDate(_ text: String) -> Date? {
    guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
    let bytes = Array(text.utf8)
    func number(_ start: Int, _ end: Int) -> Int? { Int(String(decoding: bytes[start..<end], as: UTF8.self)) }
    guard let year = number(0, 4), let month = number(5, 7), let day = number(8, 10),
          let hour = number(11, 13), let minute = number(14, 16), let second = number(17, 19),
          (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
    let isLeap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let monthDays = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard (1...monthDays[month - 1]).contains(day) else { return nil }
    if bytes.last != 90 {
        let offsetStart = bytes.count - 6
        guard let offsetHour = number(offsetStart + 1, offsetStart + 3), let offsetMinute = number(offsetStart + 4, offsetStart + 6),
              (0...23).contains(offsetHour), (0...59).contains(offsetMinute) else { return nil }
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
}

func mcpValidateEventResult(_ json: JSONValue) throws {
    guard json.objectValue != nil, json["_meta"] == nil || json["_meta"]?.objectValue != nil,
          json["resultType"] == nil || json["resultType"]?.stringValue != nil else {
        throw MCPClientError(message: "Invalid MCP event result")
    }
}