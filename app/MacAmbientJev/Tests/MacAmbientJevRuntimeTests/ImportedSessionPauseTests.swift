import AVFoundation
import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevPipeline
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private actor PausedImportVAD: FinalTranscriptVADSegmenter {
    nonisolated let provenance = RunProvenance(engine: "fake-vad", model: nil, version: "test", configuration: [:])
    private(set) var calls = 0

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        calls += 1
        return [
            SegmentReference(segmentationRunID: runID, segmentID: "speech_001", speechRanges: [0..<16_000]),
            SegmentReference(segmentationRunID: runID, segmentID: "speech_002", speechRanges: [16_000..<reader.info.committedFrames]),
        ]
    }
}

private actor PausedImportASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private(set) var calls = 0

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        calls += 1
        return ASRResult(text: calls == 1 ? "saved prefix" : "resumed tail", detectedLanguage: "ja")
    }

    func unload() async {}
}

private actor PauseAfterFirstImportSegment {
    private var segments = 0

    func check(at point: InferenceGatePoint) -> InferenceHoldReason? {
        if point == .segmentBoundary { segments += 1 }
        return segments == 1 ? nil : .thermal
    }
}

@Test
func thermalPauseIsSavedAsPausedRecoveredAndCompletedOnRerun() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths,
        sessionID: sessionID,
        source: .imported(originalFilename: "fixture.wav"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let processingDirectory = sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory)
    let samples = Array(repeating: Float(0.1), count: 32_000)
    let writer = try DurableAudioWriter(directory: processingDirectory, chunkDurationSeconds: 1, sessionURL: sessionURL)
    try await writer.append(samples: samples)
    let sourceURL = sessionURL.appending(path: "audio/original.caf")
    do {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: CanonicalAudio.sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
        try file.write(from: buffer)
    }

    let asr = PausedImportASR()
    let vad = PausedImportVAD()
    let pauseAfterFirstSegment = PauseAfterFirstImportSegment()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            finalTranscriptVAD: vad
        ),
        audioHandling: SessionProcessingAudio(timelineBuilder: AudioFileTimelineBuilder()),
        contentPriority: .disabled,
        sleep: { _ in }
    )
    let paused = await processor.processSession(
        sessionID: sessionID,
        pacingMode: .normal,
        shouldPause: { await pauseAfterFirstSegment.check(at: $0) },
        onPhase: { _ in },
        metadataPolicy: .reject,
        onStatus: { _ in },
        onUpdate: { _, _ in },
        onGenerationOpened: { _ in }
    )

    #expect(paused.disposition == .paused)
    #expect(paused.metrics?.initialPendingCount == 2)
    #expect(paused.retainedTranscript == .finalized)
    #expect(await asr.calls == 1)
    #expect(await vad.calls == 1)
    let pausedMetadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
    #expect(pausedMetadata.state == .paused)
    let reader = EventLogTranscriptReader()
    let pausedStore = try #require(try reader.read(eventsURL: SessionLayout(sessionURL: sessionURL).eventsURL, sessionID: sessionID))
    let pausedGenerationID = pausedStore.state.generation.id
    let pausedRuns = pausedStore.state.runs
    #expect(pausedMetadata.generationID == pausedGenerationID)
    #expect(pausedStore.state.segments == [
        SegmentReference(segmentationRunID: try #require(pausedRuns.segmentation), segmentID: "speech_001", speechRanges: [0..<16_000]),
        SegmentReference(segmentationRunID: try #require(pausedRuns.segmentation), segmentID: "speech_002", speechRanges: [16_000..<32_000]),
    ])
    let pausedRows = try TranscriptMaterializer(sampleRate: pausedStore.state.generation.sampleRate)
        .materialize(events: pausedStore.events, activeRuns: pausedStore.state.runs)
    #expect(pausedRows.map(\.text) == ["saved prefix"])
    let pausedPrefixSource = try #require(pausedRows.first?.source)

    let candidate = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).inspect(sessionID: sessionID).recovery
    #expect(candidate?.action == .finalize)
    guard let candidate,
          case .importedOriginal = try SessionLayout(sessionURL: sessionURL).audioSource(for: candidate.manifest) else {
        Issue.record("a paused import resumes from its original")
        return
    }

    let resumed = await processor.processSession(
        sessionID: sessionID,
        pacingMode: .normal,
        shouldPause: { _ in nil },
        onPhase: { _ in },
        metadataPolicy: .reject,
        onStatus: { _ in },
        onUpdate: { _, _ in },
        onGenerationOpened: { _ in }
    )

    #expect(resumed.disposition == .completed)
    #expect(await asr.calls == 2)
    #expect(await vad.calls == 1)
    let completedMetadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
    #expect(completedMetadata.state == .complete)
    #expect(completedMetadata.generationID == pausedGenerationID)
    let completed = try reader.validateCompletion(
        eventsURL: SessionLayout(sessionURL: sessionURL).eventsURL, sessionID: sessionID, frameCount: 32_000
    )
    #expect(completed.state.generation.id == pausedGenerationID)
    #expect(completed.state.runs.selectsSameRuns(as: pausedRuns))
    #expect(completed.state.segments == pausedStore.state.segments)
    #expect(completed.state.runs.segmentation != nil)
    #expect(completed.state.runs.asr != nil)
    #expect(completed.state.runs.clauseBoundary == nil)
    #expect(completed.state.runs.contentPriority == nil)
    let sources = try completed.events.compactMap { try $0.asrSource() }
    let rows = try TranscriptMaterializer(sampleRate: completed.state.generation.sampleRate)
        .materialize(events: completed.events, activeRuns: completed.state.runs)
    #expect(rows.map(\.text) == ["saved prefix", "resumed tail"])
    #expect(rows.first?.source == pausedPrefixSource)
    #expect(rows.map(\.clauseState) == [.boundaryPending, .boundaryPending])
    #expect(completed.pendingDecisions.boundarySegments == sources)
    #expect(completed.pendingDecisions.clauses.isEmpty)
    // Local finalization completes without decision runs; its boundary-pending text remains retryable.
    let pending = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot)
        .inspect(sessionID: sessionID).recovery
    #expect(pending?.action == .retryContentPriority(boundarySegments: sources, clauses: []))
    #expect(try SessionAudioStorageStore(layout: SessionLayout(sessionURL: sessionURL)).load()
        == .importedOriginal(TimelineAudioInfo(committedFrames: 32_000, gapEvents: [])))
}
