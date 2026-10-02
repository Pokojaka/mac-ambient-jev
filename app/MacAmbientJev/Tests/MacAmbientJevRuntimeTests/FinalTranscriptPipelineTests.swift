import Foundation
import MacAmbientJevAppleSupport
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private actor FinalizationCallLog {
    private var values: [String] = []

    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private final class SynchronousCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func recordCall() {
        lock.lock()
        callCount += 1
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

private actor FinalizationStatusRecorder {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor FinalizationStateRecorder {
    struct Entry: Sendable {
        let texts: [String]
        let state: ProcessingState
    }

    private var values: [Entry] = []

    func append(_ value: ([String], ProcessingState)) {
        values.append(Entry(texts: value.0, state: value.1))
    }

    func snapshot() -> [Entry] { values }
}

private struct FakeFinalVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "fake-vad", model: nil, version: "test", configuration: [:])
    let segments: [SegmentReference]
    let log: FinalizationCallLog

    func segment(reader: ProcessingTimelineReader, runID: String) async throws -> [SegmentReference] {
        await log.append("vad")
        return segments.map {
            SegmentReference(
                segmentationRunID: runID,
                segmentID: $0.segmentID,
                startFrame: $0.startFrame,
                endFrame: $0.endFrame
            )
        }
    }
}

private struct FakeFinalDiarizer: DiarizationEngine {
    let provenance = RunProvenance(engine: "fake-diarizer", model: nil, version: "test", configuration: [:])
    let spans: [SpeakerSpan]
    let log: FinalizationCallLog
    let shouldFail: Bool

    func prepare() async throws {}

    func diarize(fileURL: URL, canonicalSampleRate: Double) async throws -> [SpeakerSpan] {
        await log.append("diarize")
        guard !shouldFail else { throw FakeFinalizationError.expected }
        return spans
    }
}

private actor FakeFinalASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private let log: FinalizationCallLog
    private let values: [String]
    private let shouldFail: Bool
    private var callIndex = 0
    private var audioFrameCounts: [Int] = []

    init(log: FinalizationCallLog, values: [String], shouldFail: Bool = false) {
        self.log = log
        self.values = values
        self.shouldFail = shouldFail
    }

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        let index = callIndex
        callIndex += 1
        audioFrameCounts.append(input.samples.count)
        await log.append("asr:\(index)")
        guard !shouldFail else { throw FakeFinalizationError.expected }
        return ASRResult(text: values[index], detectedLanguage: "ja")
    }

    func unload() async {}

    func recordedAudioFrameCounts() -> [Int] { audioFrameCounts }
}

private enum FakeFinalizationError: Error {
    case expected
}

private actor PreparationFailingASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private(set) var prepareCallCount = 0

    func prepare() async throws {
        prepareCallCount += 1
        throw FakeFinalizationError.expected
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        throw FakeFinalizationError.expected
    }

    func unload() async {}
}

private func finalizationFixture(
    frames: Int = 16_000,
    samples: [Float]? = nil,
    sessionID: UUID = UUID()
) async throws -> (AppPaths, URL, AudioCheckpoint) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory)
    )
    let sessionURL = try SessionBootstrapper().createSession(
        paths: paths,
        sessionID: sessionID,
        source: .recording(.microphone)
    )
    let processingDirectory = sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory)
    let writer = try DurableAudioWriter(
        directory: processingDirectory,
        sampleRate: 16_000,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
    try await writer.append(samples: samples ?? Array(repeating: 0.1, count: frames))
    return (paths, sessionURL, await writer.committedSnapshot())
}

private func savePreviousRuns(sessionURL: URL) throws -> ActiveRuns {
    let runs = ActiveRuns(
        segmentation: "seg_previous",
        asr: "asr_previous",
        diarization: "diar_previous",
        scene: "scene_previous",
        scope: "scope_previous"
    )
    try ProcessingMetadataStore(sessionURL: sessionURL).save(ProcessingMetadata(
        timelineVersion: 1,
        vadVersion: "old-vad",
        vadConfigHash: "old-config",
        asrEngine: "old-asr",
        asrModel: "old-model",
        asrVersion: "old-version",
        diarizationVersion: "old-diarization",
        sceneAnalyzerVersion: 1,
        jevSchemaVersion: 1,
        policyVersion: 1,
        materializerSchemaVersion: 1,
        activeRuns: runs
    ))
    return runs
}

