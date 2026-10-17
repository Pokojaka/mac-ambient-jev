import Foundation
import Testing
@testable import MacAmbientJevCore

@Test func failedPartialChunkFlushPreservesAudioForRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
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
        #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root).readSamples(frameRange: 0..<3) == [1, 2, 3])
    }
}

@Test func recoveredCheckpointRejectsOverflowingChannelCount() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let checkpoint = AudioCheckpoint(
        committedFrames: 0,
        sampleRate: 10,
        channelCount: Int.max,
        sampleFormat: .float32LE,
        chunkFiles: [],
        chunkFrameCounts: [],
        gapEvents: []
    )
    try JSONEncoder().encode(checkpoint).write(
        to: root.appending(path: DurableAudioWriter.checkpointFilename)
    )

    #expect(throws: DurableAudioWriterError.incompatibleCheckpoint) {
        _ = try AudioCheckpoint.loadRecovered(from: root, relativeTo: root)
    }
}

@Test func indexedChunkByteCountOverflowThrowsInsteadOfTrapping() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let filename = "chunk-000000.f32le"
    try Data(repeating: 0, count: MemoryLayout<Float>.size)
        .write(to: root.appending(path: filename))
    let checkpoint = AudioCheckpoint(
        committedFrames: 1,
        sampleRate: 10,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: [filename],
        chunkFrameCounts: [Int.max],
        gapEvents: []
    )
    try JSONEncoder().encode(checkpoint).write(
        to: root.appending(path: DurableAudioWriter.checkpointFilename)
    )

    #expect(throws: DurableAudioWriterError.incompatibleCheckpoint) {
        _ = try AudioCheckpoint.loadRecovered(from: root, relativeTo: root)
    }
}

@Test func reopeningRejectsTruncatedIndexedChunkBeforeAppending() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await first.append(samples: Array(repeating: 1, count: 10))
    let chunk = root.appending(path: "chunk-000000.f32le")
    let handle = try FileHandle(forWritingTo: chunk)
    try handle.truncate(atOffset: UInt64(6 * MemoryLayout<Float>.size))
    try handle.close()

    #expect(throws: DurableAudioWriterError.corruptChunk("chunk-000000.f32le")) {
        _ = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    }
}

@Test func tornChunkIndexTailDoesNotHideAudioOrCorruptNextAppend() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await writer.append(samples: Array(repeating: 1, count: 10))
    let index = root.appending(path: DurableAudioWriter.chunkIndexFilename)
    let handle = try FileHandle(forWritingTo: index)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"index\":1,\"frames\":".utf8))
    try handle.close()

    let recovered = try #require(try AudioCheckpoint.loadRecovered(from: root, relativeTo: root))
    #expect(recovered.committedFrames == 10)
    let reopened = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await reopened.append(samples: Array(repeating: 2, count: 10))
    let checkpoint = try await reopened.finish()
    #expect(checkpoint.committedFrames == 20)
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<20)
        == Array(repeating: Float(1), count: 10) + Array(repeating: Float(2), count: 10))
}

@Test func recoveredGapLogExcludesAudioLostWithAnUncommittedTail() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await writer.append(samples: Array(repeating: 1, count: 10))
    try await writer.recordGap(startFrame: 10, frameCount: 12, reason: .missingCallback)
    try await writer.append(samples: Array(repeating: 0, count: 10))
    #expect(await writer.committedSnapshot().gapEvents == [
        AudioGapEvent(startFrame: 10, frameCount: 10, reason: .missingCallback)
    ])
    // The log is synced before the remaining two replacement frames can commit.
    let recovered = try #require(try AudioCheckpoint.loadRecovered(from: root, relativeTo: root))
    #expect(recovered.committedFrames == 20)
    #expect(recovered.gapEvents == [
        AudioGapEvent(startFrame: 10, frameCount: 10, reason: .missingCallback)
    ])

    // A persisted partial diagnostic is still a valid prefix of the raw log.
    #expect(try await writer.checkpoint().gapEvents == recovered.gapEvents)
    #expect(try AudioCheckpoint.loadRecovered(from: root, relativeTo: root) == recovered)

    let reopened = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await reopened.append(samples: Array(repeating: 2, count: 10))
    let final = try await reopened.finish()
    #expect(final.gapEvents == recovered.gapEvents)
    #expect(try AudioCheckpoint.loadRecovered(from: root, relativeTo: root) == final)
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: final, sessionURL: root)
        .readSamples(frameRange: 18..<30) == [0, 0] + Array(repeating: Float(2), count: 10))
}

