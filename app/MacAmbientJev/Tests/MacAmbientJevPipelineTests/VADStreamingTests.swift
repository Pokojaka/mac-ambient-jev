import Testing
import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private let chunk = VADSegmentationParameters.chunkSamples

private func events(_ probabilities: [Float]) -> [Int: VADStreamEvent] {
    var machine = VADStreamingStateMachine()
    var found: [Int: VADStreamEvent] = [:]
    for (index, probability) in probabilities.enumerated() {
        if let event = machine.advance(probability: probability, chunkSampleCount: chunk) {
            found[index] = event
        }
    }
    return found
}

@Suite("VADStreamingStateMachineTests")
struct VADStreamingStateMachineTests {
    @Test
    func probabilityBelowEntryThresholdNeverStartsSpeech() {
        #expect(events([0, 0.1, 0.49, 0.4999, 0.2]).isEmpty)
    }

    @Test
    func speechStartsAtTheFirstChunkAtOrAboveTheThreshold() {
        let found = events([0.1, 0.2, 0.5, 0.9])
        #expect(found.count == 1)
        #expect(found[2] == VADStreamEvent(kind: .speechStart, sampleIndex: 2 * chunk))
    }

    @Test
    func speechEndsOnlyAfterMinimumSilenceAndPointsAtTheFirstSilentChunk() {
        // 0.75 s is 12,000 samples, so three silent chunks (12,288 samples) end speech once
        // the third one is consumed: silence is measured from the end of the first silent chunk.
        let found = events([0.9, 0.1, 0.1, 0.1, 0.1])
        #expect(found[0] == VADStreamEvent(kind: .speechStart, sampleIndex: 0))
        #expect(found[1] == nil)
        #expect(found[2] == nil)
        #expect(found[3] == nil)
        #expect(found[4] == VADStreamEvent(kind: .speechEnd, sampleIndex: chunk))
        #expect(found.count == 2)
    }

    @Test
    func silenceShorterThanMinimumKeepsSpeechOpen() {
        let found = events([0.9, 0.1, 0.1, 0.9, 0.1, 0.1, 0.9])
        #expect(found.keys.sorted() == [0])
    }

    @Test
    func deadBandProbabilityNeitherStartsNorCancelsSilence() {
        // 0.40 lies between the exit (0.35) and entry (0.50) thresholds: it does not start a
        // silence, and it does not clear one that has started.
        let noSilenceStarted = events([0.9, 0.4, 0.4, 0.4, 0.4, 0.4])
        #expect(noSilenceStarted.keys.sorted() == [0])

        let silenceKept = events([0.9, 0.1, 0.4, 0.4, 0.1])
        #expect(silenceKept[4] == VADStreamEvent(kind: .speechEnd, sampleIndex: chunk))
    }

    @Test
    func speechAtTheEntryThresholdRestartsTheSilenceTimer() {
        let found = events([0.9, 0.1, 0.1, 0.5, 0.1, 0.1, 0.1, 0.1])
        #expect(found[7] == VADStreamEvent(kind: .speechEnd, sampleIndex: 4 * chunk))
        #expect(found.count == 2)
    }

    @Test
    func newSpeechAfterAnEndStartsANewRegion() {
        let found = events([0.9, 0.1, 0.1, 0.1, 0.1, 0.9])
        #expect(found[4]?.kind == .speechEnd)
        #expect(found[5] == VADStreamEvent(kind: .speechStart, sampleIndex: 5 * chunk))
    }

    @Test
    func partialLastChunkAdvancesByItsUnpaddedLength() {
        var machine = VADStreamingStateMachine()
        _ = machine.advance(probability: 0.9, chunkSampleCount: chunk)
        _ = machine.advance(probability: 0.9, chunkSampleCount: 100)
        #expect(machine.processedSamples == chunk + 100)
        let event = machine.advance(probability: 0.9, chunkSampleCount: 1)
        #expect(event == nil)
    }

