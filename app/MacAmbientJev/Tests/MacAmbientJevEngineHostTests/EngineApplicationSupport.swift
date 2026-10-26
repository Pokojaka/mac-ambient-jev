import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
import MacAmbientJevTestSupport

// MARK: Fake engines

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func increment(_ name: String) {
        lock.lock()
        counts[name, default: 0] += 1
        lock.unlock()
    }

    func count(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[name, default: 0]
    }
}

final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

struct FakeASR: ASREngine {
    let provenance = RunProvenance(engine: "host-test-asr", model: nil, version: "test", configuration: [:])
    let calls: CallCounter

    func prepare() async throws {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        calls.increment("asr")
        return ASRResult(text: "日本語のテストです。", detectedLanguage: "ja")
    }
    func unload() async { calls.increment("asr.unload") }
}

struct FakeDiarizer: DiarizationEngine {
    let provenance = RunProvenance(engine: "host-test-diarizer", model: nil, version: "test", configuration: [:])
    let calls: CallCounter

    func prepare() async throws {}
    func unload() async { calls.increment("diarization.unload") }
    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] {
        calls.increment("diarization")
        return [SpeakerSpan(speakerID: "Speaker 1", startFrame: 0, endFrame: 16_000, confidence: 0.95)]
    }
}

struct FakeFinalVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "host-test-vad", model: nil, version: "test", configuration: [:])

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        guard reader.info.committedFrames > 0 else { return [] }
        return [SegmentReference(
            segmentationRunID: runID, segmentID: "final_segment_1", startFrame: 0, endFrame: reader.info.committedFrames
        )]
    }
}

/// Emits the whole recording as one speech segment when it finishes, like a VAD that closes its last segment on stop.
struct FakeLiveVAD: LiveVADProcessing {
    let segmentationRunID: String

    func processAvailable(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        LiveVADProgress(emittedSegments: [], totalSegmentCount: 0, committedFrames: checkpoint.committedFrames, micSpeechLevels: [])
    }

    func finish(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        guard checkpoint.committedFrames > 0 else {
            return LiveVADProgress(emittedSegments: [], totalSegmentCount: 0, committedFrames: 0, micSpeechLevels: [])
        }
        let segment = SegmentReference(
            segmentationRunID: segmentationRunID, segmentID: "live_segment_1", startFrame: 0, endFrame: checkpoint.committedFrames
        )
        return LiveVADProgress(
            emittedSegments: [segment], totalSegmentCount: 1, committedFrames: checkpoint.committedFrames, micSpeechLevels: []
        )
    }
}

struct FakeTimelineBuilder: ImportedAudioTimelineBuilding {
    func build(from sourceURL: URL, into processingDirectory: URL, sessionURL: URL) async throws -> AudioCheckpoint {
        let writer = try DurableAudioWriter(directory: processingDirectory, chunkDurationSeconds: 0.5, sessionURL: sessionURL)
        try await writer.append(samples: FakeCaptureSession.tone(seconds: 2))
        return try await writer.finish()
    }
}

final class FakeInferenceProvider: EngineInferenceProviding, @unchecked Sendable {
    let calls = CallCounter()
    let usageCounter = DecisionUsageCounter()
    private let failure = LockedBox<EngineAdapterError?>(nil)

    func failPrepare(with error: EngineAdapterError?) {
        failure.set(error)
    }

    func prepare(settings: EngineSettings, onProgress: @escaping @Sendable (EngineModelProgress) -> Void) async throws {
        calls.increment("prepare")
        onProgress(EngineModelProgress(stage: .validating, completed: 0, total: 1))
        if let failure = failure.get() { throw failure }
        onProgress(EngineModelProgress(stage: .loading, completed: 1, total: 1))
    }

    func decisionUsage() async throws -> DecisionUsageSnapshot {
        await usageCounter.snapshot()
    }

    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity {
        throw EngineAdapterError(
            code: .modelMissing,
            message: "テスト用の発話文モデルはインストールされていません",
            recoveryAction: .prepareModels,
            details: []
        )
    }

    func makeInference(settings: EngineSettings) throws -> EngineInference {
        EngineInference(
            engines: SessionProcessingEngines(asr: FakeASR(calls: calls), diarization: FakeDiarizer(calls: calls), finalTranscriptVAD: FakeFinalVAD()),
            contentPriority: .disabled,
            timelineBuilder: FakeTimelineBuilder(),
            makeLiveVADSession: { _, _, _, runID in FakeLiveVAD(segmentationRunID: runID) }
        )
    }
}

// MARK: Fake capture

private struct FakeCaptureClock: CaptureClock {
    func now() -> TimeInterval { 0 }
}

private final class FakeIdentityCanonicalAudioConverter: CanonicalAudioConverting, @unchecked Sendable {
    let sourceSampleRate = 16_000.0
    private let lock = NSLock()
    private var isFinished = false

