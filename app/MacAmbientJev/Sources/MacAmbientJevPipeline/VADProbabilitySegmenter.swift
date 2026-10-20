import MacAmbientJevCore

/// Cuts segments from one speech probability per VAD chunk.
///
/// This is the engine-independent half of a VAD engine that scores chunks itself: the
/// streaming hysteresis of `VADStreamingStateMachine` followed by `VADSegmentationState`.
public struct VADProbabilitySegmenter: Sendable {
    private var streamingStateMachine = VADStreamingStateMachine()
    private var segmentationState: VADSegmentationState

    public init(segmentationRunID: String, canonicalSampleRate: Double) {
        segmentationState = VADSegmentationState(
            segmentationRunID: segmentationRunID,
            canonicalSampleRate: canonicalSampleRate
        )
    }

    public var processedSamples: Int { streamingStateMachine.processedSamples }

    /// `samples` are the chunk's unpadded audio.
    public mutating func process(samples: [Float], probability: Float) -> [SegmentReference] {
        let event = streamingStateMachine.advance(
            probability: probability, chunkSampleCount: samples.count
        )
        return segmentationState.process(
            samples: samples,
            event: event,
            processedSamples: Int64(streamingStateMachine.processedSamples)
        )
    }

    public mutating func finish(totalCanonicalFrames: Int64) -> [SegmentReference] {
        segmentationState.finish(totalCanonicalFrames: totalCanonicalFrames)
    }
}
