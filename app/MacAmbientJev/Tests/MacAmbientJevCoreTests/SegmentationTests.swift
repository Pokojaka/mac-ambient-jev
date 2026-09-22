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

@Test
func segmentationAssemblerSplitsLongUtteranceWithoutDroppingContinuation() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 0,
        maxSegmentFrames: 1_000
    )

    assembler.speechStarted(atFrame: 500)
    let first = assembler.splitIfNeeded(atFrame: 1_500)
    let second = assembler.speechEnded(atFrame: 1_800)

    #expect(first?.startFrame == 500)
    #expect(first?.endFrame == 1_500)
    #expect(second?.startFrame == 1_500)
    #expect(second?.endFrame == 1_800)
}

@Test
func vadFrameMapperMaps16kSamplesOntoCanonicalTimeline() {
    let mapper = VADFrameMapper(canonicalSampleRate: 48_000)
    #expect(mapper.canonicalFrame(forVADSample: 16_000) == 48_000)
}


@Test
func segmentationAssemblerFlushesOpenSpeechAtEndOfInput() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 100,
        maxSegmentFrames: 10_000
    )

    assembler.speechStarted(atFrame: 1_000)
    let segment = assembler.finish(atFrame: 1_750)

    #expect(segment?.startFrame == 900)
    #expect(segment?.endFrame == 1_750)
}

@Test
func segmentationAssemblerFinishIsIdempotentWithoutOpenSpeech() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 0,
        maxSegmentFrames: 10_000
    )

    #expect(assembler.finish(atFrame: 1_000) == nil)
}
