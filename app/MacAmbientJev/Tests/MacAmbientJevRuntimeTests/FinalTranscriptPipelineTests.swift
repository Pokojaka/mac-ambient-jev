import struct FluidAudio.TimedSpeakerSegment
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

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
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
    func unload() async {}

    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] {
        await log.append("diarize")
        guard !shouldFail else { throw FakeFinalizationError.expected }
        return spans
    }
}

private struct PaddedWindowFinalDiarizer: DiarizationEngine {
    let provenance = RunProvenance(engine: "deterministic-fluid-diarizer", model: nil, version: "test", configuration: [:])
    let startFrame: Int64
    let endFrame: Int64

    func prepare() async throws {}
    func unload() async {}

    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] {
        let source = try CanonicalCAFAudioSource(fileURL: fileURL, sessionURL: sessionURL)
        return try FluidOfflineDiarizationEngine.mapSegments(
            [TimedSpeakerSegment(
                speakerId: "S1", embedding: [],
                startTimeSeconds: Float(Double(startFrame) / canonicalSampleRate),
                endTimeSeconds: Float(Double(endFrame) / canonicalSampleRate),
                qualityScore: 0.9
            )],
            sampleCount: source.sampleCount,
            config: .default
        )
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
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths,
        sessionID: sessionID,
        source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let processingDirectory = sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory)
    let writer = try DurableAudioWriter(
        directory: processingDirectory,
        chunkDurationSeconds: 1, sessionURL: sessionURL
    )
    try await writer.append(samples: samples ?? Array(repeating: 0.1, count: frames))
    return (paths, sessionURL, await writer.committedSnapshot())
}

private func savePreviousRuns(sessionURL: URL) async throws -> ActiveRuns {
    let runs = ActiveRuns(
        segmentation: "seg_previous",
        asr: "asr_previous",
        diarization: "diar_previous"
    )
    let sessionID = try SessionLayout(sessionURL: sessionURL).loadManifest().sessionID
    let writer = try SessionWriter(sessionURL: sessionURL)
    let provenance = RunProvenance(engine: "fixture", model: nil, version: "1", configuration: [:])
    for (stage, runID) in [
        (ProcessingStage.segmentation, "seg_previous"), (.asr, "asr_previous"),
        (.diarization, "diar_previous")
    ] {
        try await writer.append(EventDraft(
            eventType: "processing.run.started", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunStartedPayload(stage: stage, provenance: provenance)
        ))
        try await writer.append(EventDraft(
            eventType: "processing.run.completed", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunCompletedPayload(stage: stage, succeeded: true, completedCount: 0, failedCount: 0)
        ))
    }
    try ProcessingMetadataStore(sessionURL: sessionURL).save(ProcessingMetadata(
        finalizationAttempt: FinalizationAttempt(attemptID: "finalize_previous", state: .complete, failureReason: nil),
        activeRuns: runs,
        pendingClauseBoundarySegments: [],
        pendingContentPriorityClauses: []
    ))
    return runs
}

private func processFinal(
    _ processor: NativeSessionProcessor,
    sessionID: UUID,
    sessionURL: URL,
    metadataPolicy: UnreadableMetadataPolicy,
    statuses: FinalizationStatusRecorder,
    states: FinalizationStateRecorder,
    phases: FinalizationCallLog
) async throws -> SessionProcessingResult {
    return await processor.processSession(
        sessionID: sessionID,
        pacingMode: .normal,
        shouldPause: { false },
        onPhase: { await phases.append("phase:\($0.rawValue)") },
        metadataPolicy: metadataPolicy,
        onStatus: { await statuses.append($0) },
        onUpdate: { segments, state in await states.append((segments.map(\.text), state)) }
    )
}

private func eventObjects(_ sessionURL: URL) throws -> [[String: Any]] {
    try SessionRecovery.recoverJSONL(Data(contentsOf: sessionURL.appending(path: "events.jsonl")))
        .lines.compactMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

@Test
func finalTranscriptPipelineBoundsFluidPaddingBeforePublishing() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, _) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let asr = FakeFinalASR(log: log, values: ["末尾の発話"])
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            diarization: PaddedWindowFinalDiarizer(startFrame: 8_000, endFrame: 16_660),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
                log: log
            )
        ),
        contentPriority: .disabled
    )

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed)
    let metadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
    #expect(metadata.finalizationAttempt?.state == .complete)
    let rawEvents = try eventObjects(sessionURL)
    let speakerEvent = try #require(rawEvents.first { $0["event_type"] as? String == "speaker.span" })
    #expect(speakerEvent["source_start_frame"] as? Int64 == 8_000)
    #expect(speakerEvent["source_end_frame"] as? Int64 == 16_000)
    #expect(await asr.recordedAudioFrameCounts() == [16_000])
    let storage = try SessionAudioStorageStore(layout: SessionLayout(sessionURL: sessionURL)).load()
    guard case .recordingFLAC(let info) = storage else {
        Issue.record("Finalization did not compact the recording")
        return
    }
    #expect(info.committedFrames == 16_000)
}

