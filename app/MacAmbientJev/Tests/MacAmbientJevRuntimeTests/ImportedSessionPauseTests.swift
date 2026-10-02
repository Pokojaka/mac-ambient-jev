import Foundation
import MacAmbientJevAppleSupport
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private struct PausedImportVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "fake-vad", model: nil, version: "test", configuration: [:])
    func segment(reader: ProcessingTimelineReader, runID: String) async throws -> [SegmentReference] {
        [SegmentReference(
            segmentationRunID: runID,
            segmentID: "spoken",
            startFrame: 0,
            endFrame: reader.checkpoint.committedFrames
        )]
    }
}

private struct PausedImportDiarizer: DiarizationEngine {
    let provenance = RunProvenance(engine: "fake-diarizer", model: nil, version: "test", configuration: [:])
    func prepare() async throws {}

    func diarize(fileURL: URL, canonicalSampleRate: Double) async throws -> [SpeakerSpan] {
        [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)]
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
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory)
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper().createSession(
        paths: paths,
        sessionID: sessionID,
        sourceKind: .importedFile,
        captureSource: .microphone
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
    try await writer.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await writer.committedSnapshot()
    let sourceURL = sessionURL.appending(path: "audio/original.caf")
    try ProcessingTimelineAudioExporter().export(
        reader: ProcessingTimelineReader(directory: processingDirectory, checkpoint: checkpoint),
        to: sourceURL
    )

    let asr = PausedImportASR()
    let processor = NativeSessionProcessor(
        paths: paths,
        asr: asr,
        diarizationEngine: PausedImportDiarizer(),
        finalTranscriptVAD: PausedImportVAD()
    )
    let paused = await processor.processImportedSession(
        sessionID: sessionID,
        originalURL: sourceURL,
        pacingMode: .normal,
        shouldPause: { true },
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

    let candidate = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).inspect(sessionID: sessionID)
    #expect(candidate?.action == .finalize)
    guard case .importedOriginal(let originalURL) = candidate?.source else {
        Issue.record("a paused import resumes from its original")
        return
    }

    let resumed = await processor.processImportedSession(
        sessionID: sessionID,
        originalURL: originalURL,
        pacingMode: .normal,
        shouldPause: { false },
        onPhase: { _ in },
        metadataPolicy: .reject,
        onStatus: { _ in },
        onUpdate: { _, _ in }
    )

    #expect(resumed.disposition == .completed)
    #expect(await asr.calls == 1)
    let completed = try ProcessingMetadataStore(sessionURL: sessionURL).load()
    #expect(completed?.finalizationAttempt?.state == .complete)
    #expect(completed?.activeRuns?.scope != nil)
    #expect(try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).inspect(sessionID: sessionID) == nil)
}
