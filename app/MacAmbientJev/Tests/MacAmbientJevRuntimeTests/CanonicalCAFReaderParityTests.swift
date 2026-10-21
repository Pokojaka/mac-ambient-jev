import AVFoundation
import Foundation
import MacAmbientJevCAFFixtures
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevRuntime

private func expectSameSamples(_ url: URL, sessionURL: URL, ranges: [(offset: Int, count: Int)]) throws {
    let reader = try CanonicalCAFReader(url: url, sessionURL: sessionURL)
    let source = try CanonicalCAFAudioSource(fileURL: url, sessionURL: sessionURL)
    #expect(Int64(source.sampleCount) == reader.sampleCount)
    for (offset, count) in ranges {
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { destination.deallocate() }
        destination.initialize(repeating: -2, count: count)
        try source.copySamples(into: destination, offset: offset, count: count)
        let available = max(0, min(count, source.sampleCount - offset))
        let start = Int64(min(offset, source.sampleCount))
        let expected = try reader.readSamples(frames: start..<start + Int64(available))
        #expect(Array(UnsafeBufferPointer(start: destination, count: available)).map(\.bitPattern) == expected.map(\.bitPattern))
        #expect(UnsafeBufferPointer(start: destination + available, count: count - available).allSatisfy { $0 == -2 })
    }
}

@Test func canonicalCAFReaderMatchesTheMacSourceOnTheMacWrittenFixture() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "canonical.caf")
    try FileManager.default.copyItem(at: CanonicalCAFFixture.cafURL(), to: url)
    try expectSameSamples(url, sessionURL: root, ranges: [
        (0, 4_800), (0, 320), (1, 4_799), (503, 2_000), (4_000, 2_000), (4_799, 320), (4_800, 320), (4_803, 320)
    ])
}

@Test func canonicalCAFReaderMatchesTheMacSourceAcrossReadBlocksAndTheFinalPartialRange() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "canonical.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: CanonicalAudio.sampleRate, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
    let channels = try #require(buffer.floatChannelData)
    buffer.frameLength = buffer.frameCapacity
    try autoreleasepool {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for block in 0..<8 {
            for frame in 0..<16_000 { channels[0][frame] = Float((block * 16_000 + frame) % 997) / 997 - 0.5 }
            try file.write(from: buffer)
        }
    }
    try expectSameSamples(url, sessionURL: root, ranges: [
        (0, 128_000), (8_203, 20_017), (127_993, 20_017), (128_000, 320), (128_003, 320), (503, 8_192), (8_191, 8_193)
    ])
}