@Test(arguments: [(Int64(16_000), Int64(16_660)), (Int64(16_001), Int64(16_660)), (Int64(8_000), Int64(160_001))])
func finalTranscriptPipelineRejectsFluidSpansOutsideFinalPadding(startFrame: Int64, endFrame: Int64) async throws {
    let sessionID = UUID()
    let (paths, sessionURL, _) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let previousRuns = try await savePreviousRuns(sessionURL: sessionURL)
    let log = FinalizationCallLog()
    let asr = FakeFinalASR(log: log, values: ["使われない"])
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            diarization: PaddedWindowFinalDiarizer(startFrame: startFrame, endFrame: endFrame),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
                log: log
            )
        ),
        contentPriority: .disabled
    )

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .failed)
    #expect(result.message?.contains(FinalTranscriptPipelineError.invalidSpeakerSpan(
        speakerID: "S1", startFrame: startFrame, endFrame: endFrame, totalFrames: 16_000
    ).localizedDescription) == true)
    let metadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
    #expect(metadata.finalizationAttempt?.state == .failed)
    #expect(metadata.activeRuns == previousRuns)
    #expect(await asr.recordedAudioFrameCounts() == [])
    #expect(try eventObjects(sessionURL).contains { $0["event_type"] as? String == "speaker.span" } == false)
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
        engines: SessionProcessingEngines(
            asr: asr,
            diarization: diarizer,
            finalTranscriptVAD: vad
        ),
        contentPriority: .disabled
    )
    let statuses = FinalizationStatusRecorder()

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: statuses, states: FinalizationStateRecorder(), phases: FinalizationCallLog()
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
    let rows = try TranscriptMaterializer(sampleRate: 16_000).materialize(
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
        engines: SessionProcessingEngines(
            asr: asr,
            diarization: diarizer,
            finalTranscriptVAD: vad
        ),
        contentPriority: .disabled
    )

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed)
    let loadedActiveRuns = try ProcessingMetadataStore(sessionURL: sessionURL).load()?.activeRuns
    let activeRuns = try #require(loadedActiveRuns)
    let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: sessionURL.appending(path: "events.jsonl")))
    let events = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: activeRuns)
    let rows = try TranscriptMaterializer(sampleRate: 16_000).materialize(events: events, activeRuns: activeRuns)
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
        engines: SessionProcessingEngines(
            asr: asr,
            diarization: diarizer,
            finalTranscriptVAD: vad
        ),
        contentPriority: .disabled
    )

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed)
    let loadedActiveRuns = try ProcessingMetadataStore(sessionURL: sessionURL).load()?.activeRuns
    let activeRuns = try #require(loadedActiveRuns)
    let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: sessionURL.appending(path: "events.jsonl")))
    let events = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: activeRuns)
    let rows = try TranscriptMaterializer(sampleRate: 16_000).materialize(events: events, activeRuns: activeRuns)
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
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: [" \n\t"]),
            diarization: FakeFinalDiarizer(
                spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)],
                log: log,
                shouldFail: false
            ),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "seg_empty", startFrame: 0, endFrame: 16_000)],
                log: log
            )
        ),
        contentPriority: .jev({
            jevFactoryCalls.recordCall()
            return nil
        }, usageCounter: JevUsageCounter())
    )

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed)
    #expect(jevFactoryCalls.count() == 0)
}

