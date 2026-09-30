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

    func openSpeechRange(upToFrame durableFrame: Int64) async -> OpenSpeechRange? {
        guard durableFrame > 0 else { return nil }
        return OpenSpeechRange(
            utteranceID: "u1",
            startFrame: 0,
            endFrame: durableFrame
        )
    }
}

@Test
func liveVADSessionAccumulatesOnlyNewDurableAudio() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(
        directory: root,
        sampleRate: 16_000,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
    let runID = "seg_live_test"
    let vad = EmittingLiveVAD(runID: runID)

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
    let session = LiveVADSession(
        segmentationRunID: runID,
        processor: processor,
        initialCommittedFrames: firstCheckpoint.committedFrames
    )

    let first = try await session.processAvailable(
        checkpoint: firstCheckpoint
    )
    #expect(first.emittedSegments.count == 3)
    #expect(first.totalSegmentCount == 3)
    #expect(first.openSpeech?.endFrame == firstCheckpoint.committedFrames)

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
    #expect(final.openSpeech == nil)
    #expect(await session.allSegments().count == 8)
}

@Test
func liveVADSessionFinishIsIdempotent() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(
        directory: root,
        sampleRate: 16_000,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
    try await writer.append(
        samples: Array(repeating: Float(0.1), count: 16_000)
    )
    let checkpoint = await writer.committedSnapshot()

    let runID = "seg_live_test"
    let session = LiveVADSession(
        segmentationRunID: runID,
        processor: FluidVADTimelineProcessor(
            reader: ProcessingTimelineReader(
                directory: root,
                checkpoint: checkpoint
            ),
            engine: EmittingLiveVAD(runID: runID),
            sourceReadSeconds: 1
        ),
        initialCommittedFrames: checkpoint.committedFrames
    )

    let first = try await session.finish(checkpoint: checkpoint)
    let second = try await session.finish(checkpoint: checkpoint)

    #expect(first.totalSegmentCount == 4)
    #expect(second.emittedSegments.isEmpty)
    #expect(second.totalSegmentCount == first.totalSegmentCount)
    #expect(first.openSpeech == nil)
}
