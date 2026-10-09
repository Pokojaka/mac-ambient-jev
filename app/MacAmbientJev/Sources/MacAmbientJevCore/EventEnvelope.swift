import Foundation

public struct EmptyPayload: Codable, Sendable, Equatable {
    public init() {}
}

/// The only `events.jsonl` envelope version readers and writers accept.
public enum EventLogSchema {
    public static let version = 3
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
        self.schemaVersion = EventLogSchema.version
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

    private enum CodingKeys: String, CodingKey {
        case eventSeq = "event_seq", eventID = "event_id", eventType = "event_type"
        case schemaVersion = "schema_version", sessionID = "session_id"
        case processingRunID = "processing_run_id", segmentationRunID = "segmentation_run_id"
        case segmentID = "segment_id", sourceStartFrame = "source_start_frame", sourceEndFrame = "source_end_frame"
        case createdAt = "created_at", payload
    }

    public init(eventSeq: UInt64, eventID: UUID, eventType: String,
                sessionID: UUID, processingRunID: String?, segmentationRunID: String?,
                segmentID: String?, sourceStartFrame: Int64?, sourceEndFrame: Int64?,
                createdAt: Date, payload: Payload) {
        self.eventSeq = eventSeq
        self.eventID = eventID
        self.eventType = eventType
        self.schemaVersion = EventLogSchema.version
        self.sessionID = sessionID
        self.processingRunID = processingRunID
        self.segmentationRunID = segmentationRunID
        self.segmentID = segmentID
        self.sourceStartFrame = sourceStartFrame
        self.sourceEndFrame = sourceEndFrame
        self.createdAt = createdAt
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == EventLogSchema.version else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "schema_version \(EventLogSchema.version) required")
        }
        self.init(
            eventSeq: try c.decode(UInt64.self, forKey: .eventSeq),
            eventID: try c.decode(UUID.self, forKey: .eventID),
            eventType: try c.decode(String.self, forKey: .eventType),
            sessionID: try c.decode(UUID.self, forKey: .sessionID),
            processingRunID: try c.decodeIfPresent(String.self, forKey: .processingRunID),
            segmentationRunID: try c.decodeIfPresent(String.self, forKey: .segmentationRunID),
            segmentID: try c.decodeIfPresent(String.self, forKey: .segmentID),
            sourceStartFrame: try c.decodeIfPresent(Int64.self, forKey: .sourceStartFrame),
            sourceEndFrame: try c.decodeIfPresent(Int64.self, forKey: .sourceEndFrame),
            createdAt: try c.decode(Date.self, forKey: .createdAt),
            payload: try c.decode(Payload.self, forKey: .payload)
        )
    }
}

public enum EventLogSchemaError: LocalizedError, Sendable, Equatable {
    case unsupportedSchemaVersion(index: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let index):
            "イベントログの \(index + 1) 行目は対応していない形式です（schema_version \(EventLogSchema.version) のみ対応）"
        }
    }
}

extension EventLogSchema {
    private struct Header: Decodable {
        let schemaVersion: Int
        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version" }
    }

    /// Rejects a line whose envelope is not the current version, including a missing version.
    public static func validate(line: Data, index: Int) throws {
        guard let header = try? JSONDecoder().decode(Header.self, from: line),
              header.schemaVersion == version else {
            throw EventLogSchemaError.unsupportedSchemaVersion(index: index)
        }
    }
}
