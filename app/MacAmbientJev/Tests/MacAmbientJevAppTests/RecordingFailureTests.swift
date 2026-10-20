import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCapture
import MacAmbientJevCore
import MacAmbientJevPipeline
import MacAmbientJevRuntime

@MainActor
final class FakeAppCaptureEngine: AppCaptureEngine {
    var onStart: ((UUID) async throws -> Void)?
    private var failureHandler: (@MainActor @Sendable (String) -> Void)?
    private(set) var warningHandler: (@MainActor @Sendable (String) -> Void)?
    private(set) var micStatusHandler: (@MainActor @Sendable (UUID, MicInputStatus) -> Void)?
    private var pendingMicConfiguration: Bool?
    private(set) var micConfigurations: [Bool] = []
    private(set) var consumedMicSpeechLevels: [(sessionID: UUID, windows: [MicLevelWindow])] = []
    private(set) var micMonitoringUnavailableSessions: [UUID] = []
    var onCancelStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onTerminate: (() -> Void)?
    var stopResult: AudioCaptureStopResult?
    var stopError: Error?
    var stopped = 0
    var starts = 0
    var cancellations = 0
    var terminations = 0
    var events: [String] = []
    func signalFailure(_ message: String) { failureHandler?(message) }

    func start(
        sessionID: UUID,
        source: CaptureSource,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onWarning: @escaping @MainActor @Sendable (String) -> Void,
        onPermissionWaiting: @escaping @MainActor @Sendable () -> Void,
        onDropouts: @escaping @MainActor @Sendable (UInt64) -> Void,
        onSilenceChanged: @escaping @MainActor @Sendable (Bool) -> Void
    ) async throws {
        starts += 1
        events.append("start")
        if source == .microphone {
            guard pendingMicConfiguration != nil else {
                throw AudioCaptureEngineError.micInputVolumeNotConfigured
            }
            pendingMicConfiguration = nil
        }
        failureHandler = onFailure
        warningHandler = onWarning
        try await onStart?(sessionID)
    }

    func configureMicInputVolume(
        automaticAdjustmentEnabled: Bool,
        onStatus: @escaping @MainActor @Sendable (UUID, MicInputStatus) -> Void
    ) {
        pendingMicConfiguration = automaticAdjustmentEnabled
        micConfigurations.append(automaticAdjustmentEnabled)
        micStatusHandler = onStatus
    }

    func consumeMicSpeechLevels(_ windows: [MicLevelWindow], sessionID: UUID) {
        consumedMicSpeechLevels.append((sessionID, windows))
    }

    func micSpeechMonitoringUnavailable(sessionID: UUID) {
        micMonitoringUnavailableSessions.append(sessionID)
    }

    func cancelStarting() { cancellations += 1; events.append("cancel"); onCancelStart?() }

    func committedCheckpoint() async throws -> AudioCheckpoint {
        guard let stopResult else { throw AudioCaptureEngineError.notRecording }
        return stopResult.checkpoint
    }

    func stop() async throws -> AudioCaptureStopResult {
        stopped += 1
        events.append("stop")
        failureHandler = nil
        onStop?()
        if let stopError { throw stopError }
        guard let stopResult else { throw AudioCaptureEngineError.notRecording }
        return stopResult
    }

    func terminate() {
        terminations += 1
        events.append("terminate")
        failureHandler = nil
        onTerminate?()
    }
}

actor FakeLiveVAD: LiveVADProcessing {
    nonisolated let segmentationRunID = "test-vad"
    private(set) var finishedCheckpoints: [AudioCheckpoint] = []

    func processAvailable(checkpoint: AudioCheckpoint) -> LiveVADProgress {
        LiveVADProgress(emittedSegments: [], totalSegmentCount: 0,
                        committedFrames: checkpoint.committedFrames, micSpeechLevels: [])
    }

    func finish(checkpoint: AudioCheckpoint) -> LiveVADProgress {
        finishedCheckpoints.append(checkpoint)
        return LiveVADProgress(emittedSegments: [], totalSegmentCount: 1,
                               committedFrames: checkpoint.committedFrames, micSpeechLevels: [])
    }
}

func temporaryRecordingPaths() -> (root: URL, paths: AppPaths) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    return (root, AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    ))
}

