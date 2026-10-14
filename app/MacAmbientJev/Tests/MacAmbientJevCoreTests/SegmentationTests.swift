import Testing
@testable import MacAmbientJevCore

@Test
func rollingHistorySelectsQuietestFrameForChosenMaximumLengthSplit() {
    let frameSampleCount = 320
    let maxSegmentFrames: Int64 = 224_000
    var samples = [Float](repeating: 1, count: Int(maxSegmentFrames))
    for sampleIndex in 208_000..<208_320 {
        samples[sampleIndex] = 0
    }

    var history = RollingFrameEnergyHistory(frameSampleCount: frameSampleCount, capacity: 150)
    var offset = 0
    while offset < samples.count {
        let end = min(offset + 4_096, samples.count)
        let batch = Array(samples[offset..<end])
        #expect(batch.count <= 4_096)
        history.append(batch)
        offset = end
    }

    #expect(history.processedSamples == maxSegmentFrames)
    #expect(history.storedFrameCount == 150)
    #expect(history.quietestFrame(in: 192_000..<224_000) == 208_160)

    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 0,
        maxSegmentFrames: maxSegmentFrames,
        minimumIndependentSegmentFrames: 8_000
    )
    assembler.speechStarted(atFrame: 0)
    #expect(assembler.splitStartFrameIfNeeded(atFrame: 223_999) == nil)
    #expect(assembler.splitStartFrameIfNeeded(atFrame: maxSegmentFrames) == 0)

    let first = assembler.split(atFrame: history.quietestFrame(in: 192_000..<224_000))
    let continuation = assembler.speechEnded(atFrame: maxSegmentFrames).first
    #expect(first.startFrame == 0)
    #expect(first.endFrame == 208_160)
    #expect(continuation?.startFrame == first.endFrame)
    #expect(continuation?.endFrame == maxSegmentFrames)
    #expect(first.endFrame == continuation?.startFrame)
}

@Test
func rollingHistoryUniformEnergyChoosesEarliestCompleteFrame() {
    let sampleCount = 224_000
    var history = RollingFrameEnergyHistory(frameSampleCount: 320, capacity: 150)
    history.append([Float](repeating: 1, count: sampleCount))

    #expect(history.quietestFrame(in: 192_000..<224_000) == 192_160)
}

@Test
func rollingHistoryUsesOnlyCompleteAlignedFramesInUnalignedRange() {
    var history = RollingFrameEnergyHistory(frameSampleCount: 320, capacity: 10)
    var samples = [Float](repeating: 0, count: 320)
    samples.append(contentsOf: [Float](repeating: 1, count: 320))
    samples.append(contentsOf: [Float](repeating: 0.5, count: 320))
    history.append(samples)

    #expect(history.quietestFrame(in: 100..<960) == 800)
}

@Test
func rollingHistoryCombinesPartialSamplesAndKeepsEarliestEnergyTie() {
    var history = RollingFrameEnergyHistory(frameSampleCount: 4, capacity: 3)
    history.append([1, 1])
    #expect(history.processedSamples == 2)
    #expect(history.storedFrameCount == 0)

    history.append([0, 0, 0.25])
    #expect(history.storedFrameCount == 1)
    history.append([0.25, 0.25, 0.25, -0.25])
    #expect(history.storedFrameCount == 2)
    history.append([-0.25, -0.25, -0.25])

    #expect(history.processedSamples == 12)
    #expect(history.storedFrameCount == 3)
    #expect(history.quietestFrame(in: 0..<12) == 6)
}

@Test
func independentSegmentsApplyMinimumWithoutAdvancingIDsForDroppedSpeech() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 0,
        maxSegmentFrames: 224_000,
        minimumIndependentSegmentFrames: 8_000
    )

    assembler.speechStarted(atFrame: 0)
    #expect(assembler.speechEnded(atFrame: 7_840).isEmpty)
    assembler.speechStarted(atFrame: 10_000)
    let emitted = assembler.speechEnded(atFrame: 18_000).first

    #expect(emitted?.segmentID == "seg_000001")
    #expect(emitted?.startFrame == 10_000)
    #expect(emitted?.endFrame == 18_000)
}

