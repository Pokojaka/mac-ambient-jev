import Foundation
import MacAmbientJevCore

public struct LiveVADProgress: Sendable, Equatable {
    public let emittedSegments: [SegmentReference]
    public let totalSegmentCount: Int
    public let committedFrames: Int64

    public init(
        emittedSegments: [SegmentReference],
        totalSegmentCount: Int,
        committedFrames: Int64
    ) {
        self.emittedSegments = emittedSegments
        self.totalSegmentCount = totalSegmentCount
        self.committedFrames = committedFrames
    }
}

/// Owns one incremental VAD run for a live recording.
///
/// This actor only reads frames that are already durable in the processing
/// timeline. It never participates in microphone capture, so VAD latency or
/// failure cannot block audio persistence.
public actor LiveVADSession {
    public nonisolated let segmentationRunID: String

    private let processor: FluidVADTimelineProcessor
    private var segments: [SegmentReference] = []
    private var lastCommittedFrames: Int64
    private var isFinished = false

    public static func make(
        processingDirectory: URL,
        initialCheckpoint: AudioCheckpoint,
        segmentationRunID: String = "seg_live_\(UUID().uuidString.lowercased())"
    ) async throws -> LiveVADSession {
        let engine = try await FluidVADSegmentationEngine.make(
            segmentationRunID: segmentationRunID,
            canonicalSampleRate: initialCheckpoint.sampleRate
        )
        let reader = ProcessingTimelineReader(
            directory: processingDirectory,
            checkpoint: initialCheckpoint
        )
        return LiveVADSession(
            segmentationRunID: segmentationRunID,
            processor: FluidVADTimelineProcessor(
                reader: reader,
                engine: engine
            ),
            initialCommittedFrames: initialCheckpoint.committedFrames
        )
    }

    init(
        segmentationRunID: String,
        processor: FluidVADTimelineProcessor,
        initialCommittedFrames: Int64
    ) {
        self.segmentationRunID = segmentationRunID
        self.processor = processor
        self.lastCommittedFrames = initialCommittedFrames
    }

    @discardableResult
    public func processAvailable(
        checkpoint: AudioCheckpoint
    ) async throws -> LiveVADProgress {
        guard !isFinished else {
            return LiveVADProgress(
                emittedSegments: [],
                totalSegmentCount: segments.count,
                committedFrames: lastCommittedFrames
            )
        }

        let emitted = try await processor.processAvailable(
            checkpoint: checkpoint
        )
        segments.append(contentsOf: emitted)
        lastCommittedFrames = checkpoint.committedFrames

        return LiveVADProgress(
            emittedSegments: emitted,
            totalSegmentCount: segments.count,
            committedFrames: checkpoint.committedFrames
        )
    }

    @discardableResult
    public func finish(
        checkpoint: AudioCheckpoint
    ) async throws -> LiveVADProgress {
        guard !isFinished else {
            return LiveVADProgress(
                emittedSegments: [],
                totalSegmentCount: segments.count,
                committedFrames: lastCommittedFrames
            )
        }

        let emitted = try await processor.finish(checkpoint: checkpoint)
        segments.append(contentsOf: emitted)
        lastCommittedFrames = checkpoint.committedFrames
        isFinished = true

        return LiveVADProgress(
            emittedSegments: emitted,
            totalSegmentCount: segments.count,
            committedFrames: checkpoint.committedFrames
        )
    }

    public func allSegments() -> [SegmentReference] {
        segments
    }
}
