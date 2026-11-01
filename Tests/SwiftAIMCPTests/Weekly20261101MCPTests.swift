import Foundation
import Testing
@testable import SwiftAIMCP
import SwiftAIProvider
import SwiftAITransport

private actor WeeklyMCPTransport: MCPTransport {
    nonisolated let supportsProtocolVersionDiscovery = true
    let mode: String
    var sent: [JSONValue] = []
    init(_ mode: String = "two") { self.mode = mode }
    func start() {}
    func close() {}
    func notify(_ message: JSONValue) {}
    func request(_ message: JSONValue) async throws -> JSONValue {
        sent.append(message)
        let id = message["id"] ?? 0, method = message["method"]?.stringValue ?? ""
        if method == "server/discover" {
            if mode.hasPrefix("discovery-") {
                let code = mode == "discovery-access" ? -32020 : mode == "discovery-auth" ? -32021 : -32022
                let supported: JSONValue = mode == "discovery-unknown" ? ["2099-01-01"] : mode == "discovery-modern" ? [.string(MCPClient.latestProtocolVersion)] : mode == "discovery-invalid" ? [42] : ["2025-11-25", "2025-06-18"]
                return ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": "Server says no", "data": ["supported": supported, "marker": "original"]]]
            }
            return ["jsonrpc": "2.0", "id": id, "result": ["resultType": "complete", "supportedVersions": [.string(MCPClient.latestProtocolVersion)], "capabilities": ["tools": [:], "resources": [:], "prompts": [:]]]]
        }
        if method == "prompts/list" { return ["id": id, "result": ["resultType": "complete", "prompts": [["name": "prompt"]]]] }
        let count = sent.filter { $0["method"]?.stringValue == method }.count
        if mode == "two" && count <= 2 || mode == "forever" || mode == "state" && count == 1 || mode.hasPrefix("invalid-") || mode == "pending" && count == 1 || mode == "many" && count == 1 {
            if mode == "state" || mode == "forever" { return ["id": id, "result": ["resultType": "input_required", "requestState": ""]] }
            var request: JSONValue = ["method": "elicitation/create", "params": ["mode": "form", "message": "question", "requestedSchema": ["type": "object", "properties": ["answer": ["type": "string"]]]]]
            if mode == "invalid-method" { request = ["method": "sampling/createMessage", "params": [:]] }
            if mode == "invalid-url" { request = ["method": "elicitation/create", "params": ["mode": "url", "url": "https://example.com"]] }
            if mode == "invalid-schema" { request = ["method": "elicitation/create", "params": ["mode": "form", "message": "question", "requestedSchema": ["type": "array"]]] }
            if mode == "invalid-state" { return ["id": id, "result": ["resultType": "input_required", "requestState": 42]] }
            if mode == "invalid-empty" { return ["id": id, "result": ["resultType": "input_required"]] }
            let key = count == 1 ? "first" : "second"
            let requests = mode == "many" ? JSONValue.object(Dictionary(uniqueKeysWithValues: (0..<17).map { (String($0), request) })) : .object([key: request])
            var result: [String: JSONValue] = ["resultType": "input_required", "inputRequests": requests]
            if count == 1 { result["requestState"] = "opaque" }
            return ["id": id, "result": .object(result)]
        }
        let result: JSONValue
        if method == "resources/read" { result = ["resultType": "complete", "contents": [["uri": "test://resource", "text": "done"]]] }
        else if method == "prompts/get" { result = ["resultType": "complete", "messages": [["role": "user", "content": ["type": "text", "text": "done"]]]] }
        else { result = ["resultType": "complete", "content": [["type": "text", "text": "done"]]] }
        return ["id": id, "result": result]
    }
    func calls(_ method: String) -> [JSONValue] { sent.filter { $0["method"]?.stringValue == method } }
}

private actor WeeklyMCPAnswer {
    private var pending: CheckedContinuation<MCPElicitResult, Never>?
    func wait() async -> MCPElicitResult { await withCheckedContinuation { pending = $0 } }
    func release() { pending?.resume(returning: MCPElicitResult(action: .accept)); pending = nil }
}

