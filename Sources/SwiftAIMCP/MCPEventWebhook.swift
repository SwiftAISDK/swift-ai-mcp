import Foundation
import CryptoKit
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public func createMCPEventSecret() -> String {
    var random = SystemRandomNumberGenerator()
    return "whsec_" + Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }).base64EncodedString()
}

public func decodeMCPEventSecret(_ secret: String) throws -> Data {
    guard secret.hasPrefix("whsec_"),
          String(secret.dropFirst(6)).range(of: #"^[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil,
          let data = mcpWebhookBase64(String(secret.dropFirst(6))) else {
        throw MCPClientError(message: "Invalid MCP event signing secret")
    }
    guard (24...64).contains(data.count) else { throw MCPClientError(message: "MCP event signing secrets must contain 24–64 random bytes") }
    return data
}

private func mcpWebhookBase64(_ value: String) -> Data? {
    let padding = (4 - value.utf8.count % 4) % 4
    return Data(base64Encoded: value + String(repeating: "=", count: padding))
}

/// Standard Webhooks v1: authenticates the exact body bytes and accepts any
/// valid rotation signature within the five-minute timestamp window.
public func verifyMCPEventSignature(headers: [String: String], body: Data, secret: String, now: Date = Date()) throws -> Bool {
    func header(_ key: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value }
    guard let id = header("webhook-id"), !id.isEmpty,
          let timestamp = header("webhook-timestamp"), !timestamp.isEmpty,
          timestamp.utf8.allSatisfy({ (48...57).contains($0) }),
          let seconds = Double(timestamp), seconds.isFinite,
          abs(now.timeIntervalSince1970 - seconds) <= 300,
          let signatures = header("webhook-signature"), !signatures.isEmpty else { return false }
    let key = try SymmetricKey(data: decodeMCPEventSecret(secret))
    let message = Data("\(id).\(timestamp).".utf8) + body
    for entry in signatures.split(separator: " ") {
        let fields = entry.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 2, fields[0] == "v1", let signature = mcpWebhookBase64(String(fields[1])) else { continue }
        if HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: message, using: key) { return true }
    }
    return false
}

/// Mount at the callback URL before subscribing. Resolve callbacks only after
/// durable acceptance. Applications deduplicate/order by subscription + event
/// ID; this handler never starts agents or executes tools.
public struct MCPEventWebhook: Sendable {
    public static let maxBodyBytes = 256 * 1024
    private let store: any MCPEventStore
    private let validatePayload: MCPEventArgumentValidator?
    private let onEvent: @Sendable (MCPEventSubscriptionInfo, MCPEvent) async throws -> Void
    private let onGap: (@Sendable (MCPEventSubscriptionInfo, String, MCPEventGap) async throws -> Void)?
    private let onTerminated: (@Sendable (MCPEventSubscriptionInfo, String, MCPEventTermination) async throws -> Void)?
    private let onError: (@Sendable (any Error) -> Void)?
    private let now: @Sendable () -> Date

    public init(store: any MCPEventStore, validatePayload: MCPEventArgumentValidator? = nil, onEvent: @escaping @Sendable (MCPEventSubscriptionInfo, MCPEvent) async throws -> Void, onGap: (@Sendable (MCPEventSubscriptionInfo, String, MCPEventGap) async throws -> Void)? = nil, onTerminated: (@Sendable (MCPEventSubscriptionInfo, String, MCPEventTermination) async throws -> Void)? = nil, onError: (@Sendable (any Error) -> Void)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.validatePayload = validatePayload; self.onEvent = onEvent
        self.onGap = onGap; self.onTerminated = onTerminated; self.onError = onError; self.now = now
    }