/// An injected preference store; all reads and writes stay in this instance's memory.
private final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { values[key] ?? registered[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Float, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func set(_ value: URL?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func register(defaults: [String: Any]) {
        registered.merge(defaults) { _, new in new }
    }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func float(forKey key: String) -> Float { object(forKey: key) as? Float ?? 0 }
    override func double(forKey key: String) -> Double { object(forKey: key) as? Double ?? 0 }
    override func url(forKey key: String) -> URL? { object(forKey: key) as? URL }
    override func dictionaryRepresentation() -> [String: Any] {
        registered.merging(values) { _, value in value }
    }
    override func removePersistentDomain(forName _: String) { values.removeAll() }
}

func temporaryDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let defaults = InMemoryUserDefaults()
    MicInputVolumePreference.register(in: defaults)
    return (defaults, "in-memory")
}

@MainActor
func idleLiveVADFactory() -> LiveVADFactory {
    { _, _, _, _ in FakeLiveVAD() }
}

/// A stop with no loss, storage failure or release failure.
func cleanStopResult(_ checkpoint: AudioCheckpoint) -> AudioCaptureStopResult {
    AudioCaptureStopResult(
        checkpoint: checkpoint, didOverflow: false, dropoutCount: 0, gapCount: 0,
        totalGapFrames: 0, sleepAssertionHeld: true,
        writerFailure: nil, systemAudioReleaseFailure: nil
    )
}

func testCheckpoint() -> AudioCheckpoint {
    AudioCheckpoint(
        committedFrames: 16_000,
        sampleRate: 16_000,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["audio-00000.caf"],
        chunkFrameCounts: [16_000],
        gapEvents: []
    )
}

@MainActor
@Test("durable write failure keeps the error visible and finalizes the healthy saved prefix", .timeLimit(.minutes(10)))
func durableWriteFailureFinalizesHealthyPrefix() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    var startedSessionID: UUID?
    let engine = FakeAppCaptureEngine()
    engine.onStart = { startedSessionID = $0 }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let state = AppState(
        paths: paths, captureEngine: engine, microphoneAccess: { true }, pausesProcessing: true,
        userDefaults: defaults, engines: .production(paths: paths), makeLiveVADSession: idleLiveVADFactory(),
        thermalMonitor: TestThermalMonitor(.nominal),
        liveTranscriptionSleep: { try await Task.sleep(for: $0) }
    )
    await state.startRecording()
    let sessionID = try #require(startedSessionID)
    let sessionURL = try SessionDirectoryLocator(fileManager: .default).resolve(sessionsRoot: paths.sessionsRoot, sessionID: sessionID)
    let directory = sessionURL.appending(path: "audio/processing", directoryHint: .isDirectory)
    let writer = try DurableAudioWriter(directory: directory, chunkDurationSeconds: 1, sessionURL: sessionURL)
    try await writer.append(samples: Array(repeating: 0.25, count: 16_000))
    let checkpoint = await writer.committedSnapshot()
    let message = AudioCaptureEngineError.writerFailure(
        DurableAudioWriterError.outOfSpace("chunk-000001.f32le").localizedDescription
    ).localizedDescription
    engine.stopResult = AudioCaptureStopResult(
        checkpoint: checkpoint, didOverflow: false, dropoutCount: 0, gapCount: 0,
        totalGapFrames: 0, sleepAssertionHeld: true,
        writerFailure: message, systemAudioReleaseFailure: nil
    )

    engine.signalFailure(message)
    #expect(state.recordingPhase == .stopping)
    #expect(state.statusText == message)
    let stopping = try #require(state.failureStopTask)
    await stopping.value
    #expect(state.statusTone == .error)
    #expect(state.statusText == "録音の保存に失敗しました: 空き容量が不足したため chunk-000001.f32le を書き込めませんでした")
    #expect(engine.stopped == 1)
    #expect(state.processingQueue.pending.count == 1)
    guard case .finalize(let queuedSession, .reject)? = state.processingQueue.pending.first else {
        Issue.record("Expected the healthy prefix to be queued for finalization")
        return
    }
    #expect(queuedSession == sessionID)

    #expect(state.recordingPhase == .idle)
    #expect(!state.isRecording)
    #expect(state.savedSessions.first(where: { $0.sessionID == sessionID })?.audioSource
        == .recordedPCM(checkpoint))
    #expect(try ProcessingTimelineReader(directory: directory, checkpoint: checkpoint, sessionURL: sessionURL)
        .readSamples(frameRange: 0..<16_000) == Array(repeating: 0.25, count: 16_000))
}

