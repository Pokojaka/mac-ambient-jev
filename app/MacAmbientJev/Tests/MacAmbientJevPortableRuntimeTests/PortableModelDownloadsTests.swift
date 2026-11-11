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

struct PortableModelDownloadsTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "PortableModelDownloadsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func fetchMissingUsesOnlyTheConfiguredQwen3ASRManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = PortableInstalledModelLayout(bundledRoot: root, downloadedRoot: root)
        let configuration = try PortableProcessingConfiguration.installed(
            layout: layout, qwen3Size: .small, threads: 1, logicalCPUCount: 4, withDecisions: false
        )
        let entry = configuration.qwen3Size.manifestEntry
        let file = try #require(entry.files.first)
        let url = URL(string: "https://huggingface.co/\(entry.repository)/resolve/\(entry.commit)/\(file.name)")!
        let transport = FakeTransport([url: Data()])
        await #expect(throws: ModelDownloadError.self) {
            try await PortableModelDownloads.fetchMissing(
                configuration: configuration, transport: transport, onProgress: { _ in }
            )
        }
        #expect(transport.opened == [url])
    }

    @Test func nothingMissingOpensNoTransportAndReportsNoProgress() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = PortableInstalledModelLayout(bundledRoot: root, downloadedRoot: root)
        let configuration = try PortableProcessingConfiguration.installed(
            layout: layout, qwen3Size: .small, threads: 1, logicalCPUCount: 4, withDecisions: false
        )
        try FileManager.default.createDirectory(at: configuration.qwen3ModelDirectory, withIntermediateDirectories: true)
        for file in configuration.qwen3Size.manifestEntry.files {
            let url = configuration.qwen3ModelDirectory.appending(path: file.name)
            try Data().write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(file.byteCount))
        }
        let transport = FakeTransport([:])
        let log = ProgressLog()
        try await PortableModelDownloads.fetchMissing(
            configuration: configuration, transport: transport, onProgress: { log.add($0) }
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
