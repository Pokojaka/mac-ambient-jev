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
    var stateHold: EngineResourceHoldReason { self == .pressure ? .resourcePressure : .monitorFailed }
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
            paths: paths, logicalCPUCount: 4, resourceMonitor: resources, memoryProber: resources,
            sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: .seconds(30)
        ), capture: capture, inference: inference, events: events)
        context = EngineRequestContext(requestID: try EngineID(1), events: events)
    }
    func start() async throws {
        app.start(); await app.waitForStartupRecovery()
        _ = try await app.core.replace(.init(expectedRevision: nil, settings: settings), context: context)
    }
    func assessment(_ workload: EngineResourceWorkload) async throws -> EngineResourceAssessment {
        try await app.handlers.models.preflight(.init(workload: workload), context: context)
    }
    func acknowledge(_ assessment: EngineResourceAssessment) async throws {
        _ = try await app.handlers.models.acknowledge(.init(assessmentID: assessment.assessmentID), context: context)
    }
    func prepare() async throws {
        try await acknowledgeResourceWarning(app, workload: .load, context: context)
        try await app.core.prepare(context: context); await app.core.processingCoordinator.waitUntilIdle()
    }
    func shutdown() async throws { try await app.core.shutdown(reason: .requested) }
}

@MainActor private func rejected(_ code: EngineErrorCode, containing text: String? = nil,
                                  action: @MainActor () async throws -> Void) async {
    do { try await action(); Issue.record("expected command rejection") }
    catch let error as EngineCommandError { #expect(error.code == code); if let text { #expect(error.message.contains(text)) } }
    catch { Issue.record("unexpected error: \(error)") }
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
    @Test func sameWarningPreflightPreservesAcknowledgementAndWorkloadBinding() async throws {
        let f = try ResourceFixture(inference: FakeInferenceProvider(), resources: FakeResourceMonitor())
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.start()

        let load = try await f.assessment(.load)
        #expect(load.result == .warning && load.reason == .envelopeUnmeasured)
        #expect(load.explanation == "推論のメモリ使用量が未計測です。")
        try await f.acknowledge(load)
        let refreshedLoad = try await f.assessment(.load)
        #expect(refreshedLoad.assessmentID != load.assessmentID)
        let loadEntry = try #require(f.app.core.resourceAssessments.first { $0.snapshot.workload == .load })
        #expect(loadEntry.snapshot == EngineResourceSnapshot(
            settingsRevision: try #require(f.app.core.settingsResult?.revision), workload: .load,
            result: .warning, reason: .envelopeUnmeasured
        ))
        #expect(loadEntry.acknowledged)
        await rejected(.staleRevision) { try await f.acknowledge(load) }

        try await f.app.core.prepare(context: f.context)
        await f.app.core.processingCoordinator.waitUntilIdle()
        try await f.app.core.prepare(context: f.context)
        await f.app.core.processingCoordinator.waitUntilIdle()
        #expect(f.app.core.resourceAssessments.filter { $0.snapshot.workload == .load }.count == 1)
        #expect(f.app.core.resourceAssessments.first { $0.snapshot.workload == .load }?.acknowledged == true)

        let payload = try EngineRecordingStartPayload(source: .microphone, device: .default)
        await rejected(.invalidRequest, containing: "resources.preflight と resources.acknowledge") {
            _ = try await f.app.core.start(payload, context: f.context)
        }
        let refusedLive = try #require(f.app.core.resourceAssessments.first { $0.snapshot.workload == .live })
        #expect(refusedLive.snapshot != loadEntry.snapshot)
        #expect(refusedLive.assessment.result == .warning && !refusedLive.acknowledged)
        let live = try await f.assessment(.live)
        try await f.acknowledge(live)
        let recording = try await f.app.core.start(payload, context: f.context)
        let finalization = try await f.assessment(.finalization)
        #expect(finalization.result == .warning && finalization.reason == .envelopeUnmeasured)
        await rejected(.invalidRequest, containing: "確定処理には確認応答") { try await f.acknowledge(finalization) }
        _ = try await f.app.core.stop(recording, context: f.context)
        await f.app.core.processingCoordinator.waitUntilIdle()
        try await f.shutdown()
    }

    @Test func settingsReplacementInvalidatesResourceAcknowledgement() async throws {
        let f = try ResourceFixture(inference: FakeInferenceProvider(), resources: FakeResourceMonitor())
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.start(); try await f.prepare()

        let payload = try EngineRecordingStartPayload(source: .microphone, device: .default)
        let live = try await f.assessment(.live)
        try await f.acknowledge(live)
        let previousRevision = try #require(f.app.core.settingsResult?.revision)
        _ = try await f.app.core.replace(.init(expectedRevision: previousRevision, settings: f.settings), context: f.context)
        let newRevision = try #require(f.app.core.settingsResult?.revision)
        #expect(newRevision != previousRevision)

        await rejected(.invalidRequest, containing: "resources.preflight と resources.acknowledge") {
            _ = try await f.app.core.start(payload, context: f.context)
        }
        let invalidated = try #require(f.app.core.resourceAssessments.first { $0.snapshot.workload == .live })
        #expect(invalidated.assessment.assessmentID != live.assessmentID)
        #expect(invalidated.snapshot.settingsRevision == newRevision && !invalidated.acknowledged)
        let current = try await f.assessment(.live)
        try await f.acknowledge(current)
        let recording = try await f.app.core.start(payload, context: f.context)
        _ = try await f.app.core.stop(recording, context: f.context)
        await f.app.core.processingCoordinator.waitUntilIdle()
        try await f.shutdown()
    }

    @Test func blockedAssessmentCannotBeAcknowledgedAndFinalizationAcknowledgementIsRejected() async throws {
        let f = try ResourceFixture(inference: FakeInferenceProvider(), resources: FakeResourceMonitor())
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.start(); try await f.prepare()

        let healthy = f.resources.facts
        f.resources.facts = InferenceMemoryFacts(
            physicalMemoryBytes: healthy.physicalMemoryBytes, freePhysicalMemoryBytes: healthy.freePhysicalMemoryBytes,
            commitHeadroomBytes: healthy.commitHeadroomBytes, lowMemorySignal: true
        )
        let blocked = try await f.assessment(.live)
        #expect(blocked.result == .blocked && blocked.reason == .lowMemory)
        await rejected(.modelFailure) { try await f.acknowledge(blocked) }
        let payload = try EngineRecordingStartPayload(source: .microphone, device: .default)
        await rejected(.modelFailure) { _ = try await f.app.core.start(payload, context: f.context) }
        let freshBlocked = try #require(f.app.core.resourceAssessments.first { $0.snapshot.workload == .live })
        #expect(freshBlocked.assessment.assessmentID != blocked.assessmentID)
        #expect(freshBlocked.assessment.result == .blocked && freshBlocked.assessment.reason == .lowMemory)
        #expect(!freshBlocked.acknowledged)

        f.resources.facts = healthy
        await rejected(.invalidRequest, containing: "resources.preflight と resources.acknowledge") {
            _ = try await f.app.core.start(payload, context: f.context)
        }
        let current = try await f.assessment(.live)
        try await f.acknowledge(current)
        let recording = try await f.app.core.start(payload, context: f.context)
        let finalization = try await f.assessment(.finalization)
        #expect(finalization.result == .warning && finalization.reason == .envelopeUnmeasured)
        #expect(finalization.explanation == "推論のメモリ使用量が未計測です。")
        await rejected(.invalidRequest, containing: "確定処理には確認応答") { try await f.acknowledge(finalization) }
        _ = try await f.app.core.stop(recording, context: f.context)
        await f.app.core.processingCoordinator.waitUntilIdle()
        try await f.shutdown()
    }

    @Test func sameReasonDifferentFreeBytesKeepsLiveAcknowledgement() async throws {
        let f = try ResourceFixture(inference: FakeInferenceProvider(), resources: FakeResourceMonitor())
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.start(); try await f.prepare()

        let warning = try await f.assessment(.live)
        try await f.acknowledge(warning)
        let initialSnapshot = try #require(f.app.core.resourceAssessments.first { $0.snapshot.workload == .live }).snapshot
        let initialFreeBytes = f.resources.facts.freePhysicalMemoryBytes
        let payload = try EngineRecordingStartPayload(source: .microphone, device: .default)
        for _ in 0..<2 {
            let facts = f.resources.facts
            f.resources.facts = InferenceMemoryFacts(
                physicalMemoryBytes: facts.physicalMemoryBytes, freePhysicalMemoryBytes: facts.freePhysicalMemoryBytes + 1,
                commitHeadroomBytes: facts.commitHeadroomBytes, lowMemorySignal: facts.lowMemorySignal
            )
            let recording = try await f.app.core.start(payload, context: f.context)
            _ = try await f.app.core.stop(recording, context: f.context)
            await f.app.core.processingCoordinator.waitUntilIdle()
        }
        let liveEntries = f.app.core.resourceAssessments.filter { $0.snapshot.workload == .live }
        #expect(f.resources.facts.freePhysicalMemoryBytes == initialFreeBytes + 2)
        #expect(liveEntries.count == 1 && liveEntries[0].acknowledged)
        #expect(liveEntries[0].snapshot == initialSnapshot)
        #expect(liveEntries[0].snapshot.result == .warning && liveEntries[0].snapshot.reason == .envelopeUnmeasured)
        try await f.shutdown()
    }

    @Test func reasonChangeAfterAcknowledgementRefusesActualAdmission() async throws {
        let f = try ResourceFixture(inference: FakeInferenceProvider(), resources: FakeResourceMonitor())
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.start(); try await f.prepare()

        let warning = try await f.assessment(.live)
        try await f.acknowledge(warning)
        let warningEntry = try #require(f.app.core.resourceAssessments.first { $0.snapshot.workload == .live })
        #expect(warningEntry.snapshot != EngineResourceSnapshot(
            settingsRevision: warningEntry.snapshot.settingsRevision, workload: .live,
            result: .warning, reason: .envelopeStale
        ))

        let healthy = f.resources.facts
        f.resources.facts = InferenceMemoryFacts(
            physicalMemoryBytes: healthy.physicalMemoryBytes, freePhysicalMemoryBytes: healthy.freePhysicalMemoryBytes,
            commitHeadroomBytes: healthy.commitHeadroomBytes, lowMemorySignal: true
        )
        let payload = try EngineRecordingStartPayload(source: .microphone, device: .default)
        await rejected(.modelFailure) { _ = try await f.app.core.start(payload, context: f.context) }
        let blocked = try #require(f.app.core.resourceAssessments.first { $0.snapshot.workload == .live })
        #expect(blocked.assessment.assessmentID != warning.assessmentID)
        #expect(blocked.assessment.result == .blocked && blocked.assessment.reason == .lowMemory)
        #expect(blocked.snapshot.result == .blocked && blocked.snapshot.reason == .lowMemory)
        #expect(!blocked.acknowledged)

        f.resources.facts = healthy
        var refusal: EngineCommandError?
        do {
            _ = try await f.app.core.start(payload, context: f.context)
            Issue.record("expected command rejection")
        } catch let error as EngineCommandError {
            refusal = error
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(refusal?.code == .invalidRequest)
        let renewedWarning = try #require(f.app.core.resourceAssessments.first { $0.snapshot.workload == .live })
        #expect(refusal?.message.contains(renewedWarning.assessment.assessmentID) == true)
        #expect(renewedWarning.assessment.assessmentID != warning.assessmentID)
        #expect(renewedWarning.assessment.result == .warning && renewedWarning.assessment.reason == .envelopeUnmeasured)
        #expect(!renewedWarning.acknowledged)

        let current = try await f.assessment(.live)
        try await f.acknowledge(current)
        let recording = try await f.app.core.start(payload, context: f.context)
        _ = try await f.app.core.stop(recording, context: f.context)
        await f.app.core.processingCoordinator.waitUntilIdle()
        try await f.shutdown()
    }

    @Test(arguments: Pressure.allCases)
    fileprivate func liveResourceHoldKeepsRecordingAndDurableAudio(_ pressure: Pressure) async throws {
        let f = try ResourceFixture(inference: FakeInferenceProvider(), resources: FakeResourceMonitor())
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.start(); try await f.prepare()
        try await acknowledgeResourceWarning(f.app, workload: .live, context: f.context)
        let recording = try await f.app.core.start(.init(source: .microphone, device: .default), context: f.context)
        let id = try #require(UUID(uuidString: recording.sessionID)), capture = try #require(f.capture.session)
        try await capture.appendSpeech(seconds: 1); let before = try await capture.committedCheckpoint()
        f.resources.setSignal(pressure.signal)
        #expect(f.app.core.recording.phase == .recording)
        #expect(f.app.core.currentState().resourceProtection.holdReasons == [pressure.stateHold])
        #expect(f.app.core.liveTranscription.failure(sessionID: id) != nil)
        f.resources.setSignal(.healthy)
        #expect(f.app.core.liveTranscription.failure(sessionID: id) != nil)
        try await capture.appendSpeech(seconds: 1)
        #expect((try await capture.committedCheckpoint()).committedFrames > before.committedFrames)
        #expect(!capture.isStopped && f.app.core.recording.phase == .recording)
        #expect(f.app.core.liveTranscription.failure(sessionID: id) != nil)
        #expect(f.app.core.currentState().resourceProtection.holdReasons == [pressure.stateHold])
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
        #expect(try store.load()?.activeRuns == nil)
        f.resources.setSignal(pressure.signal)
        #expect(f.app.core.currentState().resourceProtection.holdReasons == [pressure.stateHold] && f.app.core.currentState().presentation.processingStatusText?.contains("終了待ち") == true)
        await gate.release(); await f.app.core.processingCoordinator.waitUntilIdle()
        let paused = try #require(try store.load()); let reason = pressure.hold
        #expect(paused.finalizationAttempt?.state == .paused && paused.finalizationAttempt?.attemptID == attempt && provider.base.calls.count("asr") == 1)
        #expect(paused.activeRuns == nil && f.app.core.processingQueue.held.first?.reason == reason && f.app.core.currentState().presentation.processingStatusText == reason.finalizationExplanation)
        #expect(provider.base.calls.count("asr.unload") > 0 && provider.base.calls.count("diarization.unload") > 0)
        let original = try SessionLayout(sessionURL: sessionURL).importedOriginalURL()
        #expect(try Data(contentsOf: original) == bytes)
        if shutsDown {
            try await f.shutdown(); f.resources.setSignal(.healthy); await f.app.core.processingCoordinator.waitUntilIdle()
            let stopped = try #require(try store.load()?.finalizationAttempt)
            let bytesAfterShutdown = try Data(contentsOf: original)
            #expect(provider.base.calls.count("asr") == 1 && stopped.state == .paused && stopped.attemptID == attempt)
            #expect(bytesAfterShutdown == bytes)
        } else {
            f.resources.setSignal(.healthy); await f.app.core.processingCoordinator.waitUntilIdle()
            let completed = try #require(try store.load()?.finalizationAttempt)
            let completedOriginalBytes = try Data(contentsOf: original)
            #expect(completed.state == .complete && completed.attemptID != attempt && provider.base.calls.count("asr") == 3)
            #expect(completedOriginalBytes == bytes)
            try await f.shutdown()
        }
    }
}
