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

public struct OpenSpeechRange: Sendable, Equatable {
    public let utteranceID: String
    public let startFrame: Int64
    public let endFrame: Int64

    public init(utteranceID: String, startFrame: Int64, endFrame: Int64) {
        self.utteranceID = utteranceID
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}

public actor SegmentJobQueue {
    private let capacity: Int
    private var storage: [SegmentReference] = []
    public private(set) var overflowCount: UInt64 = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage.reserveCapacity(max(1, capacity))
    }

    public var count: Int { storage.count }

    @discardableResult
    public func tryEnqueue(_ reference: SegmentReference) -> Bool {
        guard storage.count < capacity else {
            overflowCount &+= 1
            return false
        }
        storage.append(reference)
        return true
    }

    public func dequeue() -> SegmentReference? {
        guard !storage.isEmpty else { return nil }
        return storage.removeFirst()
    }
}

public struct SegmentationAssembler: Sendable {
    public let segmentationRunID: String
    public let preRollFrames: Int64
    public let maxSegmentFrames: Int64
    public let minimumSegmentFrames: Int64

    private var activeStartFrame: Int64?
    private var activeUtteranceStartFrame: Int64?
    private var activeUtteranceID: String?
    private var nextSegmentIndex: UInt64 = 1
    private var nextUtteranceIndex: UInt64 = 1

    public init(
        segmentationRunID: String,
        preRollFrames: Int64,
        maxSegmentFrames: Int64,
        minimumSegmentFrames: Int64 = 0
    ) {
        self.segmentationRunID = segmentationRunID
        self.preRollFrames = max(0, preRollFrames)
        self.maxSegmentFrames = max(1, maxSegmentFrames)
        self.minimumSegmentFrames = max(0, minimumSegmentFrames)
    }

    public mutating func speechStarted(atFrame frame: Int64) {
        guard activeStartFrame == nil else { return }
        let startFrame = max(0, frame - preRollFrames)
        activeStartFrame = startFrame
        activeUtteranceStartFrame = startFrame
        activeUtteranceID = String(
            format: "%@_utt_%06llu",
            segmentationRunID,
            nextUtteranceIndex
        )
        nextUtteranceIndex &+= 1
    }

    public func openSpeechRange(upToFrame durableFrame: Int64) -> OpenSpeechRange? {
        guard let start = activeUtteranceStartFrame,
              let utteranceID = activeUtteranceID,
              durableFrame > start else {
            return nil
        }
        return OpenSpeechRange(
            utteranceID: utteranceID,
            startFrame: start,
            endFrame: durableFrame
        )
    }

    public mutating func speechEnded(atFrame frame: Int64) -> SegmentReference? {
        let start = activeStartFrame
        activeStartFrame = nil
        activeUtteranceStartFrame = nil
        activeUtteranceID = nil
        guard let start, frame > start else { return nil }
        guard frame - start >= minimumSegmentFrames else { return nil }
        return makeSegment(startFrame: start, endFrame: frame)
    }

    public mutating func splitIfNeeded(atFrame frame: Int64) -> SegmentReference? {
        guard let start = activeStartFrame, frame - start >= maxSegmentFrames else { return nil }
        let end = start + maxSegmentFrames
        activeStartFrame = end
        activeUtteranceStartFrame = end
        activeUtteranceID = String(
            format: "%@_utt_%06llu",
            segmentationRunID,
            nextUtteranceIndex
        )
        nextUtteranceIndex &+= 1
        return makeSegment(startFrame: start, endFrame: end)
    }

    public mutating func finish(atFrame frame: Int64) -> SegmentReference? {
        speechEnded(atFrame: frame)
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
