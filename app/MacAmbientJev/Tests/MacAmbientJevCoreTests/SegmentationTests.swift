import Testing
@testable import MacAmbientJevCore

@Test
func segmentQueueStoresFrameReferencesInFIFOOrder() async {
    let queue = SegmentJobQueue(capacity: 2)
    let first = SegmentReference(
        segmentationRunID: "seg_run_01",
        segmentID: "seg_01",
        startFrame: 0,
        endFrame: 48_000
    )
    let second = SegmentReference(
        segmentationRunID: "seg_run_01",
        segmentID: "seg_02",
        startFrame: 48_000,
        endFrame: 96_000
    )

    #expect(await queue.tryEnqueue(first))
    #expect(await queue.tryEnqueue(second))
    #expect(await queue.dequeue() == first)
    #expect(await queue.dequeue() == second)
}

@Test
func segmentQueueRejectsOverflowWithoutBlockingCapture() async {
    let queue = SegmentJobQueue(capacity: 1)
    let first = SegmentReference(
        segmentationRunID: "seg_run_01",
        segmentID: "seg_01",
        startFrame: 0,
        endFrame: 1_000
    )
    let overflow = SegmentReference(
        segmentationRunID: "seg_run_01",
        segmentID: "seg_02",
        startFrame: 1_000,
        endFrame: 2_000
    )

    #expect(await queue.tryEnqueue(first))
    #expect(!(await queue.tryEnqueue(overflow)))
    #expect(await queue.overflowCount == 1)
    #expect(await queue.count == 1)
}

@Test
func segmentationAssemblerKeepsShortUtterancesAndAppliesPreRoll() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 100,
        maxSegmentFrames: 10_000
    )

    assembler.speechStarted(atFrame: 1_000)
    let segment = assembler.speechEnded(atFrame: 1_080)

    #expect(segment?.startFrame == 900)
    #expect(segment?.endFrame == 1_080)
}
