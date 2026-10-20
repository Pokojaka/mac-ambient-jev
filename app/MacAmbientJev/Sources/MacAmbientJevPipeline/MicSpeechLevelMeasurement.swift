import MacAmbientJevCore

/// Speech-gated level evidence for one unpadded 16 kHz VAD chunk.
public enum MicSpeechLevelMeasurement {
    public static let sampleRate = CanonicalAudio.sampleRate
    public static let speechProbabilityThreshold: Float = 0.85

    public static func measure(
        samples: [Float], startSeconds: Double, speechProbability: Float
    ) -> MicLevelWindow {
        let seconds = Double(samples.count) / sampleRate
        let nonSpeech = MicLevelWindow(
            startSeconds: startSeconds, endSeconds: startSeconds + seconds,
            speechSeconds: 0, speechMeanSquare: nil, speechPeak: 0,
            inputPeak: 0, clippedFraction: 0
        )
        guard !samples.isEmpty, startSeconds.isFinite, startSeconds >= 0,
              speechProbability.isFinite, speechProbability <= 1,
              speechProbability >= speechProbabilityThreshold else { return nonSpeech }
        var sumOfSquares = 0.0
        var peak: Float = 0
        for sample in samples {
            guard sample.isFinite else { return nonSpeech }
            let value = Double(sample)
            sumOfSquares += value * value
            peak = max(peak, abs(sample))
        }
        guard peak > 0 else { return nonSpeech }
        return MicLevelWindow(
            startSeconds: startSeconds, endSeconds: startSeconds + seconds,
            speechSeconds: seconds, speechMeanSquare: sumOfSquares / Double(samples.count),
            speechPeak: peak, inputPeak: 0, clippedFraction: 0
        )
    }
}
