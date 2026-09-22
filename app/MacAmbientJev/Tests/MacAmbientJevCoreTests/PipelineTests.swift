import Testing
@testable import MacAmbientJevCore

@Test
func recordingCanRemainActiveWhileProcessingIsBacklogged() async {
    let state = SessionProcessingState()

    await state.setCapture(.recording)
    await state.setProcessing(.backlogged)

    #expect(await state.captureState == .recording)
    #expect(await state.processingState == .backlogged)
}

@Test
func processingFailureDoesNotOverwriteCaptureState() async {
    let state = SessionProcessingState()

    await state.setCapture(.recording)
    await state.setProcessing(.partialFailure("ASR failed"))

    #expect(await state.captureState == .recording)
    #expect(await state.processingState == .partialFailure("ASR failed"))
}


private enum PipelineTestError: Error {
    case failed
}

private actor SuccessfulPipelineASR: ASREngine {
    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        #expect(!input.samples.isEmpty)
        return ASRResult(text: "公開鍵暗号です", detectedLanguage: "ja")
    }

    func unload() async {}
}

private actor FailingPipelineASR: ASREngine {
    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        throw PipelineTestError.failed
    }

    func unload() async {}
}

@Test
func pipelinePersistsPendingBeforeCompletedResultAndMaterializesText() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let audioDirectory = root.appending(path: "audio/processing", directoryHint: .isDirectory)
    let audioWriter = try DurableAudioWriter(
        directory: audioDirectory,
        sampleRate: 10,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
    try await audioWriter.append(samples: Array(repeating: 0.25, count: 10))
    let checkpoint = try await audioWriter.finish()

    let sessionWriter = try SessionWriter(sessionURL: root)
    let state = SessionProcessingState()
    let reader = ProcessingTimelineReader(
        directory: audioDirectory,
        checkpoint: checkpoint
    )
    let coordinator = PipelineCoordinator(
        sessionID: sessionID,
        segmentationRunID: "seg_run_01",
        asrRunID: "asr_run_01",
        writer: sessionWriter,
        asr: SuccessfulPipelineASR(),
        loader: ASRAudioLoader(reader: reader),
        materializer: TranscriptMaterializer(sampleRate: 10),
        state: state
    )

    let result = await coordinator.process(segments: [
        SegmentReference(
            segmentationRunID: "seg_run_01",
            segmentID: "seg_000001",
            startFrame: 0,
            endFrame: 10
        )
    ])

    #expect(result.completedCount == 1)
    #expect(result.failedCount == 0)
    #expect(result.materializedSegments.first?.text == "公開鍵暗号です")
    #expect(await state.processingState == .complete)

    let log = try String(contentsOf: root.appending(path: "events.jsonl"), encoding: .utf8)
    #expect(log.contains(#""event_type":"segment.created""#))
    #expect(log.contains(#""event_type":"asr.pending""#))
    #expect(log.contains(#""event_type":"asr.completed""#))
}

@Test
func pipelineKeepsFailedASRSeparateFromAudioAndSegmentEvents() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let audioDirectory = root.appending(path: "audio/processing", directoryHint: .isDirectory)
    let audioWriter = try DurableAudioWriter(
        directory: audioDirectory,
        sampleRate: 10,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
    try await audioWriter.append(samples: Array(repeating: 0.25, count: 10))
    let checkpoint = try await audioWriter.finish()

    let state = SessionProcessingState(captureState: .stopped)
    let coordinator = PipelineCoordinator(
        sessionID: UUID(),
        segmentationRunID: "seg_run_01",
        asrRunID: "asr_run_01",
        writer: try SessionWriter(sessionURL: root),
        asr: FailingPipelineASR(),
        loader: ASRAudioLoader(reader: ProcessingTimelineReader(
            directory: audioDirectory,
            checkpoint: checkpoint
        )),
        materializer: TranscriptMaterializer(sampleRate: 10),
        state: state
    )

    let result = await coordinator.process(segments: [
        SegmentReference(
            segmentationRunID: "seg_run_01",
            segmentID: "seg_000001",
            startFrame: 0,
            endFrame: 10
        )
    ])

    #expect(result.completedCount == 0)
    #expect(result.failedCount == 1)
    #expect(result.materializedSegments.isEmpty)
    #expect(await state.captureState == .stopped)

    let log = try String(contentsOf: root.appending(path: "events.jsonl"), encoding: .utf8)
    #expect(log.contains(#""event_type":"segment.created""#))
    #expect(log.contains(#""event_type":"asr.failed""#))
}