    func convert(mono: [Float]) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { throw CanonicalAudioError.alreadyFinished }
        guard mono.allSatisfy({ $0.isFinite }) else { throw CanonicalAudioError.invalidSamples }
        return mono
    }

    func finish() throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { throw CanonicalAudioError.alreadyFinished }
        isFinished = true
        return []
    }
}

private enum FakeCaptureSessionError: Error {
    case producerFinished
    case producerBusy
}

private enum FakeCaptureFormat {
    static let sampleRate = 16_000.0
    static let packetFrameCapacity = 512
}

@MainActor
final class FakeCaptureSession: EngineCaptureSession {
    let writer: DurableAudioWriter
    private let ring: AudioBlockRing
    private let sink: TimestampedMonoSink
    private let drain: AudioCaptureDrain
    private var sourceCursor: Int64 = 0
    private var appendInProgress = false
    private(set) var isStopped = false

    init(sessionURL: URL) throws {
        writer = try DurableAudioWriter(
            directory: SessionLayout(sessionURL: sessionURL).processingDirectory, chunkDurationSeconds: 0.5, sessionURL: sessionURL
        )
        ring = AudioBlockRing(
            capacity: 2, blockFrameCapacity: FakeCaptureFormat.packetFrameCapacity, sampleRate: FakeCaptureFormat.sampleRate
        )
        sink = TimestampedMonoSink(
            ring: ring, frameCapacity: FakeCaptureFormat.packetFrameCapacity, clock: FakeCaptureClock(), meter: nil
        )
        drain = AudioCaptureDrain(ring: ring, writer: writer, converter: FakeIdentityCanonicalAudioConverter())
    }

    nonisolated static func tone(seconds: Double) -> [Float] {
        let frameCount = Int(FakeCaptureFormat.sampleRate * seconds)
        return (0..<frameCount).map { frame in
            let phase = Double(frame) * 2 * .pi * 440 / FakeCaptureFormat.sampleRate
            return Float(sin(phase)) * 0.2
        }
    }

    func appendSpeech(seconds: Double) async throws {
        guard !isStopped else { throw FakeCaptureSessionError.producerFinished }
        guard !appendInProgress else { throw FakeCaptureSessionError.producerBusy }
        appendInProgress = true
        defer { appendInProgress = false }

        let samples = Self.tone(seconds: seconds)
        var offset = 0
        while offset < samples.count {
            guard !isStopped else { throw FakeCaptureSessionError.producerFinished }
            let count = min(FakeCaptureFormat.packetFrameCapacity, samples.count - offset)
            let packet = Array(samples[offset..<(offset + count)])
            let startFrame = sourceCursor
            packet.withUnsafeBufferPointer { buffer in
                let channels = [UnsafePointer(buffer.baseAddress!)]
                let strides = [1]
                channels.withUnsafeBufferPointer { channelPointers in
                    strides.withUnsafeBufferPointer { stridePointers in
                        sink.receive(
                            channels: channelPointers.baseAddress!, strides: stridePointers.baseAddress!,
                            channelCount: 1, frameCount: count, startFrame: startFrame
                        )
                    }
                }
            }
            sourceCursor += Int64(count)
            try await drain.drainAvailable()
            offset += count
        }
    }

    func committedCheckpoint() async throws -> AudioCheckpoint {
        try await drain.committedSnapshot()
    }

    func stop() async throws -> AudioCaptureStopResult {
        // Stop the sole producer before publishing its final source-frame tail.
        isStopped = true
        ring.finish(tailFrame: sink.lastEndFrame)
        let checkpoint = try await drain.finish()
        let gaps = await drain.gapStatistics()
        return AudioCaptureStopResult(
            checkpoint: checkpoint, didOverflow: ring.overflowCount > 0, dropoutCount: ring.dropoutCount,
            gapCount: gaps.count, totalGapFrames: gaps.frames,
            sleepAssertionHeld: false, writerFailure: nil, systemAudioReleaseFailure: nil
        )
    }
}

@MainActor
final class FakeCapture: EngineCaptureProviding {
    private(set) var session: FakeCaptureSession?
    private(set) var callbacks: EngineCaptureCallbacks?
    var startError: EngineAdapterError?

    func devices(source: EngineSource) throws -> EngineDevicesResult {
        try EngineDevicesResult(
            source: source, devices: [try EngineDeviceInfo(id: "fake-endpoint", name: "Fake endpoint", isDefault: true)],
            defaultDeviceID: "fake-endpoint"
        )
    }

