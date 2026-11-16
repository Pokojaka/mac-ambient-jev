import Foundation

public struct SegmentReference: Sendable, Equatable {
    public let segmentationRunID: String
    public let segmentID: String
    public let speechRanges: [Range<Int64>]
    public var startFrame: Int64 { speechRanges[0].lowerBound }
    public var endFrame: Int64 { speechRanges[speechRanges.count - 1].upperBound }

    public init(segmentationRunID: String, segmentID: String, speechRanges: [Range<Int64>]) {
        precondition(Self.isValid(speechRanges), "speechRanges must be ordered, nonempty, and within the maximum duration")
        self.segmentationRunID = segmentationRunID
        self.segmentID = segmentID
        self.speechRanges = speechRanges
    }

    public static func isValid(_ speechRanges: [Range<Int64>]) -> Bool {
        guard let first = speechRanges.first, let last = speechRanges.last else { return false }
        var previousUpperBound: Int64?
        for range in speechRanges {
            guard range.lowerBound >= 0, range.lowerBound < range.upperBound else { return false }
            if let previousUpperBound, range.lowerBound < previousUpperBound { return false }
            previousUpperBound = range.upperBound
        }
        return last.upperBound - first.lowerBound
            <= Int64(ASRAudioInput.maximumDurationSeconds * CanonicalAudio.sampleRate)
    }
}

public struct RollingFrameEnergyHistory: Sendable {
    public let frameSampleCount: Int
    public let capacity: Int
    public private(set) var processedSamples: Int64 = 0
    public var storedFrameCount: Int { storedEnergyCount }

    private var frameEnergies: [Double]
    private var nextWriteIndex = 0
    private var storedEnergyCount = 0
    private var completedFrameCount: Int64 = 0
    private var partialFrameSumSquares = 0.0
    private var partialFrameSampleCount = 0

    public init(frameSampleCount: Int, capacity: Int) {
        precondition(frameSampleCount > 0 && frameSampleCount.isMultiple(of: 2), "frameSampleCount must be positive and even")
        precondition(Int64(exactly: frameSampleCount) != nil, "frameSampleCount must fit in Int64")
        precondition(capacity > 0, "capacity must be positive")
        self.frameSampleCount = frameSampleCount
        self.capacity = capacity
        self.frameEnergies = Array(repeating: 0, count: capacity)
    }

    public mutating func append(_ samples: [Float]) {
        guard let appendedSampleCount = Int64(exactly: samples.count) else {
            preconditionFailure("サンプル数が Int64 の範囲を超えています")
        }
        precondition(appendedSampleCount <= Int64.max - processedSamples, "処理済みサンプル数が Int64 の範囲を超えます")

        for sample in samples {
            precondition(sample.isFinite, "samples must contain only finite values")
            let value = Double(sample)
            partialFrameSumSquares += value * value
            partialFrameSampleCount += 1

            if partialFrameSampleCount == frameSampleCount {
                frameEnergies[nextWriteIndex] = sqrt(partialFrameSumSquares / Double(frameSampleCount))
                nextWriteIndex = (nextWriteIndex + 1) % capacity
                storedEnergyCount = min(storedEnergyCount + 1, capacity)
                completedFrameCount += 1
                partialFrameSumSquares = 0
                partialFrameSampleCount = 0
            }
        }
        processedSamples += appendedSampleCount
    }

    public func quietestFrame(in range: Range<Int64>) -> Int64 {
        precondition(range.lowerBound >= 0 && range.lowerBound < range.upperBound, "range must be nonnegative and nonempty")
        precondition(range.upperBound <= processedSamples, "range must not extend beyond processed samples")
        precondition(storedEnergyCount > 0, "range must include retained complete frames")

        let frameSize = Int64(frameSampleCount)
        let earliestRetainedFrameIndex = completedFrameCount - Int64(storedEnergyCount)
        let earliestRetainedFrameStart = earliestRetainedFrameIndex * frameSize
        precondition(range.lowerBound >= earliestRetainedFrameStart, "range begins before the earliest retained frame")

        let firstCandidateFrameIndex = range.lowerBound / frameSize + (range.lowerBound.isMultiple(of: frameSize) ? 0 : 1)
        let endCandidateFrameIndex = range.upperBound / frameSize
        precondition(firstCandidateFrameIndex < endCandidateFrameIndex, "range must contain a complete aligned frame")
        precondition(firstCandidateFrameIndex >= earliestRetainedFrameIndex, "candidate frame is no longer retained")
        precondition(endCandidateFrameIndex <= completedFrameCount, "candidate frame is incomplete")

        let oldestRingIndex = storedEnergyCount == capacity ? nextWriteIndex : 0
        let firstRingIndex = (oldestRingIndex + Int(firstCandidateFrameIndex - earliestRetainedFrameIndex)) % capacity
        let candidateCount = Int(endCandidateFrameIndex - firstCandidateFrameIndex)
        var quietestFrameIndex = firstCandidateFrameIndex
        var quietestEnergy = frameEnergies[firstRingIndex]

        if candidateCount > 1 {
            for offset in 1..<candidateCount {
                let ringIndex = (firstRingIndex + offset) % capacity
                let energy = frameEnergies[ringIndex]
                if energy < quietestEnergy {
                    quietestEnergy = energy
                    quietestFrameIndex = firstCandidateFrameIndex + Int64(offset)
                }
            }
        }

        return quietestFrameIndex * frameSize + frameSize / 2
    }
}