@Test
func finalTranscriptPipelineSplitsVADSegmentsAtSpeakerChangesBeforeASR() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let diarizer = FakeFinalDiarizer(
        spans: [
            SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 8_000, confidence: 0.9),
            SpeakerSpan(speakerID: "S2", startFrame: 8_000, endFrame: 16_000, confidence: 0.9)
        ],
        log: log,
        shouldFail: false
    )
    let asr = FakeFinalASR(log: log, values: ["前半", "後半"])
    let vad = FakeFinalVAD(
        segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
        log: log
    )
    let processor = NativeSessionProcessor(
        paths: paths,
        asr: asr,
        sessionsRoot: paths.sessionsRoot,
        diarizationEngine: diarizer,
        finalTranscriptVAD: vad
    )
    let statuses = FinalizationStatusRecorder()

    let result = await processor.processFinalTranscript(
        sessionID: sessionID,
        checkpoint: checkpoint,
        onStatus: { await statuses.append($0) }
    )

    #expect(result.disposition == .completed)
    #expect(await statuses.snapshot().last?.contains("完了しました") == true)
    #expect(await log.snapshot() == ["vad", "diarize", "asr:0", "asr:1"])
    let loadedMetadata = try ProcessingMetadataStore(sessionURL: sessionURL).load()
    let metadata = try #require(loadedMetadata)
    #expect(metadata.finalizationAttempt?.state == .complete)
    #expect(metadata.activeRuns?.segmentation != "seg_previous")
    #expect(metadata.activeRuns?.asr != "asr_previous")
    let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: sessionURL.appending(path: "events.jsonl")))
    let events = try EventLogTranscriptReader().events(
        lines: recovered.lines,
        activeRuns: try #require(metadata.activeRuns)
    )
    let rows = TranscriptMaterializer(sampleRate: 16_000).materialize(
        events: events,
        activeRuns: try #require(metadata.activeRuns)
    )
    #expect(rows.map(\.text) == ["前半", "後半"])
    #expect(rows.map(\.startMilliseconds) == [0, 500])
    #expect(rows.map(\.endMilliseconds) == [500, 1_000])
    #expect(rows.map { $0.speakers.map(\.id) } == [["S1"], ["S2"]])
    #expect(await asr.recordedAudioFrameCounts() == [8_000, 8_000])

    let rawEvents = try recovered.lines.compactMap { line -> [String: Any]? in
        try JSONSerialization.jsonObject(with: line) as? [String: Any]
    }
    let created = rawEvents.filter { $0["event_type"] as? String == "segment.created" }
    let segmentationCompletionIndex = try #require(rawEvents.firstIndex {
        $0["event_type"] as? String == "processing.run.completed"
            && ($0["payload"] as? [String: Any])?["stage"] as? String == ProcessingStage.segmentation.rawValue
    })
    #expect(created.count == 2)
    #expect(created.allSatisfy { ( $0["event_seq"] as? Int ?? Int.max) < (rawEvents[segmentationCompletionIndex]["event_seq"] as? Int ?? -1) })
    let completionPayload = rawEvents[segmentationCompletionIndex]["payload"] as? [String: Any]
    #expect(completionPayload?["completed_count"] as? Int == created.count)
    #expect(Set(created.compactMap { $0["segment_id"] as? String }) == Set(rows.map(\.segmentID)))
}

@Test
func finalTranscriptPipelinePassesOverlappingSpeakerSpansInOneASRCall() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let diarizer = FakeFinalDiarizer(
        spans: [
            SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 9_000, confidence: 0.8),
            SpeakerSpan(speakerID: "S2", startFrame: 7_000, endFrame: 16_000, confidence: 0.8)
        ],
        log: log,
        shouldFail: false
    )
    let asr = FakeFinalASR(log: log, values: ["短い相づち"])
    let vad = FakeFinalVAD(
        segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
        log: log
    )
    let processor = NativeSessionProcessor(
        paths: paths,
        asr: asr,
        diarizationEngine: diarizer,
        finalTranscriptVAD: vad
    )

    let result = await processor.processFinalTranscript(sessionID: sessionID, checkpoint: checkpoint)

    #expect(result.disposition == .completed)
    let loadedActiveRuns = try ProcessingMetadataStore(sessionURL: sessionURL).load()?.activeRuns
    let activeRuns = try #require(loadedActiveRuns)
    let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: sessionURL.appending(path: "events.jsonl")))
    let events = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: activeRuns)
    let rows = TranscriptMaterializer(sampleRate: 16_000).materialize(events: events, activeRuns: activeRuns)
    #expect(rows.map(\.text) == ["短い相づち"])
    #expect(await log.snapshot() == ["vad", "diarize", "asr:0"])
}

