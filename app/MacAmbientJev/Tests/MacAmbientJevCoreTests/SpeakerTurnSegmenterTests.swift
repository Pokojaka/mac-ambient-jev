import Testing
@testable import MacAmbientJevCore

struct SpeakerTurnSegmenterTests {
    private let rate = 1_000.0

    private func segment(_ start: Int64 = 0, _ end: Int64 = 2_000, id: String = "seg") -> SegmentReference {
        SegmentReference(segmentationRunID: "run", segmentID: id, startFrame: start, endFrame: end)
    }

    private func span(_ speaker: String, _ start: Int64, _ end: Int64) -> SpeakerSpan {
        SpeakerSpan(speakerID: speaker, startFrame: start, endFrame: end, confidence: 0.9)
    }

    @Test func gapUsesMidpointAndContactUsesExactBoundary() throws {
        let gap = try SpeakerTurnSegmenter.split([segment()], speakerSpans: [
            span("A", 0, 800), span("B", 1_000, 2_000)
        ], sampleRate: rate)
        #expect(gap.map(\.startFrame) == [0, 900])
        #expect(gap.map(\.endFrame) == [900, 2_000])

        let contact = try SpeakerTurnSegmenter.split([segment()], speakerSpans: [
            span("A", 0, 1_000), span("B", 1_000, 2_000)
        ], sampleRate: rate)
        #expect(contact.map(\.startFrame) == [0, 1_000])
        #expect(contact.map(\.endFrame) == [1_000, 2_000])
    }

    @Test func overlapAndNestedSpansDoNotCreateAmbiguousCut() throws {
        let overlapping = try SpeakerTurnSegmenter.split([segment()], speakerSpans: [
            span("A", 0, 1_100), span("B", 900, 2_000)
        ], sampleRate: rate)
        #expect(overlapping == [segment()])

        let nested = try SpeakerTurnSegmenter.split([segment()], speakerSpans: [
            span("A", 0, 1_400), span("B", 500, 800)
        ], sampleRate: rate)
        #expect(nested == [segment()])
    }

    @Test func shortBlipIsPreservedWithoutSplit() throws {
        let result = try SpeakerTurnSegmenter.split([segment()], speakerSpans: [
            span("A", 0, 1_000), span("B", 1_000, 1_050), span("A", 1_050, 2_000)
        ], sampleRate: rate)
        #expect(result == [segment()])
    }

    @Test func childrenCoverParentExactlyAndHaveDeterministicUniqueIDs() throws {
        let parent = segment(100, 2_100, id: "parent")
        let spans = [span("A", 100, 900), span("B", 1_100, 2_100)]
        let first = try SpeakerTurnSegmenter.split([parent], speakerSpans: spans, sampleRate: rate)
        let second = try SpeakerTurnSegmenter.split([parent], speakerSpans: spans, sampleRate: rate)
        #expect(first == second)
        #expect(first.count == 2)
        #expect(first.first?.startFrame == parent.startFrame)
        #expect(first.last?.endFrame == parent.endFrame)
        #expect(zip(first, first.dropFirst()).map { $0.endFrame == $1.startFrame } == [true])
        #expect(first.reduce(Int64(0)) { $0 + ($1.endFrame - $1.startFrame) } == parent.endFrame - parent.startFrame)
        #expect(Set(first.map(\.segmentID)).count == first.count)
        #expect(first.allSatisfy { $0.segmentationRunID == parent.segmentationRunID })
    }

    @Test func generatedIDCollisionFailsExplicitly() {
        let parents = [segment(0, 2_000, id: "foo"), segment(2_000, 4_000, id: "foo_turn_0001")]
        let spans = [span("A", 0, 1_000), span("B", 1_000, 4_000)]
        #expect(throws: (any Error).self) {
            try SpeakerTurnSegmenter.split(parents, speakerSpans: spans, sampleRate: rate)
        }
    }

    @Test func invalidInputFailsExplicitly() {
        #expect(throws: (any Error).self) { try SpeakerTurnSegmenter.split([segment()], speakerSpans: [], sampleRate: .nan) }
        #expect(throws: (any Error).self) { try SpeakerTurnSegmenter.split([segment(4, 4)], speakerSpans: [], sampleRate: rate) }
        #expect(throws: (any Error).self) { try SpeakerTurnSegmenter.split([segment(), segment()], speakerSpans: [], sampleRate: rate) }
        #expect(throws: (any Error).self) { try SpeakerTurnSegmenter.split([segment()], speakerSpans: [span("A", 10, 10)], sampleRate: rate) }
    }
}
