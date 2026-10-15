import Testing
@testable import MacAmbientJev
import MacAmbientJevCore

@MainActor
@Test
func speakerHeadingsUseTheRenderedRowSnapshotAfterRowsClear() throws {
    var currentRows = try [
        LiveTranscriptRow(
            segment: .fixture(
                segmentID: "first", startMilliseconds: 0, endMilliseconds: 1_000, text: "最初", fillerRanges: [],
                speakers: [], isDiarized: true
            ),
            displaySpeakerLabels: ["Speaker 1"]
        ),
        LiveTranscriptRow(
            segment: .fixture(
                segmentID: "second", startMilliseconds: 1_000, endMilliseconds: 2_000, text: "続き", fillerRanges: [],
                speakers: [], isDiarized: true
            ),
            displaySpeakerLabels: ["Speaker 1"]
        ),
        LiveTranscriptRow(
            segment: .fixture(
                segmentID: "third", startMilliseconds: 2_000, endMilliseconds: 3_000, text: "次", fillerRanges: [],
                speakers: [], isDiarized: true
            ),
            displaySpeakerLabels: ["Speaker 2"]
        )
    ]
    let renderedRows = currentRows
    currentRows.removeAll()

    #expect(LiveTranscriptView.speakerHeading(for: 0, in: renderedRows) == "Speaker 1")
    #expect(LiveTranscriptView.speakerHeading(for: 1, in: renderedRows) == nil)
    #expect(LiveTranscriptView.speakerHeading(for: 2, in: renderedRows) == "Speaker 2")
    #expect(currentRows.isEmpty)
}

@MainActor
@Test
func rowTopSpacingSeparatesSpeakerTurnsAndKeepsContinuationsClose() {
    #expect(LiveTranscriptView.topSpacing(forIndex: 0, speakerHeading: "Speaker 1") == 0)
    #expect(LiveTranscriptView.topSpacing(forIndex: 1, speakerHeading: nil) == AppSpacing.xs)
    #expect(LiveTranscriptView.topSpacing(forIndex: 2, speakerHeading: "Speaker 2") == AppSpacing.md)
}

@MainActor
@Test
func waitingAndPendingRowsDescribeTheirDecisionStateWithoutHidingText() throws {
    let row = try LiveTranscriptRow(
        segment: .fixture(
            segmentID: "waiting", startMilliseconds: 0, endMilliseconds: 1_000, text: "えー、続く",
            fillerRanges: [try TextUTF16Range(start: 0, end: 2)], speakers: [], isDiarized: false,
            clauseState: .awaitingNextSegment
        ),
        displaySpeakerLabels: []
    )
    #expect(LiveTranscriptView.awaitingNextSegmentTitle == "発話文の続き待ち")
    #expect(LiveTranscriptView.clauseStateDescription(.awaitingNextSegment) == "発話文: 続き待ち")
    #expect(LiveTranscriptView.clauseStateDescription(.boundaryPending) == "発話文: 境界判定を保留中")
    #expect(LiveTranscriptView.clauseStateDescription(.priorityPending) == "発話文: 優先度判定を待っています")
    #expect(LiveTranscriptView.clauseStateDescription(.classified) == "発話文: 判定済み")
    #expect(row.text == "続く")
}
