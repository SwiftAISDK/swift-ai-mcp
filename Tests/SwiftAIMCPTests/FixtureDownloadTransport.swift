@testable import SwiftAITransport
import SwiftAIProvider
import SwiftAITransport
import SwiftAIMCP

/// Explicit opt-in for transports that only return in-memory test fixtures.
/// Production transports must implement DNS pinning in these hooks; fixture
/// transports perform no DNS lookup and cannot connect to a private address.
protocol FixtureDownloadTransport: AITransport {}

extension FixtureDownloadTransport {
    func sendValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        try await send(request)
    }
}

protocol FixtureStreamingDownloadTransport: AIStreamingTransport, FixtureDownloadTransport {}

extension FixtureStreamingDownloadTransport {
    func streamValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        try await stream(request)
    }
}
