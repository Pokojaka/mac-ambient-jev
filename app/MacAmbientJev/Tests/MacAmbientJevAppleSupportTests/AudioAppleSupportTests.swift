import AVFoundation
import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevAppleSupport

@Test
func audioFileTimelineBuilderRebuildsACorruptedTimelineFromTheOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let source = root.appending(path: "fixture-resume.caf")
    let format = AVAudioFormat(
        standardFormatWithSampleRate: 16_000,
        channels: 1
    )!
    try autoreleasepool {
        let file = try AVAudioFile(
            forWriting: source,
            settings: format.settings
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12)!
        buffer.frameLength = 12
        for index in 0..<12 {
            buffer.floatChannelData![0][index] = Float(index) / 12
        }
        try file.write(from: buffer)
    }

    let processingDirectory = root.appending(
        path: "processing-rebuild",
        directoryHint: .isDirectory
    )
    let builder = AudioFileTimelineBuilder(readFrameCount: 4)

    let first = try await builder.build(
        from: source,
        into: processingDirectory
    )
    try Data([0xFF]).write(
        to: processingDirectory.appending(path: first.chunkFiles[0])
    )
    let second = try await builder.build(
        from: source,
        into: processingDirectory
    )

    #expect(first.committedFrames == 12)
    #expect(second.committedFrames == 12)
    #expect(second.chunkFiles == first.chunkFiles)
}

@Test
func processingTimelineExporterWritesStandardAudioWithoutWholeTimelineBuffer() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let processing = root.appending(path: "processing", directoryHint: .isDirectory)
    let writer = try DurableAudioWriter(directory: processing, chunkDurationSeconds: 8.0 / CanonicalAudio.sampleRate)
    try await writer.append(samples: (0..<24).map { Float($0) / 24 })
    let checkpoint = try await writer.finish()

    let reader = try ProcessingTimelineReader(
        directory: processing,
        checkpoint: checkpoint
    )
    let output = root.appending(path: "diarization.caf")

    try ProcessingTimelineAudioExporter(
        framesPerBuffer: 5
    ).export(reader: reader, to: output, encoding: .float32CAF)

    let file = try AVAudioFile(forReading: output)
    #expect(file.length == 24)
    #expect(file.processingFormat.sampleRate == CanonicalAudio.sampleRate)
    #expect(file.processingFormat.channelCount == 1)
}