    @Test
    func startIndexOfAPartialChunkIsItsFirstSample() {
        var machine = VADStreamingStateMachine()
        _ = machine.advance(probability: 0.1, chunkSampleCount: chunk)
        let event = machine.advance(probability: 0.9, chunkSampleCount: 100)
        #expect(event == VADStreamEvent(kind: .speechStart, sampleIndex: chunk))
    }
}

@Suite("VADChunkScoringTests")
struct VADChunkScoringTests {
    @Test
    func noisyORIsTheComplementOfAllFramesBeingSilent() {
        #expect(VADChunkScoring.noisyOR([0, 0, 0]) == 0)
        #expect(VADChunkScoring.noisyOR([1, 0, 0]) == 1)
        #expect(abs(VADChunkScoring.noisyOR([0.5, 0.5]) - 0.75) < 1e-7)
        #expect(abs(VADChunkScoring.noisyOR([0.1, 0.2, 0.3]) - (1 - 0.9 * 0.8 * 0.7)) < 1e-6)
    }

    @Test
    func partialChunkRepeatsItsLastSample() {
        let padded = VADChunkScoring.paddedChunk([0.1, 0.2, 0.3], to: 6)
        #expect(padded == [0.1, 0.2, 0.3, 0.3, 0.3, 0.3])
    }

    @Test
    func fullChunkIsReturnedUnchanged() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        #expect(VADChunkScoring.paddedChunk(samples, to: 3) == samples)
    }
}

@Suite("VADProbabilitySegmenterTests")
struct VADProbabilitySegmenterTests {
    private func run(
        probabilities: [Float], tailSamples: Int = 0, sample: Float = 1
    ) -> (segments: [SegmentReference], totalFrames: Int64) {
        var segmenter = VADProbabilitySegmenter(segmentationRunID: "run", canonicalSampleRate: 16_000)
        var segments: [SegmentReference] = []
        var total: Int64 = 0
        for (index, probability) in probabilities.enumerated() {
            let count = index == probabilities.count - 1 && tailSamples > 0 ? tailSamples : chunk
            segments += segmenter.process(
                samples: [Float](repeating: sample, count: count), probability: probability
            )
            total += Int64(count)
        }
        segments += segmenter.finish(totalCanonicalFrames: total)
        return (segments, total)
    }

    @Test
    func segmentStartsPreRollBeforeTheDetectedStartAndEndsAtTheSilenceStart() {
        // Speech from chunk 2, then four silent chunks: the end event points at the start of
        // chunk 5, the first silent one.
        let probabilities: [Float] = [0, 0, 0.9, 0.9, 0.9, 0.1, 0.1, 0.1, 0.1, 0]
        let (segments, _) = run(probabilities: probabilities)
        #expect(segments.count == 1)
        #expect(segments[0].startFrame == Int64(2 * chunk) - 1_600)
        #expect(segments[0].endFrame == Int64(5 * chunk))
    }

    @Test
    func speechRunningToTheEndIsClosedAtTheActualLengthOfAPartialLastChunk() {
        let (segments, total) = run(probabilities: [0.9, 0.9, 0.9], tailSamples: 123)
        #expect(total == Int64(2 * chunk + 123))
        #expect(segments.count == 1)
        #expect(segments[0].startFrame == 0)
        #expect(segments[0].endFrame == total)
    }

    @Test
    func continuousSpeechIsSplitIntoSegmentsAtMostFourteenSecondsLong() {
        let chunks = 20 * 16_000 / chunk
        let (segments, total) = run(probabilities: [Float](repeating: 0.9, count: chunks))
        #expect(segments.count >= 2)
        #expect(segments.first?.startFrame == 0)
        #expect(segments.last?.endFrame == total)
        for index in segments.indices {
            #expect(segments[index].endFrame - segments[index].startFrame <= 224_000)
            if index > 0 {
                #expect(segments[index - 1].endFrame == segments[index].startFrame)
            }
        }
    }

    @Test
    func speechShorterThanHalfASecondIsDropped() {
        // One speech chunk (0.256 s) followed by the minimum silence ends below 0.5 s.
        let (segments, _) = run(probabilities: [0.9, 0.1, 0.1, 0.1, 0.1, 0])
        #expect(segments.isEmpty)
    }
}