    public func handle(_ request: AIHTTPRequest) async -> AIHTTPResponse {
        func header(_ key: String) -> String? { request.headers.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value }
        guard request.method == "POST" else { return AIHTTPResponse(statusCode: 405, headers: ["Allow": "POST"]) }
        guard header("content-type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { return AIHTTPResponse(statusCode: 415) }
        if let length = header("content-length").flatMap(Double.init), length > Double(Self.maxBodyBytes) { return AIHTTPResponse(statusCode: 413) }
        do {
            guard let key = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == MCPEventCallbackKey })?.value, !key.isEmpty,
                  let id = header("X-MCP-Subscription-Id"), !id.isEmpty,
                  let subscription = try await store.get(key: key), subscription.id == nil || subscription.id == id else { return AIHTTPResponse(statusCode: 401) }
            var body: Data
            if let data = request.body { body = data }
            else if let stream = request.bodyStream {
                body = Data()
                for try await chunk in stream {
                    guard chunk.count <= Self.maxBodyBytes - body.count else {
                        await request.cancelRequestBody()
                        return AIHTTPResponse(statusCode: 413)
                    }
                    body.append(chunk)
                }
            } else { return AIHTTPResponse(statusCode: 400) }
            guard body.count <= Self.maxBodyBytes else { return AIHTTPResponse(statusCode: 413) }
            guard try verifyMCPEventSignature(headers: request.headers, body: body, secret: subscription.delivery.secret, now: now()) else { return AIHTTPResponse(statusCode: 401) }
            guard let json = try? JSONDecoder().decode(JSONValue.self, from: body) else { return AIHTTPResponse(statusCode: 400) }
            let type = json["type"]
            var gap: MCPEventGap?
            var termination: MCPEventTermination?
            if let type {
                switch type.stringValue {
                case "verification":
                    guard let challenge = json["challenge"]?.stringValue, !challenge.isEmpty else { return AIHTTPResponse(statusCode: 400) }
                    return AIHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: try JSONEncoder().encode(JSONValue.object(["challenge": .string(challenge)])))
                case "gap":
                    guard let cursor = json["cursor"]?.stringValue else { return AIHTTPResponse(statusCode: 400) }
                    var raw = json.objectValue ?? [:]; raw["truncated"] = true
                    gap = MCPEventGap(cursor: cursor, rawValue: .object(raw))
                case "terminated":
                    guard let code = json["error"]?["code"]?.doubleValue, code.isFinite, let integer = Int(exactly: code),
                          let message = json["error"]?["message"]?.stringValue else { return AIHTTPResponse(statusCode: 400) }
                    termination = MCPEventTermination(code: integer, message: message, data: json["error"]?["data"], rawValue: json)
                default: return AIHTTPResponse(statusCode: 400)
                }
            }
            guard let storedID = subscription.id, subscription.status == .active || termination != nil else { return AIHTTPResponse(statusCode: 503) }
            let info = MCPEventSubscriptionInfo(id: storedID, name: subscription.name, arguments: subscription.arguments, deliveryURL: subscription.delivery.url, refreshBefore: subscription.refreshBefore)
            let messageID = header("webhook-id") ?? ""
            if let gap {
                try await onGap?(info, messageID, gap)
                try await store.update(key: key, patch: .init(["cursor": .string(gap.cursor), "truncated": true]))
                return AIHTTPResponse(statusCode: 204)
            }
            if let termination {
                try await onTerminated?(info, messageID, termination)
                try await store.delete(key: key)
                return AIHTTPResponse(statusCode: 204)
            }
            if let expiry = subscription.refreshBefore.flatMap(mcpEventDate), expiry <= now() { return AIHTTPResponse(statusCode: 410) }
            guard let event = try? MCPEvent(json: json), event.name == subscription.name, event.eventId == messageID else { return AIHTTPResponse(statusCode: 400) }
            do { try await validatePayload?(subscription.definition, event.data) }
            catch { onError?(error); return AIHTTPResponse(statusCode: 400) }
            try await onEvent(info, event)
            if let cursor = event.cursor { try await store.update(key: key, patch: .init(["cursor": cursor])) }
            return AIHTTPResponse(statusCode: 204)
        } catch {
            onError?(error)
            return AIHTTPResponse(statusCode: 503)
        }
    }
}