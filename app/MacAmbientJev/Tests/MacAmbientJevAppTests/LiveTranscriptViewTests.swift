import Testing
@testable import MacAmbientJev
import MacAmbientJevCore

@MainActor
@Test
func waitingAndPendingRowsDescribeTheirDecisionStateWithoutHidingText() throws {
    let row = try LiveTranscriptRow(
        segment: .fixture(
            segmentID: "waiting", startMilliseconds: 0, endMilliseconds: 1_000, text: "えー、続く",
            fillerRanges: [try TextUTF16Range(start: 0, end: 2)],
            clauseState: .awaitingNextSegment
        )
    )
    #expect(LiveTranscriptView.awaitingNextSegmentTitle == "発話文の続き待ち")
    #expect(TranscriptClauseState.awaitingNextSegment.rowDetailsDescription == "発話文: 続き待ち")
    #expect(TranscriptClauseState.boundaryPending.rowDetailsDescription == "発話文: 境界判定を保留中")
    #expect(TranscriptClauseState.priorityPending.rowDetailsDescription == "発話文: 優先度判定を待っています")
    #expect(TranscriptClauseState.classified.rowDetailsDescription == "発話文: 判定済み")
    #expect(row.text == "続く")
}
