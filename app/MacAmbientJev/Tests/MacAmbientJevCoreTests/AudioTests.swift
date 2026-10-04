import Foundation
import Testing
@testable import MacAmbientJevCore

@Test func durableWriterRecordsCommittedFrameRange() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 15)

    try await writer.append(samples: Array(repeating: 0.1, count: 4_800))
    let checkpoint = try await writer.checkpoint()

    #expect(checkpoint.committedFrames == 4_800)
    #expect(checkpoint.chunkFiles.count == 1)
}

@Test func durableWriterSplitsAtConfiguredChunkDuration() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate)

    try await writer.append(samples: Array(repeating: 0.25, count: 25))
    let checkpoint = try await writer.checkpoint()

    #expect(checkpoint.committedFrames == 25)
    #expect(checkpoint.chunkFiles.count == 3)
    #expect(checkpoint.chunkFrameCounts == [10, 10, 5])
}

@Test func liveTranscriptionCheckpointCommitsAtHalfSecondBoundary() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sampleRate = 16_000.0
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: (sampleRate * LiveTranscriptionCadence.durableChunkDurationSeconds) / CanonicalAudio.sampleRate)

    try await writer.append(samples: Array(repeating: 0.1, count: 7_999))
    #expect(await writer.committedSnapshot().committedFrames == 0)
    try await writer.append(samples: [0.1])
    #expect(await writer.committedSnapshot().committedFrames == 8_000)
}

@Test func timelineConvertsGenericFrameCoordinatesToMilliseconds() {
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
    #expect(pushMono([1, 2, 3, 4], at: 0, into: ring))
    #expect(pushMono([5, 6, 7, 8], at: 4, into: ring))
    #expect(!pushMono([9, 10, 11, 12], at: 8, into: ring))
    #expect(ring.overflowCount == 1)
    #expect(ring.pop()?.samples == [1, 2, 3, 4])
    #expect(ring.pop()?.samples == [5, 6, 7, 8])
    #expect(ring.pop() == nil)
}

@Test func processingTimelineReaderReadsAcrossDurableChunkBoundaries() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate)
    try await writer.append(samples: (0..<25).map(Float.init))
    let checkpoint = try await writer.finish()

    let reader = ProcessingTimelineReader(directory: root, checkpoint: checkpoint)
    let samples = try reader.readSamples(frameRange: 8..<13)

    #expect(samples == [8, 9, 10, 11, 12])
}

@Test func audioBlockRingAveragesPlanarInputWithoutCallbackArray() {
    let ring = AudioBlockRing(capacity: 1, blockFrameCapacity: 4)
    var left: [Float] = [1, 2]
    var right: [Float] = [10, 20]

    let accepted = left.withUnsafeMutableBufferPointer { leftBuffer in
        right.withUnsafeMutableBufferPointer { rightBuffer in
            var channels = [leftBuffer.baseAddress!, rightBuffer.baseAddress!]
            return channels.withUnsafeMutableBufferPointer { channelBuffer in
                ring.pushPlanarFloat32(
                    channelData: channelBuffer.baseAddress!,
                    channelCount: 2,
                    frameCount: 2,
                    startFrame: 0
                )
            }
        }
    }

    #expect(accepted)
    #expect(ring.pop()?.samples == [5.5, 11])
}

@Test func captureDrainWritesQueuedAudioOutsideRealtimeCallback() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 4)
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 4.0 / CanonicalAudio.sampleRate)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: CanonicalMonoPassthrough())

    #expect(pushMono([1, 2, 3, 4], at: 0, into: ring))
    #expect(pushMono([5, 6], at: 4, into: ring))

    #expect(try await drain.drainAvailable() == 2)
    let checkpoint = try await drain.finish()

    #expect(checkpoint.committedFrames == 6)
    let reader = ProcessingTimelineReader(directory: root, checkpoint: checkpoint)
    #expect(try reader.readSamples(frameRange: 0..<6) == [1, 2, 3, 4, 5, 6])
}

@Test
func durableWriterPersistsCheckpointBesideChunks() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate)

    let checkpointURL = root.appending(path: "checkpoint.json")
    let initialBytes = try Data(contentsOf: checkpointURL)
    try await writer.append(samples: Array(repeating: 0.5, count: 30))

    // Committed chunk files are durable without rewriting the growing JSON snapshot.
    #expect(try Data(contentsOf: checkpointURL) == initialBytes)
    let recovered = try #require(try AudioCheckpoint.loadRecovered(from: root))
    #expect(recovered.committedFrames == 30)
    #expect(recovered.chunkFrameCounts == [10, 10, 10])
    #expect(try ProcessingTimelineReader(directory: root, checkpoint: recovered)
        .readSamples(frameRange: 0..<30) == Array(repeating: Float(0.5), count: 30))
    let reopened = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate)
    try await reopened.append(samples: Array(repeating: 0.75, count: 10))
    let final = try await reopened.finish()
    #expect(final.chunkFrameCounts == [10, 10, 10, 10])
    #expect(try AudioCheckpoint.loadRecovered(from: root) == final)
}

