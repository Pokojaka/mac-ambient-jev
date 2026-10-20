import MacAmbientJevONNX
import MacAmbientJevPipeline

/// Scores a 4,096-sample chunk like FluidAudio's `silero-vad-unified-256ms-v6.2.1` model:
/// eight consecutive 512-sample frames through one recurrent `SileroVAD`, aggregated by
/// `VADChunkScoring.noisyOR`. The VAD state carries over from one chunk to the next.
struct SileroChunkScorer {
    private static let framesPerChunk = VADSegmentationParameters.chunkSamples / SileroVAD.frameSamples

    private let vad: SileroVAD

    init(vad: SileroVAD) {
        precondition(
            VADSegmentationParameters.chunkSamples.isMultiple(of: SileroVAD.frameSamples),
            "the VAD chunk must be a whole number of Silero frames"
        )
        self.vad = vad
    }

    /// `chunk` may be shorter than a full chunk only for the last one. A failed chunk leaves
    /// the VAD state as it was, so the caller can score the same chunk again.
    func speechProbability(chunk: [Float]) throws -> Float {
        let snapshot = vad.snapshot()
        do {
            return try scoreFrames(of: chunk)
        } catch {
            vad.restore(snapshot)
            throw error
        }
    }

    private func scoreFrames(of chunk: [Float]) throws -> Float {
        let padded = VADChunkScoring.paddedChunk(chunk, to: VADSegmentationParameters.chunkSamples)
        var frameProbabilities: [Float] = []
        frameProbabilities.reserveCapacity(Self.framesPerChunk)
        for frameIndex in 0..<Self.framesPerChunk {
            let start = frameIndex * SileroVAD.frameSamples
            frameProbabilities.append(
                try vad.speechProbability(frame: Array(padded[start..<(start + SileroVAD.frameSamples)]))
            )
        }
        return VADChunkScoring.noisyOR(frameProbabilities)
    }
}
