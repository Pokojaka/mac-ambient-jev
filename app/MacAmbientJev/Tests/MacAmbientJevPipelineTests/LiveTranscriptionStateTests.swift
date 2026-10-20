import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private func checkpoint(_ committedFrames: Int64) -> AudioCheckpoint {
    AudioCheckpoint(
        committedFrames: committedFrames,
        sampleRate: 16_000,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: [],
        chunkFrameCounts: [],
        gapEvents: []
    )
}

private func segment(_ segmentID: String, at startFrame: Int64) -> SegmentReference {
    SegmentReference(
        segmentationRunID: "seg_live_test",
        segmentID: segmentID,
        startFrame: startFrame,
        endFrame: startFrame + 1
    )
}

@MainActor
@Test
func liveTranscriptionStateDequeuesBatchesFIFOWithLatestCheckpoint() throws {
    let state = LiveTranscriptionState()
    let sessionID = UUID()
    let firstBatch = [segment("seg_1", at: 0), segment("seg_2", at: 1)]
    let secondBatch = [segment("seg_3", at: 2)]
    let oldCheckpoint = checkpoint(10)
    let latestCheckpoint = checkpoint(20)

    state.enqueue(sessionID: sessionID, segments: firstBatch, checkpoint: oldCheckpoint)
    state.enqueue(sessionID: sessionID, segments: secondBatch, checkpoint: latestCheckpoint)

    #expect(state.latestCheckpoint(sessionID: sessionID) == latestCheckpoint)
    #expect(state.hasQueued(sessionID: sessionID))
    #expect(state.pendingSegmentCount(sessionID: sessionID) == 3)
    #expect(state.queuedSegments(sessionID: sessionID).map(\.segmentID) == ["seg_1", "seg_2", "seg_3"])
    #expect(state.queuedBatchCount(sessionID: sessionID) == 2)
    let first = try #require(state.dequeue(sessionID: sessionID))
    #expect(first.segments == firstBatch)
    #expect(first.checkpoint == latestCheckpoint)
    #expect(state.queuedSegments(sessionID: sessionID).map(\.segmentID) == ["seg_3"])
    #expect(state.queuedBatchCount(sessionID: sessionID) == 1)

    let second = try #require(state.dequeue(sessionID: sessionID))
    #expect(second.segments == secondBatch)
    #expect(second.checkpoint == latestCheckpoint)
    #expect(state.dequeue(sessionID: sessionID)?.segments == nil)
    #expect(!state.hasQueued(sessionID: sessionID))
    #expect(state.pendingSegmentCount(sessionID: sessionID) == 0)
    #expect(state.queuedSegments(sessionID: sessionID).isEmpty)
    #expect(state.queuedBatchCount(sessionID: sessionID) == 0)
}

@MainActor
@Test
func liveTranscriptionStateFailureBlocksDequeueWithDiscardSemantics() throws {
    let state = LiveTranscriptionState()
    let failedSessionID = UUID()
    let healthySessionID = UUID()
    let queued = [segment("seg_1", at: 0)]
    let ignored = [segment("seg_2", at: 1)]
    let latestCheckpoint = checkpoint(20)

    state.enqueue(sessionID: failedSessionID, segments: queued, checkpoint: checkpoint(10))
    state.recordFailure(sessionID: failedSessionID, message: "ASR failed", discardQueued: false)
    #expect(state.failure(sessionID: failedSessionID) == "ASR failed")
    #expect(state.pendingSegmentCount(sessionID: failedSessionID) == 1)
    #expect(state.dequeue(sessionID: failedSessionID)?.segments == nil)

    let healthyBatch = [segment("seg_3", at: 2)]
    state.enqueue(sessionID: healthySessionID, segments: healthyBatch, checkpoint: checkpoint(30))
    let healthy = try #require(state.dequeue(sessionID: healthySessionID))
    #expect(healthy.segments == healthyBatch)
    #expect(healthy.checkpoint == checkpoint(30))

    state.enqueue(sessionID: healthySessionID, segments: healthyBatch, checkpoint: checkpoint(40))
    state.recordFailure(sessionID: healthySessionID, message: "discard", discardQueued: true)
    #expect(state.failure(sessionID: healthySessionID) == "discard")
    #expect(state.pendingSegmentCount(sessionID: healthySessionID) == 0)
    #expect(!state.hasQueued(sessionID: healthySessionID))
    #expect(state.dequeue(sessionID: healthySessionID)?.segments == nil)

    state.begin(sessionID: failedSessionID)
    #expect(state.failure(sessionID: failedSessionID) == nil)
    #expect(state.pendingSegmentCount(sessionID: failedSessionID) == 0)
    #expect(!state.hasQueued(sessionID: failedSessionID))
    state.enqueue(sessionID: failedSessionID, segments: ignored, checkpoint: latestCheckpoint)
    let restarted = try #require(state.dequeue(sessionID: failedSessionID))
    #expect(restarted.segments == ignored)
    #expect(restarted.checkpoint == latestCheckpoint)
}

