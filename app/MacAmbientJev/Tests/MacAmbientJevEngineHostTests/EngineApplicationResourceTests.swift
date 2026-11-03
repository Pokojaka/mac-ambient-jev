import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
@testable import MacAmbientJevPipeline
import MacAmbientJevTestSupport

private enum Pressure: CaseIterable, Equatable, Sendable {
    case pressure, monitorFailed
    var signal: InferenceResourceSignal { self == .pressure ? .pressure : .monitorFailed("test") }
    var hold: InferenceHoldReason { self == .pressure ? .resourcePressure : .monitorFailed }
}

@MainActor private final class ResourceFixture {
    let root: URL, paths: AppPaths, settings: EngineSettings, resources: FakeResourceMonitor
    let capture = FakeCapture()
    let app: EngineApplication
    let context: EngineRequestContext
    init(inference: any EngineInferenceProviding, resources: FakeResourceMonitor) throws {
        root = try ApplicationHarness.makeRoot(); paths = engineTestPaths(root: root)
        settings = try engineTestSettings(); self.resources = resources
        let transport = EngineTransport(source: ScriptedSource(), sink: ScriptedSink(), limits: testLimits())
        let events = EngineEventEmitter(transport: transport)
        app = EngineApplication(configuration: EngineApplicationConfiguration(
            paths: paths, logicalCPUCount: 4, resourceMonitor: resources,
            sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: .seconds(30)
        ), capture: capture, inference: inference, events: events)
        context = EngineRequestContext(requestID: try EngineID(1), events: events)
    }
    func start() async throws {
        app.start(); await app.waitForStartupRecovery()
        _ = try await app.core.replace(.init(expectedRevision: nil, settings: settings), context: context)
    }
    func prepare() async throws {
        try await app.core.prepare(context: context); await app.core.processingCoordinator.waitUntilIdle()
    }
    func shutdown() async throws { try await app.core.shutdown(reason: .requested) }
}

private struct ResourceGatedASR: ASREngine {
    let gate: LifecycleContinuationGate, calls: CallCounter
    let provenance = RunProvenance(engine: "resource-gated-asr", model: nil, version: "test", configuration: [:])
    func prepare() async throws {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        calls.increment("asr")
        if calls.count("asr") == 1 { try await gate.suspend() }
        return ASRResult(text: "日本語のテストです。", detectedLanguage: "ja")
    }
    func unload() async { calls.increment("asr.unload") }
}

private struct ResourceFinalVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "resource-final-vad", model: nil, version: "test", configuration: [:])
    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        [SegmentReference(segmentationRunID: runID, segmentID: "first", startFrame: 0, endFrame: 16_000),
         SegmentReference(segmentationRunID: runID, segmentID: "second", startFrame: 16_000, endFrame: 32_000)]
    }
}

private final class ResourceGatedProvider: EngineInferenceProviding, @unchecked Sendable {
    let base = FakeInferenceProvider(), gate: LifecycleContinuationGate
    init(gate: LifecycleContinuationGate) { self.gate = gate }
    func prepare(settings: EngineSettings, onProgress: @escaping @Sendable (EngineModelProgress) -> Void) async throws {
        try await base.prepare(settings: settings, onProgress: onProgress)
    }
    func decisionUsage() async throws -> DecisionUsageSnapshot { try await base.decisionUsage() }
    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity { try await base.inspectClauseTagger() }
    func makeInference(settings: EngineSettings) throws -> EngineInference {
        let standard = try base.makeInference(settings: settings)
        return EngineInference(engines: SessionProcessingEngines(
            asr: ResourceGatedASR(gate: gate, calls: base.calls),
            diarization: FakeDiarizer(calls: base.calls), finalTranscriptVAD: ResourceFinalVAD()),
            contentPriority: standard.contentPriority, timelineBuilder: standard.timelineBuilder,
            makeLiveVADSession: standard.makeLiveVADSession)
    }
}

@MainActor @Suite struct EngineApplicationResourceTests {
    @Test(arguments: Pressure.allCases)
    fileprivate func liveResourceHoldKeepsRecordingAndDurableAudio(_ pressure: Pressure) async throws {
        let f = try ResourceFixture(inference: FakeInferenceProvider(), resources: FakeResourceMonitor())
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.start(); try await f.prepare()
        let recording = try await f.app.core.start(.init(source: .microphone, device: .default), context: f.context)
        let id = try #require(UUID(uuidString: recording.sessionID)), capture = try #require(f.capture.session)
        try await capture.appendSpeech(seconds: 1); let before = try await capture.committedCheckpoint()
        f.resources.setSignal(pressure.signal)
        #expect(f.app.core.recording.phase == .recording)
        #expect(f.app.core.liveTranscription.failure(sessionID: id) != nil)
        f.resources.setSignal(.healthy)
        try await capture.appendSpeech(seconds: 1)
        #expect((try await capture.committedCheckpoint()).committedFrames > before.committedFrames)
        #expect(!capture.isStopped && f.app.core.recording.phase == .recording)
        #expect(f.app.core.liveTranscription.failure(sessionID: id) != nil)
        try await f.shutdown()
    }

