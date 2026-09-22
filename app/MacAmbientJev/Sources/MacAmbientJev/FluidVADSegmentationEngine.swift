import FluidAudio
import MacAmbientJevCore

actor FluidVADSegmentationEngine {
    private let manager: VadManager
    private var streamState: VadStreamState
    private var assembler: SegmentationAssembler
    private let frameMapper: VADFrameMapper
    private let segmentationConfig: VadSegmentationConfig

    static func make(
        segmentationRunID: String,
        canonicalSampleRate: Double,
        preRollSeconds: Double = 0.10,
        maxSegmentSeconds: Double = 14.0,
        minSilenceSeconds: Double = 0.75
    ) async throws -> FluidVADSegmentationEngine {
        let manager = try await VadManager()
        return FluidVADSegmentationEngine(
            manager: manager,
            segmentationRunID: segmentationRunID,
            canonicalSampleRate: canonicalSampleRate,
            preRollSeconds: preRollSeconds,
            maxSegmentSeconds: maxSegmentSeconds,
            minSilenceSeconds: minSilenceSeconds
        )
    }

    init(
        manager: VadManager,
        segmentationRunID: String,
        canonicalSampleRate: Double,
        preRollSeconds: Double,
        maxSegmentSeconds: Double,
        minSilenceSeconds: Double
    ) {
        self.manager = manager
        self.streamState = VadStreamState.initial()
        self.frameMapper = VADFrameMapper(canonicalSampleRate: canonicalSampleRate)
        self.assembler = SegmentationAssembler(
            segmentationRunID: segmentationRunID,
            preRollFrames: Int64((preRollSeconds * canonicalSampleRate).rounded()),
            maxSegmentFrames: Int64((maxSegmentSeconds * canonicalSampleRate).rounded())
        )
        self.segmentationConfig = VadSegmentationConfig(
            minSpeechDuration: 0,
            minSilenceDuration: minSilenceSeconds,
            maxSpeechDuration: maxSegmentSeconds,
            speechPadding: 0
        )
    }

    func process16kChunk(_ samples: [Float]) async throws -> [SegmentReference] {
        guard !samples.isEmpty else { return [] }

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
                if let segment = assembler.speechEnded(atFrame: frame) {
                    emitted.append(segment)
                }
            }
        }

        let currentFrame = frameMapper.canonicalFrame(forVADSample: streamState.processedSamples)
        if let split = assembler.splitIfNeeded(atFrame: currentFrame) {
            emitted.append(split)
        }

        return emitted
    }

    func finish(totalCanonicalFrames: Int64) -> [SegmentReference] {
        guard let segment = assembler.finish(atFrame: totalCanonicalFrames) else {
            return []
        }
        return [segment]
    }

    func reset() {
        streamState = VadStreamState.initial()
    }
}
