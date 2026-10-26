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
    private let speakers: [EngineTranscriptSpeakerSpan]
    private let speakerByteCounts: [Int]
    private let fixedByteCount: Int
    private let navigation: EnginePageNavigation

    private static let representativeCursor = "00000000-0000-0000-0000-000000000000"

    init(sessionID: UUID, revision: UInt64, segment: MaterializedTranscriptSegment, limit: Int) throws {
        let wireSessionID = EngineFailures.wireID(sessionID)
        let wireRevision = try EngineID(revision)
        let row = try LiveTranscriptRow(segment: segment, displaySpeakerLabels: [])
        guard let wireClauseState = EngineClauseState(rawValue: row.clauseState.rawValue) else {
            throw EngineTranscriptProjectionError.unknownClauseState(row.clauseState.rawValue)
        }
        let wireClauseStateText = row.clauseState.rowDetailsDescription
        let wireSpeakers = try row.speakers.map { span in
            try EngineTranscriptSpeakerSpan(
                speakerID: span.id,
                displayLabel: span.displayLabel ?? span.id,
                startMS: span.startMilliseconds,
                endMS: span.endMilliseconds
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let speakerByteCounts = try wireSpeakers.map { try encoder.encode($0).count }
        let fixedByteCount = try Self.fixedEnvelopeByteCount(
            sessionID: wireSessionID,
            revision: wireRevision,
            rowID: row.segmentID,
            clauseState: wireClauseState,
            clauseStateText: wireClauseStateText,
            errorSessionID: sessionID
        )

        self.sessionID = sessionID
        self.revision = revision
        self.rowID = row.segmentID
        self.clauseState = wireClauseState
        self.clauseStateText = wireClauseStateText
        self.speakers = wireSpeakers
        self.speakerByteCounts = speakerByteCounts
        self.fixedByteCount = fixedByteCount
        self.navigation = EnginePageNavigation(limit: limit)
    }

    func page(cursor: String?, limit: Int) throws -> EngineTranscriptRowDetailsPage {
        let location = try navigation.location(cursor: cursor, limit: limit)
        let maximumEnd = min(speakers.count, location.start + limit)
        var end = location.start
        var pageByteCount = fixedByteCount

        while end < maximumEnd {
            let separatorByteCount = end == location.start ? 0 : 1
            let (spanAndSeparatorByteCount, spanOverflow) = speakerByteCounts[end]
                .addingReportingOverflow(separatorByteCount)
            let (candidateByteCount, pageOverflow) = pageByteCount
                .addingReportingOverflow(spanAndSeparatorByteCount)
            guard !spanOverflow, !pageOverflow, candidateByteCount <= EngineLineFramer.maxLineBytes else {
                guard end > location.start else {
                    throw Self.detailsTooLargeError(sessionID: sessionID)
                }
                break
            }

            pageByteCount = candidateByteCount
            end += 1
        }

        let cursors = navigation.cursors(for: location, end: end, total: speakers.count)
        return try EngineTranscriptRowDetailsPage(
            sessionID: EngineFailures.wireID(sessionID),
            revision: try EngineID(revision),
            rowID: rowID,
            clauseState: clauseState,
            clauseStateText: clauseStateText,
            speakers: Array(speakers[location.start..<end]),
            nextCursor: cursors.next,
            previousCursor: cursors.previous
        )
    }

    private static func fixedEnvelopeByteCount(
        sessionID: String,
        revision: EngineID,
        rowID: String,
        clauseState: EngineClauseState,
        clauseStateText: String,
        errorSessionID: UUID
    ) throws -> Int {
        let emptyPage = try EngineTranscriptRowDetailsPage(
            sessionID: sessionID,
            revision: revision,
            rowID: rowID,
            clauseState: clauseState,
            clauseStateText: clauseStateText,
            speakers: [],
            nextCursor: representativeCursor,
            previousCursor: representativeCursor
        )
        let maximumID = try EngineID(UInt64.max)
        let output = try EngineOutput(
            version: 1,
            sequence: maximumID,
            requestID: maximumID,
            event: .completed(.transcriptRowDetails(emptyPage))
        )
        do {
            return try EngineCodec.encodeOutput(output).count - 1
        } catch EngineProtocolError.lineTooLong {
            throw detailsTooLargeError(sessionID: errorSessionID)
        }
    }

    private static func detailsTooLargeError(sessionID: UUID) -> EngineCommandError {
        EngineFailures.commandError(
            .rowTooLarge,
            "文字起こし行の詳細が大きすぎて返せません",
            stage: .finalization,
            sessionID: sessionID,
            recoveryAction: .inspectSession
        )
    }
}
