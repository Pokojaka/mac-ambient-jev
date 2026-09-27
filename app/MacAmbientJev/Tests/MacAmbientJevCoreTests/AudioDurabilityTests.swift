import AVFoundation
import Foundation
import Testing
@testable import MacAmbientJevCore

@Test func failedPartialChunkFlushPreservesAudioForRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1)
    try await writer.append(samples: [1, 2, 3])

    let blockedChunk = root.appending(path: "chunk-000000.f32le")
    try FileManager.default.createDirectory(at: blockedChunk, withIntermediateDirectories: false)
    do {
        _ = try await writer.finish()
        Issue.record("An occupied chunk path should prevent writing")
    } catch {}
    try FileManager.default.removeItem(at: blockedChunk)
    let checkpoint = try await writer.finish()
    #expect(checkpoint.committedFrames == 3)
    if checkpoint.committedFrames == 3 {
        #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint).readSamples(frameRange: 0..<3) == [1, 2, 3])
    }
}

@Test func reopeningRejectsTruncatedIndexedChunkBeforeAppending() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try DurableAudioWriter(directory: root, sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1)
    try await first.append(samples: Array(repeating: 1, count: 10))
    let chunk = root.appending(path: "chunk-000000.f32le")
    let handle = try FileHandle(forWritingTo: chunk)
    try handle.truncate(atOffset: UInt64(6 * MemoryLayout<Float>.size))
    try handle.close()

    #expect(throws: DurableAudioWriterError.corruptChunk("chunk-000000.f32le")) {
        _ = try DurableAudioWriter(directory: root, sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1)
    }
}

@Test func readerRejectsDuplicatedChunkFileIndex() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let filename = "chunk-000000.f32le"
    try [Float(9)].withUnsafeBytes { Data($0) }.write(to: root.appending(path: filename))
    let checkpoint = AudioCheckpoint(
        committedFrames: 2, sampleRate: 1, channelCount: 1,
        chunkFiles: [filename, filename], chunkFrameCounts: [1, 1]
    )
    let reader = ProcessingTimelineReader(directory: root, checkpoint: checkpoint)
    #expect(throws: ProcessingTimelineReaderError.invalidChunkIndex) {
        _ = try reader.readSamples(frameRange: 0..<2)
    }
}

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
    let checkpoint = AudioCheckpoint(committedFrames: 1, sampleRate: 8_000, channelCount: 1, chunkFiles: ["missing.f32le"], chunkFrameCounts: [1])
    let reader = ProcessingTimelineReader(directory: root, checkpoint: checkpoint)
    do {
        try ProcessingTimelineAudioExporter().export(reader: reader, to: destination)
        Issue.record("Missing chunk should fail export")
    } catch {}
    #expect(try Data(contentsOf: destination) == previous)
}

@Test func readerRejectsZeroChannelCheckpointWithoutTrapping() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(count: 8).write(to: root.appending(path: "chunk-000000.f32le"))
    let checkpoint = AudioCheckpoint(committedFrames: 2, sampleRate: 10, channelCount: 0, chunkFiles: ["chunk-000000.f32le"])
    #expect(throws: ProcessingTimelineReaderError.invalidFormat) {
        _ = try ProcessingTimelineReader(directory: root, checkpoint: checkpoint).readSamples(frameRange: 0..<1)
    }
}

@Test func readerRejectsChunkNamesOutsideTheProcessingDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let processing = root.appending(path: "audio/processing", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
    try [Float(7)].withUnsafeBytes { Data($0) }.write(to: root.appending(path: "secret"))
    let checkpoint = AudioCheckpoint(
        committedFrames: 1, sampleRate: 10, channelCount: 1,
        chunkFiles: ["../../secret"], chunkFrameCounts: [1]
    )
    #expect(throws: ProcessingTimelineReaderError.invalidChunkIndex) {
        _ = try ProcessingTimelineReader(directory: processing, checkpoint: checkpoint).readSamples(frameRange: 0..<1)
    }
}

@Test func ringOverflowKeepsLaterBlocksAtTheirCapturedFramePositions() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 1, blockFrameCapacity: 4)
    let writer = try DurableAudioWriter(directory: root, sampleRate: 4, channelCount: 1, chunkDurationSeconds: 1)
    let drain = AudioCaptureDrain(ring: ring, writer: writer)

    #expect(ring.push(samples: [1, 2]))
    #expect(!ring.push(samples: [3, 4, 5]))
    _ = try await drain.drainAvailable()
    #expect(ring.push(samples: [6]))
    let checkpoint = try await drain.finish()

    #expect(ring.overflowCount == 1)
    #expect(checkpoint.committedFrames == 6)
    let reader = ProcessingTimelineReader(directory: root, checkpoint: checkpoint)
    #expect(try reader.readSamples(frameRange: 0..<6) == [1, 2, 0, 0, 0, 6])
}

@Test func planarPushRejectsOverflowingDimensionsWithoutTrapping() {
    let ring = AudioBlockRing(capacity: 1, blockFrameCapacity: 4)
    var samples: [Float] = [0]
    let accepted = samples.withUnsafeMutableBufferPointer { buffer in
        var channels = [buffer.baseAddress!, buffer.baseAddress!]
        return channels.withUnsafeMutableBufferPointer { channelBuffer in
            ring.pushPlanarFloat32(channelData: channelBuffer.baseAddress!, channelCount: 2, frameCount: Int.max)
        }
    }
    #expect(!accepted)
    #expect(ring.overflowCount == 1)
    #expect(ring.pop() == nil)
}
