import Testing
@testable import MacAmbientJevCore

@Suite struct SegmentGrouperTests {
    @Test func groupsRangesWithinSpanIncludingTouchingContinuation() {
        var grouper = SegmentGrouper(segmentationRunID: "run-a", maximumSpanFrames: 480_000)
        let ranges: [Range<Int64>] = [0..<100, 100..<200, 300..<400]
        for range in ranges { #expect(grouper.append(range) == nil) }

        let segment = grouper.finish()
        #expect(segment?.segmentationRunID == "run-a")
        #expect(segment?.segmentID == "seg_000001")
        #expect(segment?.speechRanges == ranges)
    }

    @Test(arguments: [480_000, 480_001])
    func splitsOnlyWhenCombinedEndExceedsSpan(endFrame: Int64) {
        var grouper = SegmentGrouper(segmentationRunID: "run-b", maximumSpanFrames: 480_000)
        #expect(grouper.append(0..<1) == nil)
        let closed = grouper.append(1..<endFrame)
        if endFrame == 480_000 {
            #expect(closed == nil)
            let finished = grouper.finish()
            #expect(finished?.segmentID == "seg_000001")
            #expect(finished?.speechRanges == [0..<1, 1..<480_000])
        } else {
            #expect(closed?.segmentID == "seg_000001")
            #expect(closed?.speechRanges == [0..<1])
            let finished = grouper.finish()
            #expect(finished?.segmentID == "seg_000002")
            #expect(finished?.speechRanges == [1..<480_001])
        }
    }

    @Test func settleReleasesAtElapsedSpanBoundary() {
        var grouper = SegmentGrouper(segmentationRunID: "run-c", maximumSpanFrames: 480_000)
        #expect(grouper.append(100..<150) == nil)
        #expect(grouper.settle(atFrame: 480_099) == nil)
        let released = grouper.settle(atFrame: 480_100)
        #expect(released?.segmentID == "seg_000001")
        #expect(released?.speechRanges == [100..<150])
    }

    @Test func finishReturnsOpenSegmentThenNothing() {
        var grouper = SegmentGrouper(segmentationRunID: "run-d", maximumSpanFrames: 480_000)
        #expect(grouper.append(10..<20) == nil)
        #expect(grouper.finish()?.speechRanges == [10..<20])
        #expect(grouper.finish() == nil)
    }
}
