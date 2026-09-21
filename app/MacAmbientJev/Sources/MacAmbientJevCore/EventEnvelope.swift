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
        schemaVersion: Int = 1,
        sessionID: UUID,
        processingRunID: String? = nil,
        segmentationRunID: String? = nil,
        segmentID: String? = nil,
        sourceStartFrame: Int64? = nil,
        sourceEndFrame: Int64? = nil,
        createdAt: Date = Date(),
        payload: Payload
    ) {
        self.eventType = eventType
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.processingRunID = processingRunID
        self.segmentationRunID = segmentationRunID
        self.segmentID = segmentID
        self.sourceStartFrame = sourceStartFrame
        self.sourceEndFrame = sourceEndFrame
        self.createdAt = createdAt
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
