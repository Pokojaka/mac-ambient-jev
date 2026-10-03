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

public struct SegmentationAssembler: Sendable {
    public let segmentationRunID: String
    public let preRollFrames: Int64
    public let maxSegmentFrames: Int64
    public let minimumSegmentFrames: Int64

    private var activeStartFrame: Int64?
    private var activeIsContinuation = false
    private var nextSegmentIndex: UInt64 = 1

    public init(
        segmentationRunID: String,
        preRollFrames: Int64,
        maxSegmentFrames: Int64,
        minimumSegmentFrames: Int64
    ) {
        precondition(preRollFrames >= 0, "preRollFrames must not be negative")
        precondition(maxSegmentFrames > 0, "maxSegmentFrames must be positive")
        precondition(minimumSegmentFrames >= 0, "minimumSegmentFrames must not be negative")
        self.segmentationRunID = segmentationRunID
        self.preRollFrames = preRollFrames
        self.maxSegmentFrames = maxSegmentFrames
        self.minimumSegmentFrames = minimumSegmentFrames
    }

    public mutating func speechStarted(atFrame frame: Int64) {
        guard activeStartFrame == nil else { return }
        activeStartFrame = max(0, frame - preRollFrames)
        activeIsContinuation = false
    }

    public mutating func speechEnded(atFrame frame: Int64) -> [SegmentReference] {
        var segments: [SegmentReference] = []
        while let split = splitIfNeeded(atFrame: frame) {
            segments.append(split)
        }
        let start = activeStartFrame
        let isContinuation = activeIsContinuation
        activeStartFrame = nil
        guard let start, frame > start,
              isContinuation || frame - start >= minimumSegmentFrames else {
            return segments
        }
        segments.append(makeSegment(startFrame: start, endFrame: frame))
        return segments
    }

    public mutating func splitIfNeeded(atFrame frame: Int64) -> SegmentReference? {
        guard let start = activeStartFrame, frame - start >= maxSegmentFrames else { return nil }
        let end = start + maxSegmentFrames
        activeStartFrame = end
        activeIsContinuation = true
        return makeSegment(startFrame: start, endFrame: end)
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

public struct VADFrameMapper: Sendable, Equatable {
    public let canonicalSampleRate: Double

    public init(canonicalSampleRate: Double) {
        self.canonicalSampleRate = canonicalSampleRate
    }

    public func canonicalFrame(forVADSample sample: Int) -> Int64 {
        Int64((Double(sample) * canonicalSampleRate / 16_000.0).rounded())
    }
}
