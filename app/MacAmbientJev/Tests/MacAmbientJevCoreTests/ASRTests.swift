import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func asrInputFlagsPersistedFourMillisecondSegmentButNotTwentyMilliseconds() {
    let fourMilliseconds = ASRAudioInput(
        samples: Array(repeating: 0, count: 64),
        sampleRate: 16_000
    )
    let justShort = ASRAudioInput(
        samples: Array(repeating: 0, count: 319),
        sampleRate: 16_000
    )
    let twentyMilliseconds = ASRAudioInput(
        samples: Array(repeating: 0, count: 320),
        sampleRate: 16_000
    )

    #expect(fourMilliseconds.isShorterThanMinimumASRDuration)
    #expect(justShort.isShorterThanMinimumASRDuration)
    #expect(!twentyMilliseconds.isShorterThanMinimumASRDuration)
}

@Test
func modelStoreUsesManagedModelsDirectory() {
    let paths = AppPaths(
        applicationSupportURL: URL(fileURLWithPath: "/tmp/support"),
        cacheURL: URL(fileURLWithPath: "/tmp/cache"),
        sessionsRootOverride: nil
    )
    let store = ModelStore(paths: paths)

    #expect(
        store.qwen3ASRCacheRoot.path
            == paths.modelsRoot.appending(path: "qwen3-asr-1.7b-mlx-8bit").path
    )
    #expect(!store.qwen3ASRCacheRoot.path.contains("/sessions/"))
}

@Test
func asrAudioLoaderReadsCanonicalSegmentWithoutChangingSamples() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await writer.append(samples: [2, 3, 6])
    let checkpoint = try await writer.finish()

    let reader = try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
    let loader = ASRAudioLoader(reader: reader)
    let segment = SegmentReference(
        segmentationRunID: "seg_run",
        segmentID: "seg_1",
        startFrame: 0,
        endFrame: 3
    )

    let input = try loader.load(segment: segment)

    #expect(input.samples == [2, 3, 6])
    #expect(input.sampleRate == 16_000)
}

@Test
func asrAudioLoaderRejectsReversedSegmentRange() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await writer.append(samples: [1, 2, 3])
    let checkpoint = try await writer.finish()
    let loader = ASRAudioLoader(reader: try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root))

    #expect(throws: ProcessingTimelineReaderError.invalidFrameRange) {
        try loader.load(segment: SegmentReference(
            segmentationRunID: "seg_run", segmentID: "reversed", startFrame: 2, endFrame: 1
        ))
    }
}

@Test
func asrRunCancellationHasLocalizedDescriptionAndRetainsMetrics() {
    var metrics = ASRBatchMetrics()
    metrics.processedAudioSeconds = 12.5
    metrics.asrCallSeconds = 3.25
    let cancellation = ASRRunCancellation(metrics: metrics)
    let erasedError: any Error = cancellation
    let expectedDescription = "音声認識がキャンセルされました"

    #expect(cancellation.errorDescription == expectedDescription)
    #expect(cancellation.localizedDescription == expectedDescription)
    #expect(erasedError.localizedDescription == expectedDescription)
    #expect(cancellation.metrics == metrics)
}