@Test(arguments: [true, false])
func finalTranscriptPipelineFailureLeavesPreviousActiveRunsUntouched(diarizationFails: Bool) async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let previousRuns = try await savePreviousRuns(sessionURL: sessionURL)
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
        engines: SessionProcessingEngines(
            asr: asr,
            diarization: diarizer,
            finalTranscriptVAD: vad
        ),
        contentPriority: .disabled
    )
    let statuses = FinalizationStatusRecorder()

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: statuses, states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .failed)
    #expect((result.metrics == nil) == diarizationFails)
    #expect(result.retainedTranscript == .finalized)
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
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["確定文"]),
            diarization: FakeFinalDiarizer(
                spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.8)],
                log: log,
                shouldFail: false
            ),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
                log: log
            )
        ),
        contentPriority: .disabled
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
        finalSegments: [],
        pacingMode: .normal,
        shouldPause: { false },
        onPhase: { _ in },
        onStatus: { await statuses.append($0) },
        onUpdate: { _, _ in }
    )

    #expect(finish.disposition == .completed)
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
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: []),
            diarization: FakeFinalDiarizer(spans: [], log: log, shouldFail: false),
            finalTranscriptVAD: FakeFinalVAD(segments: [], log: log)
        ),
        contentPriority: .disabled
    )
    let statuses = FinalizationStatusRecorder()

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: statuses, states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed)
    #expect(result.noSpeech)
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
        engines: SessionProcessingEngines(
            asr: asr,
            diarization: FakeFinalDiarizer(spans: [], log: log, shouldFail: false),
            finalTranscriptVAD: FakeFinalVAD(segments: [], log: log)
        ),
        contentPriority: .jev({
            jevFactoryCalls.recordCall()
            return nil
        }, usageCounter: JevUsageCounter())
    )
    let statuses = FinalizationStatusRecorder()

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: statuses, states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed)
    #expect(result.noSpeech)
    #expect(await asr.prepareCallCount == 0)
    #expect(jevFactoryCalls.count() == 0)
    #expect(await statuses.snapshot().last == "発話区間は検出されませんでした")
    let metadata = try ProcessingMetadataStore(sessionURL: sessionURL).load()
    #expect(metadata?.pendingClauseBoundarySegments == [])
    #expect(metadata?.pendingContentPriorityClauses == [])
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
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["表示する本文"]),
            diarization: FakeFinalDiarizer(
                spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)],
                log: log,
                shouldFail: false
            ),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "seg_000001", startFrame: 0, endFrame: 16_000)],
                log: log
            )
        ),
        contentPriority: .jev({ nil }, usageCounter: JevUsageCounter())
    )
    let states = FinalizationStateRecorder()
    let statuses = FinalizationStatusRecorder()

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: statuses, states: states, phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed)
    let observedStates = await states.snapshot()
    #expect(observedStates.contains { $0.texts == ["表示する本文"] && $0.state == .running })
    #expect(observedStates.last?.state == .complete)
    #expect(await statuses.snapshot().last == UserFacingStatus.jevDeferred.text)
    let loadedMetadata = try ProcessingMetadataStore(sessionURL: sessionURL).load()
    let metadata = try #require(loadedMetadata)
    #expect(metadata.activeRuns?.asr != nil)
    // The local transcript is published with every segment boundary-pending in the same write.
    #expect(metadata.pendingClauseBoundarySegments.map(\.segmentID) == ["seg_000001"])
    #expect(metadata.activeRuns?.clauseBoundary == nil)
    let rows = try readFinalRows(sessionURL: sessionURL)
    #expect(rows.map(\.clauseState) == [.boundaryPending])
    #expect(rows.map(\.displayText) == ["表示する本文"])
}

private struct RejectedKeyDecisionProvider: DecisionProvider {
    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        throw JevClientError.httpStatus(401)
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        throw JevClientError.httpStatus(401)
    }
}

@Test
func rejectedJevKeyAsksForAKeyFixInFinalizationAndRetry() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let counter = JevUsageCounter()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["一つ目", "二つ目"]),
            diarization: FakeFinalDiarizer(
                spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)],
                log: log,
                shouldFail: false
            ),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [
                    SegmentReference(segmentationRunID: "ignored", segmentID: "seg_000001", startFrame: 0, endFrame: 8_000),
                    SegmentReference(segmentationRunID: "ignored", segmentID: "seg_000002", startFrame: 8_000, endFrame: 16_000)
                ],
                log: log
            )
        ),
        contentPriority: .jev({
            JevDecisionCoordinator(provider: RejectedKeyDecisionProvider(), usageCounter: counter)
        }, usageCounter: counter)
    )
    let statuses = FinalizationStatusRecorder()

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: statuses, states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed)
    #expect(await statuses.snapshot().last == UserFacingStatus.jevAuthorizationRequired.text)
    let pending = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
        .pendingClauseBoundarySegments
    #expect(pending.map(\.segmentID) == ["seg_000001", "seg_000002"])

    let retryStatuses = FinalizationStatusRecorder()
    await processor.retryContentPrioritySession(
        sessionID: sessionID,
        boundarySegments: pending,
        clauses: [],
        onStatus: { await retryStatuses.append($0) },
        onUpdate: { _, _ in }
    )
    #expect(await retryStatuses.snapshot().last == UserFacingStatus.jevAuthorizationRequired.text)
}

@Test
func finalTranscriptPipelineForwardsPacingAndPauseToASR() async throws {
    let sourceSessionID = UUID()
    let (paths, sourceSessionURL, checkpoint) = try await finalizationFixture(sessionID: sourceSessionID)
    defer { try? FileManager.default.removeItem(at: sourceSessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let sessionID = UUID()
    let importURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .imported(originalFilename: "fixture.wav"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let originalURL = importURL.appending(path: "audio/original.caf")
    try ProcessingTimelineAudioExporter(framesPerBuffer: 48_000).export(
        reader: try ProcessingTimelineReader(
            directory: sourceSessionURL.appending(path: "audio/processing", directoryHint: .isDirectory),
            checkpoint: checkpoint, sessionURL: sourceSessionURL
        ),
        to: originalURL, sessionURL: importURL
    )
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["前半", "後半"]),
            diarization: FakeFinalDiarizer(
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
        ),
        contentPriority: .disabled
    )

    let result = await processor.processSession(
        sessionID: sessionID,
        pacingMode: .lowHeat,
        shouldPause: {
            await log.append("pause")
            return false
        },
        onPhase: { _ in },
        metadataPolicy: .reject,
        onStatus: { _ in },
        onUpdate: { _, _ in }
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
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["本文"]),
            diarization: FakeFinalDiarizer(
                spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)],
                log: log,
                shouldFail: false
            ),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
                log: log
            )
        ),
        contentPriority: .disabled
    )

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: log
    )

    #expect(result.disposition == .completed)
    #expect(await log.snapshot() == [
        "phase:preparing", "vad", "diarize", "phase:asr", "asr:0",
        "phase:postprocessing", "phase:complete"
    ])
}

