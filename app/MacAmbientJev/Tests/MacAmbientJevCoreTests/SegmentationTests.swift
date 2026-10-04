import Testing
@testable import MacAmbientJevCore

@Test
func segmentationAssemblerKeepsShortUtterancesAndAppliesPreRoll() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 100,
        maxSegmentFrames: 10_000,
        minimumSegmentFrames: 0
    )

    assembler.speechStarted(atFrame: 1_000)
    let segment = assembler.speechEnded(atFrame: 1_080).first

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
    let second = assembler.speechEnded(atFrame: 1_800).first

    #expect(first?.startFrame == 500)
    #expect(first?.endFrame == 1_500)
    #expect(second?.startFrame == 1_500)
    #expect(second?.endFrame == 1_800)
}

@Test
func segmentationAssemblerKeepsShortSplitTailAndShortSpeechButSuppressesTinyUtterances() {
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
    let shortSpeech = assembler.speechEnded(atFrame: 191_023_840).first
    assembler.speechStarted(atFrame: 191_030_000)
    let shorterSpeech = assembler.speechEnded(atFrame: 191_031_152).first

    #expect(full?.segmentID == "seg_000001")
    #expect(full?.startFrame == 190_344_768)
    #expect(full?.endFrame == 191_016_768)
    #expect(tail.map(\.segmentID) == ["seg_000002"])
    #expect(tail.first?.startFrame == 191_016_768)
    #expect(tail.first?.endFrame == 191_016_960)
    #expect(shortSpeech?.segmentID == "seg_000003")
    #expect(shortSpeech?.startFrame == 191_020_000)
    #expect(shortSpeech?.endFrame == 191_023_840)
    #expect(shorterSpeech?.segmentID == "seg_000004")
    #expect(shorterSpeech?.startFrame == 191_030_000)
    #expect(shorterSpeech?.endFrame == 191_031_152)

    assembler.speechStarted(atFrame: 191_040_000)
    #expect(assembler.speechEnded(atFrame: 191_040_192).isEmpty)
}

@Test
func segmentationAssemblerKeepsShortSplitTailAtEndOfInput() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 0,
        maxSegmentFrames: 672_000,
        minimumSegmentFrames: 960
    )

    assembler.speechStarted(atFrame: 0)
    let full = assembler.splitIfNeeded(atFrame: 672_000)

    let tail = assembler.speechEnded(atFrame: 672_192)
    #expect(full?.startFrame == 0)
    #expect(full?.endFrame == 672_000)
    #expect(tail.map(\.startFrame) == [672_000])
    #expect(tail.map(\.endFrame) == [672_192])
    #expect(assembler.speechEnded(atFrame: 672_192).isEmpty)
}

@Test
func segmentationAssemblerFlushesActiveSpeechAtEndOfInput() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 100,
        maxSegmentFrames: 10_000,
        minimumSegmentFrames: 0
    )

    assembler.speechStarted(atFrame: 1_000)
    let segment = assembler.speechEnded(atFrame: 1_750).first

    #expect(segment?.startFrame == 900)
    #expect(segment?.endFrame == 1_750)
}

@Test
func segmentationAssemblerSpeechEndWithoutActiveSpeechEmitsNothing() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 0,
        maxSegmentFrames: 10_000,
        minimumSegmentFrames: 0
    )

    #expect(assembler.speechEnded(atFrame: 1_000).isEmpty)
}

@Test
func segmentationAssemblerKeepsTailShorterThanMinimumAfterMaxSplit() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg", preRollFrames: 0,
        maxSegmentFrames: 224_000, minimumSegmentFrames: 320
    )
    assembler.speechStarted(atFrame: 0)
    let first = assembler.splitIfNeeded(atFrame: 224_000)
    let tail = assembler.speechEnded(atFrame: 224_319)
    #expect(first?.endFrame == 224_000)
    #expect(tail.map(\.startFrame) == [224_000])
    #expect(tail.map(\.endFrame) == [224_319])
}

@Test
func segmentationAssemblerSpeechEndDoesNotExceedMaxSegmentLength() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg", preRollFrames: 0,
        maxSegmentFrames: 224_000, minimumSegmentFrames: 320
    )
    assembler.speechStarted(atFrame: 0)
    let segments = assembler.speechEnded(atFrame: 448_001)
    #expect(segments.map(\.startFrame) == [0, 224_000, 448_000])
    #expect(segments.map(\.endFrame) == [224_000, 448_000, 448_001])
}
