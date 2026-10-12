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
}

struct VADSegmentationState: Sendable {
    private let canonicalSampleRate: Double
    private var assembler: SegmentationAssembler
    private var energyHistory: RollingFrameEnergyHistory

    init(segmentationRunID: String, canonicalSampleRate: Double) {
        precondition(canonicalSampleRate == 16_000, "canonicalSampleRate must be 16000")
        self.canonicalSampleRate = canonicalSampleRate
        self.assembler = SegmentationAssembler(
            segmentationRunID: segmentationRunID,
            preRollFrames: Int64(
                (FluidVADSegmentationEngine.preRollSeconds * canonicalSampleRate).rounded()
            ),
            maxSegmentFrames: Int64(
                (FluidVADSegmentationEngine.maxSegmentSeconds * canonicalSampleRate).rounded()
            ),
            minimumIndependentSegmentFrames: Int64(
                (FluidVADSegmentationEngine.minimumIndependentSegmentSeconds * canonicalSampleRate).rounded()
            )
        )
        self.energyHistory = RollingFrameEnergyHistory(
            frameSampleCount: Int(
                (FluidVADSegmentationEngine.splitEnergyFrameSeconds * canonicalSampleRate).rounded()
            ),
            capacity: 150
        )
    }

    mutating func process(
        samples: [Float], event: VadStreamEvent?, processedSamples: Int64
    ) -> [SegmentReference] {
        precondition(samples.count <= VadManager.chunkSize, "samples exceed VadManager.chunkSize")
        let (expectedProcessedSamples, overflow) = energyHistory.processedSamples
            .addingReportingOverflow(Int64(samples.count))
        precondition(
            !overflow && processedSamples == expectedProcessedSamples,
            "processedSamples must equal the appended audio sample count"
        )
        energyHistory.append(samples)

        var emitted: [SegmentReference] = []
        if let event {
            let eventFrame = Int64(event.sampleIndex)
            switch event.kind {
            case .speechStart:
                assembler.speechStarted(atFrame: eventFrame)
            case .speechEnd:
                emitted.append(contentsOf: drainSplits(atFrame: eventFrame))
                emitted.append(contentsOf: assembler.speechEnded(atFrame: eventFrame))
            }
        }
        emitted.append(contentsOf: drainSplits(atFrame: processedSamples))
        return emitted
    }

    mutating func finish(totalCanonicalFrames: Int64) -> [SegmentReference] {
        precondition(
            totalCanonicalFrames == energyHistory.processedSamples,
            "totalCanonicalFrames must equal the appended audio sample count"
        )
        var emitted = drainSplits(atFrame: totalCanonicalFrames)
        emitted.append(contentsOf: assembler.speechEnded(atFrame: totalCanonicalFrames))
        return emitted
    }

    private mutating func drainSplits(atFrame frame: Int64) -> [SegmentReference] {
        let maximumSegmentFrames = Int64(
            (FluidVADSegmentationEngine.maxSegmentSeconds * canonicalSampleRate).rounded()
        )
        let searchWindowFrames = Int64(
            (FluidVADSegmentationEngine.splitSearchWindowSeconds * canonicalSampleRate).rounded()
        )
        var emitted: [SegmentReference] = []
        while let startFrame = assembler.splitStartFrameIfNeeded(atFrame: frame) {
            let maximumEndFrame = startFrame + maximumSegmentFrames
            let searchRange = (maximumEndFrame - searchWindowFrames)..<maximumEndFrame
            let cutFrame = energyHistory.quietestFrame(in: searchRange)
            emitted.append(assembler.split(atFrame: cutFrame))
        }
        return emitted
    }
}

actor FluidVADSegmentationEngine: VADChunkSegmenting {
    static let speechProbabilityThreshold: Float = 0.50
    static let preRollSeconds = 0.10
    static let maxSegmentSeconds = 14.0
    static let minSilenceSeconds = 0.75
    static let splitSearchWindowSeconds = 2.0
    static let splitEnergyFrameSeconds = 0.02
    static let minimumIndependentSegmentSeconds = 0.5
    static let vadConfig = VadConfig(defaultThreshold: speechProbabilityThreshold)
    static let segmentationConfig = VadSegmentationConfig(
        minSpeechDuration: 0,
        minSilenceDuration: minSilenceSeconds,
        maxSpeechDuration: maxSegmentSeconds,
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
            event: result.event,
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
}
