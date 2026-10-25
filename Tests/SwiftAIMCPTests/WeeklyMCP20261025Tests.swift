@testable import SwiftAIMCP
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
import Testing

@Suite("WeeklyMCP20261025")
struct WeeklyMCP20261025Tests {
    @Test(arguments: [JSONValue.string("Hello"), .string("")])
    func primitiveStringsBecomeTextIncludingEmptyStrings(value: JSONValue) {
        #expect(mcpToolModelOutput(from: value) == ["type": "text", "value": value])
    }

    @Test(arguments: [JSONValue.number(7), .number(0), .bool(true), .bool(false), .null, .array([JSONValue]())])
    func otherPrimitiveAndArrayOutputsRetainJSON(value: JSONValue) {
        #expect(mcpToolModelOutput(from: value) == ["type": "json", "value": value])
    }

    @Test func wrappedMCPExecutionStringIsNotReinterpretedAsContent() {
        let value = JSONValue.string(#"{"content":[{"type":"text","text":"result"}]}"#)
        #expect(mcpToolModelOutput(from: value) == ["type": "text", "value": value])
        #expect(mcpToolModelOutput(from: ["content": [["type": "text", "text": "result"]]]) ==
            ["type": "content", "value": [["type": "text", "text": "result"]]])
    }
}