@Test
func finalTranscriptPipelineKeepsShortSpeakerSpanAudioInUnsplitASRChunk() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let diarizer = FakeFinalDiarizer(
        spans: [
            SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 7_000, confidence: 0.8),
            SpeakerSpan(speakerID: "S2", startFrame: 7_000, endFrame: 7_100, confidence: 0.8),
            SpeakerSpan(speakerID: "S3", startFrame: 7_100, endFrame: 16_000, confidence: 0.8)
        ],
        log: log,
        shouldFail: false
    )
    let asr = FakeFinalASR(log: log, values: ["短い話者区間を含む音声"])
    let vad = FakeFinalVAD(
        segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
        log: log
    )
    let processor = NativeSessionProcessor(
        paths: paths,
        asr: asr,
        diarizationEngine: diarizer,
        finalTranscriptVAD: vad
    )

    let result = await processor.processFinalTranscript(sessionID: sessionID, checkpoint: checkpoint)

    #expect(result.disposition == .completed)
    let loadedActiveRuns = try ProcessingMetadataStore(sessionURL: sessionURL).load()?.activeRuns
    let activeRuns = try #require(loadedActiveRuns)
    let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: sessionURL.appending(path: "events.jsonl")))
    let events = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: activeRuns)
    let rows = TranscriptMaterializer(sampleRate: 16_000).materialize(events: events, activeRuns: activeRuns)
    #expect(rows.map(\.text) == ["短い話者区間を含む音声"])
    #expect(rows.map(\.startMilliseconds) == [0])
    #expect(rows.map(\.endMilliseconds) == [1_000])
    #expect(await asr.recordedAudioFrameCounts() == [16_000])
    #expect(await log.snapshot() == ["vad", "diarize", "asr:0"])
}

@Test
func jevSkipsWhitespaceOnlyFinalTranscript() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let jevFactoryCalls = SynchronousCallRecorder()
    let processor = NativeSessionProcessor(
        paths: paths,
        allowExternalJev: true,
        asr: FakeFinalASR(log: log, values: [" \n\t"]),
        diarizationEngine: FakeFinalDiarizer(
            spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)],
            log: log,
            shouldFail: false
        ),
        finalTranscriptVAD: FakeFinalVAD(
            segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "seg_empty", startFrame: 0, endFrame: 16_000)],
            log: log
        ),
        jevDecisionCoordinatorFactory: {
            jevFactoryCalls.recordCall()
            return nil
        }
    )

    let result = await processor.processFinalTranscript(
        sessionID: sessionID,
        checkpoint: checkpoint
    )

    #expect(result.disposition == .completed)
    #expect(jevFactoryCalls.count() == 0)
}

@Test(arguments: [true, false])
func finalTranscriptPipelineFailureLeavesPreviousActiveRunsUntouched(diarizationFails: Bool) async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let previousRuns = try savePreviousRuns(sessionURL: sessionURL)
    let log = FinalizationCallLog()
    let diarizer = FakeFinalDiarizer(
        spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.8)],
        log: log,
        shouldFail: diarizationFails
    )
    let asr = FakeFinalASR(log: log, values: ["text"], shouldFail: !diarizationFails)
    let vad = FakeFinalVAD(
        segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
        log: log
    )
    let processor = NativeSessionProcessor(
        paths: paths,
        asr: asr,
        diarizationEngine: diarizer,
        finalTranscriptVAD: vad
    )
    let statuses = FinalizationStatusRecorder()

    let result = await processor.processFinalTranscript(
        sessionID: sessionID,
        checkpoint: checkpoint,
        onStatus: { await statuses.append($0) }
    )

    #expect(result.disposition == .failed)
    #expect(await statuses.snapshot().last?.contains("確定処理に失敗") == true)
    let failedMetadata = try ProcessingMetadataStore(sessionURL: sessionURL).load()
    #expect(failedMetadata?.activeRuns == previousRuns)
    #expect(failedMetadata?.finalizationAttempt?.state == .failed)
}

@Test
func finishLiveTranscriptionEndsWithFinalizationStatus() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        asr: FakeFinalASR(log: log, values: ["確定文"]),
        diarizationEngine: FakeFinalDiarizer(
            spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.8)],
            log: log,
            shouldFail: false
        ),
        finalTranscriptVAD: FakeFinalVAD(
            segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
            log: log
        )
    )
    _ = try await processor.startLiveTranscription(
        sessionID: sessionID,
        segmentationRunID: "live-seg",
        sampleRate: checkpoint.sampleRate
    )
    let statuses = FinalizationStatusRecorder()

    let finish = await processor.finishLiveTranscription(
        sessionID: sessionID,
        checkpoint: checkpoint,
        onStatus: { await statuses.append($0) }
    )

    #expect(finish == .completed)
    #expect(await statuses.snapshot().last?.contains("完了しました") == true)
}

