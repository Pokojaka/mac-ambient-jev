import AVFoundation
import Foundation
import MacAmbientJevCAFFixtures
import Testing
@testable import MacAmbientJevCore

private struct ExpectedSamplesTimeline: TimelineAudioReading {
    let info: TimelineAudioInfo
    let samples: [Float]

    func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        Array(samples[Int(frameRange.lowerBound)..<Int(frameRange.upperBound)])
    }

    func validateAudio() throws {}
}

private func withCanonicalCAFReader<Result>(
    at url: URL,
    sessionURL: URL,
    perform: (CanonicalCAFReader) throws -> Result
) throws -> Result {
    let reader = try CanonicalCAFReader(url: url, sessionURL: sessionURL)
    return try perform(reader)
}

private func withAVAudioFile<Result>(
    at url: URL,
    perform: (AVAudioFile) throws -> Result
) throws -> Result {
    let file = try AVAudioFile(forReading: url)
    return try perform(file)
}

private func expectAVAudioFileSamples(at url: URL, expected: [Float]) throws {
    try withAVAudioFile(at: url) { file in
        #expect(file.fileFormat.sampleRate == CanonicalAudio.sampleRate)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.commonFormat == .pcmFormatFloat32)
        #expect(file.length == Int64(expected.count))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(expected.count))
        )
        try file.read(into: buffer)
        #expect(Int(buffer.frameLength) == expected.count)
        let channel = try #require(buffer.floatChannelData)
        let decoded = Array(UnsafeBufferPointer(start: channel[0], count: expected.count))
        #expect(decoded.map(\.bitPattern) == expected.map(\.bitPattern))
    }
}

@Test func canonicalCAFLayoutsHaveIdenticalSamplesThroughCoreAndAVFoundation() throws {
    let expected = try CanonicalCAFFixture.expectedSamples()
    #expect(expected.count == 4_800)
    #expect(expected.count == CanonicalCAFFixture.frameCount)

    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let fixture = root.appending(path: "canonical-input.caf")
    try FileManager.default.copyItem(at: CanonicalCAFFixture.cafURL(), to: fixture)
    let exported = root.appending(path: "diarization-input.caf")
    let timeline = ExpectedSamplesTimeline(
        info: try TimelineAudioInfo(committedFrames: Int64(expected.count), gapEvents: []),
        samples: expected
    )
    try MacAmbientJevCore.ProcessingTimelineAudioExporter(framesPerBuffer: 1_000)
        .export(reader: timeline, to: exported, sessionURL: root)

    let fixtureBytes = try Data(contentsOf: fixture)
    let exportedBytes = try Data(contentsOf: exported)
    #expect(fixtureBytes.count == 23_296)
    #expect(exportedBytes.count == 19_268)
    #expect(fixtureBytes.count != exportedBytes.count)
    #expect(Array(fixtureBytes.prefix(52)) == Array(exportedBytes.prefix(52)))
    #expect(Array(fixtureBytes.prefix(68)) != Array(exportedBytes.prefix(68)))

    for url in [fixture, exported] {
        try withCanonicalCAFReader(at: url, sessionURL: root) { reader in
            #expect(reader.sampleCount == 4_800)
            let samples = try reader.readSamples(frames: 0..<4_800)
            #expect(samples.map(\.bitPattern) == expected.map(\.bitPattern))
        }
        try expectAVAudioFileSamples(at: url, expected: expected)
    }
}

@Test func committedCanonicalCAFFixtureReadsBackAsTheExpectedSamplesThroughAVFoundation() throws {
    let expected = try CanonicalCAFFixture.expectedSamples()
    try expectAVAudioFileSamples(at: CanonicalCAFFixture.cafURL(), expected: expected)
}
