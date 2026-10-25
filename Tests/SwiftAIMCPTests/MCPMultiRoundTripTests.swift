@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

private actor MRTRTransport: MCPTransport {
    nonisolated let supportsProtocolVersionDiscovery = true
    let mode: String
    var sent: [JSONValue] = []
    init(_ mode: String = "normal") { self.mode = mode }
    func start() {}
    func close() {}
    func notify(_ message: JSONValue) {}
    func request(_ message: JSONValue) async throws -> JSONValue {
        sent.append(message)
        let id = message["id"] ?? .number(0)
        if message["method"]?.stringValue == "server/discover" {
            return ["jsonrpc": "2.0", "id": id, "result": ["resultType": "complete", "supportedVersions": ["2026-07-28"], "capabilities": ["tools": [:], "resources": [:], "prompts": [:]]]]
        }
        let params = message["params"] ?? [:]
        let name = params["name"]?.stringValue ?? "tool"
        var input: JSONValue = ["question": ["method": "elicitation/create", "params": ["mode": "form", "message": .string(name), "requestedSchema": ["type": "object", "properties": ["answer": ["type": "string"]]]]]]
        if mode == "unsupported" { input = ["sample": ["method": "sampling/createMessage", "params": [:]]] }
        if mode == "url" { input = ["question": ["method": "elicitation/create", "params": ["mode": "url", "url": "https://example.com/"]]] }
        if mode == "many" { input = .object(Dictionary(uniqueKeysWithValues: (0..<17).map { (String($0), input["question"]!) })) }
        let attempts = sent.filter { $0["method"]?.stringValue == message["method"]?.stringValue && $0["params"]?["name"] == params["name"] }.count
        if mode == "malformed" { return ["id": id, "result": ["resultType": "input_required", "requestState": 42]] }
        if mode == "empty" { return ["id": id, "result": ["resultType": "input_required"]] }
        if mode == "forever" || attempts == 1 || (mode == "two" && attempts == 2) {
            var result: [String: JSONValue] = ["resultType": "input_required"]
            if mode != "state-only" { result["inputRequests"] = input }
            if mode != "two" || attempts == 1 { result["requestState"] = .string("opaque:" + name + ":\u{2603}") }
            return ["jsonrpc": "2.0", "id": id, "result": .object(result)]
        }
        if message["method"]?.stringValue == "resources/read" {
            return ["id": id, "result": ["resultType": "complete", "contents": [["uri": params["uri"] ?? "test://resource", "text": "resource result"]]]]
        }
        if message["method"]?.stringValue == "prompts/get" {
            return ["id": id, "result": ["resultType": "complete", "messages": [["role": "user", "content": ["type": "text", "text": "prompt result"]]]]]
        }
        return ["jsonrpc": "2.0", "id": id, "result": ["resultType": "complete", "content": [["type": "text", "text": .string(name)]]]]
    }
    func messages() -> [JSONValue] { sent }
}

private func mrtrClient(_ transport: MRTRTransport, advertised: Bool = true) async throws -> MCPClient {
    let client = try await MCPClient.connect(transport: transport, clientCapabilities: advertised ? ["elicitation": ["form": [:]]] : [:])
    await client.onElicitationRequest { request in MCPElicitResult(action: .accept, content: ["answer": .string(request.message)]) }
    return client
}

@Test func mcpMRTRUsesNewIDsAndOpaquePerRequestState() async throws {
    let transport = MRTRTransport(), client = try await mrtrClient(transport)
    async let a = client.callTool(name: "one", arguments: ["value": 1])
    async let b = client.callTool(name: "two", arguments: ["value": 2])
    _ = try await (a, b)
    let sent = await transport.messages().filter { $0["method"]?.stringValue == "tools/call" }
    #expect(sent.count == 4)
    #expect(Set(sent.compactMap { $0["id"]?.intValue }).count == sent.count)
    for name in ["one", "two"] {
        let calls = sent.filter { $0["params"]?["name"]?.stringValue == name }
        #expect(calls[0]["params"]?["requestState"] == nil)
        #expect(calls[1]["params"]?["requestState"]?.stringValue == "opaque:" + name + ":\u{2603}")
        #expect(calls[1]["params"]?["inputResponses"]?["question"]?["content"]?["answer"]?.stringValue == name)
        #expect(calls[0]["params"]?["arguments"] == calls[1]["params"]?["arguments"])
        #expect(calls[1]["params"]?["_meta"]?["io.modelcontextprotocol/protocolVersion"]?.stringValue == "2026-07-28")
    }
    try await client.close()
}

