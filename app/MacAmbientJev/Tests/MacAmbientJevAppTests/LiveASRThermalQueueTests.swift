import Foundation
import Testing
@testable import MacAmbientJev
@testable import MacAmbientJevPipeline
import MacAmbientJevCapture
import MacAmbientJevCore
@testable import MacAmbientJevRuntime

@MainActor
@Test("Cooling transcribes the entire live backlog once in order and stop releases its checkpoint", .timeLimit(.minutes(1)))
func coolingDrainsLiveBacklogWithLatestCheckpointAndStopReleasesState() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let capture = FakeAppCaptureEngine()
    let expectedInputs = [Float(0.125), 0.25, 0.375].map {
        ASRAudioInput(samples: Array(repeating: $0, count: 8_000), sampleRate: 16_000)
    }
    capture.onStart = { sessionID in
        let sessionURL = try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: paths.sessionsRoot, sessionID: sessionID)
        let writer = try DurableAudioWriter(
            directory: SessionLayout(sessionURL: sessionURL).processingDirectory,
            chunkDurationSeconds: 0.5,
            sessionURL: sessionURL
        )
        for input in expectedInputs {
            try await writer.append(samples: input.samples)
        }
        let latest = try await writer.finish()
        capture.stopResult = cleanStopResult(latest)
    }
    let asr = ThermalQueueASR()
    let pressure = TestThermalMonitor(.critical)
    let liveVAD = ThermalQueueLiveVAD()
    let poll = LivePollSleep()
    let thermalRecheck = LivePollSleep()
    let state = AppState(
        paths: paths, captureEngine: capture, microphoneAccess: { true },
        pausesProcessing: false, userDefaults: defaults,
        engines: SessionProcessingEngines(
            asr: asr, diarization: UnusedThermalQueueDiarizer(),
            finalTranscriptVAD: EmptyThermalQueueFinalVAD()
        ),
        makeLiveVADSession: { _, _, _, _ in liveVAD },
        thermalMonitor: pressure,
        liveTranscriptionSleep: { duration in
            if duration == .milliseconds(LiveTranscriptionCadence.checkpointPollIntervalMilliseconds) {
                try await poll.sleep(duration)
            } else if duration == .milliseconds(LiveTranscriptionCadence.thermalRecheckIntervalMilliseconds) {
                try await thermalRecheck.sleep(duration)
            } else {
                throw LivePollWaitFailure(message: "Unexpected live transcription sleep duration: \(duration)")
            }
        }
    )
    // Injected thermal control must not register an observer that reads host pressure.
    #expect(state.thermalObserver == nil)
    await state.startupMaintenanceTask?.value
    try #require(!state.processingQueue.isMaintainingStorage)

    await state.startRecording()
    do {
        try #require(state.recordingPhase == .recording)
        let sessionID = try #require(state.recordingSessionID)
        let latest = try #require(capture.stopResult?.checkpoint)

        try await poll.advance()
        try await thermalRecheck.waitUntilSuspended()
        #expect(state.processingStatusText == UserFacingStatus.liveTranscriptionThermalSuspended.text)
        #expect(state.transcriptViewModel.statusText == UserFacingStatus.liveTranscriptionThermalSuspended.text)
        #expect(await asr.inputs() == [])
        #expect(state.liveTranscription.queuedSegments(sessionID: sessionID).map(\.segmentID)
            == ["row_0", "row_1", "row_2"])
        #expect(state.liveTranscription.latestCheckpoint(sessionID: sessionID) == latest)

        pressure.pressure = .fair
        try await thermalRecheck.advance()
        await state.waitForLiveASRDrain(sessionID: sessionID)
        #expect(await asr.inputs() == expectedInputs)
        #expect(state.liveTranscription.failure(sessionID: sessionID) == nil)
        #expect(!state.liveTranscription.hasQueued(sessionID: sessionID))
        #expect(state.liveTranscription.latestCheckpoint(sessionID: sessionID) == latest)

        await state.stopRecording()
        await state.processingCoordinator.waitUntilIdle()
        await state.modelPreparationTask?.value
        await state.idleReleaseTask?.value
        #expect(state.recordingPhase == .idle)
        #expect(state.liveCoordinator.isASRIdle)
        #expect(state.liveTranscription.latestCheckpoint(sessionID: sessionID) == nil)
        #expect(!state.liveCoordinator.isDraining(sessionID: sessionID))
        #expect(await asr.inputs() == expectedInputs)
    } catch {
        pressure.pressure = .fair
        await state.stopRecording()
        await state.processingCoordinator.waitUntilIdle()
        await state.modelPreparationTask?.value
        await state.idleReleaseTask?.value
        throw error
    }
}

private actor ThermalQueueLiveVAD: LiveVADProcessing {
    nonisolated let segmentationRunID = "thermal"
    private var emitted = false

    func processAvailable(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        guard !emitted else {
            return LiveVADProgress(
                emittedSegments: [], totalSegmentCount: 3,
                committedFrames: checkpoint.committedFrames, micSpeechLevels: []
            )
        }
        emitted = true
        let segments = (0..<3).map { index in
            SegmentReference(
                segmentationRunID: segmentationRunID,
                segmentID: "row_\(index)",
                startFrame: Int64(index) * 8_000,
                endFrame: Int64(index + 1) * 8_000
            )
        }
        return LiveVADProgress(
            emittedSegments: segments, totalSegmentCount: 3,
            committedFrames: checkpoint.committedFrames, micSpeechLevels: []
        )
    }

    func finish(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        LiveVADProgress(
            emittedSegments: [], totalSegmentCount: 3,
            committedFrames: checkpoint.committedFrames, micSpeechLevels: []
        )
    }
}

private actor ThermalQueueASR: ASREngine {
    nonisolated let provenance = RunProvenance(
        engine: "thermal-queue-asr", model: nil, version: "test", configuration: [:]
    )
    private var recordedInputs: [ASRAudioInput] = []
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        recordedInputs.append(input)
        // Empty text keeps this synthetic queue scenario independent of external classification.
        return ASRResult(text: "", detectedLanguage: "ja")
    }
    func inputs() -> [ASRAudioInput] { recordedInputs }
}

private struct EmptyThermalQueueFinalVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(
        engine: "thermal-queue-vad", model: nil, version: "test", configuration: [:]
    )
    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        []
    }
}

private struct UnusedThermalQueueDiarizer: DiarizationEngine {
    let provenance = RunProvenance(
        engine: "thermal-queue-diarizer", model: nil, version: "test", configuration: [:]
    )
    func prepare() async throws { throw UnexpectedDiarization.called }
    func unload() async {}
    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] {
        throw UnexpectedDiarization.called
    }
    private enum UnexpectedDiarization: Error { case called }
}
