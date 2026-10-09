import Foundation
import Synchronization
import Testing
@testable import MacAmbientJev
@testable import MacAmbientJevCapture
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevRuntime

private struct InjectedLiveVADFailure: Error {}

/// Returns scripted speech windows, one batch per live poll, and runs a hook before each batch.
private actor ScriptedLiveVAD: LiveVADProcessing {
    nonisolated let segmentationRunID = "scripted"
    private var batches: [[MicLevelWindow]]
    private let finalLevels: [MicLevelWindow]
    private let failsProcessing: Bool
    private let beforeBatch: @Sendable (Int) -> Void
    private(set) var deliveredBatches = 0

    init(
        batches: [[MicLevelWindow]], finalLevels: [MicLevelWindow] = [], failsProcessing: Bool = false,
        beforeBatch: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.batches = batches
        self.finalLevels = finalLevels
        self.failsProcessing = failsProcessing
        self.beforeBatch = beforeBatch
    }

    func append(_ more: [[MicLevelWindow]]) { batches += more }

    func processAvailable(checkpoint: AudioCheckpoint) throws -> LiveVADProgress {
        if failsProcessing { throw InjectedLiveVADFailure() }
        var levels: [MicLevelWindow] = []
        if deliveredBatches < batches.count {
            beforeBatch(deliveredBatches)
            levels = batches[deliveredBatches]
            deliveredBatches += 1
        }
        return LiveVADProgress(emittedSegments: [], totalSegmentCount: 0,
                               committedFrames: checkpoint.committedFrames, micSpeechLevels: levels)
    }

    func finish(checkpoint: AudioCheckpoint) -> LiveVADProgress {
        LiveVADProgress(emittedSegments: [], totalSegmentCount: 0,
                        committedFrames: checkpoint.committedFrames, micSpeechLevels: finalLevels)
    }
}

/// Speech windows of 0.25 s covering one second each, at a fixed level.
private func speechBatches(seconds: Range<Int>, dBFS: Double) -> [[MicLevelWindow]] {
    let meanSquare = pow(10, dBFS / 10)
    return seconds.map { second in
        (0..<4).map { quarter in
            let start = Double(second) + Double(quarter) * 0.25
            return MicLevelWindow(
                startSeconds: start, endSeconds: start + 0.25, speechSeconds: 0.25,
                speechMeanSquare: meanSquare, speechPeak: Float(sqrt(meanSquare) * 2),
                inputPeak: 0, clippedFraction: 0
            )
        }
    }
}

private final class TestCaptureClock: CaptureClock {
    private let millis: Atomic<Int64>
    init(seconds: Double) { millis = Atomic(Int64((seconds * 1_000).rounded())) }
    func now() -> TimeInterval { Double(millis.load(ordering: .relaxed)) / 1_000 }
    func set(seconds: Double) { millis.store(Int64((seconds * 1_000).rounded()), ordering: .relaxed) }
}

@MainActor
private final class FakeMicVolume: MicInputVolumeControlling {
    var values: [UInt32: Float] = [0: 0.5]
    private(set) var writes: [[MicInputVolumeElement]] = []
    private var onChange: (@MainActor @Sendable (MicInputVolumeChange) -> Void)?

    private var current: MicInputVolumeSnapshot {
        MicInputVolumeSnapshot(deviceUID: "mic", elements: values.keys.sorted().map {
            MicInputVolumeElement(element: $0, scalar: values[$0]!)
        }, isSettable: true)
    }

    func bind(captureDeviceUID: String,
              onChange: @escaping @MainActor @Sendable (MicInputVolumeChange) -> Void) throws(MicInputVolumeFailure)
        -> MicInputVolumeSnapshot {
        self.onChange = onChange
        return current
    }
    func snapshot() throws(MicInputVolumeFailure) -> MicInputVolumeSnapshot { current }
    func setVolumes(_ requested: [MicInputVolumeElement], expected: MicInputVolumeSnapshot)
        async throws(MicInputVolumeWriteFailure) -> MicInputVolumeSnapshot {
        writes.append(requested)
        for value in requested { values[value.element] = value.scalar }
        return current
    }
    func unbind() throws(MicInputVolumeFailure) { onChange = nil }

