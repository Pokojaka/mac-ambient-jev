import AVFoundation
import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevAppleSupport

@Test
func audioFileTimelineBuilderCreatesDiskBackedProcessingTimeline() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let source = root.appending(path: "fixture.caf")
    let format = AVAudioFormat(
        standardFormatWithSampleRate: 8_000,
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
        path: "processing",
        directoryHint: .isDirectory
    )
    let checkpoint = try await AudioFileTimelineBuilder(
        readFrameCount: 4
    ).build(from: source, into: processingDirectory)

    #expect(checkpoint.sampleRate == 8_000)
    #expect(checkpoint.channelCount == 1)
    #expect(checkpoint.committedFrames == 12)

    let samples = try ProcessingTimelineReader(
        directory: processingDirectory,
        checkpoint: checkpoint
    ).readSamples(frameRange: 0..<12)

    #expect(samples.count == 12)
    #expect(abs(samples[6] - 0.5) < 0.0001)
}

@Test
func audioFileTimelineBuilderResumesWithoutDuplicatingImportedAudio() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let source = root.appending(path: "fixture-resume.caf")
    let format = AVAudioFormat(
        standardFormatWithSampleRate: 8_000,
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
        path: "processing-resume",
        directoryHint: .isDirectory
    )
    let builder = AudioFileTimelineBuilder(readFrameCount: 4)

    let first = try await builder.build(
        from: source,
        into: processingDirectory
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
    let writer = try DurableAudioWriter(
        directory: processing,
        sampleRate: 8_000,
        channelCount: 1,
        chunkDurationSeconds: 0.001
    )
    try await writer.append(samples: (0..<24).map { Float($0) / 24 })
    let checkpoint = try await writer.finish()

    let reader = ProcessingTimelineReader(
        directory: processing,
        checkpoint: checkpoint
    )
    let output = root.appending(path: "diarization.caf")

    try ProcessingTimelineAudioExporter(
        framesPerBuffer: 5
    ).export(reader: reader, to: output)

    let file = try AVAudioFile(forReading: output)
    #expect(file.length == 24)
    #expect(file.processingFormat.sampleRate == 8_000)
    #expect(file.processingFormat.channelCount == 1)
}