@Test func recoveryDropsGapLoggedBeforeAnyReplacementAudioCommitted() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await writer.recordGap(startFrame: 0, frameCount: 3, reason: .invalidBuffer)
    #expect(await writer.committedSnapshot().gapEvents.isEmpty)
    try await writer.append(samples: [0, 0, 0])
    #expect(try AudioCheckpoint.loadRecovered(from: root, relativeTo: root)?.gapEvents == [])
    let reopened = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await reopened.append(samples: Array(repeating: 7, count: 10))
    let final = try await reopened.finish()
    #expect(final.gapEvents.isEmpty)
    #expect(try AudioCheckpoint.loadRecovered(from: root, relativeTo: root) == final)
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: final, sessionURL: root)
        .readSamples(frameRange: 0..<10) == Array(repeating: Float(7), count: 10))
}

@Test func largeAppendCommitsEveryChunkWithoutRewritingTheSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let checkpointURL = root.appending(path: DurableAudioWriter.checkpointFilename)
    let initialSnapshot = try Data(contentsOf: checkpointURL)
    let samples = (0..<1_005).map(Float.init)
    try await writer.append(samples: samples)
    #expect(try Data(contentsOf: checkpointURL) == initialSnapshot)
    let recovered = try #require(try AudioCheckpoint.loadRecovered(from: root, relativeTo: root))
    #expect(recovered.committedFrames == 1_000)
    #expect(recovered.chunkFrameCounts == Array(repeating: 10, count: 100))
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: recovered, sessionURL: root)
        .readSamples(frameRange: 995..<1_000) == Array(samples[995..<1_000]))
    let final = try await writer.finish()
    #expect(final.committedFrames == 1_005)
    #expect(final.chunkFrameCounts == Array(repeating: 10, count: 100) + [5])
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: final, sessionURL: root)
        .readSamples(frameRange: 1_000..<1_005) == Array(samples[1_000..<1_005]))
    #expect(try AudioCheckpoint.loadRecovered(from: root, relativeTo: root) == final)
}

@Test func readerRejectsDuplicatedChunkFileIndex() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let filename = "chunk-000000.f32le"
    try [Float(9)].withUnsafeBytes { Data($0) }.write(to: root.appending(path: filename))
    let checkpoint = AudioCheckpoint(
        committedFrames: 2,
        sampleRate: 16_000,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: [filename, filename],
        chunkFrameCounts: [1, 1],
        gapEvents: []
    )
    let reader = try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
    #expect(throws: ProcessingTimelineReaderError.invalidChunkIndex) {
        _ = try reader.readSamples(frameRange: 0..<2)
    }
}

@Test func readerRejectsZeroChannelCheckpointWithoutTrapping() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(count: 8).write(to: root.appending(path: "chunk-000000.f32le"))
    let checkpoint = AudioCheckpoint(committedFrames: 2, sampleRate: 10, channelCount: 0, sampleFormat: .float32LE, chunkFiles: ["chunk-000000.f32le"], chunkFrameCounts: [2], gapEvents: [])
    #expect(throws: ProcessingTimelineReaderError.invalidFormat) {
        _ = try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root).readSamples(frameRange: 0..<1)
    }
}

@Test func readerRejectsChunkNamesOutsideTheProcessingDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let processing = root.appending(path: "audio/processing", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
    try [Float(7)].withUnsafeBytes { Data($0) }.write(to: root.appending(path: "secret"))
    let checkpoint = AudioCheckpoint(
        committedFrames: 1,
        sampleRate: 16_000,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["../../secret"],
        chunkFrameCounts: [1],
        gapEvents: []
    )
    #expect(throws: ProcessingTimelineReaderError.invalidChunkIndex) {
        _ = try ProcessingTimelineReader(directory: processing, checkpoint: checkpoint, sessionURL: root).readSamples(frameRange: 0..<1)
    }
}

