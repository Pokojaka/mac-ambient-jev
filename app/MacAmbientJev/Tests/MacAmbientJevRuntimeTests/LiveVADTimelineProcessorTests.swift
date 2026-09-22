import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private actor RecordingVADChunkSegmenter: VADChunkSegmenting {
    private var sizes: [Int] = []

    func process16kChunk(
        _ samples: [Float]
    ) async throws -> [SegmentReference] {
        sizes.append(samples.count)
        return []
    }

    func finish(
        totalCanonicalFrames: Int64
    ) async -> [SegmentReference] {
        []
    }

    func recordedChunkSizes() -> [Int] {
        sizes
    }
}

@Test
func liveVADProcessorConsumesEachDurableFrameOnlyOnce() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(
        directory: root,
        sampleRate: 16_000,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
    let vad = RecordingVADChunkSegmenter()

    try await writer.append(
        samples: Array(repeating: Float(0.1), count: 16_000)
    )
    let firstCheckpoint = await writer.committedSnapshot()

    let processor = FluidVADTimelineProcessor(
        reader: ProcessingTimelineReader(
            directory: root,
            checkpoint: firstCheckpoint
        ),
        engine: vad,
        sourceReadSeconds: 1
    )

    _ = try await processor.processAvailable(
        checkpoint: firstCheckpoint
    )
    #expect(await vad.recordedChunkSizes() == [
        4_096,
        4_096,
        4_096
    ])

    // Polling the same durable boundary must not re-feed audio.
    _ = try await processor.processAvailable(
        checkpoint: firstCheckpoint
    )
    #expect(await vad.recordedChunkSizes().count == 3)

    try await writer.append(
        samples: Array(repeating: Float(0.2), count: 16_000)
    )
    let secondCheckpoint = await writer.committedSnapshot()

    _ = try await processor.processAvailable(
        checkpoint: secondCheckpoint
    )
    #expect(await vad.recordedChunkSizes().count == 7)

    _ = try await processor.finish(
        checkpoint: secondCheckpoint
    )

    let sizes = await vad.recordedChunkSizes()
    #expect(sizes.count == 8)
    #expect(sizes.last == 3_328)
    #expect(sizes.reduce(0, +) == 32_000)
}
