import Foundation
import MacAmbientJevCore
import MacAmbientJevONNX
import MacAmbientJevPipeline

/// The Linux and Windows counterpart of the Mac `FluidVADSegmentationEngine`: the same
/// segmentation rules driven by Silero VAD probabilities from ONNX Runtime.
actor SileroVADSegmentationEngine: VADChunkSegmenting {
    nonisolated let chunkSize = VADSegmentationParameters.chunkSamples

    private let scorer: SileroChunkScorer
    private var segmenter: VADProbabilitySegmenter
    private let measureMicInputLevels: Bool

    init(
        environment: ONNXEnvironment,
        modelURL: URL,
        intraOpThreads: Int,
        segmentationRunID: String,
        canonicalSampleRate: Double,
        measureMicInputLevels: Bool
    ) throws {
        guard canonicalSampleRate == CanonicalAudio.sampleRate else {
            throw CanonicalAudioError.noncanonicalFormat
        }
        self.scorer = SileroChunkScorer(
            vad: try SileroVAD(
                environment: environment,
                modelURL: modelURL,
                intraOpThreads: intraOpThreads
            )
        )
        self.segmenter = VADProbabilitySegmenter(
            segmentationRunID: segmentationRunID,
            canonicalSampleRate: canonicalSampleRate
        )
        self.measureMicInputLevels = measureMicInputLevels
    }

    func process16kChunk(_ samples: [Float]) async throws -> VADChunkOutput {
        guard !samples.isEmpty else { return VADChunkOutput(segments: [], micLevel: nil) }

        let startSeconds = Double(segmenter.processedSamples) / MicSpeechLevelMeasurement.sampleRate
        let probability = try scorer.speechProbability(chunk: samples)
        let emitted = segmenter.process(samples: samples, probability: probability)

        return VADChunkOutput(
            segments: emitted,
            micLevel: measureMicInputLevels
                ? MicSpeechLevelMeasurement.measure(
                    samples: samples, startSeconds: startSeconds, speechProbability: probability
                )
                : nil
        )
    }

    func finish(totalCanonicalFrames: Int64) async -> [SegmentReference] {
        segmenter.finish(totalCanonicalFrames: totalCanonicalFrames)
    }
}
