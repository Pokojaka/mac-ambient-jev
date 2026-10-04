import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private actor RecordingVADChunkSegmenter: VADChunkSegmenting {
    private var sizes: [Int] = []

    func process16kChunk(
        _ samples: [Float]
    ) async throws -> VADChunkOutput {
        sizes.append(samples.count)
        return VADChunkOutput(segments: [], micLevel: nil)
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

    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1)
    let vad = RecordingVADChunkSegmenter()

    try await writer.append(
        samples: Array(repeating: Float(0.1), count: 16_000)
    )
    let firstCheckpoint = await writer.committedSnapshot()

    let processor = FluidVADTimelineProcessor(engine: vad)

    _ = try await processor.processAvailable(reader: try ProcessingTimelineReader(directory: root, checkpoint: firstCheckpoint))
    #expect(await vad.recordedChunkSizes() == [
        4_096,
        4_096,
        4_096
    ])

    // Polling the same durable boundary must not re-feed audio.
    _ = try await processor.processAvailable(reader: try ProcessingTimelineReader(directory: root, checkpoint: firstCheckpoint))
    #expect(await vad.recordedChunkSizes().count == 3)

    try await writer.append(
        samples: Array(repeating: Float(0.2), count: 16_000)
    )
    let secondCheckpoint = await writer.committedSnapshot()

    _ = try await processor.processAvailable(reader: try ProcessingTimelineReader(directory: root, checkpoint: secondCheckpoint))
    #expect(await vad.recordedChunkSizes().count == 7)

    _ = try await processor.finish(reader: try ProcessingTimelineReader(directory: root, checkpoint: secondCheckpoint))

    let sizes = await vad.recordedChunkSizes()
    #expect(sizes.count == 8)
    #expect(sizes.last == 3_328)
    #expect(sizes.reduce(0, +) == 32_000)
}

private enum InjectedVADFailure: Error { case secondChunk }

private actor FailingOnceVADChunkSegmenter: VADChunkSegmenting {
    private var calls = 0
    private var acceptedFrames = 0

    func process16kChunk(_ samples: [Float]) async throws -> VADChunkOutput {
        calls += 1
        if calls == 2 { throw InjectedVADFailure.secondChunk }
        acceptedFrames += samples.count
        guard calls == 1 else { return VADChunkOutput(segments: [], micLevel: nil) }
        return VADChunkOutput(
            segments: [SegmentReference(segmentationRunID: "seg", segmentID: "before-failure", startFrame: 0, endFrame: 100)],
            micLevel: nil
        )
    }

    func finish(totalCanonicalFrames: Int64) async -> [SegmentReference] { [] }
    func acceptedFrameCount() -> Int { acceptedFrames }
}

@Test
func vadProcessorRetryAfterChunkErrorNeitherReplaysAudioNorDropsSegments() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1)
    try await writer.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await writer.committedSnapshot()
    let vad = FailingOnceVADChunkSegmenter()
    let processor = FluidVADTimelineProcessor(engine: vad)
    await #expect(throws: InjectedVADFailure.secondChunk) {
        try await processor.processAvailable(reader: try ProcessingTimelineReader(directory: root, checkpoint: checkpoint))
    }
    var emitted = try await processor.processAvailable(reader: try ProcessingTimelineReader(directory: root, checkpoint: checkpoint))
    emitted += try await processor.finish(reader: try ProcessingTimelineReader(directory: root, checkpoint: checkpoint))
    #expect(await vad.acceptedFrameCount() == 16_000)
    #expect(emitted.map(\.segmentID) == ["before-failure"])
}
