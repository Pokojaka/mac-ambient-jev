import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevPortableRuntime

private final class FakeTransport: ModelDownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let bodies: [URL: Data]
    private var urls: [URL] = []

    init(_ bodies: [URL: Data]) { self.bodies = bodies }

    var opened: Set<URL> { lock.lock(); defer { lock.unlock() }; return Set(urls) }

    private func record(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }

    func open(_ request: ModelDownloadRequest) async throws -> ModelDownloadResponse {
        record(request.url)
        let body = try #require(bodies[request.url])
        return ModelDownloadResponse(statusCode: 200, contentRange: nil, chunks: AsyncThrowingStream { continuation in
            for start in stride(from: 0, to: body.count, by: 3) {
                continuation.yield(body.subdata(in: start..<min(start + 3, body.count)))
            }
            continuation.finish()
        })
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ModelDownloadProgress] = []
    func add(_ value: ModelDownloadProgress) { lock.lock(); values.append(value); lock.unlock() }
    var all: [ModelDownloadProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

private func entry(_ repository: String, _ files: [String: String]) -> (ModelManifestEntry, [URL: Data]) {
    let commit = String(repeating: "a", count: 40)
    var bodies: [URL: Data] = [:]
    var manifestFiles: [ModelManifestFile] = []
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
        let data = Data(text.utf8)
        bodies[URL(string: "https://huggingface.co/\(repository)/resolve/\(commit)/\(name)")!] = data
        manifestFiles.append(ModelManifestFile(name: name, role: "x", byteCount: Int64(data.count), sha256: FileSHA256.hexDigest(of: data)))
    }
    return (ModelManifestEntry(repository: repository, commit: commit, files: manifestFiles), bodies)
}

struct PortableModelDownloadsTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "PortableModelDownloadsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func fetchesOnlyTheEntriesThatAreNotFullyPresentAndReportsOneTotal() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (a, aBodies) = entry("org/a", ["a1.bin": "alpha-one", "a2.bin": "alpha-two"])
        let (b, bBodies) = entry("org/b", ["b1.bin": "bravo-one", "b2.bin": "bravo-two!"])
        let (c, cBodies) = entry("org/c", ["c1.bin": "charlie"])
        let asr = root.appending(path: "asr", directoryHint: .isDirectory)
        let diarization = root.appending(path: "diarization", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: asr, withIntermediateDirectories: true)
        for (url, data) in aBodies { try data.write(to: asr.appending(path: url.lastPathComponent)) }

        let transport = FakeTransport(bBodies.merging(cBodies) { first, _ in first }.merging(aBodies) { first, _ in first })
        let log = ProgressLog()
        try await PortableModelDownloads.fetchMissing(
            [
                PortableModelDownload(model: .asr, directory: asr, entries: [a]),
                PortableModelDownload(model: .diarization, directory: diarization, entries: [b, c]),
            ],
            transport: transport, onProgress: { log.add($0) }
        )

        #expect(transport.opened == Set(bBodies.keys).union(cBodies.keys))
        for (url, data) in bBodies.merging(cBodies, uniquingKeysWith: { first, _ in first }) {
            #expect(try Data(contentsOf: diarization.appending(path: url.lastPathComponent)) == data)
        }
        let total = (Array(bBodies.values) + Array(cBodies.values)).reduce(Int64(0)) { $0 + Int64($1.count) }
        let reports = log.all
        #expect(reports.first == ModelDownloadProgress(bytesDone: 0, bytesTotal: total))
        #expect(reports.last == ModelDownloadProgress(bytesDone: total, bytesTotal: total))
        #expect(reports.allSatisfy { $0.bytesTotal == total })
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone })
    }

    @Test func nothingMissingOpensNoTransportAndReportsNoProgress() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (a, bodies) = entry("org/a", ["a1.bin": "alpha-one"])
        for (url, data) in bodies { try data.write(to: root.appending(path: url.lastPathComponent)) }
        let transport = FakeTransport([:])
        let log = ProgressLog()
        try await PortableModelDownloads.fetchMissing(
            [PortableModelDownload(model: .asr, directory: root, entries: [a])],
            transport: transport, onProgress: { log.add($0) }
        )
        #expect(transport.opened.isEmpty)
        #expect(log.all.isEmpty)
    }

    @Test func aDownloadedFileWithWrongBytesIsDeletedAndReportedInvalid() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = ModelManifestFile(name: "m.bin", role: "x", byteCount: 4, sha256: FileSHA256.hexDigest(of: Data("good".utf8)))
        let url = root.appending(path: "m.bin")
        for model in [PortableModelKind.asr, .vad] {
            try Data("evil".utf8).write(to: url)
            do {
                try PortableModelPreparationService.verify(model, directory: root, files: [file], guidance: "g")
                Issue.record("accepted wrong bytes")
            } catch let error as PortableModelPreparationError {
                guard case let .invalid(kind, path, detail, _) = error else { Issue.record("not invalid"); return }
                #expect(kind == model)
                #expect(path == url.path)
                #expect(detail.contains("SHA-256"))
            }
            #expect(FileManager.default.fileExists(atPath: url.path) == (model == .vad))
        }
    }
}
