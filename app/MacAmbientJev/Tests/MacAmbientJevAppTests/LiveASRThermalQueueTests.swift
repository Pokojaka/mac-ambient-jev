import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCapture
import MacAmbientJevCore
@testable import MacAmbientJevRuntime

@MainActor
@Test("critical heat holds the live queue without recognizing, and cooling resumes it")
func criticalHeatSuspendsLiveRecognitionUntilCooled() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let state = AppState(
        paths: paths, captureEngine: AudioCaptureEngine(paths: paths), microphoneAccess: { false },
        pausesProcessing: false, userDefaults: defaults, engines: .production(paths: paths), makeLiveVADSession: idleLiveVADFactory()
    )
    let sessionID = UUID()
    state.showNewSession(sessionID)
    state.markRecordingStarted(sessionID: sessionID)

    let pressure = ThermalPressureSource(.critical)
    state.readLiveThermalPressure = { pressure.value }
    let segments = [
        SegmentReference(segmentationRunID: "seg", segmentID: "seg_000001", startFrame: 0, endFrame: 8_000),
        SegmentReference(segmentationRunID: "seg", segmentID: "seg_000002", startFrame: 8_000, endFrame: 16_000)
    ]
    state.liveASRQueues[sessionID] = segments.map {
        AppState.LiveASRBatch(segments: [$0])
    }
    state.liveASRLatestCheckpoints[sessionID] = testCheckpoint()
    state.startLiveASRDrainIfIdle(sessionID: sessionID)

    try await Task.sleep(for: .milliseconds(1_500))
    let suspendedText = UserFacingStatus.liveTranscriptionThermalSuspended.text
    #expect(state.liveASRQueues[sessionID]?.count == 2)
    #expect(state.liveASRFailures[sessionID] == nil)
    #expect(state.processingStatusText == suspendedText)
    #expect(state.transcriptViewModel.statusText == suspendedText)

    // No live ASR session was started, so the first recognition attempt fails visibly.
    pressure.value = .fair
    let deadline = ContinuousClock.now + .seconds(5)
    while state.liveASRFailures[sessionID] == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(
        state.liveASRFailures[sessionID]
            == NativeSessionProcessorError.liveASRSessionNotStarted.localizedDescription
    )
    #expect(state.liveASRQueues[sessionID]?.isEmpty == true)
}

@MainActor
@Test("Cooling transcribes the entire live backlog once in order and stop releases its checkpoint")
func coolingDrainsLiveBacklogWithLatestCheckpointAndStopReleasesState() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let capture = FakeAppCaptureEngine()
    let asr = ThermalQueueASR()
    let state = AppState(
        paths: paths, captureEngine: capture, microphoneAccess: { false },
        pausesProcessing: false, userDefaults: defaults,
        engines: SessionProcessingEngines(
            asr: asr, diarization: UnusedThermalQueueDiarizer(),
            finalTranscriptVAD: EmptyThermalQueueFinalVAD()
        ),
        makeLiveVADSession: idleLiveVADFactory()
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .recording(.systemAudio),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let writer = try DurableAudioWriter(directory: sessionURL.appending(path: "audio/processing", directoryHint: .isDirectory), chunkDurationSeconds: 0.5, sessionURL: sessionURL)
    state.showNewSession(sessionID)
    state.markRecordingStarted(sessionID: sessionID)
    let pressure = ThermalPressureSource(.critical)
    state.readLiveThermalPressure = { pressure.value }
    _ = try await state.sessionProcessor.startLiveTranscription(
        sessionID: sessionID, segmentationRunID: "thermal", sampleRate: 16_000
    )
    let expectedInputs = [Float(0.125), 0.25, 0.375].map {
        ASRAudioInput(samples: Array(repeating: $0, count: 8_000), sampleRate: 16_000)
    }
    for (index, input) in expectedInputs.enumerated() {
        try await writer.append(samples: input.samples)
        let checkpoint = await writer.committedSnapshot()
        await state.enqueueLiveASR(
            sessionID: sessionID,
            segments: [SegmentReference(
                segmentationRunID: "thermal", segmentID: "row_\(index)",
                startFrame: Int64(index) * 8_000, endFrame: Int64(index + 1) * 8_000
            )],
            checkpoint: checkpoint
        )
    }
    let latest = try await writer.finish()
    let deadline = ContinuousClock.now + .seconds(5)
    while state.processingStatusText != UserFacingStatus.liveTranscriptionThermalSuspended.text,
          ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(state.processingStatusText == UserFacingStatus.liveTranscriptionThermalSuspended.text)
    #expect(await asr.inputs() == [])
    #expect(state.liveASRQueues[sessionID]?.flatMap(\.segments).map(\.segmentID)
        == ["row_0", "row_1", "row_2"])
    #expect(state.liveASRLatestCheckpoints == [sessionID: latest])

    pressure.value = .fair
    await state.waitForLiveASRDrain(sessionID: sessionID)
    #expect(await asr.inputs() == expectedInputs)
    #expect(state.liveASRFailures[sessionID] == nil)
    #expect(state.liveASRQueues[sessionID]?.isEmpty == true)
    #expect(state.liveASRLatestCheckpoints == [sessionID: latest])

    capture.stopResult = cleanStopResult(latest)
    await state.stopRecording()
    await state.processingTask?.value
    await state.modelPreparationTask?.value
    await state.idleReleaseTask?.value
    #expect(state.recordingPhase == .idle)
    #expect(state.liveASRQueues.isEmpty)
    #expect(state.liveASRLatestCheckpoints.isEmpty)
    #expect(state.liveASRTasks.isEmpty)
    #expect(await asr.inputs() == expectedInputs)
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

@MainActor
private final class ThermalPressureSource {
    var value: ThermalPressure
    init(_ value: ThermalPressure) { self.value = value }
}