private actor SegmentLineDroppingASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "log-mutating-asr", model: nil, version: "test", configuration: [:])
    let eventsURL: URL
    let log: FinalizationCallLog
    private var callIndex = 0

    init(eventsURL: URL, log: FinalizationCallLog) {
        self.eventsURL = eventsURL
        self.log = log
    }

    func prepare() async throws {}
    func unload() async {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        let index = callIndex
        callIndex += 1
        await log.append("asr:\(index)")
        let lines = try String(contentsOf: eventsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        let created = try lines.indices.compactMap { index -> (index: Int, runID: String)? in
            let object = try JSONSerialization.jsonObject(with: Data(lines[index].utf8)) as? [String: Any]
            guard object?["event_type"] as? String == "segment.created",
                  let runID = object?["segmentation_run_id"] as? String else { return nil }
            return (index, runID)
        }
        let currentRunID = created.last?.runID
        let createdIndices = created.filter { $0.runID == currentRunID }.map(\.index)
        if createdIndices.count == 2 {
            var kept = lines
            kept.remove(at: createdIndices[0])
            try (kept.joined(separator: "\n") + "\n").write(to: eventsURL, atomically: true, encoding: .utf8)
        }
        return ASRResult(text: index == 0 ? "前半" : "後半", detectedLanguage: "ja")
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
        audio: try SessionAudioReaders.open(
            try #require(try SessionLayout(sessionURL: sessionURL).audioSource(
                for: SessionLayout(sessionURL: sessionURL).loadManifest()
            )),
            layout: SessionLayout(sessionURL: sessionURL)
        ),
        asr: SegmentLineDroppingASR(eventsURL: sessionURL.appending(path: "events.jsonl"), log: log),
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
        )
    )

    await #expect {
        _ = try await pipeline.process(
            onStatus: { _ in }, pacingMode: .normal, shouldPause: { false }, onPhase: { _ in }
        )
    } throws: { error in
        guard let failure = error as? FinalTranscriptPipelineFailure else { return false }
        return failure.message.contains("の保存済み区間が一致しません") && failure.metrics != nil
    }
    #expect(await log.snapshot() == ["vad", "diarize", "asr:0", "asr:1"])
}


@Test
func persistedValidationFailureKeepsPublishedRunsAndDisplayAndReturnsASRMetrics() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["最初の確定"]),
            diarization: FakeFinalDiarizer(
                spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)],
                log: log,
                shouldFail: false
            ),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
                log: log
            )
        ),
        contentPriority: .disabled
    )
    let first = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )
    #expect(first.disposition == .completed)
    let publishedValue = try ProcessingMetadataStore(sessionURL: sessionURL).load()?.activeRuns
    let published = try #require(publishedValue)

    let failing = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: SegmentLineDroppingASR(eventsURL: sessionURL.appending(path: "events.jsonl"), log: log),
            diarization: FakeFinalDiarizer(
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
        ),
        contentPriority: .disabled
    )
    let states = FinalizationStateRecorder()
    let result = try await processFinal(
        failing, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: states, phases: FinalizationCallLog()
    )
    #expect(result.disposition == .failed)
    #expect(result.metrics?.initialPendingCount == 2)
    #expect(await states.snapshot().last?.texts == ["最初の確定"])
    #expect(try readFinalRows(sessionURL: sessionURL).map(\.text) == ["最初の確定"])
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.activeRuns == published)
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.finalizationAttempt?.state == .failed)
}

