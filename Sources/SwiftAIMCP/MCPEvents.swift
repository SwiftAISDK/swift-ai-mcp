import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public let MCPEventCallbackKey = "mcp_event_subscription"

public struct MCPEvents: Sendable {
    let client: MCPClient
    let configuration: MCPEventsConfiguration
    let managedOperations: (any MCPEventOperations)?

    public func list(cursor: String? = nil, options: MCPRequestOptions? = nil) async throws -> MCPListEventsResult {
        try await MCPListEventsResult(json: client.eventRequest(method: "events/list", params: cursor.map { .object(["cursor": .string($0)]) }, options: options))
    }

    public func subscribe(_ input: MCPSubscribeEventOptions) async throws -> MCPSubscribeEventResult {
        let store = try directStore()
        var url = try validatedCallbackURL(input)
        if case let .milliseconds(ttl) = input.lifetime, ttl <= 0 || ttl > 9_007_199_254_740_991 {
            throw MCPClientError(message: "Invalid MCP event subscription lifetime or replay age")
        }
        if let age = input.maxAgeMilliseconds, age < 0 || age > 9_007_199_254_740_991 {
            throw MCPClientError(message: "Invalid MCP event subscription lifetime or replay age")
        }
        var cursor: String?
        var visited = Set<String>()
        var definition: MCPEventDefinition?
        repeat {
            let page = try await list(cursor: cursor, options: input.options)
            definition = page.events.first { $0.name == input.name }
            if definition != nil { break }
            cursor = page.nextCursor
            if let cursor, !visited.insert(cursor).inserted {
                throw MCPClientError(message: "Repeated MCP events pagination cursor")
            }
        } while cursor != nil
        guard let definition else { throw MCPClientError(message: "Unknown MCP event: \(input.name)") }
        guard definition.delivery.contains(.webhook) else { throw MCPClientError(message: "MCP event \(input.name) does not support webhook delivery") }
        if case let .direct(_, validate) = configuration { try await validate?(definition, input.arguments) }
        let secret = input.secret ?? createMCPEventSecret()
        _ = try decodeMCPEventSecret(secret)
        let key = UUID().uuidString.lowercased()
        var query = url.queryItems ?? []
        query.removeAll { $0.name == MCPEventCallbackKey }
        query.append(URLQueryItem(name: MCPEventCallbackKey, value: key))
        url.queryItems = query
        guard let callback = url.url else { throw MCPClientError(message: "Invalid MCP event callback URL") }
        let subscription = MCPEventSubscription(key: key, name: input.name, arguments: input.arguments, definition: definition, delivery: .init(url: callback, secret: secret), cursor: input.cursor, lifetime: input.lifetime, maxAgeMilliseconds: input.maxAgeMilliseconds)
        // A callback can arrive before the subscribe response. Keep this pending
        // record on errors because the remote server may already have accepted it.
        try await store.set(subscription)
        return try await sendSubscribe(subscription, options: input.options)
    }

    public func refresh(_ reference: MCPEventSubscriptionReference, options: MCPRequestOptions? = nil) async throws -> MCPSubscribeEventResult {
        let subscription = try await storedSubscription(reference)
        try await directStore().update(key: subscription.key, patch: .init(["status": "pending"]))
        return try await sendSubscribe(subscription, options: options)
    }

    public func unsubscribe(_ reference: MCPEventSubscriptionReference, options: MCPRequestOptions? = nil) async throws {
        let subscription = try await storedSubscription(reference)
        let result = try await client.eventRequest(method: "events/unsubscribe", params: .object([
            "name": .string(subscription.name), "arguments": .object(subscription.arguments),
            "delivery": .object(["mode": "webhook", "url": .string(subscription.delivery.url.absoluteString)])
        ]), options: options)
        try mcpValidateEventResult(result)
        try await directStore().delete(key: subscription.key)
    }

    public func subscribe(_ input: MCPManagedSubscribeInput) async throws -> MCPManagedSubscription {
        try await operations().subscribe(input)
    }

    public func getSubscription(id: String, options: MCPRequestOptions? = nil) async throws -> MCPManagedSubscription {
        try await operations().getSubscription(id: id, options: options)
    }

    public func listSubscriptions(cursor: String? = nil, limit: Int? = nil, status: MCPManagedSubscription.Status? = nil, options: MCPRequestOptions? = nil) async throws -> MCPManagedSubscriptionPage {
        try await operations().listSubscriptions(cursor: cursor, limit: limit, status: status, options: options)
    }

    public func unsubscribe(id: String, options: MCPRequestOptions? = nil) async throws -> MCPManagedSubscription {
        try await operations().unsubscribe(id: id, options: options)
    }

    private func operations() throws -> any MCPEventOperations {
        guard let managedOperations else { throw MCPClientError(message: "Configure an MCP event adapter to manage backend subscriptions") }
        return managedOperations
    }

    private func directStore() throws -> any MCPEventStore {
        guard case let .direct(store?, _) = configuration else {
            throw MCPClientError(message: "Configure experimentalEvents.store to manage direct event subscriptions")
        }
        return store
    }

    private func storedSubscription(_ reference: MCPEventSubscriptionReference) async throws -> MCPEventSubscription {
        let store = try directStore()
        let subscription: MCPEventSubscription?
        let value: String
        switch reference {
        case let .id(id): value = id; subscription = try await store.getById(id)
        case let .key(key): value = key; subscription = try await store.get(key: key)
        }
        guard let subscription else { throw MCPClientError(message: "Unknown MCP event subscription: \(value)") }
        return subscription
    }

    private func sendSubscribe(_ subscription: MCPEventSubscription, options: MCPRequestOptions?) async throws -> MCPSubscribeEventResult {
        var params: [String: JSONValue] = [
            "name": .string(subscription.name), "arguments": .object(subscription.arguments),
            "delivery": .object(["mode": "webhook", "url": .string(subscription.delivery.url.absoluteString), "secret": .string(subscription.delivery.secret)]),
            "cursor": subscription.cursor.map(JSONValue.string) ?? .null
        ]
        if let lifetime = subscription.lifetime {
            switch lifetime {
            case .indefinite: params["ttlMs"] = .null
            case let .milliseconds(value): params["ttlMs"] = .number(Double(value))
            }
        }
        if let age = subscription.maxAgeMilliseconds { params["maxAgeMs"] = .number(Double(age)) }
        let result = try await MCPSubscribeEventResult(json: client.eventRequest(method: "events/subscribe", params: .object(params), options: options))
        try await directStore().update(key: subscription.key, patch: .init([
            "id": .string(result.id), "refreshBefore": result.refreshBefore.map(JSONValue.string) ?? .null,
            "cursor": result.cursor.map(JSONValue.string) ?? .null, "truncated": .bool(result.truncated), "status": "active"
        ]))
        return result
    }
}

private func validatedCallbackURL(_ input: MCPSubscribeEventOptions) throws -> URLComponents {
    guard let url = URLComponents(url: input.callbackURL, resolvingAgainstBaseURL: false), url.host != nil else {
        throw MCPClientError(message: "Invalid MCP event callback URL")
    }
    let localHTTP = input.allowInsecureLocalhost && url.scheme?.lowercased() == "http" && ["127.0.0.1", "[::1]", "::1"].contains(url.host ?? "")
    guard (url.scheme?.lowercased() == "https" || localHTTP), (url.user ?? "").isEmpty, (url.password ?? "").isEmpty, (url.fragment ?? "").isEmpty else {
        throw MCPClientError(message: "MCP event callback URLs must use HTTPS without credentials or fragments")
    }
    return url
}