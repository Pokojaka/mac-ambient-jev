import Testing
@testable import MacAmbientJevCore

@Test
func asrAudioLoaderLoadsSeparateSpeechRanges() throws {
    let reader = try SpeechRangeTimelineAudioReader()
    let segment = SegmentReference(
        segmentationRunID: "seg_run",
        segmentID: "seg_1",
        speechRanges: [1..<3, 6..<8]
    )

    let input = try ASRAudioLoader(reader: reader).load(segment: segment)

    #expect(input.samples == [1, 2, 3, 4])
    #expect(!input.samples.contains(-999))
    #expect(input.sampleRate == 16_000)
}

private struct SpeechRangeTimelineAudioReader: TimelineAudioReading {
    let info: TimelineAudioInfo
    private let samples: [Float] = [-999, 1, 2, -999, -999, -999, 3, 4, -999]

    init() throws {
        info = try TimelineAudioInfo(committedFrames: 9, gapEvents: [])
    }

    func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        #expect(frameRange == 1..<3 || frameRange == 6..<8)
        return Array(samples[Int(frameRange.lowerBound)..<Int(frameRange.upperBound)])
    }

    func validateAudio() throws {}
}
