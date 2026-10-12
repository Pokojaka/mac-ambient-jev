import Foundation

public struct SegmentReference: Codable, Sendable, Equatable {
    public let segmentationRunID: String
    public let segmentID: String
    public let startFrame: Int64
    public let endFrame: Int64

    public init(segmentationRunID: String, segmentID: String, startFrame: Int64, endFrame: Int64) {
        self.segmentationRunID = segmentationRunID
        self.segmentID = segmentID
        self.startFrame = startFrame
        self.endFrame = endFrame
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

public struct SegmentationAssembler: Sendable {
    public let segmentationRunID: String
    public let preRollFrames: Int64
    public let maxSegmentFrames: Int64
    public let minimumIndependentSegmentFrames: Int64

    private var activeStartFrame: Int64?
    private var activeIsContinuation = false
    private var nextSegmentIndex: UInt64 = 1

    public init(
        segmentationRunID: String,
        preRollFrames: Int64,
        maxSegmentFrames: Int64,
        minimumIndependentSegmentFrames: Int64
    ) {
        precondition(preRollFrames >= 0, "preRollFrames must not be negative")
        precondition(maxSegmentFrames > 0, "maxSegmentFrames must be positive")
        precondition(minimumIndependentSegmentFrames >= 0, "minimumIndependentSegmentFrames must not be negative")
        self.segmentationRunID = segmentationRunID
        self.preRollFrames = preRollFrames
        self.maxSegmentFrames = maxSegmentFrames
        self.minimumIndependentSegmentFrames = minimumIndependentSegmentFrames
    }

    public mutating func speechStarted(atFrame frame: Int64) {
        guard activeStartFrame == nil else { return }
        activeStartFrame = frame <= preRollFrames ? 0 : frame - preRollFrames
        activeIsContinuation = false
    }

    public mutating func speechEnded(atFrame frame: Int64) -> [SegmentReference] {
        precondition(
            splitStartFrameIfNeeded(atFrame: frame) == nil,
            "最大区間長に達した場合は、選択した cutFrame で先に split(atFrame:) を呼び出してください"
        )

        let start = activeStartFrame
        let isContinuation = activeIsContinuation
        activeStartFrame = nil
        activeIsContinuation = false
        guard let start, frame > start,
              isContinuation || frame - start >= minimumIndependentSegmentFrames else {
            return []
        }
        return [makeSegment(startFrame: start, endFrame: frame)]
    }

    public func splitStartFrameIfNeeded(atFrame frame: Int64) -> Int64? {
        guard let start = activeStartFrame, frame >= start else { return nil }
        let elapsed = frame.subtractingReportingOverflow(start)
        return elapsed.overflow || elapsed.partialValue >= maxSegmentFrames ? start : nil
    }

    public mutating func split(atFrame cutFrame: Int64) -> SegmentReference {
        guard let start = activeStartFrame else {
            preconditionFailure("split(atFrame:) には有効な音声区間が必要です")
        }
        let maximumEnd = start.addingReportingOverflow(maxSegmentFrames)
        precondition(
            start < cutFrame && (maximumEnd.overflow || cutFrame <= maximumEnd.partialValue),
            "cutFrame は現在の開始位置より後で最大区間長以内でなければなりません"
        )

        activeStartFrame = cutFrame
        activeIsContinuation = true
        return makeSegment(startFrame: start, endFrame: cutFrame)
    }

    private mutating func makeSegment(startFrame: Int64, endFrame: Int64) -> SegmentReference {
        defer { nextSegmentIndex &+= 1 }

        return SegmentReference(
            segmentationRunID: segmentationRunID,
            segmentID: String(format: "seg_%06llu", nextSegmentIndex),
            startFrame: startFrame,
            endFrame: endFrame
        )
    }
}
