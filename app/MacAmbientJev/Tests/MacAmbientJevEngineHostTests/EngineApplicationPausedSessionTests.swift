import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
@testable import MacAmbientJevPipeline
import MacAmbientJevTestSupport

private actor PausedSessionFinalizationGate {
    private var entered = false
    private var released = false
    private var cancellationObserved = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let changes = ChangeSignal()

    func suspend() async {
        entered = true
        changes.signal()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if released {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.observeCancellation() }
        }
    }

    func waitUntilEntered() async throws {
        try await changes.wait("offline ASR finalization entry") { entered }
    }

    func waitUntilCancelled() async throws {
        try await changes.wait("offline ASR finalization cancellation") { cancellationObserved }
    }

    private func observeCancellation() {
        cancellationObserved = true
        changes.signal()
    }

    func release() {
        guard !released else { preconditionFailure("finalization gate released more than once") }
        released = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private struct PausedSessionGatedASR: ASREngine {
    let gate: PausedSessionFinalizationGate
    let calls: CallCounter
    let provenance = RunProvenance(engine: "host-test-paused-session-asr", model: nil, version: "test", configuration: [:])

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        calls.increment("asr")
        await gate.suspend()
        return ASRResult(text: "日本語のテストです。", detectedLanguage: "ja")
    }

    func unload() async {}
}

private struct PausedSessionNoLiveSegmentsVAD: LiveVADProcessing {
    let segmentationRunID: String

    func processAvailable(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        LiveVADProgress(
            emittedSegments: [], totalSegmentCount: 0,
            committedFrames: checkpoint.committedFrames, micSpeechLevels: []
        )
    }

    func finish(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        LiveVADProgress(
            emittedSegments: [], totalSegmentCount: 0,
            committedFrames: checkpoint.committedFrames, micSpeechLevels: []
        )
    }
}

private final class PausedSessionInferenceProvider: EngineInferenceProviding, @unchecked Sendable {
    private let gate: PausedSessionFinalizationGate
    private let calls = CallCounter()
    private let usageCounter = DecisionUsageCounter()
    private let inspectionProvider = FakeInferenceProvider()

    init(gate: PausedSessionFinalizationGate) {
        self.gate = gate
    }

    func prepare(settings: EngineSettings, onProgress: @escaping @Sendable (EngineModelProgress) -> Void) async throws {
        onProgress(EngineModelProgress(stage: .validating, completed: 1, total: 1))
        onProgress(EngineModelProgress(stage: .loading, completed: 1, total: 1))
    }

    func decisionUsage() async throws -> DecisionUsageSnapshot {
        await usageCounter.snapshot()
    }

    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity {
        try await inspectionProvider.inspectClauseTagger()
    }

    func makeInference(settings: EngineSettings) throws -> EngineInference {
        EngineInference(
            engines: SessionProcessingEngines(
                asr: PausedSessionGatedASR(gate: gate, calls: calls),
                diarization: FakeDiarizer(calls: calls),
                finalTranscriptVAD: FakeFinalVAD()
            ),
            contentPriority: .disabled,
            timelineBuilder: FakeTimelineBuilder(),
            makeLiveVADSession: { _, _, _, runID in PausedSessionNoLiveSegmentsVAD(segmentationRunID: runID) }
        )
    }
}

@MainActor
private final class PausedSessionFinalizationHarness {
    let root: URL
    let paths: AppPaths
    let capture = FakeCapture()
    let app: EngineApplication
    let context: EngineRequestContext

    init(root: URL, gate: PausedSessionFinalizationGate) throws {
        self.root = root
        paths = engineTestPaths(root: root)
        let transport = EngineTransport(source: ScriptedSource(), sink: ScriptedSink(), limits: testLimits())
        let events = EngineEventEmitter(transport: transport)
        app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: paths,
                logicalCPUCount: 4,
                sleep: { try await Task.sleep(for: $0) },
                shutdownPauseTimeout: .seconds(30)
            ),
            capture: capture,
            inference: PausedSessionInferenceProvider(gate: gate),
            events: events
        )
        context = EngineRequestContext(requestID: try EngineID(1), events: events)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(10))) struct EngineApplicationPausedSessionTests {
    @Test func cancelledFinalizationListsPausedAudioWithRestartStatus() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PausedSessionFinalizationGate()
        let first = try PausedSessionFinalizationHarness(root: root, gate: gate)
        let settings = try engineTestSettings()
        _ = try await first.app.core.replace(
            EngineSettingsReplacePayload(expectedRevision: nil, settings: settings), context: first.context
        )
        try await first.app.core.prepare(context: first.context)
        await first.app.core.processingCoordinator.waitUntilIdle()

        let recording = try await first.app.core.start(
            EngineRecordingStartPayload(source: .microphone, device: .default), context: first.context
        )
        let sessionID = try #require(UUID(uuidString: recording.sessionID))
        try await first.capture.session?.appendSpeech(seconds: 2)
        _ = try await first.app.core.stop(recording, context: first.context)
        try await gate.waitUntilEntered()

        let shutdownTask = Task { @MainActor in
            try await first.app.core.shutdown(reason: .requested)
        }
        try await gate.waitUntilCancelled()
        await gate.release()
        try await shutdownTask.value

        let sessionURL = try SessionDirectoryLocator(fileManager: .default).resolve(
            sessionsRoot: first.paths.sessionsRoot, sessionID: sessionID
        )
        let pausedMetadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
        #expect(pausedMetadata.finalizationAttempt?.state == .paused)

        let second = ApplicationHarness(root: root)
        second.start()
        try await second.hello()
        await second.app.waitForStartupRecovery()
        #expect(try await second.state().setup == .modelsRequired)
        guard case let .sessionList(page) = try await second.call(
            "session.list", payload: "{\"cursor\":null,\"limit\":100}"
        ) else {
            Issue.record("session.list did not return a page")
            return
        }
        let listed = try #require(page.sessions.first { $0.sessionID == sessionID.uuidString.lowercased() })
        #expect(listed.statusText == "処理は中断されました。次回の起動時に再開できます")
        guard case let .readable(_, _, audio, _) = listed.metadata else {
            Issue.record("the paused session should have readable audio metadata")
            return
        }
        #expect(audio == .available)
        #expect(try await second.shutdown() == .shutdownRequested)
    }
}
