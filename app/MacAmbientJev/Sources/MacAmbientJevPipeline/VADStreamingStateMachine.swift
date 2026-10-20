/// Speech start and end decisions from one probability per VAD chunk, with hysteresis.
///
/// Ported from FluidAudio 0.15.8 `VadManager+Streaming.swift` (`streamingStateMachine`),
/// Apache-2.0, keeping only the path the app configures: the entry threshold is
/// `VADSegmentationParameters.speechProbabilityThreshold`, the exit threshold is that value
/// minus FluidAudio's 0.15 offset, and speech padding is zero.
public struct VADStreamingStateMachine: Sendable {
    static let negativeThresholdOffset: Float = 0.15
    static let minimumNegativeThreshold: Float = 0.01
    static let sampleRate = 16_000

    public static var negativeThreshold: Float {
        max(
            VADSegmentationParameters.speechProbabilityThreshold - negativeThresholdOffset,
            minimumNegativeThreshold
        )
    }

    private static var minSilenceSamples: Int {
        Int(VADSegmentationParameters.minSilenceSeconds * Double(sampleRate))
    }

    public private(set) var processedSamples = 0
    private var triggered = false
    /// First sample after the chunk where the probability fell below the exit threshold.
    /// Only a probability at or above the entry threshold clears it.
    private var silenceStartSample: Int?

    public init() {}

    /// Consumes the next chunk's probability. `chunkSampleCount` is the unpadded length.
    public mutating func advance(probability: Float, chunkSampleCount: Int) -> VADStreamEvent? {
        precondition(probability.isFinite, "probability must be finite")
        precondition(chunkSampleCount > 0, "chunkSampleCount must be positive")
        processedSamples += chunkSampleCount

        if probability >= VADSegmentationParameters.speechProbabilityThreshold {
            silenceStartSample = nil
            guard !triggered else { return nil }
            triggered = true
            return VADStreamEvent(
                kind: .speechStart,
                sampleIndex: max(0, processedSamples - chunkSampleCount)
            )
        }

        guard probability < Self.negativeThreshold, triggered else { return nil }
        let silenceStart = silenceStartSample ?? processedSamples
        silenceStartSample = silenceStart
        guard processedSamples - silenceStart >= Self.minSilenceSamples else { return nil }
        triggered = false
        silenceStartSample = nil
        return VADStreamEvent(
            kind: .speechEnd,
            sampleIndex: max(0, silenceStart - chunkSampleCount)
        )
    }
}