@MainActor
@Test
func liveTranscriptionStateCleanupClearsOnlyOneSession() throws {
    let state = LiveTranscriptionState()
    let cleanedSessionID = UUID()
    let retainedSessionID = UUID()
    let retainedBatch = [segment("seg_retained", at: 0)]

    state.enqueue(
        sessionID: cleanedSessionID,
        segments: [segment("seg_cleaned", at: 0)],
        checkpoint: checkpoint(10)
    )
    state.recordFailure(sessionID: cleanedSessionID, message: "failure", discardQueued: false)
    state.contentPriorityStatus[cleanedSessionID] = "cleaned"

    state.enqueue(sessionID: retainedSessionID, segments: retainedBatch, checkpoint: checkpoint(20))
    state.contentPriorityStatus[retainedSessionID] = "retained"
    #expect(state.latestCheckpoint(sessionID: cleanedSessionID) == checkpoint(10))
    #expect(state.latestCheckpoint(sessionID: retainedSessionID) == checkpoint(20))

    state.cleanup(sessionID: cleanedSessionID)

    #expect(state.latestCheckpoint(sessionID: cleanedSessionID) == nil)
    #expect(state.latestCheckpoint(sessionID: retainedSessionID) == checkpoint(20))
    #expect(state.failure(sessionID: cleanedSessionID) == nil)
    #expect(state.pendingSegmentCount(sessionID: cleanedSessionID) == 0)
    #expect(!state.hasQueued(sessionID: cleanedSessionID))
    #expect(state.contentPriorityStatus[cleanedSessionID] == nil)
    #expect(state.failure(sessionID: retainedSessionID) == nil)
    #expect(state.contentPriorityStatus[retainedSessionID] == "retained")

    let retained = try #require(state.dequeue(sessionID: retainedSessionID))
    #expect(retained.segments == retainedBatch)
    #expect(retained.checkpoint == checkpoint(20))
}

@MainActor
@Test
func liveTranscriptionStateQueueEmptinessReflectsQueuedBatches() {
    let state = LiveTranscriptionState()
    let sessionID = UUID()
    #expect(state.isQueueEmpty)

    state.enqueue(sessionID: sessionID, segments: [segment("seg_1", at: 0)], checkpoint: checkpoint(10))
    #expect(!state.isQueueEmpty)
    #expect(state.dequeue(sessionID: sessionID)?.segments != nil)
    #expect(state.isQueueEmpty)
}

@MainActor
@Test
func liveTranscriptionStateResetVADPreservesASRQueue() throws {
    let state = LiveTranscriptionState()
    let sessionID = UUID()
    let batch = [segment("seg_1", at: 0)]
    let audioCheckpoint = checkpoint(10)

    state.vadSegmentCount = 5
    state.vadFailureText = "VAD failed"
    state.enqueue(sessionID: sessionID, segments: batch, checkpoint: audioCheckpoint)
    #expect(state.pendingSegmentCount(sessionID: sessionID) == 1)
    #expect(state.queuedSegments(sessionID: sessionID) == batch)

    state.resetVAD()

    #expect(state.vadFailureText == nil)
    #expect(state.vadSegmentCount == 0)
    #expect(state.pendingSegmentCount(sessionID: sessionID) == 1)
    #expect(state.queuedSegments(sessionID: sessionID) == batch)
    #expect(state.latestCheckpoint(sessionID: sessionID) == audioCheckpoint)
    let queued = try #require(state.dequeue(sessionID: sessionID))
    #expect(queued.segments == batch)
    #expect(queued.checkpoint == audioCheckpoint)
}
