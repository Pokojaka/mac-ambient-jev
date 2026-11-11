import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol

@MainActor
struct EngineTranscriptRowDetailsSnapshot {
    let sessionID: UUID
    let revision: UInt64
    let rowID: String

    private let clauseState: EngineClauseState
    private let clauseStateText: String

    init(sessionID: UUID, revision: UInt64, segment: MaterializedTranscriptSegment) throws {
        let row = try LiveTranscriptRow(segment: segment)
        guard let clauseState = EngineClauseState(rawValue: row.clauseState.rawValue) else {
            throw EngineTranscriptProjectionError.unknownClauseState(row.clauseState.rawValue)
        }

        self.sessionID = sessionID
        self.revision = revision
        self.rowID = row.segmentID
        self.clauseState = clauseState
        self.clauseStateText = row.clauseState.rowDetailsDescription
    }

    func page() throws -> EngineTranscriptRowDetailsPage {
        try EngineTranscriptRowDetailsPage(
            sessionID: EngineFailures.wireID(sessionID),
            revision: try EngineID(revision),
            rowID: rowID,
            clauseState: clauseState,
            clauseStateText: clauseStateText
        )
    }
}