@Test func failedSecondChunkRetainsCaptureBlockWithoutGapOrDuplicateOnRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 1, blockFrameCapacity: 20)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    let samples = (1...20).map(Float.init)
    #expect(pushMono(samples, at: 0, into: ring))

    // The first ten frames commit; the next chunk's occupied path rejects its write.
    let blockedChunk = root.appending(path: "chunk-000001.f32le")
    try FileManager.default.createDirectory(at: blockedChunk, withIntermediateDirectories: false)
    do {
        _ = try await drain.drainAvailable()
        Issue.record("The occupied second chunk path should reject the drain")
    } catch {}
    let first = await writer.committedSnapshot()
    #expect(first.committedFrames == 10)
    #expect(first.chunkFrameCounts == [10])
    #expect(first.gapEvents.isEmpty)
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: first, sessionURL: root)
        .readSamples(frameRange: 0..<10) == Array(samples[..<10]))

    try FileManager.default.removeItem(at: blockedChunk)
    // The block was converted before the failed append; the retry resends only its output.
    #expect(try await drain.drainAvailable() == 0)
    let final = try await drain.finish()
    #expect(final.committedFrames == 20)
    #expect(final.chunkFrameCounts == [10, 10])
    #expect(final.gapEvents.isEmpty)
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: final, sessionURL: root)
        .readSamples(frameRange: 0..<20) == samples)
}

@Test func failedSilenceChunkRetainsGapAndOriginalCallbackPTSOnRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 2)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 4.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    #expect(pushMono([1, 2], at: 0, into: ring))
    #expect(try await drain.drainAvailable() == 1)
    #expect(pushMono([9, 10], at: 9, into: ring))

    // The first chunk accepts two silence frames; the second accepts four
    // more before its write fails. The queued callback still belongs at PTS 9.
    let blockedChunk = root.appending(path: "chunk-000001.f32le")
    try FileManager.default.createDirectory(at: blockedChunk, withIntermediateDirectories: false)
    do {
        _ = try await drain.drainAvailable()
        Issue.record("The occupied silence chunk path should reject the drain")
    } catch {}
    let committed = await writer.committedSnapshot()
    #expect(committed.committedFrames == 4)
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: committed, sessionURL: root)
        .readSamples(frameRange: 0..<4) == [1, 2, 0, 0])
    #expect(pushMono([11, 12], at: 11, into: ring))

    try FileManager.default.removeItem(at: blockedChunk)
    #expect(try await drain.drainAvailable() == 2)
    let checkpoint = try await drain.finish()
    #expect(checkpoint.committedFrames == 13)
    #expect(checkpoint.gapEvents == [
        AudioGapEvent(startFrame: 2, frameCount: 7, reason: .missingCallback)
    ])
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<13) == [1, 2] + Array(repeating: Float(0), count: 7) + [9, 10, 11, 12])
}

@Test func ringOverflowKeepsLaterBlocksAtTheirCapturedFramePositions() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 1, blockFrameCapacity: 4)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 4.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())

    #expect(pushMono([1, 2], at: 0, into: ring))
    #expect(!pushMono([3, 4, 5], at: 2, into: ring))
    _ = try await drain.drainAvailable()
    #expect(pushMono([6], at: 5, into: ring))
    let checkpoint = try await drain.finish()

    #expect(ring.overflowCount == 1)
    #expect(checkpoint.committedFrames == 6)
    let reader = try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
    #expect(try reader.readSamples(frameRange: 0..<6) == [1, 2, 0, 0, 0, 6])
}

@Test func planarPushRejectsOverflowingDimensionsWithoutTrapping() {
    let ring = AudioBlockRing(capacity: 1, blockFrameCapacity: 4)
    var samples: [Float] = [0]
    let accepted = samples.withUnsafeMutableBufferPointer { buffer in
        var channels = [buffer.baseAddress!, buffer.baseAddress!]
        return channels.withUnsafeMutableBufferPointer { channelBuffer in
            ring.pushPlanarFloat32(channelData: channelBuffer.baseAddress!, channelCount: 2,
                                   frameCount: Int.max, startFrame: 0)
        }
    }
    #expect(!accepted)
    #expect(ring.overflowCount == 1)
    #expect(ring.pop() == nil)
}