    @Test(arguments: Pressure.allCases, [false, true])
    fileprivate func finalizationPausesAndRecoversOnlyWhileRunning(_ pressure: Pressure, _ shutsDown: Bool) async throws {
        let gate = LifecycleContinuationGate(), resources = FakeResourceMonitor()
        let provider = ResourceGatedProvider(gate: gate), f = try ResourceFixture(inference: provider, resources: resources)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.start(); try await f.prepare()
        let input = f.root.appending(path: "import.wav"), bytes = Data("fake wav".utf8)
        try bytes.write(to: input)
        let imported = try await f.app.core.importSession(try EngineImportPayload(inputPath: input.path), context: f.context)
        try await gate.waitUntilEntered()
        #expect(provider.base.calls.count("asr") == 1)
        let id = try #require(UUID(uuidString: imported.sessionID))
        let sessionURL = try SessionDirectoryLocator(fileManager: .default).resolve(sessionsRoot: f.paths.sessionsRoot, sessionID: id)
        let store = ProcessingMetadataStore(sessionURL: sessionURL), attempt = try #require(try store.load()?.finalizationAttempt?.attemptID)
        f.resources.setSignal(pressure.signal)
        #expect(f.app.core.currentState().presentation.processingStatusText == pressure.hold.finalizationExplanation + "（実行中の処理の終了待ち）")
        await gate.release(); await f.app.core.processingCoordinator.waitUntilIdle()
        let paused = try #require(try store.load())
        #expect(paused.finalizationAttempt?.state == .paused && paused.finalizationAttempt?.attemptID == attempt && provider.base.calls.count("asr") == 1)
        #expect(paused.activeRuns == nil && f.app.core.processingQueue.held.first?.reason == pressure.hold)
        #expect(f.app.core.currentState().presentation.processingStatusText == pressure.hold.finalizationExplanation)
        #expect(provider.base.calls.count("asr.unload") > 0 && provider.base.calls.count("diarization.unload") > 0)
        let original = try SessionLayout(sessionURL: sessionURL).importedOriginalURL()
        #expect(try Data(contentsOf: original) == bytes)
        if shutsDown {
            try await f.shutdown(); f.resources.setSignal(.healthy); await f.app.core.processingCoordinator.waitUntilIdle()
            let stopped = try #require(try store.load()?.finalizationAttempt)
            #expect(provider.base.calls.count("asr") == 1 && stopped.state == .paused && stopped.attemptID == attempt)
            #expect(try Data(contentsOf: original) == bytes)
        } else {
            f.resources.setSignal(.healthy); await f.app.core.processingCoordinator.waitUntilIdle()
            let completed = try #require(try store.load()?.finalizationAttempt)
            #expect(completed.state == .complete && completed.attemptID != attempt && provider.base.calls.count("asr") == 3)
            #expect(try Data(contentsOf: original) == bytes)
            try await f.shutdown()
        }
    }

    @Test(arguments: Pressure.allCases)
    fileprivate func pressureAtStopReleasesModelsOnceAndFinalizesAfterRecovery(_ pressure: Pressure) async throws {
        let provider = FakeInferenceProvider(), resources = FakeResourceMonitor()
        let f = try ResourceFixture(inference: provider, resources: resources)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.start(); try await f.prepare()
        let recording = try await f.app.core.start(.init(source: .microphone, device: .default), context: f.context)
        let id = try #require(UUID(uuidString: recording.sessionID))
        try await #require(f.capture.session).appendSpeech(seconds: 2)
        let unloadsBefore = provider.calls.count("asr.unload")
        resources.setSignal(pressure.signal)
        _ = try await f.app.core.stop(recording, context: f.context)
        await f.app.core.processingCoordinator.waitUntilIdle()
        let held = try #require(f.app.core.processingQueue.held.first)
        guard case .finalize(let heldID, .reject) = held.request else { Issue.record("held \(held.request)"); return }
        #expect(heldID == id && held.reason == pressure.hold)
        #expect(provider.calls.count("asr.unload") - unloadsBefore == 1)
        resources.setSignal(.healthy)
        await f.app.core.processingCoordinator.waitUntilIdle()
        let sessionURL = try SessionDirectoryLocator(fileManager: .default).resolve(sessionsRoot: f.paths.sessionsRoot, sessionID: id)
        #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.finalizationAttempt?.state == .complete)
        try await f.shutdown()
    }
}
