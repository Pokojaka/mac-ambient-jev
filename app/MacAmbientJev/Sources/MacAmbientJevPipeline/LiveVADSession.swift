import Foundation
import MacAmbientJevCore

public protocol LiveVADProcessing: Sendable {
    var segmentationRunID: String { get }
    func processAvailable(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress
    func finish(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress
}

public struct LiveVADProgress: Sendable, Equatable {
    public let emittedSegments: [SegmentReference]
    public let totalSegmentCount: Int
    public let committedFrames: Int64
    /// Newly measured VAD-confirmed speech windows in capture-relative seconds.
    public let micSpeechLevels: [MicLevelWindow]

    public init(
        emittedSegments: [SegmentReference],
        totalSegmentCount: Int,
        committedFrames: Int64,
        micSpeechLevels: [MicLevelWindow]
    ) {
        self.emittedSegments = emittedSegments
        self.totalSegmentCount = totalSegmentCount
        self.committedFrames = committedFrames
        self.micSpeechLevels = micSpeechLevels
    }
}

/// Owns one incremental VAD run for a live recording.
///
/// This actor only reads frames that are already durable in the processing
/// timeline. It never participates in microphone capture, so VAD latency or
/// failure cannot block audio persistence.
public actor LiveVADSession: LiveVADProcessing {
    public nonisolated let segmentationRunID: String

    private let processingDirectory: URL
    private let sessionURL: URL
    private let processor: VADTimelineProcessor
    private var segmentCount = 0
    private var lastCommittedFrames: Int64
    private var isFinished = false

    public init(
        segmentationRunID: String,
        processingDirectory: URL,
        sessionURL: URL,
        processor: VADTimelineProcessor,
        initialCommittedFrames: Int64
    ) {
        self.segmentationRunID = segmentationRunID
        self.processingDirectory = processingDirectory
        self.sessionURL = sessionURL
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
                totalSegmentCount: segmentCount,
                committedFrames: lastCommittedFrames,
                micSpeechLevels: []
            )
        }

        let emitted = try await processor.processAvailable(
            reader: ProcessingTimelineReader(directory: processingDirectory, checkpoint: checkpoint, sessionURL: sessionURL)
        )
        segmentCount += emitted.count
        lastCommittedFrames = checkpoint.committedFrames

        return LiveVADProgress(
            emittedSegments: emitted,
            totalSegmentCount: segmentCount,
            committedFrames: checkpoint.committedFrames,
            micSpeechLevels: await processor.takeMicSpeechLevels()
        )
    }

    @discardableResult
    public func finish(
        checkpoint: AudioCheckpoint
    ) async throws -> LiveVADProgress {
        guard !isFinished else {
            return LiveVADProgress(
                emittedSegments: [],
                totalSegmentCount: segmentCount,
                committedFrames: lastCommittedFrames,
                micSpeechLevels: []
            )
        }

        let emitted = try await processor.finish(
            reader: ProcessingTimelineReader(directory: processingDirectory, checkpoint: checkpoint, sessionURL: sessionURL)
        )
        segmentCount += emitted.count
        lastCommittedFrames = checkpoint.committedFrames
        isFinished = true

        return LiveVADProgress(
            emittedSegments: emitted,
            totalSegmentCount: segmentCount,
            committedFrames: checkpoint.committedFrames,
            micSpeechLevels: await processor.takeMicSpeechLevels()
        )
    }
}