@Test func syntheticCallbackPTSPlacesGapsAndTrimsOverlappingFrames() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 8, blockFrameCapacity: 2)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())

    #expect(pushMono([1, 2], at: 0, into: ring))
    #expect(pushMono([5, 6], at: 4, into: ring))
    #expect(pushMono([77, 88], at: 5, into: ring))
    ring.finish(tailFrame: 7)
    let checkpoint = try await drain.finish()

    #expect(checkpoint.committedFrames == 7)
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<7) == [1, 2, 0, 0, 5, 6, 88])
    #expect(checkpoint.gapEvents == [
        AudioGapEvent(startFrame: 2, frameCount: 2, reason: .missingCallback)
    ])
}

@Test func singleFramePTSJitterIsContinuousButLongerGapIsPreserved() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 3, blockFrameCapacity: 2, sampleRate: CanonicalAudio.sampleRate)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1000.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    #expect(pushMono([1, 2], at: 0, into: ring))
    #expect(pushMono([3], at: 3, into: ring)) // One-frame rounding difference is tolerated.
    #expect(pushMono([7], at: 6, into: ring)) // Two missing source frames.
    #expect(ring.dropoutCount == 1)
    ring.finish(tailFrame: 8) // One-frame stop-clock rounding difference.
    #expect(ring.dropoutCount == 1)
    let checkpoint = try await drain.finish()
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<6) == [1, 2, 3, 0, 0, 7])
    #expect(checkpoint.gapEvents == [
        AudioGapEvent(startFrame: 3, frameCount: 2, reason: .missingCallback)
    ])
}

@Test func repeatedSmallPTSLossesPreserveAccumulatedMissingFrames() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 4, blockFrameCapacity: 2, sampleRate: CanonicalAudio.sampleRate)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1000.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())

    #expect(pushMono([1, 2], at: 0, into: ring))
    #expect(pushMono([3, 4], at: 3, into: ring))
    #expect(pushMono([5, 6], at: 6, into: ring))
    #expect(pushMono([7, 8], at: 9, into: ring))
    ring.finish(tailFrame: 11)
    let checkpoint = try await drain.finish()

    #expect(checkpoint.committedFrames == 11)
    let samples = try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<11)
    #expect(samples.filter { $0 == 0 }.count == 3)
    #expect(samples.filter { $0 != 0 } == [1, 2, 3, 4, 5, 6, 7, 8])
    #expect(checkpoint.gapEvents.reduce(Int64(0)) { $0 + $1.frameCount } == 3)
}

@Test func twentyFramePTSLossesKeepEveryCallbackAtItsPTS() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 4, blockFrameCapacity: 2, sampleRate: CanonicalAudio.sampleRate)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 15, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    #expect(pushMono([1, 2], at: 0, into: ring))
    #expect(pushMono([3, 4], at: 22, into: ring))
    #expect(pushMono([5, 6], at: 44, into: ring))
    #expect(pushMono([7, 8], at: 66, into: ring))
    ring.finish(tailFrame: 68)

    let checkpoint = try await drain.finish()
    #expect(checkpoint.committedFrames == 68)
    #expect(checkpoint.gapEvents == [
        AudioGapEvent(startFrame: 2, frameCount: 20, reason: .missingCallback),
        AudioGapEvent(startFrame: 24, frameCount: 20, reason: .missingCallback),
        AudioGapEvent(startFrame: 46, frameCount: 20, reason: .missingCallback)
    ])
    let reader = try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
    let silence = Array(repeating: Float(0), count: 20)
    let expected: [Float] = [1, 2] + silence + [3, 4] + silence + [5, 6] + silence + [7, 8]
    #expect(try reader.readSamples(frameRange: 0..<68) == expected)
}

@Test func stopAfterOneFramePTSJitterDoesNotAppendFalseTailSilence() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 2, sampleRate: CanonicalAudio.sampleRate)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1000.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    #expect(pushMono([1, 2], at: 0, into: ring))
    #expect(pushMono([3], at: 3, into: ring))
    ring.finish(tailFrame: 4) // Last raw PTS end is one frame after normalized end.
    let checkpoint = try await drain.finish()
    #expect(checkpoint.committedFrames == 3)
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<3) == [1, 2, 3])
    #expect(checkpoint.gapEvents.isEmpty)
    #expect(ring.dropoutCount == 0)
}

