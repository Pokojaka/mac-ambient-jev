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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID = "session_id"
        case revision
        case rowID = "row_id"
    }

    public init(sessionID: String, revision: EngineID, rowID: String) throws {
        try engineRowDetailsRequireNonempty(sessionID, "session_id")
        try engineRowDetailsRequireNonempty(rowID, "row_id")
        self.sessionID = sessionID
        self.revision = revision
        self.rowID = rowID
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            revision: container.decode(EngineID.self, forKey: .revision),
            rowID: container.decode(String.self, forKey: .rowID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(revision, forKey: .revision)
        try container.encode(rowID, forKey: .rowID)
    }
}

public struct EngineTranscriptRowDetailsPage: Codable, Equatable, Sendable {
    public let sessionID: String
    public let revision: EngineID
    public let rowID: String
    public let clauseState: EngineClauseState
    public let clauseStateText: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID = "session_id"
        case revision
        case rowID = "row_id"
        case clauseState = "clause_state"
        case clauseStateText = "clause_state_text"
    }

    public init(
        sessionID: String,
        revision: EngineID,
        rowID: String,
        clauseState: EngineClauseState,
        clauseStateText: String
    ) throws {
        try engineRowDetailsRequireNonempty(sessionID, "session_id")
        try engineRowDetailsRequireNonempty(rowID, "row_id")
        try engineRowDetailsRequireNonempty(clauseStateText, "clause_state_text")
        self.sessionID = sessionID
        self.revision = revision
        self.rowID = rowID
        self.clauseState = clauseState
        self.clauseStateText = clauseStateText
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            revision: container.decode(EngineID.self, forKey: .revision),
            rowID: container.decode(String.self, forKey: .rowID),
            clauseState: container.decode(EngineClauseState.self, forKey: .clauseState),
            clauseStateText: container.decode(String.self, forKey: .clauseStateText)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(revision, forKey: .revision)
        try container.encode(rowID, forKey: .rowID)
        try container.encode(clauseState, forKey: .clauseState)
        try container.encode(clauseStateText, forKey: .clauseStateText)
    }
}
