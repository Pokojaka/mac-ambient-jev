import Foundation
import Testing
@testable import MacAmbientJevCore

@Test func durableWriterRecordsCommittedFrameRange() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, sampleRate: 48_000, channelCount: 1)

    try await writer.append(samples: Array(repeating: 0.1, count: 4_800))
    let checkpoint = try await writer.checkpoint()

    #expect(checkpoint.committedFrames == 4_800)
    #expect(checkpoint.chunkFiles.count == 1)
}

@Test func durableWriterSplitsAtConfiguredChunkDuration() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(
        directory: root,
        sampleRate: 10,
        channelCount: 1,
        chunkDurationSeconds: 1
    )

    try await writer.append(samples: Array(repeating: 0.25, count: 25))
    let checkpoint = try await writer.checkpoint()

    #expect(checkpoint.committedFrames == 25)
    #expect(checkpoint.chunkFiles.count == 3)
}

@Test func timelineUsesFrameCoordinatesIndependentOfASRResampling() {
    let timeline = ProcessingTimeline(sampleRate: 48_000, channelCount: 1, sampleFormat: .float32LE)
    #expect(timeline.milliseconds(forFrame: 48_000) == 1_000)
}

@Test func importerCopiesOriginalWithoutMutatingSource() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "source.wav")
    let bytes = Data([0, 1, 2, 3, 4, 5])
    try bytes.write(to: source)
    let session = root.appending(path: "session")

    let result = try AudioImporter().importFile(source, into: session)

    #expect(try Data(contentsOf: source) == bytes)
    #expect(try Data(contentsOf: result.originalURL) == bytes)
    #expect(result.originalURL.lastPathComponent == "original.wav")
}

@Test func diskSpaceMonitorWarnsBeforeCaptureBecomesUnsafe() {
    let monitor = DiskSpaceMonitor(warningThresholdBytes: 2_000, criticalThresholdBytes: 1_000)
    #expect(monitor.level(forAvailableBytes: 3_000) == .normal)
    #expect(monitor.level(forAvailableBytes: 1_500) == .warning)
    #expect(monitor.level(forAvailableBytes: 500) == .critical)
}

@Test func audioBlockRingNeverBlocksAndReportsOverflow() {
    let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 4)
    #expect(ring.push(samples: [1, 2, 3, 4]))
    #expect(ring.push(samples: [5, 6, 7, 8]))
    #expect(!ring.push(samples: [9, 10, 11, 12]))
    #expect(ring.overflowCount == 1)
    #expect(ring.pop() == [1, 2, 3, 4])
    #expect(ring.pop() == [5, 6, 7, 8])
    #expect(ring.pop() == nil)
}


@Test func processingTimelineReaderReadsAcrossDurableChunkBoundaries() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(
        directory: root,
        sampleRate: 10,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
    try await writer.append(samples: (0..<25).map(Float.init))
    let checkpoint = try await writer.finish()

    let reader = ProcessingTimelineReader(directory: root, checkpoint: checkpoint)
    let samples = try reader.readSamples(frameRange: 8..<13)

    #expect(samples == [8, 9, 10, 11, 12])
}