@Test func gapAfterCommittedChunkUsesRecordingOriginNotLatestCheckpoint() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 4)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 4.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    #expect(pushMono([1, 2, 3, 4], at: 0, into: ring))
    #expect(try await drain.drainAvailable() == 1)
    #expect(pushMono([7], at: 6, into: ring))
    ring.finish(tailFrame: 7)
    let checkpoint = try await drain.finish()
    #expect(checkpoint.gapEvents == [
        AudioGapEvent(startFrame: 4, frameCount: 2, reason: .missingCallback)
    ])
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<7) == [1, 2, 3, 4, 0, 0, 7])
}

@Test func resumedWriterOffsetsNewCaptureGapsAfterExistingChunks() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let previous = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await previous.append(samples: Array(repeating: 9, count: 10))
    let resumed = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 2)
    let drain = AudioCaptureDrain(ring: ring, writer: resumed, converter: CanonicalMonoPassthrough())
    #expect(pushMono([1, 2], at: 0, into: ring))
    #expect(pushMono([5], at: 4, into: ring))
    ring.finish(tailFrame: 6)
    let checkpoint = try await drain.finish()
    #expect(checkpoint.gapEvents == [
        AudioGapEvent(startFrame: 12, frameCount: 2, reason: .missingCallback),
        AudioGapEvent(startFrame: 15, frameCount: 1, reason: .stopTail)
    ])
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 8..<16) == [9, 9, 1, 2, 0, 0, 5, 0])
    #expect(try AudioCheckpoint.loadRecovered(from: root, relativeTo: root) == checkpoint)
}

@Test func overflowPreservesAbsoluteGapLocationAcrossCallbacks() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 1, blockFrameCapacity: 2)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())

    #expect(pushMono([1, 2], at: 0, into: ring))
    #expect(!pushMono([5, 6], at: 4, into: ring))
    #expect(try await drain.drainAvailable() == 1)
    #expect(pushMono([9, 10], at: 8, into: ring))
    ring.finish(tailFrame: 10)
    let checkpoint = try await drain.finish()

    #expect(checkpoint.committedFrames == 10)
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<10) == [1, 2, 0, 0, 0, 0, 0, 0, 9, 10])
    #expect(checkpoint.gapEvents == [
        AudioGapEvent(startFrame: 2, frameCount: 2, reason: .missingCallback),
        AudioGapEvent(startFrame: 4, frameCount: 2, reason: .overflow),
        AudioGapEvent(startFrame: 6, frameCount: 2, reason: .missingCallback)
    ])
}

@Test func invalidCallbackAndStopTailAreRecordedAtDeviceFramePositions() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 1, blockFrameCapacity: 2)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())

    #expect(pushMono([1, 2], at: 0, into: ring))
    ring.noteMissing(startFrame: 2, frameCount: 2) // Full ring: no marker slot.
    #expect(try await drain.drainAvailable() == 1)
    #expect(pushMono([5], at: 4, into: ring))
    ring.finish(tailFrame: 7)
    let checkpoint = try await drain.finish()

    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<7) == [1, 2, 0, 0, 5, 0, 0])
    #expect(checkpoint.gapEvents == [
        AudioGapEvent(startFrame: 2, frameCount: 2, reason: .invalidBuffer),
        AudioGapEvent(startFrame: 5, frameCount: 2, reason: .stopTail)
    ])
}

@Test func invalidBufferAtEndIsRecoveredWithoutAnotherAudioCallback() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 1, blockFrameCapacity: 2)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    ring.noteMissing(startFrame: 0, frameCount: 2)
    ring.finish(tailFrame: 2)
    let checkpoint = try await drain.finish()
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<2) == [0, 0])
    #expect(checkpoint.gapEvents == [
        AudioGapEvent(startFrame: 0, frameCount: 2, reason: .invalidBuffer)
    ])
}

