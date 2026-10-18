import MacAmbientJevCore

/// Segmentation parameters shared by every VAD engine, so each platform cuts the same
/// segments from the same speech probabilities.
public enum VADSegmentationParameters {
    /// New samples per VAD probability (256 ms at 16 kHz).
    public static let chunkSamples = 4_096
    public static let speechProbabilityThreshold: Float = 0.50
    public static let preRollSeconds = 0.10
    public static let maxSegmentSeconds = 14.0
    public static let minSilenceSeconds = 0.75
    public static let splitSearchWindowSeconds = 2.0
    public static let splitEnergyFrameSeconds = 0.02
    public static let minimumIndependentSegmentSeconds = 0.5
}

public struct VADStreamEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case speechStart
        case speechEnd
    }

    public let kind: Kind
    public let sampleIndex: Int

    public init(kind: Kind, sampleIndex: Int) {
        self.kind = kind
        self.sampleIndex = sampleIndex
    }
}

/// Turns VAD stream events and the audio they refer to into segments: pre-roll, the 14 s
/// split at the quietest frame, and the minimum length of an independent segment.
public struct VADSegmentationState: Sendable {
    private let canonicalSampleRate: Double
    private var assembler: SegmentationAssembler
    private var energyHistory: RollingFrameEnergyHistory

    public init(segmentationRunID: String, canonicalSampleRate: Double) {
        precondition(canonicalSampleRate == 16_000, "canonicalSampleRate must be 16000")
        self.canonicalSampleRate = canonicalSampleRate
        self.assembler = SegmentationAssembler(
            segmentationRunID: segmentationRunID,
            preRollFrames: Int64(
                (VADSegmentationParameters.preRollSeconds * canonicalSampleRate).rounded()
            ),
            maxSegmentFrames: Int64(
                (VADSegmentationParameters.maxSegmentSeconds * canonicalSampleRate).rounded()
            ),
            minimumIndependentSegmentFrames: Int64(
                (VADSegmentationParameters.minimumIndependentSegmentSeconds * canonicalSampleRate).rounded()
            )
        )
        self.energyHistory = RollingFrameEnergyHistory(
            frameSampleCount: Int(
                (VADSegmentationParameters.splitEnergyFrameSeconds * canonicalSampleRate).rounded()
            ),
            capacity: 150
        )
    }

    public mutating func process(
        samples: [Float], event: VADStreamEvent?, processedSamples: Int64
    ) -> [SegmentReference] {
        precondition(
            samples.count <= VADSegmentationParameters.chunkSamples,
            "samples exceed VADSegmentationParameters.chunkSamples"
        )
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

    public mutating func finish(totalCanonicalFrames: Int64) -> [SegmentReference] {
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
            (VADSegmentationParameters.maxSegmentSeconds * canonicalSampleRate).rounded()
        )
        let searchWindowFrames = Int64(
            (VADSegmentationParameters.splitSearchWindowSeconds * canonicalSampleRate).rounded()
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
