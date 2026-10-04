import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCapture
import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private actor CountingASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private var isLoaded = false

    func prepare() async throws {
        guard !isLoaded else { return }
        loadCount += 1
        isLoaded = true
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        ASRResult(text: "", detectedLanguage: nil)
    }

    func unload() async {
        unloadCount += 1
        isLoaded = false
    }
}

private struct NoopDiarizer: DiarizationEngine {
    let provenance = RunProvenance(engine: "fake-diarizer", model: nil, version: "test", configuration: [:])
    func prepare() async throws {}
    func diarize(fileURL: URL, canonicalSampleRate: Double) async throws -> [SpeakerSpan] { [] }
    func unload() async {}
}

private struct NoopVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "fake-vad", model: nil, version: "test", configuration: [:])
    func segment(reader: ProcessingTimelineReader, runID: String) async throws -> [SegmentReference] { [] }
}

@MainActor
private func makeState(asr: CountingASR, defaults: UserDefaults, root: URL) -> AppState {
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    return AppState(
        paths: paths, captureEngine: AudioCaptureEngine(paths: paths), microphoneAccess: { false },
        pausesProcessing: false, userDefaults: defaults,
        engines: SessionProcessingEngines(asr: asr, diarization: NoopDiarizer(), finalTranscriptVAD: NoopVAD()),
        makeLiveVADSession: idleLiveVADFactory()
    )
}

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while await !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Test("the app releases the models when the processing queue drains with nothing recording")
func releasesWhenQueueDrains() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let asr = CountingASR()
    let state = makeState(asr: asr, defaults: defaults, root: root)

    // The session does not exist, so the finalization fails; the queue still drains.
    state.enqueueProcessing(.finalize(
        sessionID: UUID(),
        source: .importedOriginal(root.appending(path: "missing.caf")),
        metadataPolicy: .reject
    ))
    try await waitUntil { await asr.unloadCount == 1 }

    #expect(await asr.unloadCount == 1)
    #expect(state.modelPreparation == .idle)
    #expect(state.processingTask == nil)
}

@MainActor
@Test("no release happens while recording or while items are queued")
func noReleaseWhileBusy() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let asr = CountingASR()
    let state = makeState(asr: asr, defaults: defaults, root: root)

    state.markRecordingStarted(sessionID: UUID())
    state.releaseIdleResourcesIfIdle()
    #expect(state.idleReleaseTask == nil)

    state.recordingPhase = .idle
    state.thermallyHeldProcessing = [.finalize(
        sessionID: UUID(), source: .importedOriginal(root), metadataPolicy: .reject
    )]
    state.releaseIdleResourcesIfIdle()
    #expect(state.idleReleaseTask == nil)

    state.thermallyHeldProcessing = []
    state.pendingProcessing = [.finalize(
        sessionID: UUID(), source: .importedOriginal(root), metadataPolicy: .reject
    )]
    state.releaseIdleResourcesIfIdle()
    #expect(state.idleReleaseTask == nil)

    state.pendingProcessing = []
    state.releaseIdleResourcesIfIdle()
    let release = try #require(state.idleReleaseTask)
    await release.value
    #expect(await asr.unloadCount == 1)
}

@MainActor
@Test("a model load requested while a release waits for an earlier load does not deadlock, and loads again afterwards")
func reloadAfterRelease() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let asr = CountingASR()
    let state = makeState(asr: asr, defaults: defaults, root: root)

    state.prepareASRModel()
    state.releaseIdleResourcesIfIdle()
    let release = try #require(state.idleReleaseTask)
    await release.value
    #expect(await asr.loadCount == 1)
    #expect(await asr.unloadCount == 1)
    #expect(state.modelPreparation == .idle)

    state.prepareASRModel()
    try await waitUntil { state.modelPreparation == .ready }
    #expect(await asr.loadCount == 2)
    #expect(state.modelPreparation == .ready)
}