@Suite("Weekly20261101 MCP input-required upstream changes")
struct Weekly20261101MCPTests {
    @Test(arguments: ["tools/call", "resources/read", "prompts/get"])
    func inputRoundsKeepOriginalArgumentsAndOnlyCurrentState(_ method: String) async throws {
        let transport = WeeklyMCPTransport(), client = try await MCPClient.connect(transport: transport)
        await client.onElicitationRequest { _ in MCPElicitResult(action: .decline) }
        switch method {
        case "resources/read": _ = try await client.readResource(uri: "test://resource")
        case "prompts/get": _ = try await client.getPrompt(name: "prompt", arguments: ["value": "original"])
        default: _ = try await client.callTool(name: "tool", arguments: ["value": "original"])
        }
        let calls = await transport.calls(method)
        #expect(calls.count == 3)
        #expect(Set(calls.compactMap { $0["id"]?.intValue }).count == 3)
        #expect(calls[1]["params"]?["requestState"] == "opaque")
        #expect(calls[2]["params"]?["requestState"] == nil)
        #expect(calls[1]["params"]?["inputResponses"]?["first"]?["action"] == "decline")
        #expect(calls[2]["params"]?["inputResponses"]?["first"] == nil)
        #expect(calls[2]["params"]?["inputResponses"]?["second"]?["action"] == "decline")
        #expect(calls[0]["params"]?["arguments"] == calls[2]["params"]?["arguments"])
        #expect(calls[0]["params"]?["uri"] == calls[2]["params"]?["uri"])
        try await client.close()
    }

    @Test func stateOnlyEmptyStringPacesRetryAndOmitsResponses() async throws {
        let transport = WeeklyMCPTransport("state"), client = try await MCPClient.connect(transport: transport)
        let started = ContinuousClock.now
        _ = try await client.callTool(name: "tool")
        #expect(started.duration(to: .now) >= .milliseconds(200))
        let calls = await transport.calls("tools/call")
        #expect(calls.count == 2)
        #expect(calls[1]["params"]?["requestState"] == "")
        #expect(calls[1]["params"]?["inputResponses"] == nil)
        try await client.close()
    }

