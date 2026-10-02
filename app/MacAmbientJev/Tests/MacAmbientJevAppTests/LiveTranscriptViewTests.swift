import Testing
@testable import MacAmbientJev
import MacAmbientJevCore

@MainActor
@Test
func speakerHeadingsUseTheRenderedRowSnapshotAfterRowsClear() {
    var currentRows = [
        LiveTranscriptRow(
            segmentID: "first", startMilliseconds: 0, endMilliseconds: 1_000, text: "最初", scene: .unknown,
            speakers: [], displaySpeakerLabels: ["Speaker 1"], scopeSpans: [], isLowPriority: false
        ),
        LiveTranscriptRow(
            segmentID: "second", startMilliseconds: 1_000, endMilliseconds: 2_000, text: "続き", scene: .unknown,
            speakers: [], displaySpeakerLabels: ["Speaker 1"], scopeSpans: [], isLowPriority: false
        ),
        LiveTranscriptRow(
            segmentID: "third", startMilliseconds: 2_000, endMilliseconds: 3_000, text: "次", scene: .unknown,
            speakers: [], displaySpeakerLabels: ["Speaker 2"], scopeSpans: [], isLowPriority: false
        )
    ]
    let renderedRows = currentRows
    currentRows.removeAll()

    #expect(LiveTranscriptView.speakerHeading(for: 0, in: renderedRows) == "Speaker 1")
    #expect(LiveTranscriptView.speakerHeading(for: 1, in: renderedRows) == nil)
    #expect(LiveTranscriptView.speakerHeading(for: 2, in: renderedRows) == "Speaker 2")
    #expect(currentRows.isEmpty)
}
