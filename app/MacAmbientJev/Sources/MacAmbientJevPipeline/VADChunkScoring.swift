/// Chunk-level helpers for engines that score a chunk as consecutive model frames.
///
/// FluidAudio's `silero-vad-unified-256ms-v6.2.1` model scores 4,096 new samples as eight
/// consecutive 512-sample frames and reports `1 − Π(1 − pᵢ)`. A partial last chunk is padded
/// by repeating its last sample so the padding adds no energy step.
public enum VADChunkScoring {
    public static func paddedChunk(_ samples: [Float], to chunkSamples: Int) -> [Float] {
        precondition(!samples.isEmpty, "samples must not be empty")
        precondition(samples.count <= chunkSamples, "samples exceed the chunk size")
        guard samples.count < chunkSamples, let lastSample = samples.last else { return samples }
        return samples + [Float](repeating: lastSample, count: chunkSamples - samples.count)
    }

    public static func noisyOR(_ frameProbabilities: [Float]) -> Float {
        precondition(!frameProbabilities.isEmpty, "frameProbabilities must not be empty")
        var allFramesSilent = 1.0
        for probability in frameProbabilities {
            precondition((0...1).contains(probability), "frame probability must be within 0...1")
            allFramesSilent *= 1.0 - Double(probability)
        }
        return Float(1.0 - allFramesSilent)
    }
}