@Test func mcpMRTRRemovesAbsentStateOnNextRound() async throws {
    let transport = MRTRTransport("two"), client = try await mrtrClient(transport)
    _ = try await client.callTool(name: "tool")
    let sent = await transport.messages().filter { $0["method"]?.stringValue == "tools/call" }
    #expect(sent.count == 3)
    #expect(sent[1]["params"]?["requestState"] != nil)
    #expect(sent[2]["params"]?["requestState"] == nil)
    try await client.close()
}

@Test func mcpMRTRContinuesResourceAndPromptRequests() async throws {
    let transport = MRTRTransport(), client = try await mrtrClient(transport)
    let resource = try await client.readResource(uri: "test://resource")
    let prompt = try await client.experimentalGetPrompt(name: "prompt")
    #expect(resource.contents.first?.text == "resource result")
    #expect(!prompt.messages.isEmpty)
    for method in ["resources/read", "prompts/get"] {
        let requests = await transport.messages().filter { $0["method"]?.stringValue == method }
        #expect(requests.count == 2)
        #expect(requests[1]["params"]?["inputResponses"] != nil)
    }
    try await client.close()
}

@Test func mcpMRTRSupportsStateOnlyAndExplicitDecline() async throws {
    let stateTransport = MRTRTransport("state-only"), stateClient = try await mrtrClient(stateTransport)
    _ = try await stateClient.callTool(name: "state")
    let sent = await stateTransport.messages()
    #expect(sent.last?["params"]?["inputResponses"] == nil)
    #expect(sent.last?["params"]?["requestState"]?.stringValue == "opaque:state:\u{2603}")
    try await stateClient.close()
    let transport = MRTRTransport(), client = try await mrtrClient(transport)
    await client.onElicitationRequest { _ in MCPElicitResult(action: .decline) }
    _ = try await client.callTool(name: "declined")
    #expect(await transport.messages().last?["params"]?["inputResponses"]?["question"]?["action"]?.stringValue == "decline")
    try await client.close()
}

@Test(arguments: ["unsupported", "malformed", "empty", "url", "many"])
func mcpMRTRRejectsInvalidOrUnsupportedInputWithoutContinuation(_ mode: String) async throws {
    let transport = MRTRTransport(mode), client = try await mrtrClient(transport)
    await #expect(throws: MCPClientError.self) { try await client.callTool(name: "blocked") }
    #expect(await transport.messages().filter { $0["method"]?.stringValue == "tools/call" }.count == 1)
    try await client.close()
}

@Test func mcpMRTRRequiresAdvertisedCapabilityAndHandler() async throws {
    let transport = MRTRTransport(), client = try await mrtrClient(transport, advertised: false)
    await #expect(throws: MCPClientError.self) { try await client.callTool(name: "blocked") }
    #expect(await transport.messages().count == 2)
    try await client.close()
    let second = MRTRTransport(), noHandler = try await MCPClient.connect(transport: second, clientCapabilities: ["elicitation": ["form": [:]]])
    await #expect(throws: MCPClientError.self) { try await noHandler.callTool(name: "blocked") }
    #expect(await second.messages().count == 2)
    try await noHandler.close()
}

@Test func mcpMRTRBoundsRoundsAndDoesNotRetryTransportFailures() async throws {
    let transport = MRTRTransport("forever"), client = try await mrtrClient(transport)
    await #expect(throws: MCPClientError.self) { try await client.callTool(name: "bounded") }
    #expect(await transport.messages().filter { $0["method"]?.stringValue == "tools/call" }.count == 9)
    try await client.close()
}

@Test func mcpMRTRAbortAndTimeoutCoverInputHandler() async throws {
    for aborting in [true, false] {
        let transport = MRTRTransport(), client = try await mrtrClient(transport)
        let entered = AIAbortController(), abort = AIAbortController()
        await client.onElicitationRequest { _ in
            entered.abort()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return MCPElicitResult(action: .accept)
        }
        let call = Task { try await client.callTool(name: "pending", options: MCPRequestOptions(abortSignal: abort.signal, timeoutMilliseconds: aborting ? 5_000 : 100)) }
        for _ in 0..<100 where !entered.signal.isAborted { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(entered.signal.isAborted)
        if aborting { abort.abort() }
        await #expect(throws: (any Error).self) { try await call.value }
        #expect(await transport.messages().filter { $0["method"]?.stringValue == "tools/call" }.count == 1)
        try await client.close()
    }
}
