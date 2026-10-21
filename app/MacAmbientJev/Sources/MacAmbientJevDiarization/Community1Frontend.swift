// Pinned to FluidAudio 0.15.8, revision 87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc.
import Foundation

/// Invalid input to the fixed Community-1 frontend.
public enum FrontendError: Error, CustomStringConvertible {
    case invalidInput(String)

    public var description: String {
        switch self {
        case .invalidInput(let message):
            return "Invalid Community-1 frontend input: \(message)"
        }
    }
}

/// Frame-major powerset log probabilities for one Community-1 window.
public struct PowersetScores: Sendable {
    let values: [Float]

    public init(logProbabilities: [Float]) throws {
        let expectedCount = Community1Profile.segmentationFrames * Community1Profile.powersetClasses
        guard logProbabilities.count == expectedCount else {
            throw FrontendError.invalidInput(
                "logProbabilities must contain exactly \(expectedCount) values; got \(logProbabilities.count)"
            )
        }
        for (index, value) in logProbabilities.enumerated() where !value.isFinite {
            throw FrontendError.invalidInput("logProbabilities[\(index)] must be finite")
        }
        values = logProbabilities
    }
}

struct LocalActivity: Sendable {
    let speakerBits: [UInt8]

    fileprivate init(speakerBits: [UInt8]) {
        self.speakerBits = speakerBits
    }
}

/// Cleaned per-frame activity of one speaker slot, at segmentation resolution.
public struct ActivityMask: Sendable {
    public let values: [Float]

    init(values: [Float]) throws {
        guard values.count == Community1Profile.segmentationFrames else {
            throw FrontendError.invalidInput(
                "activity mask must contain exactly \(Community1Profile.segmentationFrames) values; got \(values.count)"
            )
        }
        for (index, value) in values.enumerated() {
            guard value.isFinite else {
                throw FrontendError.invalidInput("activity mask[\(index)] must be finite")
            }
            guard (0...1).contains(value) else {
                throw FrontendError.invalidInput("activity mask[\(index)] must be in 0...1")
            }
        }
        self.values = values
    }
}

/// Mask sampled at the embedding graph's pooling positions.
public struct PoolingMask: Sendable {
    public let values: [Float]

    fileprivate init(mappedValues: [Float]) {
        values = mappedValues
    }
}

struct SelectedSpeakerMask: Sendable {
    let speakerIndex: Int
    let mask: ActivityMask
    let startFrame: Int
    let endFrame: Int
}

/// A zero-padded Community-1 analysis window and its real input extent.
public struct WindowAudio: Sendable {
    public let samples: [Float]
    public let startFrame: Int64
    public let availableSampleCount: Int

    fileprivate init(samples: [Float], startFrame: Int64, availableSampleCount: Int) {
        self.samples = samples
        self.startFrame = startFrame
        self.availableSampleCount = availableSampleCount
    }
}

struct Community1WindowPlan: Sendable {
    let sampleCount: Int64
    let count: Int

    init(sampleCount: Int64) throws {
        guard sampleCount >= 0 else {
            throw FrontendError.invalidInput("sampleCount must be nonnegative")
        }
        self.sampleCount = sampleCount
        guard sampleCount > 0 else {
            count = 0
            return
        }

        let stepSamples = Int64(Community1Profile.stepSamples)
        guard let finalStart = DiarizationFinalWindowPadding.finalWindowStartFrame(
            sampleCount: sampleCount,
            stepSamples: stepSamples
        ) else {
            throw FrontendError.invalidInput("sampleCount and stepSamples do not define a final window")
        }
        // FluidAudio 0.15.8 schedules step-offset windows and pads the tail: OfflineSegmentationProcessor.swift:118-190.
        let windowCount = finalStart / stepSamples + 1
        guard let exactCount = Int(exactly: windowCount) else {
            throw FrontendError.invalidInput("window count exceeds Int range")
        }
        count = exactCount
    }

