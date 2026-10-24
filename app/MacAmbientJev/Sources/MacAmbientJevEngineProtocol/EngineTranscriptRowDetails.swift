import Foundation

private func engineRowDetailsRequire(_ condition: Bool, _ reason: String) throws {
    guard condition else {
        throw EngineProtocolError.invalidJSON(reason)
    }
}

private func engineRowDetailsRequireNonempty(_ value: String, _ field: String) throws {
    try engineRowDetailsRequire(!value.isEmpty, "\(field) must not be empty")
}

public struct EngineTranscriptRowDetailsPayload: Codable, Equatable, Sendable {
    public let sessionID: String
    public let revision: EngineID
    public let rowID: String
    @EngineNullable public private(set) var cursor: String?
    public let limit: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID = "session_id"
        case revision
        case rowID = "row_id"
        case cursor
        case limit
    }

    public init(sessionID: String, revision: EngineID, rowID: String, cursor: String?, limit: Int) throws {
        try engineRowDetailsRequireNonempty(sessionID, "session_id")
        try engineRowDetailsRequireNonempty(rowID, "row_id")
        if let cursor {
            try engineRowDetailsRequireNonempty(cursor, "cursor")
        }
        try engineRowDetailsRequire((1...200).contains(limit), "limit must be between 1 and 200")
        self.sessionID = sessionID
        self.revision = revision
        self.rowID = rowID
        _cursor = EngineNullable(wrappedValue: cursor)
        self.limit = limit
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            revision: container.decode(EngineID.self, forKey: .revision),
            rowID: container.decode(String.self, forKey: .rowID),
            cursor: container.decode(EngineNullable<String>.self, forKey: .cursor).wrappedValue,
            limit: container.decode(Int.self, forKey: .limit)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(revision, forKey: .revision)
        try container.encode(rowID, forKey: .rowID)
        try container.encode(_cursor, forKey: .cursor)
        try container.encode(limit, forKey: .limit)
    }
}

public struct EngineTranscriptSpeakerSpan: Codable, Equatable, Sendable {
    public let speakerID: String
    public let displayLabel: String
    public let startMS: Int64
    public let endMS: Int64

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case speakerID = "speaker_id"
        case displayLabel = "display_label"
        case startMS = "start_ms"
        case endMS = "end_ms"
    }

    public init(speakerID: String, displayLabel: String, startMS: Int64, endMS: Int64) throws {
        try engineRowDetailsRequireNonempty(speakerID, "speaker_id")
        try engineRowDetailsRequireNonempty(displayLabel, "display_label")
        try engineRowDetailsRequire(startMS >= 0, "start_ms must not be negative")
        try engineRowDetailsRequire(endMS >= 0, "end_ms must not be negative")
        try engineRowDetailsRequire(endMS >= startMS, "end_ms must not be before start_ms")
        self.speakerID = speakerID
        self.displayLabel = displayLabel
        self.startMS = startMS
        self.endMS = endMS
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            speakerID: container.decode(String.self, forKey: .speakerID),
            displayLabel: container.decode(String.self, forKey: .displayLabel),
            startMS: container.decode(Int64.self, forKey: .startMS),
            endMS: container.decode(Int64.self, forKey: .endMS)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(speakerID, forKey: .speakerID)
        try container.encode(displayLabel, forKey: .displayLabel)
        try container.encode(startMS, forKey: .startMS)
        try container.encode(endMS, forKey: .endMS)
    }
}

public struct EngineTranscriptRowDetailsPage: Codable, Equatable, Sendable {
    public let sessionID: String
    public let revision: EngineID
    public let rowID: String
    public let clauseState: EngineClauseState
    public let clauseStateText: String
    public let speakers: [EngineTranscriptSpeakerSpan]
    @EngineNullable public private(set) var nextCursor: String?
    @EngineNullable public private(set) var previousCursor: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID = "session_id"
        case revision
        case rowID = "row_id"
        case clauseState = "clause_state"
        case clauseStateText = "clause_state_text"
        case speakers
        case nextCursor = "next_cursor"
        case previousCursor = "previous_cursor"
    }

    public init(
        sessionID: String,
        revision: EngineID,
        rowID: String,
        clauseState: EngineClauseState,
        clauseStateText: String,
        speakers: [EngineTranscriptSpeakerSpan],
        nextCursor: String?,
        previousCursor: String?
    ) throws {
        try engineRowDetailsRequireNonempty(sessionID, "session_id")
        try engineRowDetailsRequireNonempty(rowID, "row_id")
        try engineRowDetailsRequireNonempty(clauseStateText, "clause_state_text")
        if let nextCursor {
            try engineRowDetailsRequireNonempty(nextCursor, "next_cursor")
        }
        if let previousCursor {
            try engineRowDetailsRequireNonempty(previousCursor, "previous_cursor")
        }
        try engineRowDetailsRequire(speakers.count <= 200, "speakers must contain at most 200 items")
        self.sessionID = sessionID
        self.revision = revision
        self.rowID = rowID
        self.clauseState = clauseState
        self.clauseStateText = clauseStateText
        self.speakers = speakers
        _nextCursor = EngineNullable(wrappedValue: nextCursor)
        _previousCursor = EngineNullable(wrappedValue: previousCursor)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            revision: container.decode(EngineID.self, forKey: .revision),
            rowID: container.decode(String.self, forKey: .rowID),
            clauseState: container.decode(EngineClauseState.self, forKey: .clauseState),
            clauseStateText: container.decode(String.self, forKey: .clauseStateText),
            speakers: container.decode([EngineTranscriptSpeakerSpan].self, forKey: .speakers),
            nextCursor: container.decode(EngineNullable<String>.self, forKey: .nextCursor).wrappedValue,
            previousCursor: container.decode(EngineNullable<String>.self, forKey: .previousCursor).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(revision, forKey: .revision)
        try container.encode(rowID, forKey: .rowID)
        try container.encode(clauseState, forKey: .clauseState)
        try container.encode(clauseStateText, forKey: .clauseStateText)
        try container.encode(speakers, forKey: .speakers)
        try container.encode(_nextCursor, forKey: .nextCursor)
        try container.encode(_previousCursor, forKey: .previousCursor)
    }
}
