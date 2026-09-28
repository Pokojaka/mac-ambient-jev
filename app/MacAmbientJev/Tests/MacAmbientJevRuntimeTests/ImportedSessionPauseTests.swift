import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private struct PausedImportVAD: FinalTranscriptVADSegmenter {
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
    func prepare() async throws {}

    func diarize(fileURL: URL, canonicalSampleRate: Double) async throws -> [SpeakerSpan] {
        [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.9)]
    }
}

private actor PausedImportASR: ASREngine {
    private(set) var calls = 0

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        calls += 1
        return ASRResult(text: "spoken words", detectedLanguage: "ja")
    }

    func unload() async {}
}

@Test
func importedFinalizationPauseSkipsASRAndLeavesRunsInactive() async throws {
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
        sourceKind: .importedFile
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
    let sourceURL = root.appending(path: "sample.caf")
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
    let result = await processor.processImportedSession(
        sessionID: sessionID,
        originalURL: sourceURL,
        shouldPause: { true }
    )

    #expect(result.disposition != .completed)
    let transcriptions = await asr.calls
    #expect(transcriptions == 0)
    let metadata = try ProcessingMetadataStore(sessionURL: sessionURL).load()
    #expect(metadata?.activeRuns == nil)
}