    func startFrame(at index: Int) throws -> Int64 {
        guard index >= 0, index < count else {
            throw FrontendError.invalidInput("window index \(index) is outside 0..<\(count)")
        }
        guard let exactIndex = Int64(exactly: index) else {
            throw FrontendError.invalidInput("window index \(index) exceeds Int64 range")
        }
        let (start, overflow) = exactIndex.multipliedReportingOverflow(
            by: Int64(Community1Profile.stepSamples)
        )
        guard !overflow, start < sampleCount else {
            throw FrontendError.invalidInput("window start for index \(index) is outside the audio")
        }
        return start
    }

    func window(
        at index: Int,
        readFrames: (Range<Int64>) throws -> [Float]
    ) throws -> WindowAudio {
        try Task.checkCancellation()
        let start = try startFrame(at: index)
        let available = min(Int64(Community1Profile.windowSamples), sampleCount - start)
        guard let availableCount = Int(exactly: available) else {
            throw FrontendError.invalidInput("available samples for window \(index) exceed Int range")
        }
        let end = start + available
        var samples = try readFrames(start..<end)
        guard samples.count == availableCount else {
            throw FrontendError.invalidInput(
                "window \(index) reader returned \(samples.count) samples; expected \(availableCount)"
            )
        }
        for (sampleIndex, sample) in samples.enumerated() where !sample.isFinite {
            throw FrontendError.invalidInput("window \(index) sample[\(sampleIndex)] must be finite")
        }
        samples.append(contentsOf: repeatElement(
            Float.zero,
            count: Community1Profile.windowSamples - availableCount
        ))
        return WindowAudio(
            samples: samples,
            startFrame: start,
            availableSampleCount: availableCount
        )
    }
}

internal enum Community1Frontend {
    /// Strict-`>` argmax preserves the earliest class on ties, matching FluidAudio's decoder.
    static func decode(_ scores: PowersetScores) -> LocalActivity {
        // FluidAudio 0.15.8: OfflineSegmentationProcessor.swift:327-399.
        var speakerBits = [UInt8](repeating: 0, count: Community1Profile.segmentationFrames)
        for frame in 0..<Community1Profile.segmentationFrames {
            let rowStart = frame * Community1Profile.powersetClasses
            var bestClass = 0
            var bestValue = -Float.greatestFiniteMagnitude
            for classIndex in 0..<Community1Profile.powersetClasses {
                let value = scores.values[rowStart + classIndex]
                if value > bestValue {
                    bestValue = value
                    bestClass = classIndex
                }
            }
            speakerBits[frame] = Community1Profile.powersetSpeakerBits[bestClass]
        }
        return LocalActivity(speakerBits: speakerBits)
    }

    static func selectMasks(speakerWeights: [[Float]]) throws -> [SelectedSpeakerMask] {
        guard speakerWeights.count == Community1Profile.segmentationFrames else {
            throw FrontendError.invalidInput(
                "speakerWeights must contain exactly \(Community1Profile.segmentationFrames) frames; got \(speakerWeights.count)"
            )
        }
        for (frame, row) in speakerWeights.enumerated() {
            guard row.count == Community1Profile.localSpeakers else {
                throw FrontendError.invalidInput(
                    "speakerWeights[\(frame)] must contain exactly \(Community1Profile.localSpeakers) speakers; got \(row.count)"
                )
            }
            for (speaker, value) in row.enumerated() {
                guard value.isFinite else {
                    throw FrontendError.invalidInput("speakerWeights[\(frame)][\(speaker)] must be finite")
                }
                guard (0...1).contains(value) else {
                    throw FrontendError.invalidInput("speakerWeights[\(frame)][\(speaker)] must be in 0...1")
                }
            }
        }

        // FluidAudio's frame-duration gate and clean-mask gate: OfflineEmbeddingExtractor.swift:381-386,431-535.
        let minimumCleanWeight = Float(Community1Profile.segmentationFrames)
            * Community1Profile.minimumActiveRatio
        guard Float(Community1Profile.minimumEmbeddingFrames) <= minimumCleanWeight else {
            throw FrontendError.invalidInput(
                "minimum embedding-frame gate exceeds the clean-mask acceptance threshold"
            )
        }

        var overlapFrames = [Bool](repeating: false, count: Community1Profile.segmentationFrames)
        for frame in 0..<Community1Profile.segmentationFrames {
            var activeSpeakers = 0
            for speaker in 0..<Community1Profile.localSpeakers
                where speakerWeights[frame][speaker] > Community1Profile.overlapThreshold {
                activeSpeakers += 1
            }
            overlapFrames[frame] = activeSpeakers > 1
        }

        var selected: [SelectedSpeakerMask] = []
        for speaker in 0..<Community1Profile.localSpeakers {
            var baseMask = [Float](repeating: 0, count: Community1Profile.segmentationFrames)
            for frame in 0..<Community1Profile.segmentationFrames {
                baseMask[frame] = speakerWeights[frame][speaker]
            }
            let baseSum = baseMask.reduce(Float.zero, +)
            guard baseSum > 0 else { continue }

            var cleanMask = baseMask
            for frame in 0..<Community1Profile.segmentationFrames where overlapFrames[frame] {
                cleanMask[frame] = 0
            }
            let cleanSum = cleanMask.reduce(Float.zero, +)
            guard cleanSum >= minimumCleanWeight else { continue }

            let firstFrame = cleanMask.firstIndex(where: { $0 > Community1Profile.overlapThreshold })
            let lastFrame = cleanMask.lastIndex(where: { $0 > Community1Profile.overlapThreshold })
            guard let firstFrame, let lastFrame else {
                throw FrontendError.invalidInput(
                    "accepted clean mask for speaker \(speaker) has no active frame above overlapThreshold"
                )
            }
            selected.append(
                SelectedSpeakerMask(
                    speakerIndex: speaker,
                    mask: try ActivityMask(values: cleanMask),
                    startFrame: firstFrame,
                    endFrame: lastFrame
                )
            )
        }
        // Clean masks and inclusive active bounds follow FluidAudio's embedding path.
        // FluidAudio 0.15.8: OfflineEmbeddingExtractor.swift:431-535,587-602.
        return selected
    }