@Test
func durableGapDiagnosticsSurviveRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate)
    try await writer.append(samples: Array(repeating: 1, count: 5))
    try await writer.recordGap(startFrame: 5, frameCount: 3, reason: .overflow)
    try await writer.append(samples: [0, 0, 0, 1, 1])
    try await writer.recordGap(startFrame: 10, frameCount: 2, reason: .missingCallback)
    try await writer.append(samples: [0, 0] + Array(repeating: 1, count: 8))

    let expected = [
        AudioGapEvent(startFrame: 5, frameCount: 3, reason: .overflow),
        AudioGapEvent(startFrame: 10, frameCount: 2, reason: .missingCallback)
    ]
    let recovered = try #require(try AudioCheckpoint.loadRecovered(from: root))
    #expect(recovered.committedFrames == 20)
    #expect(recovered.gapEvents == expected)
    let reopened = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate)
    #expect(await reopened.committedSnapshot().gapEvents == expected)
    let final = try await reopened.finish()
    #expect(try AudioCheckpoint.loadRecovered(from: root) == final)
    #expect(final.gapEvents == expected)
}

@Test
func checkpointWithoutFormatFrameCountsOrGapsFailsToDecode() {
    let incomplete = Data(
        #"{"committedFrames":0,"sampleRate":10,"channelCount":1,"chunkFiles":[]}"#.utf8
    )
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AudioCheckpoint.self, from: incomplete)
    }
}

@Test
func durableGapLogRepairsInterruptedTailBeforeAppendingAgain() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate)
    try await writer.recordGap(startFrame: 0, frameCount: 2, reason: .invalidBuffer)
    try await writer.append(samples: Array(repeating: 0, count: 10))
    let gapLog = root.appending(path: DurableAudioWriter.gapEventsFilename)
    let handle = try FileHandle(forWritingTo: gapLog)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"startFrame":"#.utf8))
    try handle.close()

    #expect(try AudioCheckpoint.loadRecovered(from: root)?.gapEvents == [
        AudioGapEvent(startFrame: 0, frameCount: 2, reason: .invalidBuffer)
    ])
    let resumed = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate)
    try await resumed.recordGap(startFrame: 10, frameCount: 1, reason: .stopTail)
    try await resumed.append(samples: Array(repeating: 0, count: 10))
    let final = try await resumed.finish()
    #expect(final.gapEvents == [
        AudioGapEvent(startFrame: 0, frameCount: 2, reason: .invalidBuffer),
        AudioGapEvent(startFrame: 10, frameCount: 1, reason: .stopTail)
    ])
    #expect(try AudioCheckpoint.loadRecovered(from: root)?.gapEvents == final.gapEvents)
}

@Test
func durableWriterResumesFromPersistedCheckpointWithoutOverwritingChunks() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate)
    try await first.append(samples: Array(repeating: 1, count: 10))

    let resumed = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate)
    try await resumed.append(samples: Array(repeating: 2, count: 10))
    let checkpoint = try await resumed.finish()

    #expect(checkpoint.committedFrames == 20)
    #expect(checkpoint.chunkFiles == [
        "chunk-000000.f32le",
        "chunk-000001.f32le"
    ])
    #expect(checkpoint.chunkFrameCounts == [10, 10])

    let reader = ProcessingTimelineReader(directory: root, checkpoint: checkpoint)
    #expect(try reader.readSamples(frameRange: 0..<20) == (
        Array(repeating: Float(1), count: 10)
        + Array(repeating: Float(2), count: 10)
    ))
}

@Test
func durableWriterCommittedSnapshotDoesNotFlushPartialChunk() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate)

    try await writer.append(
        samples: Array(repeating: Float(0.25), count: 15)
    )

    let live = await writer.committedSnapshot()
    #expect(live.committedFrames == 10)
    #expect(live.chunkFiles == ["chunk-000000.f32le"])

    let final = try await writer.finish()
    #expect(final.committedFrames == 15)
    #expect(final.chunkFiles == [
        "chunk-000000.f32le",
        "chunk-000001.f32le"
    ])
}

@Test
func timelineReaderUsesExactIndexForVariableLengthChunks() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate)

    try await writer.append(samples: (0..<5).map(Float.init))
    _ = try await writer.checkpoint()

    try await writer.append(samples: (5..<15).map(Float.init))
    try await writer.append(samples: (15..<20).map(Float.init))
    let checkpoint = try await writer.finish()

    #expect(checkpoint.chunkFrameCounts == [5, 10, 5])

    let reader = ProcessingTimelineReader(
        directory: root,
        checkpoint: checkpoint
    )
    #expect(
        try reader.readSamples(frameRange: 4..<17)
            == (4..<17).map(Float.init)
    )
}
