import Testing
import MacAmbientJevCore
import MacAmbientJevPipeline

private let maximumSpeechRangeFrames: Int64 = 224_000

private func processSamples(
    _ samples: [Float],
    event: VADStreamEvent? = nil,
    state: inout VADSegmentationState,
    processedSamples: inout Int64
) -> [SegmentReference] {
    #expect(samples.count <= 4_096)
    processedSamples += Int64(samples.count)
    return state.process(samples: samples, event: event, processedSamples: processedSamples)
}

private func uniformSamples(
    startingAt startFrame: Int64,
    count: Int,
    quietRange: Range<Int64>? = nil
) -> [Float] {
    guard let quietRange else { return Array(repeating: 1, count: count) }
    return (0..<count).map { offset in
        quietRange.contains(startFrame + Int64(offset)) ? 0 : 1
    }
}

private func feedSpeech(
    until totalFrames: Int64,
    quietRange: Range<Int64>? = nil,
    state: inout VADSegmentationState,
    processedSamples: inout Int64
) -> [SegmentReference] {
    var segments: [SegmentReference] = []
    while processedSamples < totalFrames {
        let count = Int(min(4_096, totalFrames - processedSamples))
        let samples = uniformSamples(
            startingAt: processedSamples, count: count, quietRange: quietRange
        )
        segments.append(contentsOf: processSamples(
            samples, state: &state, processedSamples: &processedSamples
        ))
    }
    return segments
}

private actor ProbabilityVADChunkEngine: VADChunkSegmenting {
    nonisolated let chunkSize = 4_096
    private var segmenter: VADProbabilitySegmenter
    private let probabilities: [Float]
    private var probabilityIndex = 0

    init(probabilities: [Float], segmentationRunID: String) {
        self.probabilities = probabilities
        self.segmenter = VADProbabilitySegmenter(
            segmentationRunID: segmentationRunID, canonicalSampleRate: 16_000
        )
    }

    func process16kChunk(_ samples: [Float]) async throws -> VADChunkOutput {
        let segments = segmenter.process(samples: samples, probability: probabilities[probabilityIndex])
        probabilityIndex += 1
        return VADChunkOutput(segments: segments, micLevel: nil)
    }

    func finish(totalCanonicalFrames: Int64) async -> [SegmentReference] {
        segmenter.finish(totalCanonicalFrames: totalCanonicalFrames)
    }
}

private struct SyntheticVADTimeline: TimelineAudioReading {
    let info: TimelineAudioInfo

    func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        Array(repeating: 1, count: Int(frameRange.count))
    }

    func validateAudio() throws {}
}

@Suite("VADSegmentationStateTests")
struct VADSegmentationStateTests {
    @Test
    func quietFrameChoosesSplitAndFinishClosesContinuation() throws {
        var state = VADSegmentationState(segmentationRunID: "quiet", canonicalSampleRate: 16_000)
        var processedSamples: Int64 = 0
        var emitted = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VADStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &state, processedSamples: &processedSamples
        )
        emitted += feedSpeech(
            until: maximumSpeechRangeFrames,
            quietRange: 208_000..<208_320,
            state: &state, processedSamples: &processedSamples
        )