    func userMovesSlider(to scalar: Float) {
        values[0] = scalar
        onChange?(.controls)
    }
}

/// Drives the production AudioCaptureEngine's microphone ownership without an AVCapture device:
/// one synthetic buffer stands in for the first callback, then capture time follows `clock`.
@MainActor
private final class InputFreeMicCaptureEngine: AppCaptureEngine {
    nonisolated static let clockOrigin = 99.9
    let clock = TestCaptureClock(seconds: 100)
    let volume = FakeMicVolume()
    private(set) var volumeFactoryCalls = 0
    private let root: URL
    private lazy var engine = AudioCaptureEngine(
        paths: AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root),
        bufferFrameCount: 512, clock: clock,
        micInputVolumeFactory: { [unowned self] in
            volumeFactoryCalls += 1
            return volume
        }
    )
    private var configuration: (enabled: Bool, onStatus: @MainActor @Sendable (UUID, MicInputStatus) -> Void)?

    init(root: URL) { self.root = root }

    func setCaptureTime(_ seconds: Double) { clock.set(seconds: Self.clockOrigin + seconds) }

    func start(
        sessionID: UUID, source: CaptureSource,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onWarning: @escaping @MainActor @Sendable (String) -> Void,
        onPermissionWaiting: @escaping @MainActor @Sendable () -> Void,
        onDropouts: @escaping @MainActor @Sendable (UInt64) -> Void,
        onSilenceChanged: @escaping @MainActor @Sendable (Bool) -> Void
    ) async throws {
        guard source == .microphone, let configuration else {
            throw AudioCaptureEngineError.micInputVolumeNotConfigured
        }
        self.configuration = nil
        let writer = try DurableAudioWriter(directory: root.appending(path: "capture-\(sessionID.uuidString)"), chunkDurationSeconds: 1, sessionURL: root)
        let ring = AudioBlockRing(capacity: 16, blockFrameCapacity: 512, sampleRate: 16_000)
        let sink = TimestampedMonoSink(ring: ring, frameCapacity: 512, clock: clock,
                                       meter: RawInputMeter(channelCount: 1, sampleRate: 16_000))
        engine.installCapture(
            session: nil, output: nil, receiver: nil, callbackQueue: nil, tap: nil, sink: sink,
            ring: ring, drain: AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: CanonicalAudio.sampleRate)), drainTask: nil,
            sessionID: sessionID,
            timeline: ProcessingTimeline(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32LE)
        )
        let samples = [Float](repeating: 0.01, count: 1_600)
        samples.withUnsafeBufferPointer { buffer in
            var channel = buffer.baseAddress!
            var stride = 1
            sink.receive(channels: &channel, strides: &stride, channelCount: 1,
                         frameCount: samples.count, startFrame: 0)
        }
        engine.beginMicInputVolume(
            captureDeviceUID: "mic", sessionID: sessionID,
            automaticAdjustmentEnabled: configuration.enabled, onStatus: configuration.onStatus
        )
    }

    func configureMicInputVolume(
        automaticAdjustmentEnabled: Bool,
        onStatus: @escaping @MainActor @Sendable (UUID, MicInputStatus) -> Void
    ) {
        configuration = (automaticAdjustmentEnabled, onStatus)
    }

    func consumeMicSpeechLevels(_ windows: [MicLevelWindow], sessionID: UUID) {
        engine.consumeMicSpeechLevels(windows, sessionID: sessionID)
    }

    func micSpeechMonitoringUnavailable(sessionID: UUID) {
        engine.micSpeechMonitoringUnavailable(sessionID: sessionID)
    }

    func cancelStarting() { engine.cancelStarting() }
    func committedCheckpoint() async throws -> AudioCheckpoint { try await engine.committedCheckpoint() }
    func stop() async throws -> AudioCaptureStopResult { try await engine.stop() }
    func terminate() { engine.terminate() }
}

