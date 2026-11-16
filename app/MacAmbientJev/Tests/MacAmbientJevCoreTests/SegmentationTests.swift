import Testing
@testable import MacAmbientJevCore

@Test
func rollingHistorySelectsQuietestFrameForChosenMaximumLengthSplit() {
    let frameSampleCount = 320
    let maxSpeechRangeFrames: Int64 = 224_000
    var samples = [Float](repeating: 1, count: Int(maxSpeechRangeFrames))
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

    #expect(history.processedSamples == maxSpeechRangeFrames)
    #expect(history.storedFrameCount == 150)
    #expect(history.quietestFrame(in: 192_000..<224_000) == 208_160)

    var assembler = SpeechRangeAssembler(
        preRollFrames: 0,
        maxSpeechRangeFrames: maxSpeechRangeFrames,
        minimumIndependentSpeechRangeFrames: 8_000
    )
    assembler.speechStarted(atFrame: 0)
    #expect(assembler.splitStartFrameIfNeeded(atFrame: 223_999) == nil)
    #expect(assembler.splitStartFrameIfNeeded(atFrame: maxSpeechRangeFrames) == 0)

    let firstRange = assembler.split(atFrame: history.quietestFrame(in: 192_000..<224_000))
    let continuationRange = assembler.speechEnded(atFrame: maxSpeechRangeFrames)
    #expect(firstRange.lowerBound == 0)
    #expect(firstRange.upperBound == 208_160)
    #expect(continuationRange?.lowerBound == firstRange.upperBound)
    #expect(continuationRange?.upperBound == maxSpeechRangeFrames)
    #expect(firstRange.upperBound == continuationRange?.lowerBound)
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
func independentSpeechRangesApplyMinimumAndDropShortSpeech() {
    var assembler = SpeechRangeAssembler(
        preRollFrames: 0,
        maxSpeechRangeFrames: 224_000,
        minimumIndependentSpeechRangeFrames: 8_000
    )

    assembler.speechStarted(atFrame: 0)
    #expect(assembler.speechEnded(atFrame: 7_840) == nil)
    assembler.speechStarted(atFrame: 10_000)
    let emittedRange = assembler.speechEnded(atFrame: 18_000)

    #expect(emittedRange?.lowerBound == 10_000)
    #expect(emittedRange?.upperBound == 18_000)
}

@Test
func preRollClampsAtZeroAndCountsTowardIndependentSpeechRangeMinimum() {
    var assembler = SpeechRangeAssembler(
        preRollFrames: 100,
        maxSpeechRangeFrames: 224_000,
        minimumIndependentSpeechRangeFrames: 8_000
    )

    assembler.speechStarted(atFrame: 30)
    assembler.speechStarted(atFrame: 1_000)
    #expect(assembler.speechEnded(atFrame: 7_999) == nil)

    assembler.speechStarted(atFrame: 200)
    let speechRange = assembler.speechEnded(atFrame: 8_100)
    #expect(speechRange?.lowerBound == 100)
    #expect(speechRange?.upperBound == 8_100)
}

@Test
func repeatedSpeechEndsEmitNothingAfterClosingAndWithoutActiveSpeech() {
    var assembler = SpeechRangeAssembler(
        preRollFrames: 0,
        maxSpeechRangeFrames: 224_000,
        minimumIndependentSpeechRangeFrames: 8_000
    )

    #expect(assembler.speechEnded(atFrame: 1_000) == nil)
    assembler.speechStarted(atFrame: 0)
    #expect(assembler.speechEnded(atFrame: 8_000) != nil)
    #expect(assembler.speechEnded(atFrame: 8_000) == nil)
}

@Test
func prolongedSpeechRequiresExplicitMaximumLengthCutsWithoutGaps() {
    let maxSpeechRangeFrames: Int64 = 224_000
    var assembler = SpeechRangeAssembler(
        preRollFrames: 0,
        maxSpeechRangeFrames: maxSpeechRangeFrames,
        minimumIndependentSpeechRangeFrames: 8_000
    )
    assembler.speechStarted(atFrame: 0)

    var ranges: [Range<Int64>] = []
    var activeStart: Int64 = 0
    for _ in 0..<3 {
        let cutFrame = activeStart + maxSpeechRangeFrames
        #expect(assembler.splitStartFrameIfNeeded(atFrame: cutFrame - 1) == nil)
        #expect(assembler.splitStartFrameIfNeeded(atFrame: cutFrame) == activeStart)
        ranges.append(assembler.split(atFrame: cutFrame))
        activeStart = cutFrame
    }
    let continuationRange = assembler.speechEnded(atFrame: activeStart + 123)

    #expect(ranges.count == 3)
    #expect(ranges.first?.lowerBound == 0)
    #expect(continuationRange?.upperBound == activeStart + 123)
    #expect(ranges.last?.upperBound == continuationRange?.lowerBound)
    for index in ranges.indices {
        #expect(ranges[index].upperBound - ranges[index].lowerBound <= maxSpeechRangeFrames)
        if index > 0 {
            #expect(ranges[index - 1].upperBound == ranges[index].lowerBound)
        }
    }
}
