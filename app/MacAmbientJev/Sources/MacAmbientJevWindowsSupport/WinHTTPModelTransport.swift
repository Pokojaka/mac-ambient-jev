import CWindowsHTTP
import Foundation
import MacAmbientJevCore

public struct WinHTTPError: Error, LocalizedError, Equatable, Sendable {
    public let call: String
    public let code: UInt32
    public var errorDescription: String? { "\(call) failed (Win32 \(code))" }
}

/// Streams a model file over HTTPS with WinHTTP. Reads are pulled one 256 KiB chunk at a time by the
/// consumer, so nothing is buffered beyond one chunk. Cancellation takes effect when the current
/// read returns (receive timeout 60 s); the handles are never closed while a read is in flight.
public struct WinHTTPModelTransport: ModelDownloadTransport {
    private static let chunkSize = 256 * 1024
    private static let contentRangeCapacity = 256

    public init() {}

    public func open(_ request: ModelDownloadRequest) async throws -> ModelDownloadResponse {
        try Task.checkCancellation()
        let url = request.url.absoluteString
        let rangeStart = request.startOffset ?? -1
        let (response, status, contentRange) = try await Task.detached(executorPreference: BlockingIOExecutor.shared) {
            var handle: OpaquePointer?
            var call: UnsafePointer<CChar>?
            var code = url.withCString(encodedAs: UTF16.self) { msj_http_open($0, rangeStart, &handle, &call) }
            try Self.check(code, call)
            guard let handle else { preconditionFailure("msj_http_open returned success without a handle") }
            let response = Response(handle: handle)
            var status: UInt32 = 0
            code = msj_http_status(handle, &status, &call)
            try Self.check(code, call)
            var buffer = [UInt16](repeating: 0, count: Self.contentRangeCapacity)
            var present: Int32 = 0
            code = msj_http_content_range(handle, &buffer, UInt32(buffer.count), &present, &call)
            try Self.check(code, call)
            let contentRange = present == 0 ? nil : String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
            return (response, status, contentRange)
        }.value
        let chunks = AsyncThrowingStream<Data, Error> {
            try Task.checkCancellation()
            return try await Task.detached(executorPreference: BlockingIOExecutor.shared) {
                try response.read(count: Self.chunkSize)
            }.value
        }
        return ModelDownloadResponse(statusCode: Int(status), contentRange: contentRange, chunks: chunks)
    }

    private static func check(_ code: UInt32, _ call: UnsafePointer<CChar>?) throws {
        guard code != 0 else { return }
        throw WinHTTPError(call: call.map { String(cString: $0) } ?? "unknown", code: code)
    }

    private final class Response: @unchecked Sendable {
        private let lock = NSLock()
        private var handle: OpaquePointer?

        init(handle: OpaquePointer) { self.handle = handle }

        deinit { msj_http_close(handle) }

        /// One chunk, or nil at the end of the body. The handles close at the end and after an error.
        func read(count: Int) throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            guard let open = handle else { return nil }
            var data = Data(count: count)
            var got: UInt32 = 0
            var call: UnsafePointer<CChar>?
            let code = data.withUnsafeMutableBytes { msj_http_read(open, $0.baseAddress, UInt32(count), &got, &call) }
            guard code == 0, got > 0 else {
                msj_http_close(open)
                handle = nil
                try WinHTTPModelTransport.check(code, call)
                return nil
            }
            data.removeSubrange(Int(got)...)
            return data
        }
    }
}
