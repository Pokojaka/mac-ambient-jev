import AVFoundation
import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevPipeline
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private struct PausedImportVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "fake-vad", model: nil, version: "test", configuration: [:])
    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        [SegmentReference(
            segmentationRunID: runID,
            segmentID: "spoken",
            startFrame: 0,
            endFrame: reader.info.committedFrames
        )]
    }
}

private actor PausedImportASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private(set) var calls = 0

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        calls += 1
        return ASRResult(text: "spoken words", detectedLanguage: "ja")
    }

    func unload() async {}
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
    let samples = Array(repeating: Float(0.1), count: 16_000)
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
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            finalTranscriptVAD: PausedImportVAD()
        ),
        audioHandling: SessionProcessingAudio(timelineBuilder: AudioFileTimelineBuilder()),
        contentPriority: .disabled,
        sleep: { _ in }
    )
    let paused = await processor.processSession(
        sessionID: sessionID,
        pacingMode: .normal,
        shouldPause: { .thermal },
        onPhase: { _ in },
        metadataPolicy: .reject,
        onStatus: { _ in },
        onUpdate: { _, _ in }
    )

    #expect(paused.disposition == .paused)
    #expect(paused.metrics?.initialPendingCount == 1)
    #expect(paused.retainedTranscript == .nothing)
    #expect(await asr.calls == 0)
    let pausedMetadata = try ProcessingMetadataStore(sessionURL: sessionURL).load()
    #expect(pausedMetadata?.activeRuns == nil)
    #expect(pausedMetadata?.finalizationAttempt?.state == .paused)

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
        shouldPause: { nil },
        onPhase: { _ in },
        metadataPolicy: .reject,
        onStatus: { _ in },
        onUpdate: { _, _ in }
    )

    #expect(resumed.disposition == .completed)
    #expect(await asr.calls == 1)
    let completed = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
    #expect(completed.finalizationAttempt?.state == .complete)
    let runs = try #require(completed.activeRuns)
    #expect(runs.segmentation != nil)
    #expect(runs.asr != nil)
    #expect(runs.clauseBoundary == nil)
    #expect(runs.contentPriority == nil)
    let recovered = try SessionRecovery.recoverJSONL(
        Data(contentsOf: SessionLayout(sessionURL: sessionURL).eventsURL)
    )
    let events = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: runs)
    let sources = try events.compactMap { try $0.asrSource() }
    let rows = try TranscriptMaterializer(sampleRate: CanonicalAudio.sampleRate)
        .materialize(events: events, activeRuns: runs)
    #expect(rows.map(\.text) == ["spoken words"])
    #expect(rows.map(\.clauseState) == [.boundaryPending])
    #expect(completed.pendingClauseBoundarySegments == sources)
    #expect(completed.pendingContentPriorityClauses.isEmpty)
    // Local finalization completes without decision runs; its boundary-pending text remains retryable.
    let pending = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot)
        .inspect(sessionID: sessionID).recovery
    #expect(pending?.action == .retryContentPriority(boundarySegments: sources, clauses: []))
    #expect(try SessionAudioStorageStore(layout: SessionLayout(sessionURL: sessionURL)).load()
        == .importedOriginal(TimelineAudioInfo(committedFrames: 16_000, gapEvents: [])))
}
