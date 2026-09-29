import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCore
import MacAmbientJevRuntime

@MainActor
final class FakeAppCaptureEngine: AppCaptureEngine {
    var onStart: ((UUID) async throws -> Void)?
    private var failureHandler: (@MainActor @Sendable (String) -> Void)?
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
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onWarning: @escaping @MainActor @Sendable (String) -> Void,
        onDropouts: @escaping @MainActor @Sendable (UInt64) -> Void,
        onSilenceChanged: @escaping @MainActor @Sendable (Bool) -> Void
    ) async throws {
        starts += 1
        events.append("start")
        failureHandler = onFailure
        try await onStart?(sessionID)
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

private actor FakeLiveVAD: LiveVADProcessing {
    nonisolated let segmentationRunID = "test-vad"
    private(set) var finishedCheckpoints: [AudioCheckpoint] = []

    func processAvailable(checkpoint: AudioCheckpoint) -> LiveVADProgress {
        LiveVADProgress(emittedSegments: [], totalSegmentCount: 0,
                        committedFrames: checkpoint.committedFrames)
    }

    func finish(checkpoint: AudioCheckpoint) -> LiveVADProgress {
        finishedCheckpoints.append(checkpoint)
        return LiveVADProgress(emittedSegments: [], totalSegmentCount: 1,
                               committedFrames: checkpoint.committedFrames)
    }
}

func temporaryRecordingPaths() -> (root: URL, paths: AppPaths) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    return (root, AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory)
    ))
}

func testCheckpoint() -> AudioCheckpoint {
    AudioCheckpoint(
        committedFrames: 16_000, sampleRate: 16_000, channelCount: 1,
        chunkFiles: ["audio-00000.caf"], chunkFrameCounts: [16_000]
    )
}

@MainActor
@Test("durable write failure stops recording and preserves committed audio")
func durableWriteFailureStopsCaptureWithoutDeletingAudio() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    var startedSessionID: UUID?
    let engine = FakeAppCaptureEngine()
    engine.onStart = { startedSessionID = $0 }
    engine.stopError = AudioCaptureEngineError.writerFailure("disk full")
    let state = AppState(
        paths: paths, captureEngine: engine, microphoneAccess: { true }, pausesProcessing: true
    )
    await state.startRecording()
    let sessionID = try #require(startedSessionID)
    let sessionURL = paths.sessionsRoot.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
    let directory = sessionURL.appending(path: "audio/processing", directoryHint: .isDirectory)
    let writer = try DurableAudioWriter(
        directory: directory, sampleRate: 16_000, channelCount: 1, chunkDurationSeconds: 1
    )
    try await writer.append(samples: Array(repeating: 0.25, count: 16_000))
    let checkpoint = await writer.committedSnapshot()

    engine.signalFailure("録音の保存に失敗しました: disk full")
    #expect(state.recordingPhase == .stopping)
    #expect(state.statusText == "録音の保存に失敗しました: disk full")
    for _ in 0..<1_000
        where state.recordingPhase != .idle
            || !state.savedSessions.contains(where: { $0.sessionID == sessionID }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(state.statusTone == .error)
    #expect(state.statusText == "録音の保存に失敗しました: disk full")
    #expect(engine.stopped == 1)
    #expect(state.pendingProcessing.isEmpty)

    #expect(state.recordingPhase == .idle)
    #expect(!state.isRecording)
    #expect(FileManager.default.fileExists(atPath: sessionURL.path))
    #expect(state.savedSessions.first(where: { $0.sessionID == sessionID })?.audioSource
        == .processingTimeline(checkpoint))
    #expect(try ProcessingTimelineReader(directory: directory, checkpoint: checkpoint)
        .readSamples(frameRange: 0..<16_000) == Array(repeating: 0.25, count: 16_000))
}

@MainActor
@Test("automatic capture failure and normal stop finish VAD with the stopped checkpoint")
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
        engine.stopResult = AudioCaptureStopResult(checkpoint: checkpoint, didOverflow: false)
        let state = AppState(
            paths: paths, captureEngine: engine, microphoneAccess: { true },
            pausesProcessing: true, liveVADSession: vad
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
            for _ in 0..<1_000
                where state.recordingPhase != .idle || state.pendingProcessing.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(state.statusTone == .error)
            #expect(state.statusText == "capture interrupted")
        }
        #expect(engine.events == ["start", "stop"])
        #expect(state.recordingPhase == .idle)
        #expect(await vad.finishedCheckpoints == [checkpoint])
        #expect(state.pendingProcessing.count == 1)
        guard state.pendingProcessing.count == 1,
              case .finishLive(let queuedID, let queuedCheckpoint) = state.pendingProcessing[0] else {
            Issue.record("stop did not enqueue live finalization")
            continue
        }
        #expect(queuedID == sessionID)
        #expect(queuedCheckpoint == checkpoint)
        #expect(state.processingState == .idle)
    }
}

@MainActor
@Test("failed startup removes a recovered gap-only checkpoint but keeps real captured audio")
func failedStartupRetainsOnlyCapturedAudio() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    for (hasGap, containsCapture) in [(true, false), (false, true), (true, true)] {
        let engine = FakeAppCaptureEngine()
        var startedSessionID: UUID?
        engine.onStart = { sessionID in
            startedSessionID = sessionID
            let directory = paths.sessionsRoot
                .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
                .appending(path: "audio/processing", directoryHint: .isDirectory)
            let writer = try DurableAudioWriter(
                directory: directory, sampleRate: 16_000, channelCount: 1,
                chunkDurationSeconds: 1
            )
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
        let state = AppState(
            paths: paths, captureEngine: engine, microphoneAccess: { true },
            pausesProcessing: true
        )
        await state.startRecording()
        let sessionID = try #require(startedSessionID)
        let sessionURL = paths.sessionsRoot.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: sessionURL.path) == containsCapture)
        #expect(engine.starts == 1)
        #expect(state.recordingPhase == .idle)
        #expect(state.statusTone == .error)
        #expect(state.statusText == "startup failed")
        #expect(state.savedSessions.contains(where: { $0.sessionID == sessionID }) == containsCapture)
        #expect(state.pendingProcessing.isEmpty)
    }
}
