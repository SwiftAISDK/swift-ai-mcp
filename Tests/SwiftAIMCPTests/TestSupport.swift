@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing
@testable import SwiftAIMCP

actor RecordingTransport: FixtureStreamingDownloadTransport {
    private var _requests: [AIHTTPRequest] = []
    private var _sendRequests: [AIHTTPRequest] = []
    private var _streamRequests: [AIHTTPRequest] = []
    private var responses: [AIHTTPResponse]

    init(response: AIHTTPResponse) {
        self.responses = [response]
    }

    init(responses: [AIHTTPResponse]) {
        self.responses = responses
    }

    func requests() -> [AIHTTPRequest] {
        _requests
    }

    func sendRequests() -> [AIHTTPRequest] {
        _sendRequests
    }

    func streamRequests() -> [AIHTTPRequest] {
        _streamRequests
    }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        _requests.append(request)
        _sendRequests.append(request)
        return nextResponse()
    }

    func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        _requests.append(request)
        _streamRequests.append(request)
        let response = nextResponse()
        return AIHTTPStreamResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: AsyncThrowingStream { continuation in
                continuation.yield(response.body)
                continuation.finish()
            }
        )
    }

    private func nextResponse() -> AIHTTPResponse {
        if responses.count > 1 {
            return responses.removeFirst()
        }
        return responses[0]
    }
}

func jsonResponse(_ json: String, headers: [String: String] = [:]) -> AIHTTPResponse {
    AIHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"].mergingHeaders(headers), body: Data(json.utf8))
}

func sseResponse(_ text: String, headers: [String: String] = [:]) -> AIHTTPResponse {
    var body = Data(text.utf8)
    // Shared fixtures represent complete SSE responses, so always terminate the
    // final event with a blank line. EOF-specific parser tests build raw data.
    body.append(Data("\n\n".utf8))
    return AIHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"].mergingHeaders(headers), body: body)
}

func multipartResponse(parts: [(name: String, contentType: String, body: Data)]) -> AIHTTPResponse {
    let boundary = "test-boundary"
    var body = Data()
    for part in parts {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(part.name)\"\r\n".utf8))
        body.append(Data("Content-Type: \(part.contentType)\r\n\r\n".utf8))
        body.append(part.body)
        body.append(Data("\r\n".utf8))
    }
    body.append(Data("--\(boundary)--\r\n".utf8))
    return AIHTTPResponse(statusCode: 200, headers: ["content-type": "multipart/form-data; boundary=\(boundary)"], body: body)
}

func amazonEventStreamResponse(_ events: [(eventType: String, payload: String)]) -> AIHTTPResponse {
    let body = events.reduce(into: Data()) { data, event in
        data.append(amazonEventStreamFrame(
            messageType: "event",
            eventTypeHeader: ":event-type",
            eventType: event.eventType,
            payload: Data(event.payload.utf8)
        ))
    }
    return AIHTTPResponse(statusCode: 200, headers: ["content-type": "application/vnd.amazon.eventstream"], body: body)
}

func amazonEventStreamFrame(
    messageType: String,
    eventTypeHeader: String,
    eventType: String,
    payload: Data,
    additionalStringHeaders: [(String, String)] = []
) -> Data {
    var headers = Data()
    appendAmazonStringHeader(name: ":message-type", value: messageType, to: &headers)
    appendAmazonStringHeader(name: eventTypeHeader, value: eventType, to: &headers)
    for (name, value) in additionalStringHeaders {
        appendAmazonStringHeader(name: name, value: value, to: &headers)
    }

    let totalLength = UInt32(12 + headers.count + payload.count + 4)
    var prelude = Data()
    appendUInt32(totalLength, to: &prelude)
    appendUInt32(UInt32(headers.count), to: &prelude)

    var frame = prelude
    appendUInt32(testAmazonEventStreamCRC32(prelude), to: &frame)
    frame.append(headers)
    frame.append(payload)
    appendUInt32(testAmazonEventStreamCRC32(frame), to: &frame)
    return frame
}

private func appendAmazonStringHeader(name: String, value: String, to data: inout Data) {
    let nameData = Data(name.utf8)
    let valueData = Data(value.utf8)
    data.append(UInt8(nameData.count))
    data.append(nameData)
    data.append(7)
    appendUInt16(UInt16(valueData.count), to: &data)
    data.append(valueData)
}

private func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func testAmazonEventStreamCRC32(_ data: Data) -> UInt32 {
    var crc = UInt32.max
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
        }
    }
    return crc ^ UInt32.max
}
