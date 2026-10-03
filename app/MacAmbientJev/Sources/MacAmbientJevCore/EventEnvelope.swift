import Foundation

public struct EmptyPayload: Codable, Sendable, Equatable {
    public init() {}
}

public struct EventDraft<Payload: Codable & Sendable>: Sendable {
    public let eventType: String
    public let schemaVersion: Int
    public let sessionID: UUID
    public let processingRunID: String?
    public let segmentationRunID: String?
    public let segmentID: String?
    public let sourceStartFrame: Int64?
    public let sourceEndFrame: Int64?
    public let createdAt: Date
    public let payload: Payload

    public init(
        eventType: String,
        sessionID: UUID,
        processingRunID: String? = nil,
        segmentationRunID: String? = nil,
        segmentID: String? = nil,
        sourceStartFrame: Int64? = nil,
        sourceEndFrame: Int64? = nil,
        payload: Payload
    ) {
        self.eventType = eventType
        self.schemaVersion = 1
        self.sessionID = sessionID
        self.processingRunID = processingRunID
        self.segmentationRunID = segmentationRunID
        self.segmentID = segmentID
        self.sourceStartFrame = sourceStartFrame
        self.sourceEndFrame = sourceEndFrame
        self.createdAt = Date()
        self.payload = payload
    }
}

public struct EventEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let eventSeq: UInt64
    public let eventID: UUID
    public let eventType: String
    public let schemaVersion: Int
    public let sessionID: UUID
    public let processingRunID: String?
    public let segmentationRunID: String?
    public let segmentID: String?
    public let sourceStartFrame: Int64?
    public let sourceEndFrame: Int64?
    public let createdAt: Date
    public let payload: Payload
}