@Test
func failedFinalizationShowsThePreviousFinalizedTranscript() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let vad = FakeFinalVAD(
        segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
        log: log
    )
    let spans = [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)]
    let succeeding = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["最初の確定"]),
            diarization: FakeFinalDiarizer(spans: spans, log: log, shouldFail: false),
            finalTranscriptVAD: vad
        ),
        contentPriority: .disabled
    )
    _ = try await processFinal(
        succeeding, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )
    let published = try ProcessingMetadataStore(sessionURL: sessionURL).load()?.activeRuns

    let failing = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["失敗"], shouldFail: true),
            diarization: FakeFinalDiarizer(spans: spans, log: log, shouldFail: false),
            finalTranscriptVAD: vad
        ),
        contentPriority: .disabled
    )
    let states = FinalizationStateRecorder()
    let result = try await processFinal(
        failing, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: states, phases: FinalizationCallLog()
    )

    #expect(result.disposition == .failed)
    #expect(result.retainedTranscript == .finalized)
    #expect(result.metrics?.initialPendingCount == 1)
    #expect(result.message?.contains("認識できない 1区間") == true)
    let last = try #require(await states.snapshot().last)
    #expect(last.texts == ["最初の確定"])
    guard case .partialFailure = last.state else {
        Issue.record("a failed finalization reports a partial failure")
        return
    }
    let metadata = try ProcessingMetadataStore(sessionURL: sessionURL).load()
    #expect(metadata?.activeRuns == published)
    #expect(metadata?.finalizationAttempt?.state == .failed)
}

@Test
func recordingInterruptedBeforeStopIsFinalizedIntoNewRunsOnly() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let writer = try SessionWriter(sessionURL: sessionURL)
    for (stage, runID, provenance) in [
        (ProcessingStage.clauseBoundary, "boundary_live_interrupted", JevRunProvenance.boundary(mode: "live")),
        (.contentPriority, "priority_live_interrupted", JevRunProvenance.priority(mode: "live"))
    ] {
        try await writer.append(EventDraft(
            eventType: "processing.run.started",
            sessionID: sessionID,
            processingRunID: runID,
            payload: ProcessingRunStartedPayload(stage: stage, provenance: provenance)
        ))
    }
    try await writer.append(EventDraft(
        eventType: "segment.created",
        sessionID: sessionID,
        segmentationRunID: "seg_live",
        segmentID: "live_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 16_000,
        payload: EmptyPayload()
    ))
    try await writer.append(EventDraft(
        eventType: "asr.pending",
        sessionID: sessionID,
        processingRunID: "asr_live_interrupted",
        segmentationRunID: "seg_live",
        segmentID: "live_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 16_000,
        payload: EmptyPayload()
    ))
    let scanner = SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot)
    let candidate = try #require(try scanner.inspect(sessionID: sessionID).recovery)
    #expect(candidate.action == .finalize)
    guard case .recordedPCM(let recovered) = try SessionLayout(sessionURL: sessionURL)
        .audioSource(for: candidate.manifest) else {
        Issue.record("a recording recovers from its timeline")
        return
    }
    #expect(recovered == checkpoint)

    let log = FinalizationCallLog()
    let counter = JevUsageCounter()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["復旧した本文"]),
            diarization: FakeFinalDiarizer(
                spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)],
                log: log,
                shouldFail: false
            ),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
                log: log
            )
        ),
        contentPriority: .jev({
            JevDecisionCoordinator(provider: LiveCarryOverProvider(), usageCounter: counter)
        }, usageCounter: counter)
    )
    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed)
    let runsValue = try ProcessingMetadataStore(sessionURL: sessionURL).load()?.activeRuns
    let runs = try #require(runsValue)
    #expect(runs.segmentation?.hasPrefix("seg_final_") == true)
    #expect(runs.asr?.hasPrefix("asr_final_") == true)
    #expect(runs.diarization?.hasPrefix("diar_final_") == true)
    #expect(runs.clauseBoundary != "boundary_live_interrupted")
    #expect(runs.contentPriority != "priority_live_interrupted")
    #expect(try readFinalRows(sessionURL: sessionURL).map(\.text) == ["復旧した本文"])
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.pendingJevTargets == [])
    #expect(try scanner.inspect(sessionID: sessionID).recovery == nil)
}

@Test(arguments: [Int64(-1), Int64(16_001)])
func speakerSpanOutsideTheRecordingFailsExplicitly(boundary: Int64) async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let span = boundary < 0
        ? SpeakerSpan(speakerID: "S2", startFrame: boundary, endFrame: 8_000, confidence: 0.9)
        : SpeakerSpan(speakerID: "S2", startFrame: 8_000, endFrame: boundary, confidence: 0.9)
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["使われない"]),
            diarization: FakeFinalDiarizer(spans: [span], log: log, shouldFail: false),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
                log: log
            )
        ),
        contentPriority: .disabled
    )

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .failed)
    #expect(result.message?.contains(
        FinalTranscriptPipelineError.invalidSpeakerSpan(
            speakerID: "S2",
            startFrame: span.startFrame,
            endFrame: span.endFrame,
            totalFrames: 16_000
        ).localizedDescription
    ) == true)
    #expect(await log.snapshot() == ["vad", "diarize"])
}

