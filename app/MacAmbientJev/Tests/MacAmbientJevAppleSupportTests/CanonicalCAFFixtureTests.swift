import AVFoundation
import Foundation
import MacAmbientJevCAFFixtures
import Testing
@testable import MacAmbientJevAppleSupport
@testable import MacAmbientJevCore

private struct ExpectedSamplesTimeline: TimelineAudioReading {
    let info: TimelineAudioInfo
    let samples: [Float]

    func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        Array(samples[Int(frameRange.lowerBound)..<Int(frameRange.upperBound)])
    }

    func validateAudio() throws {}
}

@Test func committedCanonicalCAFFixtureIsWhatTheMacExporterWrites() throws {
    let expected = try CanonicalCAFFixture.expectedSamples()
    #expect(expected.count == CanonicalCAFFixture.frameCount)
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let exported = root.appending(path: "diarization-input.caf")
    let timeline = ExpectedSamplesTimeline(
        info: try TimelineAudioInfo(committedFrames: Int64(expected.count), gapEvents: []),
        samples: expected
    )
    try ProcessingTimelineAudioExporter(framesPerBuffer: 1_000).export(reader: timeline, to: exported, sessionURL: root)
    #expect(try Data(contentsOf: exported) == Data(contentsOf: CanonicalCAFFixture.cafURL()))
}

@Test func committedCanonicalCAFFixtureReadsBackAsTheExpectedSamplesThroughAVFoundation() throws {
    let expected = try CanonicalCAFFixture.expectedSamples()
    let file = try AVAudioFile(forReading: CanonicalCAFFixture.cafURL())
    #expect(file.fileFormat.sampleRate == CanonicalAudio.sampleRate)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.fileFormat.commonFormat == .pcmFormatFloat32)
    #expect(file.length == Int64(expected.count))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(expected.count)))
    try file.read(into: buffer)
    #expect(Int(buffer.frameLength) == expected.count)
    let channel = try #require(buffer.floatChannelData)
    let decoded = Array(UnsafeBufferPointer(start: channel[0], count: expected.count))
    #expect(decoded.map(\.bitPattern) == expected.map(\.bitPattern))
}
