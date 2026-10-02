import FluidAudio
import MacAmbientJevCore

struct VADChunkOutput: Sendable {
    let segments: [SegmentReference]
    let micLevel: MicLevelWindow?
}

/// Speech-gated level evidence for one unpadded 16 kHz VAD chunk.
enum MicSpeechLevelMeasurement {
    static let sampleRate = Double(VadManager.sampleRate)
    static let speechProbabilityThreshold: Float = 0.85

    static func measure(
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

protocol VADChunkSegmenting: Sendable {
    func process16kChunk(_ samples: [Float]) async throws -> VADChunkOutput
    func finish(totalCanonicalFrames: Int64) async -> [SegmentReference]
    func openSpeechRange(upToFrame durableFrame: Int64) async -> OpenSpeechRange?
}

actor FluidVADSegmentationEngine: VADChunkSegmenting {
    private let manager: VadManager
    private var streamState: VadStreamState
    private var assembler: SegmentationAssembler
    private let frameMapper: VADFrameMapper
    private let segmentationConfig: VadSegmentationConfig
    private let measureMicInputLevels: Bool

    static func make(
        segmentationRunID: String,
        canonicalSampleRate: Double,
        measureMicInputLevels: Bool,
        preRollSeconds: Double = 0.10,
        maxSegmentSeconds: Double = 14.0,
        minSilenceSeconds: Double = 0.75
    ) async throws -> FluidVADSegmentationEngine {
        let manager = try await VadManager()
        return FluidVADSegmentationEngine(
            manager: manager,
            segmentationRunID: segmentationRunID,
            canonicalSampleRate: canonicalSampleRate,
            measureMicInputLevels: measureMicInputLevels,
            preRollSeconds: preRollSeconds,
            maxSegmentSeconds: maxSegmentSeconds,
            minSilenceSeconds: minSilenceSeconds
        )
    }

    init(
        manager: VadManager,
        segmentationRunID: String,
        canonicalSampleRate: Double,
        measureMicInputLevels: Bool,
        preRollSeconds: Double,
        maxSegmentSeconds: Double,
        minSilenceSeconds: Double
    ) {
        self.manager = manager
        self.measureMicInputLevels = measureMicInputLevels
        self.streamState = VadStreamState.initial()
        self.frameMapper = VADFrameMapper(canonicalSampleRate: canonicalSampleRate)
        self.assembler = SegmentationAssembler(
            segmentationRunID: segmentationRunID,
            preRollFrames: Int64((preRollSeconds * canonicalSampleRate).rounded()),
            maxSegmentFrames: Int64((maxSegmentSeconds * canonicalSampleRate).rounded()),
            minimumSegmentFrames: Int64(
                (ASRAudioInput.minimumDurationSeconds * canonicalSampleRate).rounded()
            )
        )
        self.segmentationConfig = VadSegmentationConfig(
            minSpeechDuration: 0,
            minSilenceDuration: minSilenceSeconds,
            maxSpeechDuration: maxSegmentSeconds,
            speechPadding: 0
        )
    }

    func process16kChunk(_ samples: [Float]) async throws -> VADChunkOutput {
        guard !samples.isEmpty else { return VADChunkOutput(segments: [], micLevel: nil) }

        let startSeconds = Double(streamState.processedSamples) / MicSpeechLevelMeasurement.sampleRate
        let result = try await manager.processStreamingChunk(
            samples,
            state: streamState,
            config: segmentationConfig
        )
        streamState = result.state

        var emitted: [SegmentReference] = []

        if let event = result.event {
            let frame = frameMapper.canonicalFrame(forVADSample: event.sampleIndex)

            switch event.kind {
            case .speechStart:
                assembler.speechStarted(atFrame: frame)
            case .speechEnd:
                emitted.append(contentsOf: assembler.speechEnded(atFrame: frame))
            }
        }

        let currentFrame = frameMapper.canonicalFrame(forVADSample: streamState.processedSamples)
        if let split = assembler.splitIfNeeded(atFrame: currentFrame) {
            emitted.append(split)
        }

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
        assembler.finish(atFrame: totalCanonicalFrames)
    }

    func openSpeechRange(upToFrame durableFrame: Int64) async -> OpenSpeechRange? {
        assembler.openSpeechRange(upToFrame: durableFrame)
    }

    func reset() {
        streamState = VadStreamState.initial()
    }
}
