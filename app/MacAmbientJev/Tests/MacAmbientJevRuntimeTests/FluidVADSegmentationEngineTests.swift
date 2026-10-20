import FluidAudio
import Testing
import MacAmbientJevPipeline
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private let maximumSegmentFrames: Int64 = 224_000

private func processSamples(
    _ samples: [Float],
    event: VadStreamEvent? = nil,
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

@Suite("FluidVADSegmentationEngineTests")
struct FluidVADSegmentationEngineTests {
    @Test
    func vadThresholdsAndSegmentationDurationsRemainIndependent() {
        let vadConfig = FluidVADSegmentationEngine.vadConfig
        let segmentationConfig = FluidVADSegmentationEngine.segmentationConfig
        #expect(vadConfig.defaultThreshold == 0.50)
        #expect(segmentationConfig.negativeThreshold == nil)
        #expect(abs(
            segmentationConfig.effectiveNegativeThreshold(baseThreshold: vadConfig.defaultThreshold) - 0.35
        ) < 0.000_001)
        #expect(FluidVADSegmentationEngine.speechProbabilityThreshold == 0.50)
        #expect(FluidVADSegmentationEngine.splitSearchWindowSeconds == 2.0)
        #expect(FluidVADSegmentationEngine.splitEnergyFrameSeconds == 0.02)
        #expect(FluidVADSegmentationEngine.minimumIndependentSegmentSeconds == 0.5)
        #expect(FluidVADSegmentationEngine.preRollSeconds == 0.10)
        #expect(FluidVADSegmentationEngine.maxSegmentSeconds == 14.0)
        #expect(FluidVADSegmentationEngine.minSilenceSeconds == 0.75)
        #expect(MicSpeechLevelMeasurement.speechProbabilityThreshold == 0.85)
        #expect(ASRAudioInput.minimumDurationSeconds == 0.02)
    }

    @Test
    func quietFrameChoosesSplitAndFinishClosesContinuation() throws {
        var state = VADSegmentationState(segmentationRunID: "quiet", canonicalSampleRate: 16_000)
        var processedSamples: Int64 = 0
        var emitted = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VadStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &state, processedSamples: &processedSamples
        )
        emitted += feedSpeech(
            until: maximumSegmentFrames,
            quietRange: 208_000..<208_320,
            state: &state, processedSamples: &processedSamples
        )

        let first = try #require(emitted.first)
        #expect(emitted.count == 1)
        #expect(first.startFrame == 0)
        #expect(first.endFrame == 208_160)
        let continuation = try #require(state.finish(totalCanonicalFrames: processedSamples).first)
        #expect(continuation.startFrame == first.endFrame)
        #expect(continuation.endFrame == maximumSegmentFrames)
    }

    @Test
    func uniformEnergyChoosesEarliestSplitFrame() throws {
        var state = VADSegmentationState(segmentationRunID: "uniform", canonicalSampleRate: 16_000)
        var processedSamples: Int64 = 0
        var emitted = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VadStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &state, processedSamples: &processedSamples
        )
        emitted += feedSpeech(
            until: maximumSegmentFrames,
            state: &state, processedSamples: &processedSamples
        )

        #expect(emitted.count == 1)
        #expect(emitted[0].endFrame == 192_160)
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
            event: VadStreamEvent(kind: .speechStart, sampleIndex: 4_096),
            state: &state, processedSamples: &processedSamples
        )
        emitted += feedSpeech(
            until: 2_496 + maximumSegmentFrames,
            quietRange: 208_000..<208_320,
            state: &state, processedSamples: &processedSamples
        )

        let first = try #require(emitted.first)
        #expect(emitted.count == 1)
        #expect(first.startFrame == 2_496)
        #expect(first.endFrame == 208_160)
        let continuation = try #require(
            state.finish(totalCanonicalFrames: processedSamples).first
        )
        #expect(continuation.startFrame == first.endFrame)
        #expect(continuation.endFrame == 2_496 + maximumSegmentFrames)
    }

    @Test
    func shortIndependentSpeechDropsAndMinimumLengthEmitsOnce() throws {
        var shortState = VADSegmentationState(segmentationRunID: "short", canonicalSampleRate: 16_000)
        var shortProcessed: Int64 = 0
        _ = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VadStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &shortState, processedSamples: &shortProcessed
        )
        let shortResult = processSamples(
            uniformSamples(startingAt: shortProcessed, count: 3_744),
            event: VadStreamEvent(kind: .speechEnd, sampleIndex: 7_840),
            state: &shortState, processedSamples: &shortProcessed
        )
        #expect(shortProcessed == 7_840)
        #expect(shortResult.isEmpty)
        #expect(shortState.finish(totalCanonicalFrames: shortProcessed).isEmpty)

        var minimumState = VADSegmentationState(segmentationRunID: "minimum", canonicalSampleRate: 16_000)
        var minimumProcessed: Int64 = 0
        _ = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VadStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &minimumState, processedSamples: &minimumProcessed
        )
        let minimumResult = processSamples(
            uniformSamples(startingAt: minimumProcessed, count: 3_904),
            event: VadStreamEvent(kind: .speechEnd, sampleIndex: 8_000),
            state: &minimumState, processedSamples: &minimumProcessed
        )
        #expect(minimumProcessed == 8_000)
        #expect(minimumResult.map(\.startFrame) == [0])
        #expect(minimumResult.map(\.endFrame) == [8_000])
        #expect(minimumState.finish(totalCanonicalFrames: minimumProcessed).isEmpty)
    }

    @Test
    func speechEndAfterSelectedCutKeepsFourMillisecondContinuationTail() throws {
        var state = VADSegmentationState(segmentationRunID: "tail", canonicalSampleRate: 16_000)
        var processedSamples: Int64 = 0
        var emitted = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VadStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &state, processedSamples: &processedSamples
        )
        emitted += feedSpeech(
            until: maximumSegmentFrames,
            quietRange: 208_000..<208_320,
            state: &state, processedSamples: &processedSamples
        )
        let first = try #require(emitted.first)
        let tail = processSamples(
            uniformSamples(startingAt: processedSamples, count: 64),
            event: VadStreamEvent(kind: .speechEnd, sampleIndex: Int(first.endFrame + 64)),
            state: &state, processedSamples: &processedSamples
        )

        #expect(first.endFrame == 208_160)
        #expect(tail.count == 1)
        #expect(tail[0].startFrame == first.endFrame)
        #expect(tail[0].endFrame == first.endFrame + 64)
        #expect(processedSamples == maximumSegmentFrames + 64)
        #expect(state.finish(totalCanonicalFrames: processedSamples).isEmpty)
    }

    @Test
    func prolongedUniformSpeechStaysBoundedAndContiguousThroughFinish() throws {
        let totalFrames: Int64 = 45 * 16_000
        var state = VADSegmentationState(segmentationRunID: "long", canonicalSampleRate: 16_000)
        var processedSamples: Int64 = 0
        var segments = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VadStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &state, processedSamples: &processedSamples
        )
        segments += feedSpeech(
            until: totalFrames,
            state: &state, processedSamples: &processedSamples
        )
        segments += state.finish(totalCanonicalFrames: processedSamples)

        #expect(segments.count >= 4)
        #expect(segments.first?.startFrame == 0)
        #expect(segments.last?.endFrame == totalFrames)
        for index in segments.indices {
            #expect(segments[index].endFrame - segments[index].startFrame <= maximumSegmentFrames)
            if index > 0 {
                #expect(segments[index - 1].endFrame == segments[index].startFrame)
            }
        }
    }

    @Test
    func finishUsesActualPartialChunkLength() throws {
        let totalFrames: Int64 = maximumSegmentFrames + 123
        var state = VADSegmentationState(segmentationRunID: "partial", canonicalSampleRate: 16_000)
        var processedSamples: Int64 = 0
        var emitted = processSamples(
            uniformSamples(startingAt: 0, count: 4_096),
            event: VadStreamEvent(kind: .speechStart, sampleIndex: 0),
            state: &state, processedSamples: &processedSamples
        )
        emitted += feedSpeech(
            until: totalFrames,
            state: &state, processedSamples: &processedSamples
        )
        let finalSegments = state.finish(totalCanonicalFrames: processedSamples)

        #expect(processedSamples == totalFrames)
        #expect(emitted.count == 1)
        #expect(finalSegments.count == 1)
        #expect(finalSegments[0].startFrame == emitted[0].endFrame)
        #expect(finalSegments[0].endFrame == totalFrames)
    }
}