    static func selectMasks(_ activity: LocalActivity) throws -> [SelectedSpeakerMask] {
        guard activity.speakerBits.count == Community1Profile.segmentationFrames else {
            throw FrontendError.invalidInput(
                "speakerBits must contain exactly \(Community1Profile.segmentationFrames) frames; got \(activity.speakerBits.count)"
            )
        }
        var speakerWeights = Array(
            repeating: Array(repeating: Float.zero, count: Community1Profile.localSpeakers),
            count: Community1Profile.segmentationFrames
        )
        for (frame, bits) in activity.speakerBits.enumerated() {
            let maximumSpeakerBits = UInt8((1 << Community1Profile.localSpeakers) - 1)
            guard bits <= maximumSpeakerBits else {
                throw FrontendError.invalidInput(
                    "speakerBits[\(frame)] must be a powerset value from 0 through \(maximumSpeakerBits)"
                )
            }
            for speaker in 0..<Community1Profile.localSpeakers
                where bits & (UInt8(1) << UInt8(speaker)) != 0 {
                speakerWeights[frame][speaker] = 1
            }
        }
        return try selectMasks(speakerWeights: speakerWeights)
    }

    /// Applies the embedding graph's align-corners sampling positions, then scatters them
    /// into its integer-indexed pooling slots. Graph precision is separate from this geometry.
    static func poolingMask(_ mask: ActivityMask) -> PoolingMask {
        // Pooling equation: probe-report.md, probe2 Embedding.mlmodelc/model.mil:7-17.
        var mappedValues = [Float](repeating: 0, count: Community1Profile.segmentationFrames)
        for pooledIndex in 0..<Community1Profile.poolingFrames {
            let coordinate = Double(pooledIndex) * Double(Community1Profile.segmentationFrames - 1)
                / Double(Community1Profile.poolingFrames - 1)
            let leftIndex = Int(coordinate.rounded(.down))
            let rightIndex = min(leftIndex + 1, Community1Profile.segmentationFrames - 1)
            let rightWeight = Float(coordinate - Double(leftIndex))
            let leftWeight = 1 - rightWeight
            let sampledValue = mask.values[leftIndex] * leftWeight + mask.values[rightIndex] * rightWeight
            let scatterIndex = pooledIndex * Community1Profile.segmentationFrames
                / Community1Profile.poolingFrames
            mappedValues[scatterIndex] = sampledValue
        }
        return PoolingMask(mappedValues: mappedValues)
    }
}