@Test
func finalTranscriptPipelineReportsNoSpeechAsTerminalStatus() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        asr: FakeFinalASR(log: log, values: []),
        diarizationEngine: FakeFinalDiarizer(spans: [], log: log, shouldFail: false),
        finalTranscriptVAD: FakeFinalVAD(segments: [], log: log)
    )
    let statuses = FinalizationStatusRecorder()

    let result = await processor.processFinalTranscript(
        sessionID: sessionID,
        checkpoint: checkpoint,
        onStatus: { await statuses.append($0) }
    )

    #expect(result.disposition == .completed)
    #expect(result.message == "noSpeech")
    #expect(await statuses.snapshot().last == "発話区間は検出されませんでした")
}

@Test
func noSpeechFinalizationSkipsASRPreparationAndCompletesZeroCountRun() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let asr = PreparationFailingASR()
    let log = FinalizationCallLog()
    let jevFactoryCalls = SynchronousCallRecorder()
    let processor = NativeSessionProcessor(
        paths: paths,
        allowExternalJev: true,
        asr: asr,
        diarizationEngine: FakeFinalDiarizer(spans: [], log: log, shouldFail: false),
        finalTranscriptVAD: FakeFinalVAD(segments: [], log: log),
        jevDecisionCoordinatorFactory: {
            jevFactoryCalls.recordCall()
            return nil
        }
    )
    let statuses = FinalizationStatusRecorder()

    let result = await processor.processFinalTranscript(
        sessionID: sessionID,
        checkpoint: checkpoint,
        onStatus: { await statuses.append($0) }
    )

    #expect(result.disposition == .completed)
    #expect(result.message == "noSpeech")
    #expect(await asr.prepareCallCount == 0)
    #expect(jevFactoryCalls.count() == 0)
    #expect(await statuses.snapshot().last == "発話区間は検出されませんでした")
    let metadata = try ProcessingMetadataStore(sessionURL: sessionURL).load()
    #expect(metadata?.pendingContentPrioritySegmentIDs == nil)
    let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: sessionURL.appending(path: "events.jsonl")))
    let completions = try recovered.lines.compactMap { line -> (String, Bool, Int, Int)? in
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["event_type"] as? String == "processing.run.completed",
              let runID = object["processing_run_id"] as? String,
              let payload = object["payload"] as? [String: Any],
              payload["stage"] as? String == ProcessingStage.asr.rawValue,
              let succeeded = payload["succeeded"] as? Bool,
              let completedCount = payload["completed_count"] as? Int,
              let failedCount = payload["failed_count"] as? Int else {
            return nil
        }
        return (runID, succeeded, completedCount, failedCount)
    }
    #expect(completions.count == 1)
    #expect(completions.first?.1 == true)
    #expect(completions.first?.2 == 0)
    #expect(completions.first?.3 == 0)
}

@Test
func deferredJevKeepsFinalizationRunningUntilLocalTranscriptIsVisible() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        allowExternalJev: true,
        asr: FakeFinalASR(log: log, values: ["表示する本文"]),
        diarizationEngine: FakeFinalDiarizer(
            spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)],
            log: log,
            shouldFail: false
        ),
        finalTranscriptVAD: FakeFinalVAD(
            segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "seg_000001", startFrame: 0, endFrame: 16_000)],
            log: log
        ),
        jevDecisionCoordinatorFactory: { nil }
    )
    let states = FinalizationStateRecorder()
    let statuses = FinalizationStatusRecorder()

    let result = await processor.processFinalTranscript(
        sessionID: sessionID,
        checkpoint: checkpoint,
        onStatus: { await statuses.append($0) },
        onUpdate: { segments, state in
            await states.append((segments.map(\.text), state))
        }
    )

    #expect(result.disposition == .completed)
    let observedStates = await states.snapshot()
    #expect(observedStates.contains { $0.texts == ["表示する本文"] && $0.state == .running })
    #expect(observedStates.last?.state == .complete)
    #expect(await statuses.snapshot().last == UserFacingStatus.jevDeferred.text)
    let loadedMetadata = try ProcessingMetadataStore(sessionURL: sessionURL).load()
    let metadata = try #require(loadedMetadata)
    #expect(metadata.activeRuns?.scope != nil)
    #expect(metadata.pendingContentPrioritySegmentIDs == ["seg_000001"])
}

