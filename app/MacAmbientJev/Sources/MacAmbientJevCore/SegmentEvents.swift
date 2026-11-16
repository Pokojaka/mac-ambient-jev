import Foundation

public struct SegmentCreatedPayload: Codable, Sendable, Equatable {
    /// Encoded as an array of `[start, end]` frame pairs.
    public let speechRanges: [Range<Int64>]

    private enum CodingKeys: String, CodingKey {
        case speechRanges = "speech_ranges"
    }

    public init(speechRanges: [Range<Int64>]) {
        self.speechRanges = speechRanges
    }
}

public extension EventDraft where Payload == SegmentCreatedPayload {
    /// Emits the outer frame span; gaps between speech ranges remain in the payload.
    static func segmentCreated(sessionID: UUID, segment: SegmentReference) -> EventDraft {
        EventDraft(
            eventType: "segment.created",
            sessionID: sessionID,
            segmentationRunID: segment.segmentationRunID,
            segmentID: segment.segmentID,
            sourceStartFrame: segment.startFrame,
            sourceEndFrame: segment.endFrame,
            payload: SegmentCreatedPayload(speechRanges: segment.speechRanges)
        )
    }
}