        #expect(emitted.isEmpty)
        let segments = state.finish(totalCanonicalFrames: processedSamples)
        #expect(segments.count == 1)
        let ranges = try #require(segments.first?.speechRanges)
        #expect(ranges.map(\.lowerBound) == [0, 208_160])
        #expect(ranges.map(\.upperBound) == [208_160, maximumSpeechRangeFrames])
        #expect(ranges[1].lowerBound == ranges[0].upperBound)
    }

    @Test
    func uniformEnergyChoosesEarliestSplitFrame() throws {
        var state = VADSegmentationState(segmentationRunID: "uniform", canonicalSampleRate: 16_000)
        var processedSamples: Int64 = 0
        var emitted = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VADStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &state, processedSamples: &processedSamples
        )
        emitted += feedSpeech(
            until: maximumSpeechRangeFrames,
            state: &state, processedSamples: &processedSamples
        )

        #expect(emitted.isEmpty)
        let segments = state.finish(totalCanonicalFrames: processedSamples)
        #expect(segments.count == 1)
        #expect(segments[0].speechRanges.map(\.upperBound) == [192_160, maximumSpeechRangeFrames])
    }

    @Test
    func unalignedSpeechStartUsesPreRollAndSearchWindow() throws {
        var state = VADSegmentationState(segmentationRunID: "unaligned", canonicalSampleRate: 16_000)
        var processedSamples: Int64 = 0
        _ = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            state: &state, processedSamples: &processedSamples
        )
        var emitted = processSamples(
            uniformSamples(startingAt: processedSamples, count: 4_096),
            event: VADStreamEvent(kind: .speechStart, sampleIndex: 4_096),
            state: &state, processedSamples: &processedSamples
        )
        emitted += feedSpeech(
            until: 2_496 + maximumSpeechRangeFrames,
            quietRange: 208_000..<208_320,
            state: &state, processedSamples: &processedSamples
        )

        #expect(emitted.isEmpty)
        let segments = state.finish(totalCanonicalFrames: processedSamples)
        #expect(segments.count == 1)
        let ranges = try #require(segments.first?.speechRanges)
        #expect(ranges.map(\.lowerBound) == [2_496, 208_160])
        #expect(ranges.map(\.upperBound) == [208_160, 2_496 + maximumSpeechRangeFrames])
        #expect(ranges[1].lowerBound == ranges[0].upperBound)
    }

    @Test
    func shortIndependentSpeechDropsAndMinimumLengthEmitsOnce() throws {
        var shortState = VADSegmentationState(segmentationRunID: "short", canonicalSampleRate: 16_000)
        var shortProcessed: Int64 = 0
        _ = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VADStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &shortState, processedSamples: &shortProcessed
        )
        let shortResult = processSamples(
            uniformSamples(startingAt: shortProcessed, count: 3_744),
            event: VADStreamEvent(kind: .speechEnd, sampleIndex: 7_840),
            state: &shortState, processedSamples: &shortProcessed
        )
        #expect(shortProcessed == 7_840)
        #expect(shortResult.isEmpty)
        #expect(shortState.finish(totalCanonicalFrames: shortProcessed).isEmpty)

        var minimumState = VADSegmentationState(segmentationRunID: "minimum", canonicalSampleRate: 16_000)
        var minimumProcessed: Int64 = 0
        _ = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VADStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &minimumState, processedSamples: &minimumProcessed
        )
        let minimumResult = processSamples(
            uniformSamples(startingAt: minimumProcessed, count: 3_904),
            event: VADStreamEvent(kind: .speechEnd, sampleIndex: 8_000),
            state: &minimumState, processedSamples: &minimumProcessed
        )
        #expect(minimumProcessed == 8_000)
        #expect(minimumResult.isEmpty)
        let minimumSegments = minimumState.finish(totalCanonicalFrames: minimumProcessed)
        #expect(minimumSegments.count == 1)
        #expect(minimumSegments[0].speechRanges == [0..<8_000])
    }

    @Test
    func speechEndAfterSelectedCutKeepsFourMillisecondContinuationTail() throws {
        var state = VADSegmentationState(segmentationRunID: "tail", canonicalSampleRate: 16_000)
        var processedSamples: Int64 = 0
        var emitted = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VADStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &state, processedSamples: &processedSamples
        )
        emitted += feedSpeech(
            until: maximumSpeechRangeFrames,
            quietRange: 208_000..<208_320,
            state: &state, processedSamples: &processedSamples
        )
        #expect(emitted.isEmpty)
        let cutFrame: Int64 = 208_160
        let tail = processSamples(
            uniformSamples(startingAt: processedSamples, count: 64),
            event: VADStreamEvent(kind: .speechEnd, sampleIndex: Int(cutFrame + 64)),
            state: &state, processedSamples: &processedSamples
        )

        #expect(tail.isEmpty)
        #expect(processedSamples == maximumSpeechRangeFrames + 64)
        let segments = state.finish(totalCanonicalFrames: processedSamples)
        #expect(segments.count == 1)
        #expect(segments[0].speechRanges == [0..<cutFrame, cutFrame..<(cutFrame + 64)])
    }

    @Test
    func prolongedUniformSpeechStaysBoundedAndContiguousThroughFinish() throws {
        let totalFrames: Int64 = 45 * 16_000
        var state = VADSegmentationState(segmentationRunID: "long", canonicalSampleRate: 16_000)
        var processedSamples: Int64 = 0
        var segments = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VADStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &state, processedSamples: &processedSamples
        )
        segments += feedSpeech(
            until: totalFrames,
            state: &state, processedSamples: &processedSamples
        )
        segments += state.finish(totalCanonicalFrames: processedSamples)

        #expect(segments.count >= 2)
        #expect(segments.first?.startFrame == 0)
        #expect(segments.last?.endFrame == totalFrames)
        let maximumSegmentSpanFrames: Int64 = 30 * 16_000
        for segment in segments {
            #expect(SegmentReference.isValid(segment.speechRanges))
            #expect(segment.endFrame - segment.startFrame <= maximumSegmentSpanFrames)
        }
        let speechRanges = segments.flatMap(\.speechRanges)
        for index in speechRanges.indices {
            #expect(speechRanges[index].upperBound - speechRanges[index].lowerBound <= maximumSpeechRangeFrames)
            if index > 0 {
                #expect(speechRanges[index - 1].upperBound == speechRanges[index].lowerBound)
            }
        }
    }

    @Test
    func finishUsesActualPartialChunkLength() throws {
        let totalFrames: Int64 = maximumSpeechRangeFrames + 123
        var state = VADSegmentationState(segmentationRunID: "partial", canonicalSampleRate: 16_000)
        var processedSamples: Int64 = 0
        var emitted = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VADStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &state, processedSamples: &processedSamples
        )
        emitted += feedSpeech(
            until: totalFrames,
            state: &state, processedSamples: &processedSamples
        )
        let finalSegments = state.finish(totalCanonicalFrames: processedSamples)

        #expect(processedSamples == totalFrames)
        #expect(emitted.isEmpty)
        #expect(finalSegments.count == 1)
        #expect(finalSegments[0].speechRanges.count == 2)
        #expect(finalSegments[0].speechRanges[0].upperBound == finalSegments[0].speechRanges[1].lowerBound)
        #expect(finalSegments[0].endFrame == totalFrames)
    }

    @Test(arguments: [true, false])
    func longProbabilityRunsReleaseValidGroupsWithinTheCaseBound(_ continuousSpeech: Bool) {
        let probabilities = continuousSpeech
            ? [Float](repeating: 0.9, count: 280)
            : [Float](repeating: 0.9, count: 16) + [Float](repeating: 0.1, count: 240)
        var segmenter = VADProbabilitySegmenter(segmentationRunID: "bounded", canonicalSampleRate: 16_000)
        var processEmissions: [SegmentReference] = []
        for probability in probabilities {
            let emitted = segmenter.process(samples: [Float](repeating: 1, count: 4_096), probability: probability)
            let cursor = Int64(segmenter.processedSamples)
            for segment in emitted {
                #expect(SegmentReference.isValid(segment.speechRanges))
                #expect(cursor - segment.startFrame <= 32 * 16_000 + 4_096)
            }
            processEmissions += emitted
        }
        let finished = segmenter.finish(totalCanonicalFrames: Int64(segmenter.processedSamples))
        let allSegments = processEmissions + finished
        #expect(!allSegments.isEmpty)
        #expect(!processEmissions.isEmpty)
        for segment in allSegments { #expect(SegmentReference.isValid(segment.speechRanges)) }
        if !continuousSpeech { #expect(allSegments.count == 1) }
    }

    @Test
    func liveAndFinalTimelineDrainingMatchForSyntheticMixedProbabilities() async throws {
        let probabilities = [Float](repeating: 0.9, count: 16) + [Float](repeating: 0.1, count: 64)
            + [Float](repeating: 0.9, count: 16) + [0.1] + [Float](repeating: 0.4, count: 28)
            + [0.1] + [Float](repeating: 0.9, count: 160) + [Float](repeating: 0.1, count: 10)
        let totalFrames = Int64(probabilities.count * 4_096 - 123)
        let finalReader = SyntheticVADTimeline(info: try TimelineAudioInfo(committedFrames: totalFrames, gapEvents: []))
        let finalProcessor = VADTimelineProcessor(engine: ProbabilityVADChunkEngine(probabilities: probabilities, segmentationRunID: "mixed"))
        let finalSegments = try await finalProcessor.segmentAll(reader: finalReader)
        let liveProcessor = VADTimelineProcessor(engine: ProbabilityVADChunkEngine(probabilities: probabilities, segmentationRunID: "mixed"))
        var liveSegments: [SegmentReference] = []
        var committed: Int64 = 0
        while committed < totalFrames {
            committed = min(committed + 8_000, totalFrames)
            let reader = SyntheticVADTimeline(info: try TimelineAudioInfo(committedFrames: committed, gapEvents: []))
            liveSegments += try await liveProcessor.processAvailable(reader: reader)
        }
        liveSegments += try await liveProcessor.finish(reader: finalReader)
        #expect(liveSegments == finalSegments)
        #expect(liveSegments.count > 1)
        for segment in liveSegments { #expect(SegmentReference.isValid(segment.speechRanges)) }
    }

    @Test
    func delayedSpeechEndReleasesEarlierGroupBeforeClosingLaterRange() {
        let probabilities = [Float](repeating: 0.9, count: 16) + [Float](repeating: 0.1, count: 64)
            + [Float](repeating: 0.9, count: 16) + [0.1] + [Float](repeating: 0.4, count: 28) + [0.1]
        var segmenter = VADProbabilitySegmenter(segmentationRunID: "delayed", canonicalSampleRate: 16_000)
        var beforeDelayedEnd: [SegmentReference] = []
        for (index, probability) in probabilities.enumerated() {
            let emitted = segmenter.process(samples: [Float](repeating: 1, count: 4_096), probability: probability)
            if index < 125 { beforeDelayedEnd += emitted }
            if index == 125 { #expect(emitted.isEmpty) }
        }
        #expect(beforeDelayedEnd.count == 1)
        let first = beforeDelayedEnd[0]
        #expect(first.segmentID == "seg_000001")
        #expect(first.speechRanges == [0..<65_536])
        #expect(SegmentReference.isValid(first.speechRanges))
        let finished = segmenter.finish(totalCanonicalFrames: Int64(probabilities.count * 4_096))
        #expect(finished.count == 1)
        #expect(finished[0].segmentID == "seg_000002")
        #expect(finished[0].speechRanges == [326_080..<393_216])
        #expect(SegmentReference.isValid(finished[0].speechRanges))
        #expect(first.endFrame <= finished[0].startFrame)
    }
}