@Test
func finalTranscriptPipelineForwardsPacingAndPauseToASR() async throws {
    let sourceSessionID = UUID()
    let (paths, sourceSessionURL, checkpoint) = try await finalizationFixture(sessionID: sourceSessionID)
    defer { try? FileManager.default.removeItem(at: sourceSessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let originalURL = sourceSessionURL.appending(path: "original.caf")
    try ProcessingTimelineAudioExporter().export(
        reader: ProcessingTimelineReader(
            directory: sourceSessionURL.appending(path: "audio/processing", directoryHint: .isDirectory),
            checkpoint: checkpoint
        ),
        to: originalURL
    )
    let sessionID = UUID()
    _ = try SessionBootstrapper().createSession(
        paths: paths, sessionID: sessionID, source: .imported(originalFilename: "fixture.wav")
    )
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        asr: FakeFinalASR(log: log, values: ["前半", "後半"]),
        diarizationEngine: FakeFinalDiarizer(
            spans: [
                SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 8_000, confidence: 0.9),
                SpeakerSpan(speakerID: "S2", startFrame: 8_000, endFrame: 16_000, confidence: 0.9)
            ],
            log: log,
            shouldFail: false
        ),
        finalTranscriptVAD: FakeFinalVAD(
            segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
            log: log
        )
    )

    let result = await processor.processImportedSession(
        sessionID: sessionID,
        originalURL: originalURL,
        pacingMode: .lowHeat,
        shouldPause: {
            await log.append("pause")
            return false
        }
    )

    #expect(result.disposition == .completed)
    #expect(result.metrics?.pacingWaitCount == 1)
    #expect(await log.snapshot() == ["vad", "diarize", "pause", "asr:0", "pause", "asr:1"])
}

@Test
func finalTranscriptPipelineEmitsASRPhaseBeforeTranscription() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        asr: FakeFinalASR(log: log, values: ["本文"]),
        diarizationEngine: FakeFinalDiarizer(
            spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)],
            log: log,
            shouldFail: false
        ),
        finalTranscriptVAD: FakeFinalVAD(
            segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
            log: log
        )
    )

    let result = await processor.processFinalTranscript(
        sessionID: sessionID,
        checkpoint: checkpoint,
        onPhase: { await log.append("phase:\($0.rawValue)") }
    )

    #expect(result.disposition == .completed)
    #expect(await log.snapshot() == [
        "phase:preparing", "vad", "diarize", "phase:asr", "asr:0",
        "phase:postprocessing", "phase:complete"
    ])
}

private struct SegmentLineDroppingEvidenceProvider: ProximityEvidenceProvider {
    let eventsURL: URL

    func evidenceSpans(
        startFrame: Int64,
        endFrame: Int64,
        speakerSpans: [SpeakerSpan]
    ) async throws -> [ProximityEvidenceSpan] {
        let lines = try String(contentsOf: eventsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        let createdIndices = try lines.indices.filter { index in
            let object = try JSONSerialization.jsonObject(with: Data(lines[index].utf8)) as? [String: Any]
            return object?["event_type"] as? String == "segment.created"
        }
        if createdIndices.count == 2 {
            var kept = lines
            kept.remove(at: createdIndices[0])
            try (kept.joined(separator: "\n") + "\n").write(to: eventsURL, atomically: true, encoding: .utf8)
        }
        return []
    }
}

@Test
func finalTranscriptPipelineRejectsPersistedLogMissingChildSegment() async throws {
    let sessionID = UUID()
    let (_, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let pipeline = FinalTranscriptPipeline(
        sessionID: sessionID,
        sessionURL: sessionURL,
        processingDirectory: sessionURL.appending(path: "audio/processing", directoryHint: .isDirectory),
        checkpoint: checkpoint,
        asr: FakeFinalASR(log: log, values: ["前半", "後半"]),
        diarization: FakeFinalDiarizer(
            spans: [
                SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 8_000, confidence: 0.9),
                SpeakerSpan(speakerID: "S2", startFrame: 8_000, endFrame: 16_000, confidence: 0.9)
            ],
            log: log,
            shouldFail: false
        ),
        vadSegmenter: FakeFinalVAD(
            segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
            log: log
        ),
        proximityEvidenceProvider: SegmentLineDroppingEvidenceProvider(
            eventsURL: sessionURL.appending(path: "events.jsonl")
        )
    )

    await #expect {
        _ = try await pipeline.process(onStatus: nil)
    } throws: { error in
        guard case .persistedSegmentsMismatch = error as? FinalTranscriptPipelineError else { return false }
        return true
    }
    #expect(await log.snapshot() == ["vad", "diarize", "asr:0", "asr:1"])
}