public struct SpeechRangeAssembler: Sendable {
    public let preRollFrames: Int64
    public let maxSpeechRangeFrames: Int64
    public let minimumIndependentSpeechRangeFrames: Int64
    public private(set) var activeStartFrame: Int64?

    private var activeIsContinuation = false

    public init(
        preRollFrames: Int64,
        maxSpeechRangeFrames: Int64,
        minimumIndependentSpeechRangeFrames: Int64
    ) {
        precondition(preRollFrames >= 0, "preRollFrames must not be negative")
        precondition(maxSpeechRangeFrames > 0, "maxSpeechRangeFrames must be positive")
        precondition(minimumIndependentSpeechRangeFrames >= 0, "minimumIndependentSpeechRangeFrames must not be negative")
        self.preRollFrames = preRollFrames
        self.maxSpeechRangeFrames = maxSpeechRangeFrames
        self.minimumIndependentSpeechRangeFrames = minimumIndependentSpeechRangeFrames
    }

    public mutating func speechStarted(atFrame frame: Int64) {
        guard activeStartFrame == nil else { return }
        activeStartFrame = frame <= preRollFrames ? 0 : frame - preRollFrames
        activeIsContinuation = false
    }

    public mutating func speechEnded(atFrame frame: Int64) -> Range<Int64>? {
        precondition(
            splitStartFrameIfNeeded(atFrame: frame) == nil,
            "最大区間長に達した場合は、選択した cutFrame で先に split(atFrame:) を呼び出してください"
        )

        let start = activeStartFrame
        let isContinuation = activeIsContinuation
        activeStartFrame = nil
        activeIsContinuation = false
        guard let start, frame > start,
              isContinuation || frame - start >= minimumIndependentSpeechRangeFrames else {
            return nil
        }
        return start..<frame
    }

    public func splitStartFrameIfNeeded(atFrame frame: Int64) -> Int64? {
        guard let start = activeStartFrame, frame >= start else { return nil }
        let elapsed = frame.subtractingReportingOverflow(start)
        return elapsed.overflow || elapsed.partialValue >= maxSpeechRangeFrames ? start : nil
    }

    public mutating func split(atFrame cutFrame: Int64) -> Range<Int64> {
        guard let start = activeStartFrame else {
            preconditionFailure("split(atFrame:) には有効な音声区間が必要です")
        }
        let maximumEnd = start.addingReportingOverflow(maxSpeechRangeFrames)
        precondition(
            start < cutFrame && (maximumEnd.overflow || cutFrame <= maximumEnd.partialValue),
            "cutFrame は現在の開始位置より後で最大区間長以内でなければなりません"
        )

        activeStartFrame = cutFrame
        activeIsContinuation = true
        return start..<cutFrame
    }
}

/// Groups currently available speech ranges into bounded-span segments. `settle(atFrame:)` releases a group heuristically, without promising anything about future range ends; ranges appended after a close begin a new segment.
public struct SegmentGrouper: Sendable {
    public let segmentationRunID: String
    public let maximumSpanFrames: Int64
    private var open: [Range<Int64>] = []
    private var nextSegmentIndex: UInt64 = 1

    public init(segmentationRunID: String, maximumSpanFrames: Int64) {
        precondition(maximumSpanFrames > 0, "maximumSpanFrames must be positive")
        precondition(maximumSpanFrames <= Int64(ASRAudioInput.maximumDurationSeconds * CanonicalAudio.sampleRate), "maximumSpanFrames must not exceed the maximum duration")
        self.segmentationRunID = segmentationRunID
        self.maximumSpanFrames = maximumSpanFrames
    }

    public mutating func append(_ range: Range<Int64>) -> SegmentReference? {
        precondition(range.lowerBound >= 0 && range.lowerBound < range.upperBound, "range must be nonnegative and nonempty")
        precondition(range.upperBound - range.lowerBound <= maximumSpanFrames, "range must not exceed maximumSpanFrames")
        if let first = open.first, range.upperBound - first.lowerBound > maximumSpanFrames {
            let segment = close()
            open = [range]
            return segment
        }
        open.append(range)
        return nil
    }

    public mutating func settle(atFrame frame: Int64) -> SegmentReference? {
        guard let first = open.first, frame >= first.lowerBound,
              frame - first.lowerBound >= maximumSpanFrames else { return nil }
        return close()
    }

    public mutating func finish() -> SegmentReference? { close() }

    private mutating func close() -> SegmentReference? {
        guard !open.isEmpty else { return nil }
        let segment = SegmentReference(
            segmentationRunID: segmentationRunID,
            segmentID: String(format: "seg_%06llu", nextSegmentIndex),
            speechRanges: open
        )
        open = []
        nextSegmentIndex &+= 1
        return segment
    }
}