@Test
func everyRunRecordsItsProvenanceOnceAndReprocessingRecordsNewRuns() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["一回目", "二回目"]),
            diarization: FakeFinalDiarizer(
                spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)],
                log: log,
                shouldFail: false
            ),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
                log: log
            )
        ),
        contentPriority: .disabled
    )
    var startedRunsByAttempt: [[String: String]] = []
    for _ in 0..<2 {
        let result = try await processFinal(
            processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
            statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
        )
        #expect(result.disposition == .completed)
        let runsValue = try ProcessingMetadataStore(sessionURL: sessionURL).load()?.activeRuns
        let runs = try #require(runsValue)
        let started = try eventObjects(sessionURL).filter { $0["event_type"] as? String == "processing.run.started" }
        var engines: [String: String] = [:]
        for (stage, runID) in [
            ("segmentation", runs.segmentation), ("diarization", runs.diarization), ("asr", runs.asr),
        ] {
            let ofRun = started.filter { $0["processing_run_id"] as? String == runID }
            #expect(ofRun.count == 1)
            let payload = ofRun.first?["payload"] as? [String: Any]
            #expect(payload?["stage"] as? String == stage)
            let provenance = payload?["provenance"] as? [String: Any]
            engines[stage] = provenance?["engine"] as? String
            #expect(provenance?["version"] as? String != nil)
        }
        #expect(engines == [
            "segmentation": "fake-vad",
            "diarization": "fake-diarizer",
            "asr": "fake-asr",
        ])
        startedRunsByAttempt.append(Dictionary(uniqueKeysWithValues: started.compactMap { object in
            (object["processing_run_id"] as? String).map { ($0, $0) }
        }))
    }
    #expect(startedRunsByAttempt[1].count == startedRunsByAttempt[0].count + 3)
}

@Test
func unreadableMetadataIsReplacedOnlyByExplicitReprocessing() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let metadataURL = sessionURL.appending(path: "processing_metadata.json")
    let broken = Data("{broken".utf8)
    try broken.write(to: metadataURL)
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["再処理"]),
            diarization: FakeFinalDiarizer(
                spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)],
                log: log,
                shouldFail: false
            ),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", startFrame: 0, endFrame: 16_000)],
                log: log
            )
        ),
        contentPriority: .disabled
    )

    let scan = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
    #expect(scan.candidates.isEmpty)
    #expect(scan.failures.map(\.sessionURL) == [sessionURL])

    let rejected = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )
    #expect(rejected.disposition == .failed)
    #expect(try Data(contentsOf: metadataURL) == broken)
    #expect(await log.snapshot().isEmpty)

    let replaced = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .replace,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )
    #expect(replaced.disposition == .completed)
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.finalizationAttempt?.state == .complete)
}

/// Accepts every candidate, never continues, and answers LOW for every clause.
private actor LiveCarryOverProvider: DecisionProvider {
    private var texts: [String] = []

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.9) }),
            continuationProbability: request.next.map { _ in 0.1 },
            metadata: try JevResponseMetadata(model: "counting-jev", inputTokens: 3, outputTokens: nil)
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        texts.append(contentsOf: targets.map(\.text))
        let decision = try ContentPriorityDecision(
            priority: .lowPriority, confidence: 0.95,
            probabilities: ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, decision) }),
            metadata: try JevResponseMetadata(model: "counting-jev", inputTokens: 3, outputTokens: nil)
        )
    }

    func sentTexts() -> [String] { texts }
}

