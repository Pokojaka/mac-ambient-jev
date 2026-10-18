import FluidAudio
import MacAmbientJevCore
import MacAmbientJevPipeline

actor FluidVADSegmentationEngine: VADChunkSegmenting {
    nonisolated let chunkSize = VadManager.chunkSize

    static let vadConfig = VadConfig(
        defaultThreshold: VADSegmentationParameters.speechProbabilityThreshold
    )
    static let segmentationConfig = VadSegmentationConfig(
        minSpeechDuration: 0,
        minSilenceDuration: VADSegmentationParameters.minSilenceSeconds,
        maxSpeechDuration: VADSegmentationParameters.maxSegmentSeconds,
        speechPadding: 0
    )

    private let manager: VadManager
    private var streamState: VadStreamState
    private var segmentationState: VADSegmentationState
    private let measureMicInputLevels: Bool

    static func make(
        segmentationRunID: String,
        canonicalSampleRate: Double,
        measureMicInputLevels: Bool
    ) async throws -> FluidVADSegmentationEngine {
        guard canonicalSampleRate == CanonicalAudio.sampleRate,
              Double(VadManager.sampleRate) == CanonicalAudio.sampleRate else {
            throw CanonicalAudioError.noncanonicalFormat
        }
        let manager = try await VadManager(config: Self.vadConfig)
        return FluidVADSegmentationEngine(
            manager: manager,
            segmentationRunID: segmentationRunID,
            canonicalSampleRate: canonicalSampleRate,
            measureMicInputLevels: measureMicInputLevels
        )
    }

    init(
        manager: VadManager,
        segmentationRunID: String,
        canonicalSampleRate: Double,
        measureMicInputLevels: Bool
    ) {
        self.manager = manager
        self.measureMicInputLevels = measureMicInputLevels
        self.streamState = VadStreamState.initial()
        self.segmentationState = VADSegmentationState(
            segmentationRunID: segmentationRunID,
            canonicalSampleRate: canonicalSampleRate
        )
    }

    func process16kChunk(_ samples: [Float]) async throws -> VADChunkOutput {
        guard !samples.isEmpty else { return VADChunkOutput(segments: [], micLevel: nil) }

        let startSeconds = Double(streamState.processedSamples) / MicSpeechLevelMeasurement.sampleRate
        let result = try await manager.processStreamingChunk(
            samples,
            state: streamState,
            config: Self.segmentationConfig
        )
        streamState = result.state
        let emitted = segmentationState.process(
            samples: samples,
            event: result.event.map(Self.streamEvent),
            processedSamples: Int64(streamState.processedSamples)
        )

        return VADChunkOutput(
            segments: emitted,
            micLevel: measureMicInputLevels
                ? MicSpeechLevelMeasurement.measure(
                    samples: samples, startSeconds: startSeconds,
                    speechProbability: result.probability
                )
                : nil
        )
    }

    func finish(totalCanonicalFrames: Int64) async -> [SegmentReference] {
        segmentationState.finish(totalCanonicalFrames: totalCanonicalFrames)
    }

    private static func streamEvent(_ event: VadStreamEvent) -> VADStreamEvent {
        VADStreamEvent(
            kind: event.isStart ? .speechStart : .speechEnd,
            sampleIndex: event.sampleIndex
        )
    }
}
