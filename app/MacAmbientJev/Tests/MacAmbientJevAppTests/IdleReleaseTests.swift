import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCapture
import MacAmbientJevCore
@testable import MacAmbientJevPipeline
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
    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] { [] }
    func unload() async {}
}

private struct NoopVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "fake-vad", model: nil, version: "test", configuration: [:])
    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] { [] }
}

@MainActor
private func makeState(
    asr: CountingASR, defaults: UserDefaults, root: URL,
    provisioning: any ModelProvisioning = ReadyModelProvisioning()
) -> AppState {
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    return AppState(
        paths: paths, captureEngine: AudioCaptureEngine(paths: paths), microphoneAccess: { false },
        pausesProcessing: false, userDefaults: defaults,
        engines: SessionProcessingEngines(asr: asr, diarization: NoopDiarizer(), finalTranscriptVAD: NoopVAD()),
        modelProvisioning: provisioning,
        makeLiveVADSession: idleLiveVADFactory(),
        thermalMonitor: TestThermalMonitor(.nominal),
        liveTranscriptionSleep: { try await Task.sleep(for: $0) }
    )
}

@MainActor
@Test("the app releases the models when the processing queue drains with nothing recording", .timeLimit(.minutes(10)))
func releasesWhenQueueDrains() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let asr = CountingASR()
    let state = makeState(asr: asr, defaults: defaults, root: root)

    // The session does not exist, so the finalization fails; the queue still drains.
    let maintenance = try #require(state.startupMaintenanceTask, "Startup maintenance task was not started")
    await maintenance.value
    state.enqueueProcessing(.finalize(
        sessionID: UUID(),
        metadataPolicy: .reject
    ))
    await state.processingCoordinator.waitUntilIdle()
    await state.modelPreparer.runTask?.value
    await state.idleReleaseTask?.value

    #expect(await asr.unloadCount == 1)
    #expect(state.modelPreparation == .initial)
    #expect(!state.processingCoordinator.isDraining)
}

@MainActor
@Test("no release happens while recording or while items are queued", .timeLimit(.minutes(10)))
func noReleaseWhileBusy() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let asr = CountingASR()
    let state = makeState(asr: asr, defaults: defaults, root: root)

    let sessionID = UUID()
    state.recording.start(sessionID: sessionID)
    state.markRecordingStarted(sessionID: sessionID)
    state.releaseIdleResourcesIfIdle()
    #expect(state.idleReleaseTask == nil)

    state.recording.finish()
    state.processingQueue.holdForHeat(.finalize(
        sessionID: UUID(), metadataPolicy: .reject
    ))
    state.releaseIdleResourcesIfIdle()
    #expect(state.idleReleaseTask == nil)

    state.processingQueue = SessionProcessingQueue()
    state.processingQueue.enqueue(.finalize(
        sessionID: UUID(), metadataPolicy: .reject
    ))
    state.releaseIdleResourcesIfIdle()
    #expect(state.idleReleaseTask == nil)

    state.processingQueue = SessionProcessingQueue()
    state.releaseIdleResourcesIfIdle()
    let release = try #require(state.idleReleaseTask)
    await release.value
    #expect(await asr.unloadCount == 1)
}

@MainActor
@Test("a running model preparation is not idle, and the models load again after a release", .timeLimit(.minutes(10)))
func reloadAfterRelease() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let asr = CountingASR()
    let state = makeState(asr: asr, defaults: defaults, root: root)

    state.prepareModels()
    #expect(!state.isIdleForRelease)
    state.releaseIdleResourcesIfIdle()
    #expect(state.idleReleaseTask == nil)
    await state.modelPreparer.runTask?.value
    state.releaseIdleResourcesIfIdle()
    let release = try #require(state.idleReleaseTask)
    await release.value
    #expect(await asr.loadCount == 1)
    #expect(await asr.unloadCount == 1)
    #expect(state.modelPreparation == .initial)

    state.prepareModels()
    let preparation = try #require(state.modelPreparer.runTask)
    await preparation.value
    #expect(await asr.loadCount == 2)
    #expect(state.modelPreparation.phase == .ready)
}

/// Models that are missing until `fetch` runs, which waits for the test to let it finish.
private final class MissingModels: ModelProvisioning, @unchecked Sendable {
    private let fetched = OneShotFlag()
    let gate = ModelFetchGate()
    func byteCount(_ model: MacModel) -> Int64 { 10 }
    func isFetched(_ model: MacModel) -> Bool { fetched.isSet }
    func fetch(_ model: MacModel, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        await gate.wait()
        fetched.set()
    }
    func verify(_ model: MacModel) async throws {}
}

private final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private actor ModelFetchGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
@Test("finalization queued without models waits, then runs by itself once the models arrive", .timeLimit(.minutes(10)))
func finalizationWaitsForModelsAndStartsOnReady() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let provisioning = MissingModels()
    let asr = CountingASR()
    let state = makeState(asr: asr, defaults: defaults, root: root, provisioning: provisioning)
    await state.startupMaintenanceTask?.value
    let sessionID = UUID()

    state.enqueueProcessing(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await state.processingCoordinator.waitUntilIdle()

    #expect(state.modelPreparation.phase == .downloading)
    #expect(state.processingQueue.modelHeld.map(\.sessionID) == [sessionID])
    #expect(state.processingStatusText == ModelPreparationStatus.waitingForModelsText)
    #expect(!state.isIdleForRelease)
    #expect(await asr.loadCount == 0)

    await provisioning.gate.release()
    await state.modelPreparer.runTask?.value
    await state.processingCoordinator.waitUntilIdle()

    #expect(state.modelPreparation.phase == .ready || state.modelPreparation == .initial)
    #expect(state.processingQueue.modelHeld.isEmpty)
    #expect(state.processingQueue.pending.isEmpty)
    #expect(await asr.loadCount == 1)
}