@MainActor
@Test("automatic capture failure and normal stop finish VAD with the stopped checkpoint", .timeLimit(.minutes(10)))
func automaticFailureFinalizesLikeNormalStop() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let checkpoint = testCheckpoint()
    enum StopTrigger { case normal, activeFailure, startingFailure }
    for trigger in [StopTrigger.normal, .activeFailure, .startingFailure] {
        var startedSessionID: UUID?
        let engine = FakeAppCaptureEngine()
        let vad = FakeLiveVAD()
        engine.onStart = { sessionID in
            startedSessionID = sessionID
            if trigger == .startingFailure { engine.signalFailure("capture interrupted") }
        }
        engine.stopResult = cleanStopResult(checkpoint)
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            paths: paths, captureEngine: engine, microphoneAccess: { true },
            pausesProcessing: true, userDefaults: defaults,
            engines: .production(paths: paths), makeLiveVADSession: { _, _, _, _ in vad },
            thermalMonitor: TestThermalMonitor(.nominal),
            liveTranscriptionSleep: { try await Task.sleep(for: $0) }
        )
        await state.startRecording()
        let sessionID = try #require(startedSessionID)
        if trigger == .activeFailure {
            #expect(state.recordingPhase == .recording)
            engine.signalFailure("capture interrupted")
        } else if trigger == .normal {
            #expect(state.recordingPhase == .recording)
            await state.stopRecording()
            #expect(state.statusTone == .neutral)
        }
        if trigger != .normal {
            let stopping = try #require(state.failureStopTask)
            await stopping.value
            #expect(state.statusTone == .error)
            #expect(state.statusText == "capture interrupted")
        }
        #expect(engine.events == ["start", "stop"])
        #expect(state.recordingPhase == .idle)
        // A failure reported while starting ends the recording before live VAD exists.
        #expect(await vad.finishedCheckpoints == (trigger == .startingFailure ? [] : [checkpoint]))
        #expect(state.processingQueue.pending.count == 1)
        guard state.processingQueue.pending.count == 1,
              case .finishLive(let queuedID, let queuedCheckpoint) = state.processingQueue.pending[0] else {
            Issue.record("stop did not enqueue live finalization")
            continue
        }
        #expect(queuedID == sessionID)
        #expect(queuedCheckpoint == checkpoint)
        #expect(state.processingState == .idle)
    }
}

@MainActor
@Test("duplicate capture failures do not stop or finalize twice", .timeLimit(.minutes(10)))
func duplicateCaptureFailuresDoNotStopOrFinalizeTwice() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var startedSessionID: UUID?
    let engine = FakeAppCaptureEngine()
    engine.onStart = { startedSessionID = $0 }
    engine.stopResult = cleanStopResult(testCheckpoint())
    let state = AppState(
        paths: paths, captureEngine: engine, microphoneAccess: { true }, pausesProcessing: true,
        userDefaults: defaults, engines: .production(paths: paths), makeLiveVADSession: idleLiveVADFactory(),
        thermalMonitor: TestThermalMonitor(.nominal),
        liveTranscriptionSleep: { try await Task.sleep(for: $0) }
    )

    await state.startRecording()
    let sessionID = try #require(startedSessionID)
    #expect(state.recordingPhase == .recording)
    let stopping = try #require(state.captureDidFail(sessionID: sessionID, message: "capture interrupted"))
    #expect(state.recordingPhase == .stopping)
    #expect(state.statusText == "capture interrupted")
    #expect(state.captureDidFail(sessionID: sessionID, message: "duplicate failure") == nil)
    #expect(state.statusText == "capture interrupted")

    await stopping.value
    #expect(state.recordingPhase == .idle)
    #expect(engine.stopped == 1)
    #expect(state.processingQueue.pending.count == 1)

    #expect(state.captureDidFail(sessionID: sessionID, message: "late duplicate failure") == nil)
    #expect(state.recordingPhase == .idle)
    #expect(engine.stopped == 1)
    #expect(state.processingQueue.pending.count == 1)
    #expect(state.statusText == "capture interrupted")
    #expect(state.statusTone == .error)
}

