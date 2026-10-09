import AVFoundation
import Foundation
import MacAmbientJevCore
@testable import MacAmbientJevAppleSupport
import Testing

private func ingressRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func ingressPush(_ samples: [Float], at start: Int64, ring: AudioBlockRing) -> Bool {
    var samples = samples
    let count = samples.count
    return samples.withUnsafeMutableBufferPointer { buffer in
        var channel = buffer.baseAddress!
        return withUnsafePointer(to: &channel) {
            ring.pushPlanarFloat32(channelData: $0, channelCount: 1, frameCount: count, startFrame: start)
        }
    }
}

private func tone(_ range: Range<Int>, rate: Double) -> [Float] {
    range.map { Float(0.4 * sin(2 * Double.pi * 997 * Double($0) / rate)
        + 0.15 * sin(2 * Double.pi * 3101 * Double($0) / rate)) }
}

@Test(arguments: [48_000.0, 44_100.0, 16_000.0])
func continuousCanonicalIngress(rate: Double) async throws {
    let root = try ingressRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let frames = Int(rate * 6) + 17
    let source = tone(0..<frames, rate: rate)
    let referenceConverter = try CanonicalAudioResampler(sampleRate: rate)
    var reference = try referenceConverter.convert(mono: source)
    reference += try referenceConverter.finish()
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 0.5, sessionURL: root)
    let ring = AudioBlockRing(capacity: 8, blockFrameCapacity: 512, sampleRate: rate)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: rate))
    var cursor = 0
    var block = 0
    while cursor < frames {
        let count = min([512, 37, 997, 13, 401][block % 5], frames - cursor)
        #expect(ingressPush(Array(source[cursor..<(cursor + count)]), at: Int64(cursor), ring: ring))
        _ = try await drain.drainAvailable()
        cursor += count
        block += 1
    }
    ring.finish(tailFrame: Int64(frames))
    let checkpoint = try await drain.finish()
    #expect(try await drain.finish() == checkpoint)
    let actual = try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root).readSamples(frameRange: 0..<checkpoint.committedFrames)
    #expect(try checkpoint.committedFrames == CanonicalAudio.boundary(Int64(frames), sampleRate: rate))
    #expect(actual.count == reference.count)
    // Block boundaries must not reset phase, priming, or the filter state.
    let maxDifference = zip(actual, reference).map { abs($0 - $1) }.max()!
    #expect(maxDifference < 0.00001)
    if rate == CanonicalAudio.sampleRate { #expect(actual == source) }
    let interior = 200..<(actual.count - 200)
    let errorEnergy = interior.reduce(0.0) { sum, index in
        let expected = Double(tone(index..<(index + 1), rate: CanonicalAudio.sampleRate)[0])
        return sum + pow(Double(actual[index]) - expected, 2)
    } / Double(interior.count)
    #expect(errorEnergy < 0.00001)
}

@Test
func fractionalGapsOverlapOverflowAndStopTail() async throws {
    let root = try ingressRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let rate = 44_100.0
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 0.01, sessionURL: root)
    let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 512, sampleRate: rate)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: rate))
    #expect(ingressPush(tone(0..<512, rate: rate), at: 0, ring: ring))
    _ = try await drain.drainAvailable()
    // Ring strips this overlap in source coordinates before conversion.
    #expect(ingressPush(tone(500..<900, rate: rate), at: 500, ring: ring))
    _ = try await drain.drainAvailable()
    #expect(ingressPush(tone(1037..<1549, rate: rate), at: 1037, ring: ring))
    ring.noteMissing(startFrame: 1549, frameCount: 73)
    #expect(!ingressPush(tone(1622..<2011, rate: rate), at: 1622, ring: ring))
    ring.finish(tailFrame: 2077)
    let checkpoint = try await drain.finish()
    #expect(try await drain.finish() == checkpoint)
    let ranges: [(Int64, Int64, AudioGapReason)] = [
        (900, 1037, .missingCallback), (1549, 1622, .invalidBuffer),
        (1622, 2011, .overflow), (2011, 2077, .stopTail)
    ]
    let expectedGaps = try ranges.map { start, end, reason in
        let canonicalStart = try CanonicalAudio.boundary(start, sampleRate: rate)
        return AudioGapEvent(startFrame: canonicalStart,
            frameCount: try min(checkpoint.committedFrames, CanonicalAudio.boundary(end, sampleRate: rate)) - canonicalStart, reason: reason)
    }
    #expect(checkpoint.gapEvents == expectedGaps)
    var source = tone(0..<900, rate: rate)
    source += [Float](repeating: 0, count: 137)
    source += tone(1037..<1549, rate: rate)
    source += [Float](repeating: 0, count: 528)
    let converter = try CanonicalAudioResampler(sampleRate: rate)
    var expected = try converter.convert(mono: source)
    expected += try converter.finish()
    let actual = try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root).readSamples(frameRange: 0..<checkpoint.committedFrames)
    #expect(actual == expected)
}

@Test
func failedCanonicalAppendRetriesOutputWithoutReconversion() async throws {
    let root = try ingressRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 0.001, sessionURL: root)
    let ring = AudioBlockRing(capacity: 4, blockFrameCapacity: 512, sampleRate: 44_100)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: 44_100))
    let source = tone(0..<2048, rate: 44_100)
    #expect(ingressPush(source, at: 0, ring: ring))
    let blocked = root.appending(path: "chunk-000002.f32le")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { _ = try await drain.drainAvailable() }
    try FileManager.default.removeItem(at: blocked)
    async let finish = drain.finish()
    async let snapshot = drain.committedSnapshot()
    let final = try await finish
    let observed = try await snapshot
    #expect(observed.committedFrames <= final.committedFrames)
    let converter = try CanonicalAudioResampler(sampleRate: 44_100)
    var expected = try converter.convert(mono: source)
    expected += try converter.finish()
    let actual = try ProcessingTimelineReader(directory: root, checkpoint: final, sessionURL: root).readSamples(frameRange: 0..<final.committedFrames)
    #expect(actual == expected)
}

@Test
func importedChannelsAreAveragedBeforeContinuousSRC() async throws {
    let root = try ingressRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "original.caf")
    let rate = 44_100.0
    let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic))
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
        interleaved: false, channelLayout: layout)
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_117))
    buffer.frameLength = buffer.frameCapacity
    let channels = try #require(buffer.floatChannelData)
    let source = tone(0..<Int(buffer.frameLength), rate: rate)
    for frame in source.indices {
        for channel in 0..<4 { channels[channel][frame] = source[frame] * Float(channel + 1) / 4 }
    }
    try file.write(from: buffer)
    file.close()
    let bytes = try Data(contentsOf: url)
    let processing = root.appending(path: "processing")
    let builder = AudioFileTimelineBuilder(readFrameCount: 512)
    let checkpoint = try await builder.build(from: url, into: processing, sessionURL: root)
    let converter = try CanonicalAudioResampler(sampleRate: rate)
    var expected = try converter.convert(mono: source.map { $0 * 0.625 })
    expected += try converter.finish()
    let actual = try ProcessingTimelineReader(directory: processing, checkpoint: checkpoint, sessionURL: root).readSamples(frameRange: 0..<checkpoint.committedFrames)
    #expect(actual.count == expected.count)
    #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.000001 })
    #expect(try Data(contentsOf: url) == bytes)
    #expect(try await builder.build(from: url, into: processing, sessionURL: root) == checkpoint)
}