private actor LiveFoldGate {
    private var folded = false
    private var waiter: CheckedContinuation<Void, Never>?

    func observe(_ segments: [MaterializedTranscriptSegment]) {
        guard segments.contains(where: { segment in
            segment.clauseSlices.contains { $0.priority == .lowPriority && !$0.displayRanges.isEmpty }
        }) else { return }
        folded = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !folded else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private func readFinalRows(sessionURL: URL) throws -> [MaterializedTranscriptSegment] {
    let runs = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.activeRuns)
    let lines = try SessionRecovery.recoverJSONL(Data(contentsOf: SessionLayout(sessionURL: sessionURL).eventsURL)).lines
    return try TranscriptMaterializer(sampleRate: 16_000).materialize(
        events: try EventLogTranscriptReader().events(lines: lines, activeRuns: runs), activeRuns: runs
    )
}

@Test(arguments: [false, true])
func finalizationClassifiesFinalClausesAndReusesOnlyByteIdenticalDurableLiveDecisions(changed: Bool) async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportURL.deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    // Final ASR keeps the raw filler; its nonblank clause is identical across new source segmentation.
    let liveText = "えー、同じ発話。"
    let finalText = changed ? "変更された発話。" : liveText
    let provider = LiveCarryOverProvider()
    let counter = JevUsageCounter()
    let decisions = JevDecisionCoordinator(provider: provider, usageCounter: counter)
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: [liveText, "えー", finalText]),
            diarization: FakeFinalDiarizer(
                spans: [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)],
                log: log, shouldFail: false
            ),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(
                    segmentationRunID: "ignored", segmentID: "final_row", startFrame: 0, endFrame: 16_000
                )],
                log: log
            )
        ),
        contentPriority: .jev({ decisions }, usageCounter: counter)
    )
    _ = try await processor.startLiveTranscription(
        sessionID: sessionID, segmentationRunID: "live_seg", sampleRate: checkpoint.sampleRate
    )
    let gate = LiveFoldGate()
    _ = try await processor.processLiveSegments(
        sessionID: sessionID,
        segments: [
            SegmentReference(segmentationRunID: "live_seg", segmentID: "live_row", startFrame: 0, endFrame: 8_000),
            // A filler-only successor: its clause has no text to classify, so no request depends on timing.
            SegmentReference(segmentationRunID: "live_seg", segmentID: "live_tail", startFrame: 8_000, endFrame: 16_000),
        ],
        checkpoint: checkpoint, onStatus: nil,
        onUpdate: { segments, _ in await gate.observe(segments) }
    )
    await gate.wait()
    let result = await processor.finishLiveTranscription(
        sessionID: sessionID, checkpoint: checkpoint, finalSegments: [], pacingMode: .normal,
        shouldPause: { false }, onPhase: { _ in }, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(result.disposition == .completed)
    #expect(await provider.sentTexts() == (changed ? ["同じ発話。", finalText] : ["同じ発話。"]))
    let runs = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.activeRuns)
    let materialized = try readFinalRows(sessionURL: sessionURL)
    #expect(materialized.map(\.text) == [finalText])
    #expect(materialized.map(\.displayText) == [changed ? finalText : "同じ発話。"])
    #expect(materialized.map(\.segmentID) == ["final_row"])
    #expect(materialized.map(\.clauseState) == [.classified])
    let slices = try #require(materialized.first).clauseSlices
    #expect(slices.filter { !$0.displayRanges.isEmpty }.map(\.priority) == [.lowPriority])
    if !changed {
        #expect(slices.contains { $0.displayRanges.isEmpty && $0.priority == nil && !$0.needsRetry })
    }
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.pendingJevTargets == [])
    let objects = try eventObjects(sessionURL)
    let assignment = try #require(objects.first {
        $0["event_type"] as? String == "content_priority.assigned"
            && $0["processing_run_id"] as? String == runs.contentPriority
    })
    let payload = try #require(assignment["payload"] as? [String: Any])
    let decision = try #require((payload["assignments"] as? [[String: Any]])?.first?["decision"] as? [String: Any])
    if changed {
        #expect(decision["kind"] as? String == "classified")
    } else {
        #expect(decision["kind"] as? String == "carried_over")
        #expect((decision["source_priority_run_id"] as? String)?.hasPrefix("priority_live_") == true)
        let sourceClause = try #require(decision["source_clause"] as? [String: Any])
        #expect((sourceClause["boundary_run_id"] as? String)?.hasPrefix("boundary_live_") == true)
        #expect(payload["request"] is NSNull)
    }
    let snapshot = await counter.snapshot()
    #expect(snapshot.pendingBoundarySegmentCount == 0)
    #expect(snapshot.priorityRequests.sendCount == (changed ? 2 : 1))
}

private struct PreparationRejectingDiarizer: DiarizationEngine {
    let provenance = RunProvenance(engine: "unavailable-diarizer", model: nil, version: "test", configuration: [:])
    let log: FinalizationCallLog

    func prepare() async throws {
        await log.append("prepare-diarization")
        throw FakeFinalizationError.expected
    }

    func unload() async {}

    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] {
        await log.append("diarize")
        throw FakeFinalizationError.expected
    }
}

