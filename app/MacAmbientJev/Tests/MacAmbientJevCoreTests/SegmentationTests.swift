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
        maxSegmentFrames: 1_000,
        minimumSegmentFrames: 30
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
func segmentationAssemblerSuppressesUnusableSegmentsButKeepsShortSpeech() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 0,
        maxSegmentFrames: 672_000,
        minimumSegmentFrames: 960
    )

    assembler.speechStarted(atFrame: 190_344_768)
    let full = assembler.splitIfNeeded(atFrame: 191_016_768)
    let tail = assembler.speechEnded(atFrame: 191_016_960)
    assembler.speechStarted(atFrame: 191_020_000)
    let shortSpeech = assembler.speechEnded(atFrame: 191_023_840)
    assembler.speechStarted(atFrame: 191_030_000)
    let shorterSpeech = assembler.speechEnded(atFrame: 191_031_152)

    #expect(full?.segmentID == "seg_000001")
    #expect(full?.startFrame == 190_344_768)
    #expect(full?.endFrame == 191_016_768)
    #expect(tail == nil)
    #expect(shortSpeech?.segmentID == "seg_000002")
    #expect(shortSpeech?.startFrame == 191_020_000)
    #expect(shortSpeech?.endFrame == 191_023_840)
    #expect(shorterSpeech?.segmentID == "seg_000003")
    #expect(shorterSpeech?.startFrame == 191_030_000)
    #expect(shorterSpeech?.endFrame == 191_031_152)

    assembler.speechStarted(atFrame: 191_040_000)
    #expect(assembler.speechEnded(atFrame: 191_040_192) == nil)
}

@Test
func segmentationAssemblerSuppressesSplitTailAtEndOfInput() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 0,
        maxSegmentFrames: 672_000,
        minimumSegmentFrames: 960
    )

    assembler.speechStarted(atFrame: 0)
    let full = assembler.splitIfNeeded(atFrame: 672_000)

    #expect(assembler.finish(atFrame: 672_192) == nil)
    #expect(full?.startFrame == 0)
    #expect(full?.endFrame == 672_000)
    #expect(assembler.finish(atFrame: 672_192) == nil)
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

@Test
func segmentationAssemblerPublishesStableOpenSpeechRangeBoundedByDurableFrames() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 100,
        maxSegmentFrames: 10_000
    )

    #expect(assembler.openSpeechRange(upToFrame: 1_000) == nil)

    assembler.speechStarted(atFrame: 1_000)
    let first = assembler.openSpeechRange(upToFrame: 1_500)
    let later = assembler.openSpeechRange(upToFrame: 1_700)

    #expect(first?.startFrame == 900)
    #expect(first?.endFrame == 1_500)
    #expect(first?.utteranceID == later?.utteranceID)
    #expect(later?.endFrame == 1_700)
    #expect(assembler.openSpeechRange(upToFrame: 800) == nil)

    _ = assembler.splitIfNeeded(atFrame: 10_900)
    let afterMaxSegment = assembler.openSpeechRange(upToFrame: 11_000)
    #expect(afterMaxSegment?.utteranceID != first?.utteranceID)
    #expect(afterMaxSegment?.startFrame == 10_900)
    #expect(afterMaxSegment?.endFrame == 11_000)

    _ = assembler.speechEnded(atFrame: 11_000)
    #expect(assembler.openSpeechRange(upToFrame: 11_000) == nil)
}

@Test
func segmentationAssemblerBoundsOpenSnapshotsAcrossContinuousMaxSplits() {
    let maxSegmentFrames: Int64 = 14 * 16_000
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_long_speech",
        preRollFrames: 0,
        maxSegmentFrames: maxSegmentFrames
    )
    assembler.speechStarted(atFrame: 0)

    var expectedStart: Int64 = 0
    var previousUtteranceID: String?
    for splitIndex in 1...4 {
        let boundary = Int64(splitIndex) * maxSegmentFrames
        let segment = assembler.splitIfNeeded(atFrame: boundary)
        let openRange = assembler.openSpeechRange(upToFrame: boundary + 16_000)

        #expect(segment?.startFrame == expectedStart)
        #expect(segment?.endFrame == boundary)
        #expect(openRange?.startFrame == boundary)
        #expect(openRange?.endFrame == boundary + 16_000)
        if let openRange {
            #expect(openRange.endFrame - openRange.startFrame <= maxSegmentFrames)
        }
        if let previousUtteranceID {
            #expect(openRange?.utteranceID != previousUtteranceID)
        }
        previousUtteranceID = openRange?.utteranceID
        expectedStart = boundary
    }
}
