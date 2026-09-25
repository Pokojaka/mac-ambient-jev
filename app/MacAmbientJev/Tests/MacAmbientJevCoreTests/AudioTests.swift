import AVFoundation
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
    #expect(checkpoint.chunkFrameCounts == [10, 10, 5])
}

@Test func liveTranscriptionCheckpointCommitsAtHalfSecondBoundary() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sampleRate = 16_000.0
    let writer = try DurableAudioWriter(
        directory: root,
        sampleRate: sampleRate,
        channelCount: 1,
        chunkDurationSeconds: LiveTranscriptionCadence.durableChunkDurationSeconds
    )

    try await writer.append(samples: Array(repeating: 0.1, count: 7_999))
    #expect(await writer.committedSnapshot().committedFrames == 0)
    try await writer.append(samples: [0.1])
    #expect(await writer.committedSnapshot().committedFrames == 8_000)
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


@Test func audioBlockRingInterleavesPlanarInputWithoutCallbackArray() {
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
                    frameCount: 2
                )
            }
        }
    }

    #expect(accepted)
    #expect(ring.pop() == [1, 10, 2, 20])
}


@Test func captureDrainWritesQueuedAudioOutsideRealtimeCallback() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 4)
    let writer = try DurableAudioWriter(
        directory: root,
        sampleRate: 4,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
    let drain = AudioCaptureDrain(ring: ring, writer: writer)

    #expect(ring.push(samples: [1, 2, 3, 4]))
    #expect(ring.push(samples: [5, 6]))

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

    let writer = try DurableAudioWriter(
        directory: root,
        sampleRate: 10,
        channelCount: 1,
        chunkDurationSeconds: 1
    )

    try await writer.append(samples: Array(repeating: 0.5, count: 10))

    let checkpointURL = root.appending(path: "checkpoint.json")
    let data = try Data(contentsOf: checkpointURL)
    let checkpoint = try JSONDecoder().decode(AudioCheckpoint.self, from: data)

    #expect(checkpoint.committedFrames == 10)
    #expect(checkpoint.chunkFiles == ["chunk-000000.f32le"])
    #expect(checkpoint.chunkFrameCounts == [10])
}

@Test
func durableWriterResumesFromPersistedCheckpointWithoutOverwritingChunks() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = try DurableAudioWriter(
        directory: root,
        sampleRate: 10,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
    try await first.append(samples: Array(repeating: 1, count: 10))

    let resumed = try DurableAudioWriter(
        directory: root,
        sampleRate: 10,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
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


@Test
func durableWriterCommittedSnapshotDoesNotFlushPartialChunk() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(
        directory: root,
        sampleRate: 10,
        channelCount: 1,
        chunkDurationSeconds: 1
    )

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

    let writer = try DurableAudioWriter(
        directory: root,
        sampleRate: 10,
        channelCount: 1,
        chunkDurationSeconds: 1
    )

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

@Test
func durableWriterMigratesLegacyCheckpointToChunkFrameIndex() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )

    func writeChunk(_ values: [Float], name: String) throws {
        let data = values.withUnsafeBytes { Data($0) }
        try data.write(
            to: root.appending(path: name),
            options: .atomic
        )
    }

    try writeChunk(
        Array(repeating: Float(1), count: 5),
        name: "chunk-000000.f32le"
    )
    try writeChunk(
        Array(repeating: Float(2), count: 5),
        name: "chunk-000001.f32le"
    )

    let legacy = AudioCheckpoint(
        committedFrames: 10,
        sampleRate: 10,
        channelCount: 1,
        chunkFiles: [
            "chunk-000000.f32le",
            "chunk-000001.f32le"
        ]
    )
    try JSONEncoder().encode(legacy).write(
        to: root.appending(
            path: DurableAudioWriter.checkpointFilename
        ),
        options: .atomic
    )

    let resumed = try DurableAudioWriter(
        directory: root,
        sampleRate: 10,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
    let checkpoint = await resumed.committedSnapshot()

    #expect(checkpoint.committedFrames == 10)
    #expect(checkpoint.chunkFrameCounts == [5, 5])

    let persisted = try JSONDecoder().decode(
        AudioCheckpoint.self,
        from: Data(
            contentsOf: root.appending(
                path: DurableAudioWriter.checkpointFilename
            )
        )
    )
    #expect(persisted.chunkFrameCounts == [5, 5])
}
