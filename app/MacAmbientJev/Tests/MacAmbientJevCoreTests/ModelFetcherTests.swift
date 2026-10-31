import Foundation
import Testing
import MacAmbientJevCore

private let content = Data((0..<1000).map { UInt8($0 % 251) })
private let file = ModelManifestFile(
    name: "sub/m.bin", role: "r", byteCount: Int64(content.count), sha256: FileSHA256.hexDigest(of: content)
)
private let entry = ModelManifestEntry(repository: "o/r", commit: String(repeating: "b", count: 40), files: [file])

private struct Fake: ModelDownloadTransport {
    /// Serves `body` from the requested offset; `cutAt` ends the stream with an error after that many bytes.
    var body = content
    var status: @Sendable (Int64?) -> Int = { $0 == nil ? 200 : 206 }
    var cutAt: Int?
    var seen: Seen

    final class Seen: @unchecked Sendable {
        var requests: [ModelDownloadRequest] = []
        var fetched: Bool { !requests.isEmpty }
    }

    func open(_ request: ModelDownloadRequest) async throws -> ModelDownloadResponse {
        seen.requests.append(request)
        let start = Int(request.startOffset ?? 0)
        let code = status(request.startOffset)
        let data = code == 404 || code == 416 ? Data() : body.dropFirst(start)
        let cut = cutAt
        let stream = AsyncThrowingStream<Data, Error> { c in
            var rest = data[...]
            var sent = 0
            while !rest.isEmpty {
                let piece = rest.prefix(100)
                rest = rest.dropFirst(100)
                if let cut, sent + piece.count > cut {
                    c.yield(piece.prefix(cut - sent))
                    c.finish(throwing: URLError(.networkConnectionLost))
                    return
                }
                sent += piece.count
                c.yield(Data(piece))
            }
            c.finish()
        }
        let range = code == 206 ? "bytes \(start)-\(body.count - 1)/\(body.count)" : nil
        return ModelDownloadResponse(statusCode: code, contentRange: range, chunks: stream)
    }
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "fetcher-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func partialURL(_ dir: URL) -> URL { dir.appending(path: "sub/m.bin.partial") }

private func run(_ dir: URL, _ transport: Fake) async throws {
    try await ModelFetcher.fetch(into: dir, entry: entry, transport: transport) { _ in }
}

@Test
func freshDownloadVerifiesAndUsesPinnedURL() async throws {
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let seen = Fake.Seen()
    try await run(dir, Fake(seen: seen))
    try ModelVerifier.verify(directory: dir, entry: entry)
    #expect(seen.requests.map(\.url.absoluteString) == ["https://huggingface.co/o/r/resolve/\(entry.commit)/sub/m.bin"])
    #expect(!FileManager.default.fileExists(atPath: partialURL(dir).path))
}

@Test
func cutConnectionResumesFromPartialSize() async throws {
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    await #expect(throws: ModelDownloadError.self) { try await run(dir, Fake(cutAt: 350, seen: .init())) }
    let size = try Data(contentsOf: partialURL(dir)).count
    #expect(size == 350)
    let seen = Fake.Seen()
    try await run(dir, Fake(seen: seen))
    #expect(seen.requests.map(\.startOffset) == [350])
    try ModelVerifier.verify(directory: dir, entry: entry)
}

@Test
func rangeAnsweredWith200Or416DeletesPartial() async throws {
    for status in [200, 416] {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: ModelDownloadError.self) { try await run(dir, Fake(cutAt: 300, seen: .init())) }
        await #expect(throws: ModelDownloadError.httpStatus(file: file.name, status: status)) {
            try await run(dir, Fake(status: { $0 == nil ? 200 : status }, seen: .init()))
        }
        #expect(!FileManager.default.fileExists(atPath: partialURL(dir).path))
    }
}

@Test
func wrongSizeAndWrongHashDeleteTheFile() async throws {
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    await #expect(throws: ModelDownloadError.sizeMismatch(file: file.name, expected: 1000, actual: 1001)) {
        try await run(dir, Fake(body: content + Data([1]), seen: .init()))
    }
    var flipped = content; flipped[10] ^= 0xFF
    await #expect(throws: ModelDownloadError.hashMismatch(file: file.name)) {
        try await run(dir, Fake(body: flipped, seen: .init()))
    }
    #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "sub/m.bin").path))
    #expect(!FileManager.default.fileExists(atPath: partialURL(dir).path))
}

@Test
func notFoundIsAHTTPStatusError() async throws {
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    await #expect(throws: ModelDownloadError.httpStatus(file: file.name, status: 404)) {
        try await run(dir, Fake(status: { _ in 404 }, seen: .init()))
    }
}

@Test
func correctFileIsNotFetched() async throws {
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appending(path: "sub"), withIntermediateDirectories: true)
    try content.write(to: dir.appending(path: "sub/m.bin"))
    let seen = Fake.Seen()
    try await run(dir, Fake(seen: seen))
    #expect(!seen.fetched)
}

@Test
func progressIsMonotonicAndIncludesExistingPartial() async throws {
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    await #expect(throws: ModelDownloadError.self) { try await run(dir, Fake(cutAt: 400, seen: .init())) }
    final class Log: @unchecked Sendable { var values: [Int64] = [] }
    let log = Log()
    try await ModelFetcher.fetch(into: dir, entry: entry, transport: Fake(seen: .init())) { log.values.append($0.bytesDone) }
    #expect(log.values.first == 0)
    #expect(log.values.contains(400))
    #expect(log.values == log.values.sorted())
    #expect(log.values.last == 1000)
}

@Test
func cancellationKeepsThePartial() async throws {
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let task = Task {
        try await ModelFetcher.fetch(into: dir, entry: entry, transport: Fake(seen: .init())) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(FileManager.default.fileExists(atPath: partialURL(dir).path))
}
