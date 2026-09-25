import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func asrEngineFailureIsRepresentedInsideASRState() {
    let state = ASREngineState.failed(message: "model unavailable")
    #expect(state == .failed(message: "model unavailable"))
}

@Test
func asrInputFlagsPersistedFourMillisecondSegmentButNotTwentyMilliseconds() {
    let fourMilliseconds = ASRAudioInput(
        samples: Array(repeating: 0, count: 192),
        sampleRate: 48_000
    )
    let justShort = ASRAudioInput(
        samples: Array(repeating: 0, count: 959),
        sampleRate: 48_000
    )
    let twentyMilliseconds = ASRAudioInput(
        samples: Array(repeating: 0, count: 960),
        sampleRate: 48_000
    )

    #expect(fourMilliseconds.isShorterThanMinimumASRDuration)
    #expect(justShort.isShorterThanMinimumASRDuration)
    #expect(!twentyMilliseconds.isShorterThanMinimumASRDuration)
}

@Test
func asrMinimumDurationUsesInputSampleRate() {
    let justShort = ASRAudioInput(
        samples: Array(repeating: 0, count: 881),
        sampleRate: 44_100
    )
    let twentyMilliseconds = ASRAudioInput(
        samples: Array(repeating: 0, count: 882),
        sampleRate: 44_100
    )
    let sixteenKilohertzTwentyMilliseconds = ASRAudioInput(
        samples: Array(repeating: 0, count: 320),
        sampleRate: 16_000
    )

    #expect(justShort.isShorterThanMinimumASRDuration)
    #expect(!twentyMilliseconds.isShorterThanMinimumASRDuration)
    #expect(!sixteenKilohertzTwentyMilliseconds.isShorterThanMinimumASRDuration)
}

@Test
func modelStoreUsesManagedModelsDirectory() {
    let paths = AppPaths(
        applicationSupportURL: URL(fileURLWithPath: "/tmp/support"),
        cacheURL: URL(fileURLWithPath: "/tmp/cache")
    )
    let store = ModelStore(paths: paths)

    #expect(
        store.qwen3ASRCacheRoot.path
            == "/tmp/support/mac-ambient-jev/models/qwen3-asr-1.7b-mlx-8bit"
    )
    #expect(!store.qwen3ASRCacheRoot.path.contains("/sessions/"))
}

@Test
func asrAudioLoaderReadsSegmentFromDiskAndDownmixesStereo() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(
        directory: root,
        sampleRate: 10,
        channelCount: 2,
        chunkDurationSeconds: 1
    )
    try await writer.append(samples: [1, 3, 2, 4, 5, 7])
    let checkpoint = try await writer.finish()

    let reader = ProcessingTimelineReader(directory: root, checkpoint: checkpoint)
    let loader = ASRAudioLoader(reader: reader)
    let segment = SegmentReference(
        segmentationRunID: "seg_run",
        segmentID: "seg_1",
        startFrame: 0,
        endFrame: 3
    )

    let input = try loader.load(segment: segment)

    #expect(input.samples == [2, 3, 6])
    #expect(input.sampleRate == 10)
}