@Test func stopWithoutAnyCapturedCallbackPreservesElapsedTail() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 1, blockFrameCapacity: 2)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    ring.finish(tailFrame: 4)
    let checkpoint = try await drain.finish()
    #expect(ring.dropoutCount == 1)
    #expect(checkpoint.gapEvents == [
        AudioGapEvent(startFrame: 0, frameCount: 4, reason: .stopTail)
    ])
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<4) == [0, 0, 0, 0])
}

@Test func oversizedPlanarCallbackSplitsWithoutDroppingFrames() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 3, blockFrameCapacity: 2)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    var left: [Float] = [1, 2, 3, 4, 5]
    var right: [Float] = [10, 20, 30, 40, 50]
    let accepted = left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            var channels = [l.baseAddress!, r.baseAddress!]
            return channels.withUnsafeMutableBufferPointer {
                ring.pushPlanarFloat32(channelData: $0.baseAddress!, channelCount: 2,
                                       frameCount: 5, startFrame: 0)
            }
        }
    }
    #expect(accepted)
    #expect(try await drain.drainAvailable() == 3)
    ring.finish(tailFrame: 5)
    let checkpoint = try await drain.finish()
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<5) == [5.5, 11, 16.5, 22, 27.5])
    #expect(checkpoint.gapEvents.isEmpty)
}

@Test func partialOversizedCallbackOverflowKeepsItsTailPosition() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 2)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    #expect(!pushMono([1, 2, 3, 4, 5], at: 0, into: ring))
    ring.finish(tailFrame: 5)
    let checkpoint = try await drain.finish()
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<5) == [1, 2, 3, 4, 0])
    #expect(checkpoint.gapEvents == [
        AudioGapEvent(startFrame: 4, frameCount: 1, reason: .overflow)
    ])
}

@Test func negativePTSAndOverlapsTrimWithoutDuplicatingFrames() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 4, blockFrameCapacity: 2)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    #expect(pushMono([99, 98, 1, 2], at: -2, into: ring))
    #expect(pushMono([77, 3, 4], at: 1, into: ring))
    ring.finish(tailFrame: 4)
    let checkpoint = try await drain.finish()
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<4) == [1, 2, 3, 4])
    #expect(checkpoint.gapEvents.isEmpty)
}

@Test func ringDurationCapacityUsesDeviceFramesNotInterleavedSamples() {
    let slots = AudioBlockRing.capacityForDuration(
        sampleRate: 48_000, blockFrameCapacity: 512)
    #expect(slots == 938)
    #expect(slots * 512 >= 48_000 * 10)
}

@Test func tenSecondRingHandlesFiveHundredTwelveFrameCallbacksAtFortyEightKilohertz() {
    let callbackFrames = 512
    let callbackCount = 938 // ceil(48_000 * 10 / 512)
    let slots = AudioBlockRing.capacityForDuration(
        sampleRate: 48_000, blockFrameCapacity: 16_384)
    // A configured maximum callback size does not guarantee callbacks arrive that large.
    let ring = AudioBlockRing(capacity: slots, blockFrameCapacity: callbackFrames)
    var samples = [Float](repeating: 1, count: callbackFrames)
    var accepted = 0
    samples.withUnsafeMutableBufferPointer { buffer in
        let channelData = [buffer.baseAddress!]
        channelData.withUnsafeBufferPointer { channels in
            while accepted < callbackCount, ring.pushPlanarFloat32(
                channelData: channels.baseAddress!, channelCount: 1,
                frameCount: callbackFrames, startFrame: Int64(accepted * callbackFrames)
            ) {
                accepted += 1
            }
        }
    }
    #expect(accepted == callbackCount)
    #expect(ring.overflowCount == 0)
    var consumed = 0
    while let block = ring.pop() {
        #expect(block.startFrame == Int64(consumed * callbackFrames))
        consumed += 1
    }
    #expect(consumed == callbackCount)
}

@Test func emptyPTSCallbacksDoNotMoveTimelineOrReportFalseDropout() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 1, blockFrameCapacity: 2)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    #expect(pushMono([1, 2], at: 0, into: ring))
    var dummy: [Float] = [99]
    let emptyAccepted = dummy.withUnsafeMutableBufferPointer { samples in
        var channel = [samples.baseAddress!]
        return channel.withUnsafeMutableBufferPointer {
            ring.pushPlanarFloat32(channelData: $0.baseAddress!, channelCount: 1,
                                   frameCount: 0, startFrame: 100)
        }
    }
    #expect(emptyAccepted)
    ring.noteMissing(startFrame: 100, frameCount: 0)
    ring.finish(tailFrame: 2)
    let checkpoint = try await drain.finish()
    #expect(ring.dropoutCount == 0)
    #expect(ring.overflowCount == 0)
    #expect(checkpoint.gapEvents.isEmpty)
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<2) == [1, 2])
}