    func startCapture(
        sessionID: UUID, sessionURL: URL, source: EngineSource, device: EngineDevice, callbacks: EngineCaptureCallbacks
    ) async throws -> any EngineCaptureSession {
        if let startError { throw startError }
        let session = try FakeCaptureSession(sessionURL: sessionURL)
        self.session = session
        self.callbacks = callbacks
        return session
    }
}

// MARK: Harness

struct CommandFailure: Error, CustomStringConvertible {
    let failure: EngineFailure
    var description: String { "\(failure.code.rawValue): \(failure.message)" }
}

func engineTestPaths(root: URL) -> AppPaths {
    AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
}

func engineTestSettings(decisions: Bool = false, automaticExport: Bool = false, exportPath: String? = nil) throws -> EngineSettings {
    try EngineSettings(
        schemaVersion: 1, source: .microphone, device: .default, asrSize: .small, executionProvider: .cpu,
        threads: 1, lowHeat: false, decisionsEnabled: decisions, automaticExport: automaticExport, exportDestinationPath: exportPath
    )
}

/// The composed engine behind a real controller and transport, driven by NDJSON lines.
@MainActor
final class ApplicationHarness {
    let root: URL
    let paths: AppPaths
    let source = ScriptedSource()
    let sink = ScriptedSink()
    let capture = FakeCapture()
    let inference = FakeInferenceProvider()
    let transport: EngineTransport
    let app: EngineApplication
    let controller: EngineController
    private var runTask: Task<EngineExit, Never>?
    private var nextRequestID: UInt64 = 1

    init(root: URL) {
        self.root = root
        paths = engineTestPaths(root: root)
        transport = EngineTransport(source: source, sink: sink, limits: testLimits())
        app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: paths, logicalCPUCount: 4, sleep: { try await Task.sleep(for: $0) },
                shutdownPauseTimeout: .seconds(20)
            ),
            capture: capture,
            inference: inference,
            events: EngineEventEmitter(transport: transport)
        )
        controller = EngineController(transport: transport, handlers: app.handlers, admission: .production)
    }

    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "engine-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    func start() {
        app.start()
        runTask = Task { await controller.run() }
    }

    func exit() async -> EngineExit {
        await runTask!.value
    }

    var outputs: [EngineOutput] {
        get throws { try sink.outputs() }
    }

    /// Sends one command and waits for its terminal reply: the result, or the failure it was answered with.
    @discardableResult
    func call(_ command: String, payload: String = "{}") async throws -> EngineResult {
        let id = nextRequestID
        nextRequestID += 1
        source.feed(requestLine(id, command, payload: payload))
        let sink = self.sink
        try await sink.changes.wait("terminal reply to \(command)") {
            ((try? sink.outputs()) ?? []).contains { $0.requestID?.value == id && Self.isTerminal($0.event) }
        }
        for output in try outputs where output.requestID?.value == id {
            switch output.event {
            case let .completed(result): return result
            case let .error(failure): throw CommandFailure(failure: failure)
            default: continue
            }
        }
        preconditionFailure("terminal reply vanished")
    }

    nonisolated private static func isTerminal(_ event: EngineEvent) -> Bool {
        switch event {
        case .completed, .error: true
        default: false
        }
    }

    func failureCode(of command: String, payload: String = "{}") async throws -> EngineErrorCode {
        do {
            try await call(command, payload: payload)
        } catch let error as CommandFailure {
            return error.failure.code
        }
        throw TestTimeout(description: "\(command) did not fail")
    }

    func state() async throws -> EngineState {
        guard case let .stateGet(state) = try await call("state.get") else { preconditionFailure("not a state result") }
        return state
    }

    func hello() async throws {
        try await call("hello")
    }

    func replaceSettings(_ settings: EngineSettings, expectedRevision: UInt64?) async throws {
        let request = EngineSettingsReplacePayload(expectedRevision: try expectedRevision.map { try EngineID($0) }, settings: settings)
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        try await call("settings.replace", payload: payload)
    }

    func sessions() async throws -> [EngineSessionSummary] {
        guard case let .sessionList(list) = try await call("session.list", payload: "{\"cursor\":null,\"limit\":100}") else {
            preconditionFailure("not a list result")
        }
        return list.sessions
    }

    /// Re-reads `session.list` after every `state` event until the only session reaches `status`. A session
    /// changes status only together with the processing queue, which `state` carries.
    func waitForSession(status: EngineSessionStatus) async throws -> EngineSessionSummary {
        while true {
            let statesBefore = stateEventCount
            if let session = try await sessions().first, session.status == status { return session }
            try await sink.changes.wait("a session to reach \(status)") { stateEventCount > statesBefore }
        }
    }

    /// `state` events written so far.
    var stateEventCount: Int {
        ((try? outputs) ?? []).filter { if case .state = $0.event { true } else { false } }.count
    }

    func shutdown() async throws -> EngineExit {
        try await call("shutdown")
        return await exit()
    }
}