private func scalars(_ writes: [[MicInputVolumeElement]]) -> [[Float]] {
    writes.map { $0.map(\.scalar) }
}

infix operator ≈: ComparisonPrecedence
private func ≈ (lhs: [[Float]], rhs: [[Float]]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { (left: [Float], right: [Float]) -> Bool in
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { (a: Float, b: Float) -> Bool in abs(a - b) < 1e-6 }
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<500 where !(await condition()) {
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func makeState(
    paths: AppPaths, engine: any AppCaptureEngine, defaults: UserDefaults,
    makeLiveVADSession: @escaping LiveVADFactory
) -> AppState {
    AppState(
        paths: paths, captureEngine: engine, microphoneAccess: { true }, pausesProcessing: true,
        userDefaults: defaults, engines: .production(paths: paths), makeLiveVADSession: makeLiveVADSession
    )
}

@MainActor
@Suite("MicInputStatusTests")
struct MicInputStatusTests {
    @Test("A microphone recording configures the input volume, then feeds live speech windows but never final ones")
    func microphoneRecordingDeliversLiveSpeechLevels() async throws {
        let (root, paths) = temporaryRecordingPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = FakeAppCaptureEngine()
        engine.stopResult = cleanStopResult(testCheckpoint())
        var startedSessionID: UUID?
        engine.onStart = { startedSessionID = $0 }
        let live = speechBatches(seconds: 0..<1, dBFS: -40)
        let final = speechBatches(seconds: 1..<2, dBFS: -40)[0]
        let vad = ScriptedLiveVAD(batches: live, finalLevels: final)
        var measureRequests: [Bool] = []
        let state = makeState(paths: paths, engine: engine, defaults: defaults) { _, _, measure, _ in
            measureRequests.append(measure)
            return vad
        }

        await state.startRecording()
        let sessionID = try #require(startedSessionID)
        #expect(state.recordingPhase == .recording)
        #expect(engine.micConfigurations == [true])
        try await waitUntil { !engine.consumedMicSpeechLevels.isEmpty }
        #expect(measureRequests == [true])
        #expect(engine.consumedMicSpeechLevels.map(\.sessionID) == [sessionID])
        #expect(engine.consumedMicSpeechLevels.map(\.windows) == live)

        await state.stopRecording()
        #expect(state.recordingPhase == .idle)
        #expect(engine.consumedMicSpeechLevels.map(\.windows) == live)
    }

    @Test("Status follows only the current microphone recording and is independent of capture warnings")
    func statusFollowsCurrentRecording() async throws {
        let (root, paths) = temporaryRecordingPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = FakeAppCaptureEngine()
        engine.stopResult = cleanStopResult(testCheckpoint())
        var startedSessionIDs: [UUID] = []
        engine.onStart = { startedSessionIDs.append($0) }
        let state = makeState(paths: paths, engine: engine, defaults: defaults,
                              makeLiveVADSession: idleLiveVADFactory())

        await state.startRecording()
        let first = try #require(startedSessionIDs.first)
        let firstHandler = try #require(engine.micStatusHandler)
        let low = MicInputStatus(warning: .low, speechMonitoringUnavailable: false, adjustment: .active)
        firstHandler(first, low)
        #expect(state.micInputStatus == low)
        engine.warningHandler?("空き容量が少なくなっています")
        let recovered = MicInputStatus(warning: nil, speechMonitoringUnavailable: false, adjustment: .active)
        firstHandler(first, recovered)
        #expect(state.micInputStatus == recovered)
        #expect(state.captureWarningText == "空き容量が少なくなっています")
        firstHandler(UUID(), MicInputStatus(warning: .clipping, speechMonitoringUnavailable: false, adjustment: .active))
        #expect(state.micInputStatus == recovered)

        await state.stopRecording()
        #expect(state.micInputStatus == nil)
        firstHandler(first, low)
        #expect(state.micInputStatus == nil)

        await state.startRecording()
        let second = try #require(startedSessionIDs.last)
        #expect(second != first)
        firstHandler(first, low)
        #expect(state.micInputStatus == nil)
        let paused = MicInputStatus(warning: nil, speechMonitoringUnavailable: false, adjustment: .pausedByExternalChange)
        let secondHandler = try #require(engine.micStatusHandler)
        secondHandler(second, paused)
        #expect(state.micInputStatus == paused)
        await state.stopRecording()
        #expect(state.micInputStatus == nil)
    }

    @Test("A restore failure reported while stopping stays visible until the next recording")
    func restoreFailureOutlivesRecording() async throws {
        let (root, paths) = temporaryRecordingPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = FakeAppCaptureEngine()
        engine.stopResult = cleanStopResult(testCheckpoint())
        var startedSessionID: UUID?
        engine.onStart = { startedSessionID = $0 }
        let state = makeState(paths: paths, engine: engine, defaults: defaults,
                              makeLiveVADSession: idleLiveVADFactory())

        await state.startRecording()
        let sessionID = try #require(startedSessionID)
        let handler = try #require(engine.micStatusHandler)
        handler(sessionID, MicInputStatus(warning: .low, speechMonitoringUnavailable: false, adjustment: .active))
        engine.onStop = {
            handler(sessionID, MicInputStatus(warning: .low, speechMonitoringUnavailable: false, adjustment: .restoreFailed(.writeRejected)))
        }
        await state.stopRecording()
        #expect(state.recordingPhase == .idle)
        #expect(state.micInputStatus == MicInputStatus(warning: nil, speechMonitoringUnavailable: false, adjustment: .restoreFailed(.writeRejected)))

        engine.onStop = nil
        await state.startRecording()
        #expect(state.micInputStatus == nil)
        await state.stopRecording()
    }

    @Test("System-audio recordings never configure, feed or report the microphone volume")
    func systemAudioLeavesMicrophoneAlone() async throws {
        let (root, paths) = temporaryRecordingPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = FakeAppCaptureEngine()
        engine.stopResult = cleanStopResult(testCheckpoint())
        let vad = ScriptedLiveVAD(batches: speechBatches(seconds: 0..<2, dBFS: -40))
        var measureRequests: [Bool] = []
        let state = makeState(paths: paths, engine: engine, defaults: defaults) { _, _, measure, _ in
            measureRequests.append(measure)
            return vad
        }
        state.captureSource = .systemAudio

        await state.startRecording()
        #expect(state.recordingPhase == .recording)
        try await waitUntil { await vad.deliveredBatches == 2 }
        #expect(await vad.deliveredBatches == 2)
        await state.stopRecording()
        #expect(measureRequests == [false])
        #expect(engine.micConfigurations.isEmpty)
        #expect(engine.consumedMicSpeechLevels.isEmpty)
        #expect(engine.micMonitoringUnavailableSessions.isEmpty)
        #expect(state.micInputStatus == nil)
    }

    @Test("Live VAD startup and polling failures report unavailable speech monitoring for the recording", arguments: [false, true])
    func liveVADFailureReportsMonitoringUnavailable(failsWhilePolling: Bool) async throws {
        let (root, paths) = temporaryRecordingPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = FakeAppCaptureEngine()
        engine.stopResult = cleanStopResult(testCheckpoint())
        var startedSessionID: UUID?
        engine.onStart = { startedSessionID = $0 }
        let state = makeState(paths: paths, engine: engine, defaults: defaults) { _, _, _, _ in
            guard failsWhilePolling else { throw InjectedLiveVADFailure() }
            return ScriptedLiveVAD(batches: [], failsProcessing: true)
        }

        await state.startRecording()
        let sessionID = try #require(startedSessionID)
        try await waitUntil { !engine.micMonitoringUnavailableSessions.isEmpty }
        #expect(engine.micMonitoringUnavailableSessions == [sessionID])
        #expect(state.recordingPhase == .recording)
        await state.stopRecording()
        #expect(engine.micMonitoringUnavailableSessions == [sessionID])
    }

    @Test("With automatic adjustment off, quiet speech still warns, recovers, and no volume control is created")
    func offSettingWarnsWithoutVolumeControl() async throws {
        let (root, paths) = temporaryRecordingPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: MicInputVolumePreference.key)
        let engine = InputFreeMicCaptureEngine(root: root)
        let batches = speechBatches(seconds: 0..<4, dBFS: -40) + speechBatches(seconds: 4..<7, dBFS: -22)
        let vad = ScriptedLiveVAD(batches: batches) { [clock = engine.clock] index in
            clock.set(seconds: InputFreeMicCaptureEngine.clockOrigin + Double(index + 1))
        }
        let state = makeState(paths: paths, engine: engine, defaults: defaults) { _, _, _, _ in vad }

        await state.startRecording()
        #expect(state.micInputStatus == MicInputStatus(warning: nil, speechMonitoringUnavailable: false, adjustment: .disabledBySetting))
        try await waitUntil { state.micInputStatus?.warning == .low }
        #expect(state.micInputStatus == MicInputStatus(warning: .low, speechMonitoringUnavailable: false, adjustment: .disabledBySetting))
        try await waitUntil { await vad.deliveredBatches == batches.count }
        #expect(state.micInputStatus == MicInputStatus(warning: nil, speechMonitoringUnavailable: false, adjustment: .disabledBySetting))
        await state.stopRecording()
        #expect(engine.volumeFactoryCalls == 0)
        #expect(state.micInputStatus == nil)
    }

    @Test("An automatic raise is restored on stop, but a manual slider change pauses writes and is kept", arguments: [false, true])
    func manualChangeWinsOverRestore(userMovesSlider: Bool) async throws {
        let (root, paths) = temporaryRecordingPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = InputFreeMicCaptureEngine(root: root)
        let vad = ScriptedLiveVAD(batches: speechBatches(seconds: 0..<4, dBFS: -40)) { [clock = engine.clock] index in
            clock.set(seconds: InputFreeMicCaptureEngine.clockOrigin + Double(index + 1))
        }
        let state = makeState(paths: paths, engine: engine, defaults: defaults) { _, _, _, _ in vad }

        await state.startRecording()
        try await waitUntil { engine.volume.writes.count == 1 }
        #expect(scalars(engine.volume.writes) ≈ [[0.55]])
        #expect(state.micInputStatus?.adjustment == .active)

        if userMovesSlider {
            engine.volume.userMovesSlider(to: 0.3)
            #expect(state.micInputStatus?.adjustment == .pausedByExternalChange)
            await vad.append(speechBatches(seconds: 4..<12, dBFS: -40))
            try await waitUntil { await vad.deliveredBatches == 12 }
            #expect(await vad.deliveredBatches == 12)
            #expect(engine.volume.writes.count == 1)
            #expect(state.micInputStatus == MicInputStatus(warning: .low, speechMonitoringUnavailable: false, adjustment: .pausedByExternalChange))
        }

        await state.stopRecording()
        #expect(state.micInputStatus == nil)
        if userMovesSlider {
            #expect(engine.volume.writes.count == 1)
            #expect(engine.volume.values[0] == 0.3)
        } else {
            #expect(scalars(engine.volume.writes) ≈ [[0.55], [0.5]])
            #expect(engine.volume.values[0] == 0.5)
        }
        #expect(engine.volumeFactoryCalls == 1)
    }
}
