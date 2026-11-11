import AVFoundation
import Foundation
import Testing
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
        into: processingDirectory, sessionURL: root
    )
    try Data([0xFF]).write(
        to: processingDirectory.appending(path: first.chunkFiles[0])
    )
    let second = try await builder.build(
        from: source,
        into: processingDirectory, sessionURL: root
    )

    #expect(first.committedFrames == 12)
    #expect(second.committedFrames == 12)
    #expect(second.chunkFiles == first.chunkFiles)
}
