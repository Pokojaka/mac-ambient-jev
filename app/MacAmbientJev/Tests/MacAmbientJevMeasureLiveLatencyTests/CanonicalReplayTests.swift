import AVFoundation
import Foundation
import MacAmbientJevCore
@testable import MacAmbientJevMeasureLiveLatency
import Testing

@Test(arguments: [48000.0, 44100.0])
func pacedReplayStoresCanonicalAudioWithoutLoadingEngines(rate: Double) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "replay.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    let source = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = Int(rate / 2) + 17
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = buffer.frameCapacity
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<frames {
        let sample = Float(0.4 * sin(2 * .pi * 997 * Double(frame) / rate))
        channels[0][frame] = sample
        channels[1][frame] = sample * 0.5
    }
    try source.write(from: buffer)
    source.close()
    let original = try Data(contentsOf: url)
    let directory = root.appending(path: "processing")
    let writer = try DurableAudioWriter(directory: directory, chunkDurationSeconds: 0.5, sessionURL: root)
    let checkpoint = try await MeasureLiveLatencyCommand.feedAudio(url, sourceFormat: format,
        targetFormat: format, into: writer)
    #expect(checkpoint.sampleRate == CanonicalAudio.sampleRate)
    #expect(checkpoint.channelCount == 1)
    #expect(try abs(checkpoint.committedFrames - CanonicalAudio.boundary(Int64(frames), sampleRate: rate)) <= 1)
    let actual = try ProcessingTimelineReader(directory: directory, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<checkpoint.committedFrames)
    let interior = 200..<(actual.count - 200)
    let error = interior.reduce(0.0) { sum, index in
        let expected = 0.3 * sin(2 * .pi * 997 * Double(index) / CanonicalAudio.sampleRate)
        return sum + pow(Double(actual[index]) - expected, 2)
    } / Double(interior.count)
    #expect(error < 0.00001)
    #expect(try Data(contentsOf: url) == original)
}
