import Foundation
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


@Test
func resumePendingASRDoesNotDuplicateRegisteredOrCompletedEvents() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let audioDirectory = root.appending(path: "audio/processing", directoryHint: .isDirectory)
    let audioWriter = try DurableAudioWriter(
        directory: audioDirectory,
        sampleRate: 10,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
    try await audioWriter.append(samples: Array(repeating: 0.25, count: 20))
    let checkpoint = try await audioWriter.finish()

    let sessionID = UUID()
    let segmentationRunID = "seg_resume"
    let asrRunID = "asr_resume"
    let writer = try SessionWriter(sessionURL: root)

    let firstCreated = try await writer.append(EventDraft(
        eventType: "segment.created",
        sessionID: sessionID,
        segmentationRunID: segmentationRunID,
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 10,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.pending",
        sessionID: sessionID,
        processingRunID: asrRunID,
        segmentationRunID: segmentationRunID,
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 10,
        payload: EmptyPayload()
    ))
    let secondCreated = try await writer.append(EventDraft(
        eventType: "segment.created",
        sessionID: sessionID,
        segmentationRunID: segmentationRunID,
        segmentID: "seg_000002",
        sourceStartFrame: 10,
        sourceEndFrame: 20,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.pending",
        sessionID: sessionID,
        processingRunID: asrRunID,
        segmentationRunID: segmentationRunID,
        segmentID: "seg_000002",
        sourceStartFrame: 10,
        sourceEndFrame: 20,
        payload: EmptyPayload()
    ))
    let firstCompleted = try await writer.append(EventDraft(
        eventType: "asr.completed",
        sessionID: sessionID,
        processingRunID: asrRunID,
        segmentationRunID: segmentationRunID,
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 10,
        payload: ASRCompletedEventPayload(
            text: "一つ目",
            detectedLanguage: "ja",
            engine: "qwen3-asr",
            model: "test"
        )
    ))

    let existingEvents: [TranscriptEvent] = [
        .segmentCreated(
            seq: firstCreated.eventSeq,
            segmentationRunID: segmentationRunID,
            segmentID: "seg_000001",
            startFrame: 0,
            endFrame: 10
        ),
        .segmentCreated(
            seq: secondCreated.eventSeq,
            segmentationRunID: segmentationRunID,
            segmentID: "seg_000002",
            startFrame: 10,
            endFrame: 20
        ),
        .asrCompleted(
            seq: firstCompleted.eventSeq,
            runID: asrRunID,
            segmentationRunID: segmentationRunID,
            segmentID: "seg_000001",
            text: "一つ目",
            detectedLanguage: "ja"
        )
    ]

    let state = SessionProcessingState(captureState: .stopped)
    let coordinator = PipelineCoordinator(
        sessionID: sessionID,
        segmentationRunID: segmentationRunID,
        asrRunID: asrRunID,
        writer: writer,
        asr: SuccessfulPipelineASR(),
        loader: ASRAudioLoader(reader: ProcessingTimelineReader(
            directory: audioDirectory,
            checkpoint: checkpoint
        )),
        materializer: TranscriptMaterializer(sampleRate: 10),
        state: state
    )

    let result = await coordinator.resumePendingASR(
        segments: [
            SegmentReference(
                segmentationRunID: segmentationRunID,
                segmentID: "seg_000002",
                startFrame: 10,
                endFrame: 20
            )
        ],
        existingEvents: existingEvents
    )

    #expect(result.completedCount == 2)
    #expect(result.failedCount == 0)
    #expect(result.materializedSegments.count == 2)

    let log = try String(
        contentsOf: root.appending(path: "events.jsonl"),
        encoding: .utf8
    )
    #expect(log.components(separatedBy: #""event_type":"segment.created""#).count - 1 == 2)
    #expect(log.components(separatedBy: #""event_type":"asr.pending""#).count - 1 == 2)
    #expect(log.components(separatedBy: #""event_type":"asr.completed""#).count - 1 == 2)
}


private actor SuccessfulDiarizationEngine: DiarizationEngine {
    func prepare() async throws {}

    func diarize(
        fileURL: URL,
        canonicalSampleRate: Double
    ) async throws -> [SpeakerSpan] {
        [
            SpeakerSpan(
                speakerID: "S1",
                startFrame: 0,
                endFrame: 50,
                confidence: 0.9
            ),
            SpeakerSpan(
                speakerID: "S2",
                startFrame: 50,
                endFrame: 100,
                confidence: 0.8
            )
        ]
    }
}

@Test
func diarizationCoordinatorAppendsSpeakerSpansAndMaterializesThem() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let writer = try SessionWriter(sessionURL: root)
    let existing: [TranscriptEvent] = [
        .segmentCreated(
            seq: 1,
            segmentationRunID: "seg_01",
            segmentID: "seg_000001",
            startFrame: 0,
            endFrame: 100
        ),
        .asrCompleted(
            seq: 2,
            runID: "asr_01",
            segmentationRunID: "seg_01",
            segmentID: "seg_000001",
            text: "話者が交代します",
            detectedLanguage: "ja"
        )
    ]

    let coordinator = DiarizationCoordinator(
        sessionID: sessionID,
        runID: "diar_01",
        writer: writer,
        engine: SuccessfulDiarizationEngine(),
        materializer: TranscriptMaterializer(sampleRate: 100)
    )

    let result = try await coordinator.process(
        fileURL: root.appending(path: "dummy.caf"),
        canonicalSampleRate: 100,
        existingEvents: existing,
        activeRuns: ActiveRuns(
            segmentation: "seg_01",
            asr: "asr_01",
            diarization: "diar_01"
        )
    )

    #expect(result.speakerSpans.count == 2)
    #expect(result.materializedSegments.first?.speakers.count == 2)

    let log = try String(
        contentsOf: root.appending(path: "events.jsonl"),
        encoding: .utf8
    )
    #expect(
        log.components(separatedBy: #""event_type":"speaker.span""#).count - 1 == 2
    )
    #expect(log.contains(#""stage":"diarization""#))
}
