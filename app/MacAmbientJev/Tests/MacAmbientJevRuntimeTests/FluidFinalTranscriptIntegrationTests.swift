import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevPipeline
import MacAmbientJevAppleSupport
@testable import MacAmbientJevRuntime
import struct FluidAudio.TimedSpeakerSegment

private actor FinalizationCallLog {
    private var values: [String] = []

    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
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
        audioHandling: MacSessionProcessingAudio(),
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
        audioHandling: MacSessionProcessingAudio(),
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
                segments: [
                    SegmentReference(segmentationRunID: "ignored", segmentID: "vad_1", startFrame: 0, endFrame: 8_000),
                    SegmentReference(segmentationRunID: "ignored", segmentID: "vad_2", startFrame: 8_000, endFrame: 16_000)
                ],
                log: log
            )
        ),
        audioHandling: MacSessionProcessingAudio(),
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
