import Foundation
import MacAmbientJevCore

/// Streams a model file over HTTPS. Hugging Face redirects `resolve/` URLs to a CDN, so the
/// redirect delegate sets `Range` again on the redirected request instead of trusting URLSession to copy it.
public struct URLSessionModelTransport: ModelDownloadTransport {
    private static let chunkSize = 256 * 1024

    public init() {}

    public func open(_ request: ModelDownloadRequest) async throws -> ModelDownloadResponse {
        var urlRequest = URLRequest(url: request.url)
        let range = request.startOffset.map { "bytes=\($0)-" }
        if let range { urlRequest.setValue(range, forHTTPHeaderField: "Range") }
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest, delegate: RangeRedirect(range: range))
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    buffer.reserveCapacity(Self.chunkSize)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= Self.chunkSize {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return ModelDownloadResponse(
            statusCode: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            chunks: chunks
        )
    }

    private final class RangeRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        let range: String?
        init(range: String?) { self.range = range }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            var redirected = request
            if let range { redirected.setValue(range, forHTTPHeaderField: "Range") }
            return redirected
        }
    }
}
