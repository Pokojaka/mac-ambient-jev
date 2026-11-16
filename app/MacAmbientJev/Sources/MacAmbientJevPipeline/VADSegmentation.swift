import MacAmbientJevCore

/// Segmentation parameters shared by every VAD engine, so each platform cuts the same
/// segments from the same speech probabilities.
public enum VADSegmentationParameters {
    /// New samples per VAD probability (256 ms at 16 kHz).
    public static let chunkSamples = 4_096
    public static let speechProbabilityThreshold: Float = 0.50
    public static let preRollSeconds = 0.10
    public static let maxSpeechRangeSeconds = 14.0
    public static let maxSegmentSpanSeconds = ASRAudioInput.maximumDurationSeconds
    public static let minSilenceSeconds = 0.75
    public static let splitSearchWindowSeconds = 2.0
    public static let splitEnergyFrameSeconds = 0.02
    public static let minimumIndependentSpeechRangeSeconds = 0.5

    internal static var maximumSpeechEndLagFrames: Int64 {
        Int64((minSilenceSeconds * CanonicalAudio.sampleRate).rounded()) + 2 * Int64(chunkSamples)
    }

    public static var provenanceConfiguration: [String: String] {
        [
            "pre_roll_seconds": String(preRollSeconds),
            "max_speech_range_seconds": String(maxSpeechRangeSeconds),
            "max_segment_span_seconds": String(maxSegmentSpanSeconds),
            "min_silence_seconds": String(minSilenceSeconds),
            "vad_threshold": String(speechProbabilityThreshold),
            "split_search_window_seconds": String(splitSearchWindowSeconds),
            "split_energy_frame_seconds": String(splitEnergyFrameSeconds),
            "minimum_independent_speech_range_seconds": String(minimumIndependentSpeechRangeSeconds),
        ]
    }
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

/// Turns VAD stream events and audio into speech ranges and bounded-span segments.
public struct VADSegmentationState: Sendable {
    private let canonicalSampleRate: Double
    private var assembler: SpeechRangeAssembler
    private var grouper: SegmentGrouper
    private var energyHistory: RollingFrameEnergyHistory

    public init(segmentationRunID: String, canonicalSampleRate: Double) {
        precondition(canonicalSampleRate == 16_000, "canonicalSampleRate must be 16000")
        self.canonicalSampleRate = canonicalSampleRate
        self.assembler = SpeechRangeAssembler(
            preRollFrames: Int64(
                (VADSegmentationParameters.preRollSeconds * canonicalSampleRate).rounded()
            ),
            maxSpeechRangeFrames: Int64(
                (VADSegmentationParameters.maxSpeechRangeSeconds * canonicalSampleRate).rounded()
            ),
            minimumIndependentSpeechRangeFrames: Int64(
                (VADSegmentationParameters.minimumIndependentSpeechRangeSeconds * canonicalSampleRate).rounded()
            )
        )
        self.grouper = SegmentGrouper(
            segmentationRunID: segmentationRunID,
            maximumSpanFrames: Int64(
                (VADSegmentationParameters.maxSegmentSpanSeconds * canonicalSampleRate).rounded()
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

        var ranges: [Range<Int64>] = []
        if let event {
            let eventFrame = Int64(event.sampleIndex)
            switch event.kind {
            case .speechStart:
                assembler.speechStarted(atFrame: eventFrame)
            case .speechEnd:
                ranges.append(contentsOf: drainSplits(atFrame: eventFrame))
                if let range = assembler.speechEnded(atFrame: eventFrame) {
                    ranges.append(range)
                }
            }
        }
        ranges.append(contentsOf: drainSplits(atFrame: processedSamples))

        var emitted = append(ranges)
        if let segment = grouper.settle(atFrame: settledFrame(processedSamples)) {
            emitted.append(segment)
        }
        return emitted
    }

    public mutating func finish(totalCanonicalFrames: Int64) -> [SegmentReference] {
        precondition(
            totalCanonicalFrames == energyHistory.processedSamples,
            "totalCanonicalFrames must equal the appended audio sample count"
        )
        var ranges = drainSplits(atFrame: totalCanonicalFrames)
        if let range = assembler.speechEnded(atFrame: totalCanonicalFrames) {
            ranges.append(range)
        }
        var emitted = append(ranges)
        if let segment = grouper.finish() {
            emitted.append(segment)
        }
        return emitted
    }

    private mutating func append(_ ranges: [Range<Int64>]) -> [SegmentReference] {
        var emitted: [SegmentReference] = []
        for range in ranges {
            if let segment = grouper.append(range) {
                emitted.append(segment)
            }
        }
        return emitted
    }

    private func settledFrame(_ processedSamples: Int64) -> Int64 {
        guard let activeStart = assembler.activeStartFrame else {
            return processedSamples - assembler.preRollFrames
        }
        let searchWindowFrames = Int64(
            (VADSegmentationParameters.splitSearchWindowSeconds * canonicalSampleRate).rounded()
        )
        // This is only a heuristic margin, not a bound on future speech-range ends. A later
        // range is appended after settlement and therefore belongs to the next segment.
        return max(
            activeStart,
            min(
                processedSamples - VADSegmentationParameters.maximumSpeechEndLagFrames,
                activeStart + assembler.maxSpeechRangeFrames - searchWindowFrames
            )
        )
    }

    private mutating func drainSplits(atFrame frame: Int64) -> [Range<Int64>] {
        let searchWindowFrames = Int64(
            (VADSegmentationParameters.splitSearchWindowSeconds * canonicalSampleRate).rounded()
        )
        var ranges: [Range<Int64>] = []
        while let startFrame = assembler.splitStartFrameIfNeeded(atFrame: frame) {
            let maximumEndFrame = startFrame + assembler.maxSpeechRangeFrames
            let searchRange = (maximumEndFrame - searchWindowFrames)..<maximumEndFrame
            let cutFrame = energyHistory.quietestFrame(in: searchRange)
            ranges.append(assembler.split(atFrame: cutFrame))
        }
        return ranges
    }
}
