import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private actor EmittingLiveVAD: VADChunkSegmenting {
    private let runID: String
    private var nextIndex = 1

    init(runID: String) {
        self.runID = runID
    }

    func process16kChunk(
        _ samples: [Float]
    ) async throws -> VADChunkOutput {
        guard !samples.isEmpty else { return VADChunkOutput(segments: [], micLevel: nil) }

        let index = nextIndex
        nextIndex += 1
        return VADChunkOutput(
            segments: [
                SegmentReference(
                    segmentationRunID: runID,
                    segmentID: String(format: "seg_%06d", index),
                    startFrame: Int64((index - 1) * 4_096),
                    endFrame: Int64((index - 1) * 4_096 + samples.count)
                )
            ],
            micLevel: nil
        )
    }

    func finish(
        totalCanonicalFrames: Int64
    ) async -> [SegmentReference] {
        []
    }
}

@Test
func liveVADSessionAccumulatesOnlyNewDurableAudio() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1)
    let runID = "seg_live_test"
    let vad = EmittingLiveVAD(runID: runID)

    try await writer.append(
        samples: Array(repeating: Float(0.1), count: 16_000)
    )
    let firstCheckpoint = await writer.committedSnapshot()
    let processor = FluidVADTimelineProcessor(engine: vad)
    let session = LiveVADSession(
        segmentationRunID: runID,
        processingDirectory: root,
        processor: processor,
        initialCommittedFrames: firstCheckpoint.committedFrames
    )

    let first = try await session.processAvailable(
        checkpoint: firstCheckpoint
    )
    #expect(first.emittedSegments.count == 3)
    #expect(first.totalSegmentCount == 3)

    let repeated = try await session.processAvailable(
        checkpoint: firstCheckpoint
    )
    #expect(repeated.emittedSegments.isEmpty)
    #expect(repeated.totalSegmentCount == 3)

    try await writer.append(
        samples: Array(repeating: Float(0.2), count: 16_000)
    )
    let secondCheckpoint = await writer.committedSnapshot()
    let second = try await session.processAvailable(
        checkpoint: secondCheckpoint
    )
    #expect(second.emittedSegments.count == 4)
    #expect(second.totalSegmentCount == 7)

    let final = try await session.finish(
        checkpoint: secondCheckpoint
    )
    #expect(final.emittedSegments.count == 1)
    #expect(final.totalSegmentCount == 8)
}

@Test
func liveVADSessionFinishIsIdempotent() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1)
    try await writer.append(
        samples: Array(repeating: Float(0.1), count: 16_000)
    )
    let checkpoint = await writer.committedSnapshot()

    let runID = "seg_live_test"
    let session = LiveVADSession(
        segmentationRunID: runID,
        processingDirectory: root,
        processor: FluidVADTimelineProcessor(engine: EmittingLiveVAD(runID: runID)),
        initialCommittedFrames: checkpoint.committedFrames
    )

    let first = try await session.finish(checkpoint: checkpoint)
    let second = try await session.finish(checkpoint: checkpoint)

    #expect(first.totalSegmentCount == 4)
    #expect(second.emittedSegments.isEmpty)
    #expect(second.totalSegmentCount == first.totalSegmentCount)
}