    @Test func inputRequiredRoundLimitIsTenRetries() async throws {
        let transport = WeeklyMCPTransport("forever"), client = try await MCPClient.connect(transport: transport)
        do { _ = try await client.callTool(name: "tool"); Issue.record("Expected round limit") }
        catch { #expect(String(describing: error).contains("10 rounds")) }
        #expect(await transport.calls("tools/call").count == 11)
        try await client.close()
    }

    @Test(arguments: ["method", "url", "schema", "state", "empty"])
    func malformedAndUnsupportedInputStopsWithoutResending(_ variant: String) async throws {
        let transport = WeeklyMCPTransport("invalid-" + variant), client = try await MCPClient.connect(transport: transport)
        await client.onElicitationRequest { _ in MCPElicitResult(action: .accept) }
        await #expect(throws: MCPClientError.self) { try await client.callTool(name: "tool") }
        #expect(await transport.calls("tools/call").count == 1)
        try await client.close()
    }

    @Test func missingHandlerProducesActionableError() async throws {
        let transport = WeeklyMCPTransport("pending"), client = try await MCPClient.connect(transport: transport)
        do { _ = try await client.callTool(name: "tool"); Issue.record("Expected handler diagnostic") }
        catch { #expect(String(describing: error).contains("onElicitationRequest")) }
        #expect(await transport.calls("tools/call").count == 1)
        try await client.close()
    }

    @Test func formInputCountHasNoUnpublishedSixteenRequestCap() async throws {
        let transport = WeeklyMCPTransport("many"), client = try await MCPClient.connect(transport: transport)
        await client.onElicitationRequest { _ in MCPElicitResult(action: .accept) }
        _ = try await client.callTool(name: "tool")
        #expect(await transport.calls("tools/call").last?["params"]?["inputResponses"]?.objectValue?.count == 17)
        try await client.close()
    }

    @Test(arguments: ["abort", "close", "timeout"])
    func nonCooperativeElicitationCannotResendAfterCancellation(_ mode: String) async throws {
        let transport = WeeklyMCPTransport("pending"), client = try await MCPClient.connect(transport: transport)
        let gate = WeeklyMCPAnswer(), entered = AIAbortController(), abort = AIAbortController()
        await client.onElicitationRequest { _ in entered.abort(); return await gate.wait() }
        let task = Task { try await client.callTool(name: "tool", options: MCPRequestOptions(abortSignal: abort.signal, timeoutMilliseconds: mode == "timeout" ? 80 : 5_000)) }
        for _ in 0..<200 where !entered.signal.isAborted { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(entered.signal.isAborted)
        if mode == "abort" { abort.abort(reason: "test") }
        if mode == "close" { try await client.close() }
        await #expect(throws: (any Error).self) { try await task.value }
        await gate.release()
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(await transport.calls("tools/call").count == 1)
        try await client.close()
    }

    @Test func unsupportedModernVersionHasDiagnosticAndPreservedCause() async throws {
        let transport = WeeklyMCPTransport("discovery-legacy")
        do { _ = try await MCPClient.connect(transport: transport); Issue.record("Expected discovery failure") }
        catch let error as MCPClientError {
            #expect(error.code == -32022)
            #expect(error.data?["marker"] == "original")
            #expect(error.message.contains("protocolVersionDiscovery: false"))
            #expect(error.message.contains("2025-11-25"))
            #expect((error.cause as? MCPClientError)?.message == "Server says no")
        }
        #expect(await transport.calls("initialize").isEmpty)
    }

    @Test(arguments: ["unknown", "modern", "invalid", "access", "auth"])
    func discoveryPreservesOtherErrorsAndNeverSilentlyDowngrades(_ mode: String) async throws {
        let transport = WeeklyMCPTransport("discovery-" + mode)
        do { _ = try await MCPClient.connect(transport: transport); Issue.record("Expected original failure") }
        catch let error as MCPClientError { #expect(error.message == "Server says no"); #expect(error.cause == nil) }
        #expect(await transport.calls("initialize").isEmpty)
    }

    @Test func stablePromptNamesRetainDeprecatedAliases() async throws {
        let transport = WeeklyMCPTransport("complete"), client = try await MCPClient.connect(transport: transport)
        let stableList = try await client.listPrompts(), legacyList = try await client.experimentalListPrompts()
        let stableGet = try await client.getPrompt(name: "prompt"), legacyGet = try await client.experimentalGetPrompt(name: "prompt")
        #expect(stableList.rawValue == legacyList.rawValue)
        #expect(stableGet.rawValue == legacyGet.rawValue)
        try await client.close()
    }

    @Test func zeroTimeoutPreventsTheFirstRequest() async throws {
        let transport = WeeklyMCPTransport("complete"), client = try await MCPClient.connect(transport: transport)
        await #expect(throws: MCPClientError.self) { try await client.callTool(name: "tool", options: MCPRequestOptions(timeoutMilliseconds: 0)) }
        #expect(await transport.calls("tools/call").isEmpty)
        try await client.close()
    }

    @Test func totalTimeoutIncludesStateOnlyBackoff() async throws {
        let transport = WeeklyMCPTransport("forever"), client = try await MCPClient.connect(transport: transport)
        await #expect(throws: MCPClientError.self) { try await client.callTool(name: "tool", options: MCPRequestOptions(timeoutMilliseconds: 500, maxTotalTimeoutMilliseconds: 30)) }
        #expect(await transport.calls("tools/call").count == 1)
        try await client.close()
    }

    @Test func handlerFailurePreservesCause() async throws {
        let transport = WeeklyMCPTransport("pending"), client = try await MCPClient.connect(transport: transport)
        let failure = NSError(domain: "handler", code: 7)
        await client.onElicitationRequest { _ in throw failure }
        do { _ = try await client.callTool(name: "tool"); Issue.record("Expected handler failure") }
        catch let error as MCPClientError {
            #expect(error.message == "Failed to process server response")
            #expect((error.cause as? NSError)?.domain == "handler")
        }
        #expect(await transport.calls("tools/call").count == 1)
        try await client.close()
    }

}
