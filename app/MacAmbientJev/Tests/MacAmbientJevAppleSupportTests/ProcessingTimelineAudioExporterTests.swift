import AVFoundation
import Foundation
import Testing
@testable import MacAmbientJevAppleSupport
@testable import MacAmbientJevCore

@Test func failedExportPreservesExistingDestination() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appending(path: "existing.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
    buffer.frameLength = 1
    buffer.floatChannelData![0][0] = 0.5
    try autoreleasepool {
        let existing = try AVAudioFile(forWriting: destination, settings: format.settings)
        try existing.write(from: buffer)
    }
    let previous = try Data(contentsOf: destination)
    let checkpoint = AudioCheckpoint(committedFrames: 1, sampleRate: 16_000, channelCount: 1, sampleFormat: .float32LE, chunkFiles: ["missing.f32le"], chunkFrameCounts: [1], gapEvents: [])
    let reader = try ProcessingTimelineReader(directory: root, checkpoint: checkpoint)
    do {
        try ProcessingTimelineAudioExporter(framesPerBuffer: 48_000)
            .export(reader: reader, to: destination, encoding: .float32CAF)
        Issue.record("Missing chunk should fail export")
    } catch {}
    #expect(try Data(contentsOf: destination) == previous)
}
