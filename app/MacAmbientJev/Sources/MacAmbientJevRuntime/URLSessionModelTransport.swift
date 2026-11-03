import Foundation
import MacAmbientJevCore

/// Streams a model file over HTTPS. Hugging Face redirects `resolve/` URLs to a CDN, so the
/// redirect delegate sets `Range` again on the redirected request instead of trusting URLSession
/// to copy it. The body arrives through a data-task delegate and is pulled by the consumer: the
/// task is suspended while more than `highWater` bytes wait, so a slow disk never grows memory.
public struct URLSessionModelTransport: ModelDownloadTransport {
    public init() {}

    public func open(_ request: ModelDownloadRequest) async throws -> ModelDownloadResponse {
        var urlRequest = URLRequest(url: request.url)
        let range = request.startOffset.map { "bytes=\($0)-" }
        if let range { urlRequest.setValue(range, forHTTPHeaderField: "Range") }
        let download = Download(range: range)
        let http = try await download.start(urlRequest)
        let lifetime = Lifetime(download)
        let chunks = AsyncThrowingStream<Data, Error>(unfolding: {
            _ = lifetime
            return try await withTaskCancellationHandler {
                try await download.next()
            } onCancel: { download.cancel() }
        })
        return ModelDownloadResponse(
            statusCode: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            chunks: chunks
        )
    }

    /// Cancels the download when the stream is released without being read to its end.
    private final class Lifetime: Sendable {
        let download: Download
        init(_ download: Download) { self.download = download }
        deinit { download.cancel() }
    }

    private final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private static let highWater = 4 * 1024 * 1024
        private static let lowWater = 1024 * 1024

        private let range: String?
        private let lock = NSLock()
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var head: CheckedContinuation<HTTPURLResponse, Error>?
        private var reader: CheckedContinuation<Data?, Error>?
        private var queue: [Data] = []
        private var buffered = 0
        private var suspended = false
        private var finished = false
        private var failure: Error?

        init(range: String?) { self.range = range }

        func start(_ request: URLRequest) async throws -> HTTPURLResponse {
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)
            lock.withLock {
                self.session = session
                self.task = task
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock { head = continuation }
                    task.resume()
                }
            } onCancel: { cancel() }
        }

        func next() async throws -> Data? {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                if !queue.isEmpty {
                    let data = queue.removeFirst()
                    buffered -= data.count
                    if suspended, buffered <= Self.lowWater {
                        suspended = false
                        task?.resume()
                    }
                    continuation.resume(returning: data)
                } else if finished {
                    if let failure { continuation.resume(throwing: failure) } else { continuation.resume(returning: nil) }
                } else {
                    reader = continuation
                }
            }
        }

        func cancel() {
            lock.lock()
            let session = session
            lock.unlock()
            session?.invalidateAndCancel()
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            let continuation = lock.withLock { () -> CheckedContinuation<HTTPURLResponse, Error>? in
                defer { head = nil }
                return head
            }
            if let http = response as? HTTPURLResponse {
                continuation?.resume(returning: http)
                completionHandler(.allow)
            } else {
                continuation?.resume(throwing: URLError(.badServerResponse))
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            defer { lock.unlock() }
            if let reader {
                self.reader = nil
                reader.resume(returning: data)
                return
            }
            queue.append(data)
            buffered += data.count
            if buffered >= Self.highWater, !suspended {
                suspended = true
                dataTask.suspend()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let head = head
            self.head = nil
            finished = true
            failure = error
            let reader = queue.isEmpty ? self.reader : nil
            if reader != nil { self.reader = nil }
            lock.unlock()
            head?.resume(throwing: error ?? URLError(.badServerResponse))
            if let reader {
                if let error { reader.resume(throwing: error) } else { reader.resume(returning: nil) }
            }
            session.finishTasksAndInvalidate()
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            var redirected = request
            if let range { redirected.setValue(range, forHTTPHeaderField: "Range") }
            completionHandler(redirected)
        }
    }
}
