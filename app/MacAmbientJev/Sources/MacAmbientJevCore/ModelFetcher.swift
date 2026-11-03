import Foundation

public struct ModelDownloadRequest: Equatable, Sendable {
    public let url: URL
    /// When set, the request asks for `Range: bytes=<startOffset>-`.
    public let startOffset: Int64?

    public init(url: URL, startOffset: Int64?) {
        self.url = url
        self.startOffset = startOffset
    }
}

public struct ModelDownloadResponse: Sendable {
    public let statusCode: Int
    /// The raw `Content-Range` header, such as `bytes 100-199/200`.
    public let contentRange: String?
    public let chunks: AsyncThrowingStream<Data, Error>

    public init(statusCode: Int, contentRange: String?, chunks: AsyncThrowingStream<Data, Error>) {
        self.statusCode = statusCode
        self.contentRange = contentRange
        self.chunks = chunks
    }
}

public protocol ModelDownloadTransport: Sendable {
    func open(_ request: ModelDownloadRequest) async throws -> ModelDownloadResponse
}

public struct ModelDownloadProgress: Equatable, Sendable {
    public let bytesDone: Int64
    public let bytesTotal: Int64
}

public enum ModelDownloadError: Error, Equatable, LocalizedError, Sendable {
    case network(file: String, reason: String)
    case httpStatus(file: String, status: Int)
    case sizeMismatch(file: String, expected: Int64, actual: Int64)
    case hashMismatch(file: String)
    case diskWrite(file: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .network(file, reason):
            "\(file) をダウンロードできませんでした（\(reason)）。通信環境を確認して、もう一度試してください。"
        case let .httpStatus(file, status):
            "\(file) のダウンロードがサーバーに拒否されました（HTTP \(status)）。時間をおいて、もう一度試してください。"
        case let .sizeMismatch(file, expected, actual):
            "\(file) のサイズが想定と違います（想定 \(expected) バイト、実際 \(actual) バイト）。途中のファイルは削除したので、もう一度ダウンロードしてください。"
        case let .hashMismatch(file):
            "\(file) の内容が想定と違います。途中のファイルは削除したので、もう一度ダウンロードしてください。"
        case let .diskWrite(file, reason):
            "\(file) をディスクに書き込めませんでした（\(reason)）。空き容量を確認して、もう一度試してください。"
        }
    }
}

/// Downloads the pinned files of one model, one at a time, resuming `<name>.partial` with `Range`.
public enum ModelFetcher {
    public static func fetch(
        into directory: URL,
        entry: ModelManifestEntry,
        transport: any ModelDownloadTransport,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        let total = entry.files.reduce(Int64(0)) { $0 + $1.byteCount }
        var reporter = ProgressReporter(total: total, report: progress)
        var finished: Int64 = 0
        reporter.update(done: 0, force: true)
        for file in entry.files {
            if (try? ModelVerifier.verify(file, in: directory)) == nil {
                try await download(file, entry: entry, into: directory, transport: transport) {
                    reporter.update(done: finished + $0, force: false)
                }
            }
            finished += file.byteCount
            reporter.update(done: finished, force: true)
        }
    }