@Test func reusedRingSlotDoesNotReplayPreviousOverflowGap() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ring = AudioBlockRing(capacity: 1, blockFrameCapacity: 2)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    #expect(pushMono([1, 2], at: 0, into: ring))
    #expect(!pushMono([3, 4], at: 2, into: ring))
    #expect(try await drain.drainAvailable() == 1)
    #expect(pushMono([5, 6], at: 4, into: ring))
    #expect(try await drain.drainAvailable() == 1)
    #expect(pushMono([7, 8], at: 6, into: ring))
    ring.finish(tailFrame: 8)
    let checkpoint = try await drain.finish()
    #expect(checkpoint.gapEvents == [
        AudioGapEvent(startFrame: 2, frameCount: 2, reason: .overflow)
    ])
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<8) == [1, 2, 0, 0, 5, 6, 7, 8])
}

@Test func dropoutCountTracksCallbackLossWithoutCountingTheSameTailTwice() {
    let ring = AudioBlockRing(capacity: 1, blockFrameCapacity: 2)
    #expect(pushMono([1, 2], at: 0, into: ring))
    #expect(!pushMono([3], at: 2, into: ring))
    #expect(ring.overflowCount == 1)
    #expect(ring.dropoutCount == 1)
    _ = ring.pop()
    ring.noteMissing(startFrame: 3, frameCount: 1)
    #expect(ring.dropoutCount == 2)
    _ = ring.pop()
    #expect(pushMono([7], at: 6, into: ring))
    #expect(ring.dropoutCount == 3)
    ring.finish(tailFrame: 8)
    ring.finish(tailFrame: 8)
    #expect(ring.dropoutCount == 4)
}

func pushMono(_ values: [Float], at frame: Int64, into ring: AudioBlockRing) -> Bool {
    var values = values
    let frameCount = values.count
    return values.withUnsafeMutableBufferPointer { samples in
        var channel = [samples.baseAddress!]
        return channel.withUnsafeMutableBufferPointer {
            ring.pushPlanarFloat32(channelData: $0.baseAddress!, channelCount: 1,
                                   frameCount: frameCount, startFrame: frame)
        }
    }
}

@Test func drainFinishCannotOvertakeAnAwaitingWriterAppend() async throws {
    let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 2)
    let writer = GatedCaptureWriter()
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    #expect(pushMono([1, 2], at: 0, into: ring))

    let draining = Task { try await drain.drainAvailable() }
    await writer.waitUntilFirstAppendStarts()
    #expect(pushMono([3, 4], at: 4, into: ring))
    ring.finish(tailFrame: 6)
    let finishing = Task { try await drain.finish() }

    // A reentrant drain would pop block two and finish with only that block
    // while append of block one is still suspended at this gate.
    try await Task.sleep(for: .milliseconds(30))
    #expect(!(await writer.hasFinished))
    await writer.releaseFirstAppend()
    #expect(try await draining.value == 2)
    let checkpoint = try await finishing.value
    #expect(checkpoint.committedFrames == 6)
    #expect(checkpoint.gapEvents == [
        AudioGapEvent(startFrame: 2, frameCount: 2, reason: .missingCallback)
    ])
    #expect(await writer.writtenSamples == [1, 2, 0, 0, 3, 4])
}

@Test func drainSnapshotCannotPassAnAwaitingWriterAppend() async throws {
    let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 2)
    let writer = GatedCaptureWriter()
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())
    #expect(pushMono([1, 2], at: 0, into: ring))

    let draining = Task { try await drain.drainAvailable() }
    await writer.waitUntilFirstAppendStarts()
    #expect(pushMono([3, 4], at: 2, into: ring))
    let snapshotting = Task { try await drain.committedSnapshot() }
    try await Task.sleep(for: .milliseconds(30))
    await writer.releaseFirstAppend()

    #expect(try await draining.value == 2)
    let checkpoint = try await snapshotting.value
    #expect(checkpoint.committedFrames == 4)
    #expect(await writer.writtenSamples == [1, 2, 3, 4])
}

