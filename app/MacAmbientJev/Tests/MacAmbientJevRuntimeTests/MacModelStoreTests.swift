import Foundation
import Synchronization
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private let content = Data("model bytes".utf8)
private let standInFile = ModelManifestFile(
    name: "sub/m.bin", role: "r", byteCount: Int64(content.count), sha256: FileSHA256.hexDigest(of: content)
)
private let standInEntry = ModelManifestEntry(
    repository: "o/r", commit: String(repeating: "c", count: 40), files: [standInFile]
)
private let standInManifest = Dictionary(uniqueKeysWithValues: MacModel.allCases.map { ($0, standInEntry) })

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "model-store-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func writeStandIn(_ model: MacModel, in store: MacModelStore, data: Data = content) throws {
    let file = store.directory(model).appending(path: standInFile.name)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file)
}

private final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private struct RefusingTransport: ModelDownloadTransport {
    let calls: Counter
    func open(_ request: ModelDownloadRequest) async throws -> ModelDownloadResponse {
        calls.increment()
        throw URLError(.notConnectedToInternet)
    }
}

@Test
func missingModelIsATypedErrorAndNothingIsCreated() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = MacModelStore(modelsRoot: root, manifest: standInManifest, verify: { try ModelVerifier.verify(directory: $0, entry: $1) })

    for model in MacModel.allCases {
        await #expect(throws: MacModelError.notInstalled(model)) { _ = try await store.verifiedDirectory(model) }
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test
func wrongFileIsAVerificationError() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = MacModelStore(modelsRoot: root, manifest: standInManifest, verify: { try ModelVerifier.verify(directory: $0, entry: $1) })
    try writeStandIn(.asr, in: store, data: Data("model bytes!".utf8))
    try writeStandIn(.vad, in: store, data: Data("model BYTES".utf8))

    await #expect(throws: MacModelError.invalid(.asr, .wrongSize(file: standInFile.name, expected: 11, actual: 12))) {
        _ = try await store.verifiedDirectory(.asr)
    }
    await #expect(throws: MacModelError.invalid(.vad, .wrongHash(
        file: standInFile.name, expected: standInFile.sha256, actual: FileSHA256.hexDigest(of: Data("model BYTES".utf8))
    ))) { _ = try await store.verifiedDirectory(.vad) }
}

@Test
func verificationRunsOncePerProcessAndAgainAfterFetch() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let runs = Counter()
    let store = MacModelStore(modelsRoot: root, manifest: standInManifest, verify: { directory, entry in
        runs.increment()
        try ModelVerifier.verify(directory: directory, entry: entry)
    })
    try writeStandIn(.asr, in: store)
    try writeStandIn(.vad, in: store)

    for _ in 0..<3 { _ = try await store.verifiedDirectory(.asr) }
    #expect(runs.count == 1)
    _ = try await store.verifiedDirectory(.vad)
    #expect(runs.count == 2)

    let network = Counter()
    try await store.fetch(.asr, transport: RefusingTransport(calls: network), progress: { _ in })
    #expect(network.count == 0)
    _ = try await store.verifiedDirectory(.asr)
    _ = try await store.verifiedDirectory(.asr)
    #expect(runs.count == 3)
}

@Test
func concurrentCallersShareOneVerification() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let runs = Counter()
    let store = MacModelStore(modelsRoot: root, manifest: standInManifest, verify: { _, _ in
        runs.increment()
        Thread.sleep(forTimeInterval: 0.2)
    })

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<5 { group.addTask { _ = try await store.verifiedDirectory(.diarization) } }
        try await group.waitForAll()
    }
    #expect(runs.count == 1)
}

@Test
func failedVerificationIsNotRemembered() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let runs = Counter()
    let store = MacModelStore(modelsRoot: root, manifest: standInManifest, verify: { directory, entry in
        runs.increment()
        try ModelVerifier.verify(directory: directory, entry: entry)
    })

    await #expect(throws: MacModelError.notInstalled(.asr)) { _ = try await store.verifiedDirectory(.asr) }
    try writeStandIn(.asr, in: store)
    _ = try await store.verifiedDirectory(.asr)
    #expect(runs.count == 2)
}

@Test
func enginesWithoutModelsFailWithTheTypedErrorBeforeLoading() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: nil)
    let store = try MacModelStore(paths: paths)

    await #expect(throws: MacModelError.notInstalled(.asr)) { try await NativeQwen3ASREngine(models: store).prepare() }
    await #expect(throws: MacModelError.notInstalled(.diarization)) { try await FluidOfflineDiarizationEngine(models: store).prepare() }
    await #expect(throws: MacModelError.notInstalled(.vad)) {
        _ = try await FluidVADSegmentationEngine.make(
            models: store, segmentationRunID: "seg", canonicalSampleRate: 16_000, measureMicInputLevels: false
        )
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
}