@Test("Validated empty VAD completes without speech inference", arguments: [false, true])
func validatedEmptyVADCompletesWithoutSpeechInference(preparationFails: Bool) async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(
        samples: Array(repeating: 0, count: 16_000), sessionID: sessionID
    )
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportURL.deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let asr = PreparationFailingASR()
    let diarizer: any DiarizationEngine
    if preparationFails {
        diarizer = PreparationRejectingDiarizer(log: log)
    } else {
        diarizer = FakeFinalDiarizer(spans: [], log: log, shouldFail: true)
    }
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            diarization: diarizer,
            finalTranscriptVAD: FakeFinalVAD(segments: [], log: log)
        ),
        contentPriority: .disabled
    )
    let statuses = FinalizationStatusRecorder()
    var previousRuns: ActiveRuns?
    var storedFLAC: Data?
    for attempt in 1...2 {
        let result = try await processFinal(
            processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
            statuses: statuses, states: FinalizationStateRecorder(),
            phases: FinalizationCallLog()
        )
        #expect(result.disposition == .completed)
        #expect(result.noSpeech)
        #expect(result.metrics == .zero)
        #expect(await statuses.snapshot().last == "発話区間は検出されませんでした")
        let metadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
        #expect(metadata.finalizationAttempt?.state == .complete)
        #expect(metadata.pendingClauseBoundarySegments == [])
        #expect(metadata.pendingContentPriorityClauses == [])
        let runs = try #require(metadata.activeRuns)
        #expect(runs != previousRuns)
        previousRuns = runs
        let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: SessionLayout(sessionURL: sessionURL).eventsURL))
        let events = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: runs)
        #expect(try TranscriptMaterializer(sampleRate: checkpoint.sampleRate).materialize(
            events: events, activeRuns: runs
        ).isEmpty)
        #expect(try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).inspect(sessionID: sessionID).recovery == nil)
        let objects = try eventObjects(sessionURL)
        let stageRuns: [(ProcessingStage, String?, RunProvenance)] = [
            (.segmentation, runs.segmentation, FakeFinalVAD(segments: [], log: log).provenance),
            (.diarization, runs.diarization, diarizer.provenance),
            (.asr, runs.asr, asr.provenance)
        ]
        for (stage, run, expectedProvenance) in stageRuns {
            let runID = try #require(run)
            let starts = objects.filter {
                $0["event_type"] as? String == "processing.run.started"
                    && $0["processing_run_id"] as? String == runID
            }
            #expect(starts.count == 1)
            let startedPayload = try #require(starts.first?["payload"] as? [String: Any])
            #expect(startedPayload["stage"] as? String == stage.rawValue)
            let provenance = try #require(startedPayload["provenance"] as? [String: Any])
            #expect(try JSONDecoder().decode(RunProvenance.self, from: JSONSerialization.data(
                withJSONObject: provenance
            )) == expectedProvenance)
            let completions = objects.filter {
                $0["event_type"] as? String == "processing.run.completed"
                    && $0["processing_run_id"] as? String == runID
            }
            #expect(completions.count == 1)
            let payload = try #require(completions.first?["payload"] as? [String: Any])
            #expect(payload["stage"] as? String == stage.rawValue)
            #expect(payload["succeeded"] as? Bool == true)
            #expect(payload["completed_count"] as? Int == 0)
            #expect(payload["failed_count"] as? Int == 0)
        }
        #expect(objects.allSatisfy {
            ["processing.run.started", "processing.run.completed"].contains($0["event_type"] as? String)
        })
        #expect(await log.snapshot() == Array(repeating: "vad", count: attempt))
        #expect(await asr.prepareCallCount == 0)
        #expect(!FileManager.default.fileExists(atPath: SessionLayout(sessionURL: sessionURL)
            .derivedDirectory.appending(path: "diarization-input.caf").path))
        let flac = try Data(contentsOf: SessionLayout(sessionURL: sessionURL).recordingFLACURL)
        #expect(storedFLAC == nil || flac == storedFLAC)
        storedFLAC = flac
    }
}

private struct ThrowingFinalVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "failing-vad", model: nil, version: "test", configuration: [:])

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        throw FakeFinalizationError.expected
    }
}

@Test
func failedVADDoesNotPublishNoSpeechOrReplacePreviousRuns() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(
        samples: Array(repeating: 0, count: 16_000), sessionID: sessionID
    )
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportURL.deletingLastPathComponent()) }
    let previous = try await savePreviousRuns(sessionURL: sessionURL)
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: PreparationFailingASR(),
            diarization: PreparationRejectingDiarizer(log: log),
            finalTranscriptVAD: ThrowingFinalVAD()
        ),
        contentPriority: .disabled
    )
    let statuses = FinalizationStatusRecorder()
    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: statuses, states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )
    #expect(result.disposition == .failed)
    #expect(!result.noSpeech)
    #expect(result.metrics == nil)
    let metadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
    #expect(metadata.finalizationAttempt?.state == .failed)
    #expect(metadata.activeRuns == previous)
    #expect(await statuses.snapshot().last?.contains("確定処理に失敗") == true)
}

@Test func processorLookupFailuresDoNotPublishEmptyTranscriptsOrRunEngines() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportURL.deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: []),
            diarization: FakeFinalDiarizer(spans: [], log: log, shouldFail: false),
            finalTranscriptVAD: FakeFinalVAD(segments: [], log: log)
        ),
        contentPriority: .disabled
    )
    let absent = UUID()
    do {
        _ = try await processor.startLiveTranscription(sessionID: absent, segmentationRunID: "live", sampleRate: 16_000)
        Issue.record("missing identity must fail")
    } catch {
        #expect(error as? SessionDirectoryLookupError == .notFound(absent))
    }
    let duplicate = paths.sessionsRoot.appending(path: "malformed")
    try FileManager.default.copyItem(at: sessionURL, to: duplicate)
    let originalLog = try Data(contentsOf: SessionLayout(sessionURL: sessionURL).eventsURL)
    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )
    #expect(result.disposition == .failed)
    #expect(!result.noSpeech)
    #expect(result.metrics == nil)
    let imported = await processor.processSession(
        sessionID: absent,
        pacingMode: .normal, shouldPause: { false }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(imported.disposition == .failed)
    #expect(!imported.noSpeech)
    #expect(await log.snapshot().isEmpty)
    #expect(try Data(contentsOf: SessionLayout(sessionURL: sessionURL).eventsURL) == originalLog)
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load() == nil)
}