    private static func download(
        _ file: ModelManifestFile, entry: ModelManifestEntry, into directory: URL,
        transport: any ModelDownloadTransport, onBytes: (Int64) -> Void
    ) async throws {
        let target = directory.appending(path: file.name)
        let partial = directory.appending(path: file.name + ".partial")
        do {
            try SessionFileAccess.createDirectory(partial.deletingLastPathComponent(), relativeTo: directory)
        } catch {
            throw ModelDownloadError.diskWrite(file: file.name, reason: error.localizedDescription)
        }
        var offset = try partialSize(partial, directory: directory, file: file.name)
        if offset > file.byteCount {
            try discard(partial, directory: directory, file: file.name)
            throw ModelDownloadError.sizeMismatch(file: file.name, expected: file.byteCount, actual: offset)
        }
        if offset < file.byteCount {
            let url = URL(string: "https://huggingface.co/\(entry.repository)/resolve/\(entry.commit)/\(file.name)")!
            let response: ModelDownloadResponse
            do {
                response = try await transport.open(ModelDownloadRequest(url: url, startOffset: offset > 0 ? offset : nil))
            } catch {
                throw networkFailure(error, file: file.name)
            }
            if offset > 0 {
                let misaligned = response.statusCode == 206
                    && !(contentRangeStart(response.contentRange).map { $0 == offset } ?? true)
                if response.statusCode == 200 || response.statusCode == 416 || misaligned {
                    try discard(partial, directory: directory, file: file.name)
                }
                guard response.statusCode == 206, !misaligned else {
                    throw ModelDownloadError.httpStatus(file: file.name, status: response.statusCode)
                }
            } else {
                guard response.statusCode == 200 else {
                    throw ModelDownloadError.httpStatus(file: file.name, status: response.statusCode)
                }
            }
            let handle: FileHandle
            do {
                handle = try SessionFileAccess.openHandle(partial, relativeTo: directory, writable: true, create: true)
                try handle.seek(toOffset: UInt64(offset))
            } catch {
                throw ModelDownloadError.diskWrite(file: file.name, reason: error.localizedDescription)
            }
            defer { try? handle.close() }
            onBytes(offset)
            do {
                for try await chunk in response.chunks {
                    do { try handle.write(contentsOf: chunk) }
                    catch { throw ModelDownloadError.diskWrite(file: file.name, reason: error.localizedDescription) }
                    offset += Int64(chunk.count)
                    onBytes(min(offset, file.byteCount))
                    if offset > file.byteCount { break }
                }
                try Task.checkCancellation()
            } catch let error as ModelDownloadError {
                throw error
            } catch {
                throw networkFailure(error, file: file.name)
            }
        }
        guard offset == file.byteCount else {
            if offset > file.byteCount { try discard(partial, directory: directory, file: file.name) }
            throw offset > file.byteCount
                ? ModelDownloadError.sizeMismatch(file: file.name, expected: file.byteCount, actual: offset)
                : ModelDownloadError.network(file: file.name, reason: "接続が途中で終了しました")
        }
        do {
            try SessionFileAccess.rename(partial, to: target, relativeTo: directory)
        } catch {
            throw ModelDownloadError.diskWrite(file: file.name, reason: error.localizedDescription)
        }
        do {
            try ModelVerifier.verify(file, in: directory)
        } catch let error as ModelVerificationError {
            try discard(target, directory: directory, file: file.name)
            switch error {
            case let .wrongSize(_, expected, actual):
                throw ModelDownloadError.sizeMismatch(file: file.name, expected: expected, actual: actual)
            case .wrongHash:
                throw ModelDownloadError.hashMismatch(file: file.name)
            default:
                throw ModelDownloadError.diskWrite(file: file.name, reason: "\(error)")
            }
        }
    }

    private static func networkFailure(_ error: Error, file: String) -> Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        return ModelDownloadError.network(file: file, reason: error.localizedDescription)
    }

    private static func partialSize(_ partial: URL, directory: URL, file: String) throws -> Int64 {
        do {
            return Int64(try SessionFileAccess.fileSize(partial, relativeTo: directory))
        } catch let error as CocoaError where (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOENT) {
            return 0
        } catch {
            throw ModelDownloadError.diskWrite(file: file, reason: error.localizedDescription)
        }
    }

    private static func discard(_ url: URL, directory: URL, file: String) throws {
        do { try SessionFileAccess.removeIfPresent(url, relativeTo: directory) }
        catch { throw ModelDownloadError.diskWrite(file: file, reason: error.localizedDescription) }
    }

    /// `bytes 100-199/200` gives 100.
    private static func contentRangeStart(_ header: String?) -> Int64? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        return header.dropFirst(6).split(separator: "-").first.flatMap { Int64($0) }
    }

    /// Reports at most once per 1 % or per 100 ms, never backwards, and always when forced.
    private struct ProgressReporter {
        let total: Int64
        let report: @Sendable (ModelDownloadProgress) -> Void
        private var lastDone: Int64 = -1
        private var lastTime = ContinuousClock.now

        init(total: Int64, report: @escaping @Sendable (ModelDownloadProgress) -> Void) {
            self.total = total
            self.report = report
        }

        mutating func update(done: Int64, force: Bool) {
            guard done > lastDone else { return }
            let now = ContinuousClock.now
            guard force || done - lastDone >= max(total / 100, 1) || now - lastTime >= .milliseconds(100) else { return }
            lastDone = done
            lastTime = now
            report(ModelDownloadProgress(bytesDone: done, bytesTotal: total))
        }
    }
}