private actor GatedCaptureWriter: AudioCaptureWriting {
    private var samples: [Float] = []
    private var gaps: [AudioGapEvent] = []
    private var firstAppendWaiting = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var firstAppendGate: CheckedContinuation<Void, Never>?
    private var finished = false

    var writtenSamples: [Float] { samples }
    var hasFinished: Bool { finished }

    func waitUntilFirstAppendStarts() async {
        if firstAppendWaiting { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func releaseFirstAppend() {
        firstAppendGate?.resume()
        firstAppendGate = nil
    }

    func append(samples: [Float]) async {
        if !firstAppendWaiting {
            firstAppendWaiting = true
            startedWaiter?.resume()
            startedWaiter = nil
            await withCheckedContinuation { firstAppendGate = $0 }
        }
        self.samples.append(contentsOf: samples)
    }

    func recordGap(startFrame: Int64, frameCount: Int64, reason: AudioGapReason) {
        gaps.append(AudioGapEvent(startFrame: startFrame, frameCount: frameCount, reason: reason))
    }

    func committedSnapshot() -> AudioCheckpoint {
        AudioCheckpoint(
                        committedFrames: Int64(samples.count),
                        sampleRate: CanonicalAudio.sampleRate,
                        channelCount: CanonicalAudio.channelCount,
                        sampleFormat: .float32LE,
                        chunkFiles: [],
                        chunkFrameCounts: [],
                        gapEvents: gaps
                    )
    }

    func checkpoint() -> AudioCheckpoint { committedSnapshot() }

    func finish() -> AudioCheckpoint {
        finished = true
        return committedSnapshot()
    }
}

@Test func partialReadsMatchTheSameRangeOfAFullRead() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 4.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let samples = (0..<13).map(Float.init)
    try await writer.append(samples: samples)
    let checkpoint = try await writer.finish()
    #expect(checkpoint.chunkFrameCounts == [4, 4, 4, 1])
    let reader = try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
    let full = try reader.readSamples(frameRange: 0..<13)
    #expect(full == samples)
    for range: Range<Int64> in [0..<1, 3..<5, 1..<12, 4..<8, 11..<13, 12..<13, 6..<6] {
        #expect(try reader.readSamples(frameRange: range)
            == Array(full[Int(range.lowerBound)..<Int(range.upperBound)]))
    }
}

@Test func partialReadStillRejectsAChunkWhoseSizeDiffersFromItsIndex() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 4.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await writer.append(samples: (0..<8).map(Float.init))
    let checkpoint = try await writer.finish()
    let handle = try FileHandle(forWritingTo: root.appending(path: "chunk-000001.f32le"))
    try handle.truncate(atOffset: 12)
    try handle.close()
    let reader = try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
    #expect(try reader.readSamples(frameRange: 0..<4) == [0, 1, 2, 3])
    #expect(throws: ProcessingTimelineReaderError.corruptChunk("chunk-000001.f32le")) {
        _ = try reader.readSamples(frameRange: 4..<5)
    }
    #expect(throws: ProcessingTimelineReaderError.unreadableChunk("chunk-000002.f32le")) {
        _ = try ProcessingTimelineReader(directory: root, checkpoint: AudioCheckpoint(
            committedFrames: 1, sampleRate: 16_000, channelCount: 1, sampleFormat: .float32LE,
            chunkFiles: ["chunk-000002.f32le"], chunkFrameCounts: [1], gapEvents: []
        ), sessionURL: root).readSamples(frameRange: 0..<1)
    }
}

@Test func storageErrorKeepsTheFailedChunkName() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 2.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try FileManager.default.createDirectory(
        at: root.appending(path: "chunk-000000.f32le"), withIntermediateDirectories: false
    )
    do {
        try await writer.append(samples: [1, 2])
        Issue.record("A chunk path occupied by a directory must not be written")
    } catch {
        #expect(error as? DurableAudioWriterError == .writeFailed("chunk-000000.f32le"))
    }
}
