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
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        #expect(!input.samples.isEmpty)
        return ASRResult(text: "公開鍵暗号です", detectedLanguage: "ja")
    }

    func unload() async {}
}

private actor FailingPipelineASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        throw PipelineTestError.failed
    }

    func unload() async {}
}

private actor SequencedPipelineASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var count = 0

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        count += 1
        return ASRResult(text: "result-\(count)", detectedLanguage: "en")
    }

    func unload() async {}
}

private actor StalledPipelineASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var entered = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var transcriptionWaiter: CheckedContinuation<ASRResult, Never>?

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        await withCheckedContinuation { continuation in
            transcriptionWaiter = continuation
            entered = true
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitUntilTranscribing() async {
        if entered { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func finish() {
        transcriptionWaiter?.resume(returning: ASRResult(text: "処理済み"))
        transcriptionWaiter = nil
    }

    func unload() async {}
}

@Test
func durableAudioCommitsWhileASRIsStalled() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let processing = root.appending(path: "audio/processing")
    let processingWriter = try DurableAudioWriter(
        directory: processing, sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1
    )
    try await processingWriter.append(samples: Array(repeating: 0.25, count: 10))
    let checkpoint = try await processingWriter.finish()
    let captureWriter = try DurableAudioWriter(
        directory: root.appending(path: "audio/capture"),
        sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1
    )
    let asr = StalledPipelineASR()
    let coordinator = PipelineCoordinator(
        sessionID: UUID(), segmentationRunID: "seg", asrRunID: "asr",
        writer: try SessionWriter(sessionURL: root), asr: asr,
        loader: ASRAudioLoader(reader: ProcessingTimelineReader(
            directory: processing, checkpoint: checkpoint
        )),
        materializer: TranscriptMaterializer(sampleRate: 10),
        state: SessionProcessingState(captureState: .recording)
    )
    let task = Task {
        await coordinator.process(segments: [SegmentReference(
            segmentationRunID: "seg", segmentID: "s1", startFrame: 0, endFrame: 10
        )])
    }
    await asr.waitUntilTranscribing()
    try await captureWriter.append(samples: Array(repeating: 0.5, count: 20))
    #expect(await captureWriter.committedSnapshot().committedFrames == 20)
    await asr.finish()
    #expect(await task.value.materializedSegments.first?.text == "処理済み")
}

private actor PacingProbe {
    private var observations: [(Duration, Int)] = []

    func record(duration: Duration, log: String) {
        let completedCount = log.components(
            separatedBy: #""event_type":"asr.completed""#
        ).count - 1
        observations.append((duration, completedCount))
    }

    func snapshot() -> [(Duration, Int)] { observations }
}

@Test
func lowHeatRestsAfterPersistedCompletionOnlyBetweenSegments() async throws {
    for mode: ASRPacingMode in [.normal, .lowHeat] {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let audioDirectory = root.appending(path: "audio/processing", directoryHint: .isDirectory)
        let audioWriter = try DurableAudioWriter(
            directory: audioDirectory,
            sampleRate: 10,
            channelCount: 1,
            chunkDurationSeconds: 1
        )
        try await audioWriter.append(samples: Array(repeating: 0.25, count: 30))
        let checkpoint = try await audioWriter.finish()
        let probe = PacingProbe()
        let eventsURL = root.appending(path: "events.jsonl")
        let coordinator = PipelineCoordinator(
            sessionID: UUID(),
            segmentationRunID: "seg_paced",
            asrRunID: "asr_paced",
            writer: try SessionWriter(sessionURL: root),
            asr: SequencedPipelineASR(),
            loader: ASRAudioLoader(reader: ProcessingTimelineReader(
                directory: audioDirectory,
                checkpoint: checkpoint
            )),
            materializer: TranscriptMaterializer(sampleRate: 10),
            state: SessionProcessingState(captureState: .stopped),
            pacingMode: mode,
            sleep: { duration in
                let log = try String(contentsOf: eventsURL, encoding: .utf8)
                await probe.record(duration: duration, log: log)
            }
        )

        let result = await coordinator.process(segments: (0..<3).map { index in
            SegmentReference(
                segmentationRunID: "seg_paced",
                segmentID: "seg_\(index)",
                startFrame: Int64(index * 10),
                endFrame: Int64((index + 1) * 10)
            )
        })

        #expect(result.completedCount == 3)
        #expect(result.failedCount == 0)
        #expect(result.materializedSegments.map(\.text) == ["result-1", "result-2", "result-3"])
        let observations = await probe.snapshot()
        if mode == .lowHeat {
            #expect(observations.map(\.0) == [.seconds(2), .seconds(2)])
            #expect(observations.map(\.1) == [1, 2])
            #expect(result.metrics.pacingWaitCount == 2)
        } else {
            #expect(observations.isEmpty)
            #expect(result.metrics.pacingWaitCount == 0)
        }
        #expect(result.metrics.processedAudioSeconds == 3)
        #expect(result.metrics.asrRTF != nil)
    }
}

@Test
func criticalThermalPauseLeavesRemainingASRPending() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let audioDirectory = root.appending(path: "audio/processing")
    let writer = try DurableAudioWriter(
        directory: audioDirectory, sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1
    )
    try await writer.append(samples: Array(repeating: 0.25, count: 20))
    let checkpoint = try await writer.finish()
    let eventsURL = root.appending(path: "events.jsonl")
    let coordinator = PipelineCoordinator(
        sessionID: UUID(), segmentationRunID: "seg", asrRunID: "asr",
        writer: try SessionWriter(sessionURL: root), asr: SequencedPipelineASR(),
        loader: ASRAudioLoader(reader: ProcessingTimelineReader(
            directory: audioDirectory, checkpoint: checkpoint
        )),
        materializer: TranscriptMaterializer(sampleRate: 10),
        state: SessionProcessingState(captureState: .stopped),
        shouldPause: {
            let log = try? String(contentsOf: eventsURL, encoding: .utf8)
            return log?.contains(#""event_type":"asr.completed""#) == true
        }
    )
    let result = await coordinator.process(segments: [
        SegmentReference(segmentationRunID: "seg", segmentID: "first", startFrame: 0, endFrame: 10),
        SegmentReference(segmentationRunID: "seg", segmentID: "second", startFrame: 10, endFrame: 20)
    ])
    #expect(result.disposition == .paused)
    #expect(result.completedCount == 1)
    let log = try String(contentsOf: eventsURL, encoding: .utf8)
    #expect(log.components(separatedBy: #""event_type":"asr.completed""#).count - 1 == 1)
    #expect(!log.contains(#""event_type":"processing.run.completed""#))
    let recovered = try SessionRecovery.recoverJSONL(Data(log.utf8))
    let plan = try EventLogRecoveryAnalyzer().latestASRPlan(lines: recovered.lines)
    let pending = try #require(plan)
    #expect(pending.pendingSegments.map(\.segmentID) == ["second"])
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
    nonisolated let provenance = RunProvenance(engine: "fake-diarizer", model: nil, version: "test", configuration: [:])
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

private actor ScriptedPipelineASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var results: [String?]
    private let prepareFails: Bool

    init(results: [String?], prepareFails: Bool) {
        self.results = results
        self.prepareFails = prepareFails
    }

    func prepare() async throws {
        if prepareFails { throw PipelineTestError.failed }
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        guard let text = results.removeFirst() else { throw PipelineTestError.failed }
        return ASRResult(text: text)
    }

    func unload() async {}
}

private func asrEventPayloads(in root: URL) throws -> [String: [String: Any]] {
    let lines = try SessionRecovery.recoverJSONL(
        Data(contentsOf: root.appending(path: "events.jsonl"))
    ).lines
    var payloads: [String: [String: Any]] = [:]
    for line in lines {
        let event = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        guard let type = event["event_type"] as? String,
              type == "asr.completed" || type == "asr.failed",
              let segmentID = event["segment_id"] as? String else { continue }
        payloads[segmentID] = try #require(event["payload"] as? [String: Any])
    }
    return payloads
}

@Test
func asrEventsPersistRecognitionOutcomeAndFailureKind() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let processing = root.appending(path: "audio/processing")
    let audioWriter = try DurableAudioWriter(
        directory: processing, sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1
    )
    try await audioWriter.append(samples: Array(repeating: 0.25, count: 30))
    let checkpoint = try await audioWriter.finish()
    let coordinator = PipelineCoordinator(
        sessionID: UUID(), segmentationRunID: "seg", asrRunID: "asr",
        writer: try SessionWriter(sessionURL: root),
        asr: ScriptedPipelineASR(results: ["話した内容", " \n", nil], prepareFails: false),
        loader: ASRAudioLoader(reader: ProcessingTimelineReader(
            directory: processing, checkpoint: checkpoint
        )),
        materializer: TranscriptMaterializer(sampleRate: 10),
        state: SessionProcessingState(captureState: .stopped)
    )

    let result = await coordinator.process(segments: [
        SegmentReference(segmentationRunID: "seg", segmentID: "spoken", startFrame: 0, endFrame: 10),
        SegmentReference(segmentationRunID: "seg", segmentID: "silent", startFrame: 10, endFrame: 20),
        SegmentReference(segmentationRunID: "seg", segmentID: "failed", startFrame: 20, endFrame: 30),
        SegmentReference(segmentationRunID: "seg", segmentID: "unreadable", startFrame: 20, endFrame: 40),
    ])

    #expect(result.completedCount == 2)
    #expect(result.failedCount == 2)
    #expect(result.materializedSegments.map(\.segmentID) == ["spoken", "silent"])
    #expect(result.materializedSegments.map(\.hasRecognizedText) == [true, false])
    let payloads = try asrEventPayloads(in: root)
    #expect(payloads["spoken"]?["outcome"] as? String == "recognized")
    #expect(payloads["silent"]?["outcome"] as? String == "empty")
    #expect(payloads["failed"]?["kind"] as? String == "transcription_failed")
    #expect(payloads["unreadable"]?["kind"] as? String == "audio_unreadable")
}

@Test
func asrPreparationFailureIsPersistedAsEngineUnavailable() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let processing = root.appending(path: "audio/processing")
    let audioWriter = try DurableAudioWriter(
        directory: processing, sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1
    )
    try await audioWriter.append(samples: Array(repeating: 0.25, count: 10))
    let checkpoint = try await audioWriter.finish()
    let coordinator = PipelineCoordinator(
        sessionID: UUID(), segmentationRunID: "seg", asrRunID: "asr",
        writer: try SessionWriter(sessionURL: root),
        asr: ScriptedPipelineASR(results: [], prepareFails: true),
        loader: ASRAudioLoader(reader: ProcessingTimelineReader(
            directory: processing, checkpoint: checkpoint
        )),
        materializer: TranscriptMaterializer(sampleRate: 10),
        state: SessionProcessingState(captureState: .stopped)
    )

    let result = await coordinator.process(segments: [
        SegmentReference(segmentationRunID: "seg", segmentID: "s1", startFrame: 0, endFrame: 10)
    ])

    #expect(result.disposition == .failed)
    #expect(try asrEventPayloads(in: root)["s1"]?["kind"] as? String == "engine_unavailable")
}
