import XCTest
@testable import MacAmbientJevCore

final class SpeakerTurnSegmenterTests: XCTestCase {
    private let rate = 1_000.0

    private func segment(_ start: Int64 = 0, _ end: Int64 = 2_000, id: String = "seg") -> SegmentReference {
        SegmentReference(segmentationRunID: "run", segmentID: id, startFrame: start, endFrame: end)
    }

    private func span(_ speaker: String, _ start: Int64, _ end: Int64) -> SpeakerSpan {
        SpeakerSpan(speakerID: speaker, startFrame: start, endFrame: end, confidence: 0.9)
    }

    func testGapUsesMidpointAndContactUsesExactBoundary() throws {
        let gap = try SpeakerTurnSegmenter.split([segment()], speakerSpans: [
            span("A", 0, 800), span("B", 1_000, 2_000)
        ], sampleRate: rate)
        XCTAssertEqual(gap.map(\.startFrame), [0, 900])
        XCTAssertEqual(gap.map(\.endFrame), [900, 2_000])

        let contact = try SpeakerTurnSegmenter.split([segment()], speakerSpans: [
            span("A", 0, 1_000), span("B", 1_000, 2_000)
        ], sampleRate: rate)
        XCTAssertEqual(contact.map(\.startFrame), [0, 1_000])
        XCTAssertEqual(contact.map(\.endFrame), [1_000, 2_000])
    }

    func testOverlapAndNestedSpansDoNotCreateAmbiguousCut() throws {
        let overlapping = try SpeakerTurnSegmenter.split([segment()], speakerSpans: [
            span("A", 0, 1_100), span("B", 900, 2_000)
        ], sampleRate: rate)
        XCTAssertEqual(overlapping, [segment()])

        let nested = try SpeakerTurnSegmenter.split([segment()], speakerSpans: [
            span("A", 0, 1_400), span("B", 500, 800)
        ], sampleRate: rate)
        XCTAssertEqual(nested, [segment()])
    }

    func testShortBlipIsPreservedWithoutSplit() throws {
        let result = try SpeakerTurnSegmenter.split([segment()], speakerSpans: [
            span("A", 0, 1_000), span("B", 1_000, 1_050), span("A", 1_050, 2_000)
        ], sampleRate: rate)
        XCTAssertEqual(result, [segment()])
    }

    func testChildrenCoverParentExactlyAndHaveDeterministicUniqueIDs() throws {
        let parent = segment(100, 2_100, id: "parent")
        let spans = [span("A", 100, 900), span("B", 1_100, 2_100)]
        let first = try SpeakerTurnSegmenter.split([parent], speakerSpans: spans, sampleRate: rate)
        let second = try SpeakerTurnSegmenter.split([parent], speakerSpans: spans, sampleRate: rate)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.first?.startFrame, parent.startFrame)
        XCTAssertEqual(first.last?.endFrame, parent.endFrame)
        XCTAssertEqual(zip(first, first.dropFirst()).map { $0.endFrame == $1.startFrame }, [true])
        XCTAssertEqual(first.reduce(Int64(0)) { $0 + ($1.endFrame - $1.startFrame) }, parent.endFrame - parent.startFrame)
        XCTAssertEqual(Set(first.map(\.segmentID)).count, first.count)
        XCTAssertTrue(first.allSatisfy { $0.segmentationRunID == parent.segmentationRunID })
    }

    func testGeneratedIDCollisionFailsExplicitly() {
        let parents = [segment(0, 2_000, id: "foo"), segment(2_000, 4_000, id: "foo_turn_0001")]
        let spans = [span("A", 0, 1_000), span("B", 1_000, 4_000)]
        XCTAssertThrowsError(try SpeakerTurnSegmenter.split(parents, speakerSpans: spans, sampleRate: rate))
    }

    func testInvalidInputFailsExplicitly() {
        XCTAssertThrowsError(try SpeakerTurnSegmenter.split([segment()], speakerSpans: [], sampleRate: .nan))
        XCTAssertThrowsError(try SpeakerTurnSegmenter.split([segment(4, 4)], speakerSpans: [], sampleRate: rate))
        XCTAssertThrowsError(try SpeakerTurnSegmenter.split([segment(), segment()], speakerSpans: [], sampleRate: rate))
        XCTAssertThrowsError(try SpeakerTurnSegmenter.split([segment()], speakerSpans: [span("A", 10, 10)], sampleRate: rate))
    }
}