@MainActor
@Test("failed startup removes a recovered gap-only checkpoint but keeps real captured audio")
func failedStartupRetainsOnlyCapturedAudio() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    for (hasGap, containsCapture) in [(true, false), (false, true), (true, true)] {
        let engine = FakeAppCaptureEngine()
        var startedSessionID: UUID?
        var startedSessionURL: URL?
        engine.onStart = { sessionID in
            startedSessionID = sessionID
            let sessionURL = try SessionDirectoryLocator(fileManager: .default).resolve(sessionsRoot: paths.sessionsRoot, sessionID: sessionID)
            startedSessionURL = sessionURL
            let directory = SessionLayout(sessionURL: sessionURL).processingDirectory
            let writer = try DurableAudioWriter(directory: directory, chunkDurationSeconds: 1, sessionURL: sessionURL)
            if hasGap {
                try await writer.recordGap(startFrame: 0, frameCount: 16_000, reason: .missingCallback)
                try await writer.append(samples: Array(repeating: 0, count: 16_000))
            }
            if containsCapture {
                try await writer.append(samples: Array(repeating: 0.25, count: 16_000))
            }
            _ = try await writer.finish()
            throw AudioCaptureEngineError.captureFailure("startup failed")
        }
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            paths: paths, captureEngine: engine, microphoneAccess: { true },
            pausesProcessing: true, userDefaults: defaults,
            engines: .production(paths: paths), makeLiveVADSession: idleLiveVADFactory(),
            thermalMonitor: TestThermalMonitor(.nominal),
            liveTranscriptionSleep: { try await Task.sleep(for: $0) }
        )
        await state.startRecording()
        let sessionID = try #require(startedSessionID)
        let sessionURL = try #require(startedSessionURL)
        #expect(FileManager.default.fileExists(atPath: sessionURL.path) == containsCapture)
        #expect(engine.starts == 1)
        #expect(state.recordingPhase == .idle)
        #expect(state.statusTone == .error)
        #expect(state.statusText == "startup failed")
        #expect(state.savedSessions.contains(where: { $0.sessionID == sessionID }) == containsCapture)
        #expect(state.processingQueue.pending.isEmpty)
    }
}

@MainActor
@Test("recording and release errors must both remain visible",
      arguments: ["writer", "input", "throw"])
func recordingPreservesCaptureAndReleaseFailures(kind: String) async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let engine = FakeAppCaptureEngine()
    let original = kind == "writer" ? "writer disk failure" : "input disconnected"
    let release = "system audio tap destroy failed"
    engine.stopResult = AudioCaptureStopResult(
        checkpoint: testCheckpoint(), didOverflow: false, dropoutCount: 0, gapCount: 0,
        totalGapFrames: 0, sleepAssertionHeld: true,
        writerFailure: kind == "writer" ? original : nil,
        systemAudioReleaseFailure: release
    )
    if kind == "throw" {
        engine.stopError = NSError(
            domain: "RecordingReleaseFailure", code: 1, userInfo: [NSLocalizedDescriptionKey: release]
        )
    }
    let state = AppState(
        paths: paths, captureEngine: engine, microphoneAccess: { true }, pausesProcessing: true,
        userDefaults: defaults, engines: .production(paths: paths),
        makeLiveVADSession: idleLiveVADFactory(),
        thermalMonitor: TestThermalMonitor(.nominal),
        liveTranscriptionSleep: { try await Task.sleep(for: $0) }
    )
    let sessionID = UUID()
    state.recording.start(sessionID: sessionID)
    state.markRecordingStarted(sessionID: sessionID)
    let stopping = try #require(state.captureDidFail(sessionID: sessionID, message: original))
    await stopping.value
    #expect(state.recordingPhase == .idle)
    #expect(state.statusTone == .error)
    #expect(state.statusText.contains(original))
    #expect(state.statusText.contains(release))
    if kind != "throw" { #expect(state.processingQueue.pending.count == 1) }
}
