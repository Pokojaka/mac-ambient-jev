import Foundation
import Dispatch
import MacAmbientJevCore

public struct LiveVADProgress: Sendable, Equatable {
    public let emittedSegments: [SegmentReference]
    public let totalSegmentCount: Int
    public let committedFrames: Int64
    public let openSpeech: OpenSpeechRange?
    /// Newly measured VAD-confirmed speech windows in capture-relative seconds.
    public let micSpeechLevels: [MicLevelWindow]

    public init(
        emittedSegments: [SegmentReference],
        totalSegmentCount: Int,
        committedFrames: Int64,
        openSpeech: OpenSpeechRange? = nil,
        micSpeechLevels: [MicLevelWindow]
    ) {
        self.emittedSegments = emittedSegments
        self.totalSegmentCount = totalSegmentCount
        self.committedFrames = committedFrames
        self.openSpeech = openSpeech
        self.micSpeechLevels = micSpeechLevels
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
    private let latencyTrace: LiveLatencyTrace?
    private var segments: [SegmentReference] = []
    private var lastCommittedFrames: Int64
    private var isFinished = false
    private var observedOpenUtteranceID: String?

    public static func make(
        processingDirectory: URL,
        initialCheckpoint: AudioCheckpoint,
        measureMicInputLevels: Bool,
        segmentationRunID: String = "seg_live_\(UUID().uuidString.lowercased())",
        latencyTrace: LiveLatencyTrace? = nil
    ) async throws -> LiveVADSession {
        let engine = try await FluidVADSegmentationEngine.make(
            segmentationRunID: segmentationRunID,
            canonicalSampleRate: initialCheckpoint.sampleRate,
            measureMicInputLevels: measureMicInputLevels
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
            initialCommittedFrames: initialCheckpoint.committedFrames,
            latencyTrace: latencyTrace
        )
    }

    init(
        segmentationRunID: String,
        processor: FluidVADTimelineProcessor,
        initialCommittedFrames: Int64,
        latencyTrace: LiveLatencyTrace? = nil
    ) {
        self.segmentationRunID = segmentationRunID
        self.processor = processor
        self.lastCommittedFrames = initialCommittedFrames
        self.latencyTrace = latencyTrace
    }

    @discardableResult
    public func processAvailable(
        checkpoint: AudioCheckpoint
    ) async throws -> LiveVADProgress {
        guard !isFinished else {
            return LiveVADProgress(
                emittedSegments: [],
                totalSegmentCount: segments.count,
                committedFrames: lastCommittedFrames,
                openSpeech: nil,
                micSpeechLevels: []
            )
        }

        let checkpointTimestamp = DispatchTime.now().uptimeNanoseconds
        let emitted = try await processor.processAvailable(
            checkpoint: checkpoint
        )
        segments.append(contentsOf: emitted)
        lastCommittedFrames = checkpoint.committedFrames

        let openSpeech = await processor.openSpeechRange(
            upToFrame: checkpoint.committedFrames
        )
        if let openSpeech,
           openSpeech.utteranceID != observedOpenUtteranceID {
            observedOpenUtteranceID = openSpeech.utteranceID
            let framesBeforeCheckpoint = max(
                0,
                checkpoint.committedFrames - openSpeech.startFrame
            )
            let elapsedNanoseconds = UInt64(
                (Double(framesBeforeCheckpoint) / checkpoint.sampleRate
                    * 1_000_000_000).rounded()
            )
            await latencyTrace?.record(LiveLatencyTraceEvent(
                utteranceID: openSpeech.utteranceID,
                snapshotID: nil,
                kind: .speechStart,
                timestampNanoseconds: checkpointTimestamp >= elapsedNanoseconds
                    ? checkpointTimestamp - elapsedNanoseconds
                    : 0
            ))
        }
        if let openSpeech {
            await latencyTrace?.record(LiveLatencyTraceEvent(
                utteranceID: openSpeech.utteranceID,
                snapshotID: nil,
                kind: .checkpointCommitted,
                timestampNanoseconds: checkpointTimestamp
            ))
        }

        return LiveVADProgress(
            emittedSegments: emitted,
            totalSegmentCount: segments.count,
            committedFrames: checkpoint.committedFrames,
            openSpeech: openSpeech,
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
                totalSegmentCount: segments.count,
                committedFrames: lastCommittedFrames,
                openSpeech: nil,
                micSpeechLevels: []
            )
        }

        let emitted = try await processor.finish(checkpoint: checkpoint)
        segments.append(contentsOf: emitted)
        lastCommittedFrames = checkpoint.committedFrames
        isFinished = true

        return LiveVADProgress(
            emittedSegments: emitted,
            totalSegmentCount: segments.count,
            committedFrames: checkpoint.committedFrames,
            openSpeech: nil,
            micSpeechLevels: await processor.takeMicSpeechLevels()
        )
    }

    public func allSegments() -> [SegmentReference] {
        segments
    }
}