@Test
func preRollClampsAtZeroAndCountsTowardIndependentMinimum() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 100,
        maxSegmentFrames: 224_000,
        minimumIndependentSegmentFrames: 8_000
    )

    assembler.speechStarted(atFrame: 30)
    assembler.speechStarted(atFrame: 1_000)
    #expect(assembler.speechEnded(atFrame: 7_999).isEmpty)

    assembler.speechStarted(atFrame: 200)
    let segment = assembler.speechEnded(atFrame: 8_100).first
    #expect(segment?.segmentID == "seg_000001")
    #expect(segment?.startFrame == 100)
    #expect(segment?.endFrame == 8_100)
}

@Test
func explicitlySplitContinuationEmitsFourMillisecondTail() {
    let maxSegmentFrames: Int64 = 224_000
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 0,
        maxSegmentFrames: maxSegmentFrames,
        minimumIndependentSegmentFrames: 8_000
    )

    assembler.speechStarted(atFrame: 0)
    #expect(assembler.splitStartFrameIfNeeded(atFrame: maxSegmentFrames) == 0)
    let first = assembler.split(atFrame: maxSegmentFrames)
    let tail = assembler.speechEnded(atFrame: maxSegmentFrames + 64).first

    #expect(first.endFrame == maxSegmentFrames)
    #expect(tail?.startFrame == maxSegmentFrames)
    #expect(tail?.endFrame == maxSegmentFrames + 64)
}

@Test
func repeatedSpeechEndsEmitNothingAfterClosingAndWithoutActiveSpeech() {
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 0,
        maxSegmentFrames: 224_000,
        minimumIndependentSegmentFrames: 8_000
    )

    #expect(assembler.speechEnded(atFrame: 1_000).isEmpty)
    assembler.speechStarted(atFrame: 0)
    #expect(assembler.speechEnded(atFrame: 8_000).count == 1)
    #expect(assembler.speechEnded(atFrame: 8_000).isEmpty)
}

@Test
func prolongedSpeechRequiresExplicitMaximumLengthCutsWithoutGaps() {
    let maxSegmentFrames: Int64 = 224_000
    var assembler = SegmentationAssembler(
        segmentationRunID: "seg_run_01",
        preRollFrames: 0,
        maxSegmentFrames: maxSegmentFrames,
        minimumIndependentSegmentFrames: 8_000
    )
    assembler.speechStarted(atFrame: 0)

    var segments: [SegmentReference] = []
    var activeStart: Int64 = 0
    for _ in 0..<3 {
        let cutFrame = activeStart + maxSegmentFrames
        #expect(assembler.splitStartFrameIfNeeded(atFrame: cutFrame - 1) == nil)
        #expect(assembler.splitStartFrameIfNeeded(atFrame: cutFrame) == activeStart)
        segments.append(assembler.split(atFrame: cutFrame))
        activeStart = cutFrame
    }
    segments.append(contentsOf: assembler.speechEnded(atFrame: activeStart + 123))

    #expect(segments.count == 4)
    #expect(segments.first?.startFrame == 0)
    #expect(segments.last?.endFrame == activeStart + 123)
    for index in segments.indices {
        #expect(segments[index].endFrame - segments[index].startFrame <= maxSegmentFrames)
        if index > 0 {
            #expect(segments[index - 1].endFrame == segments[index].startFrame)
        }
    }
}

@Test
func tenMinuteHistoryRetainsOnlyCapacityAndFindsRecentKnownEnergy() {
    let totalSamples = 9_600_000
    let quietFrameStart = 9_599_360
    var history = RollingFrameEnergyHistory(frameSampleCount: 320, capacity: 150)
    let reusableChunk = [Float](repeating: 1, count: 4_096)
    var offset = 0

    while offset < quietFrameStart {
        let count = min(reusableChunk.count, quietFrameStart - offset)
        history.append(count == reusableChunk.count ? reusableChunk : Array(reusableChunk.prefix(count)))
        offset += count
        #expect(history.storedFrameCount <= 150)
    }

    history.append([Float](repeating: 0, count: 320))
    offset += 320
    while offset < totalSamples {
        let count = min(reusableChunk.count, totalSamples - offset)
        history.append(count == reusableChunk.count ? reusableChunk : Array(reusableChunk.prefix(count)))
        offset += count
        #expect(history.storedFrameCount <= 150)
    }

    #expect(history.processedSamples == 9_600_000)
    #expect(history.storedFrameCount == 150)
    #expect(history.quietestFrame(in: Int64(quietFrameStart)..<Int64(quietFrameStart + 320)) == Int64(quietFrameStart + 160))
}
