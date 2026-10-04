import AVFoundation
import Foundation
import Testing
@testable import MacAmbientJevAppleSupport
@testable import MacAmbientJevCore

private struct Crash: Error {}

private func makeLayout() throws -> SessionLayout {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    return SessionLayout(sessionURL: try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: UUID(), source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    ))
}

private func cleanUp(_ layout: SessionLayout) {
    try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent())
}

/// Not 16-bit exact, so the FLAC holds the quantized values; 20,000 frames end in a partial decode buffer.
private let recordedSamples: [Float] = (0..<20_000).map { sin(Float($0) * 0.013) * 0.8 }

@discardableResult
private func recordPCM(_ layout: SessionLayout, samples: [Float] = recordedSamples) async throws -> AudioCheckpoint {
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 0.5)
    try await writer.append(samples: samples)
    return try await writer.finish()
}

private func quantized(_ samples: [Float]) -> [Float] {
    samples.map { Float(RecordingFLAC.quantize16($0)!) / 32_768 }
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

/// One authority: FLAC state, a verified FLAC equal to the quantized samples, no PCM, no partial.
private func expectConverged(
    _ layout: SessionLayout, info: TimelineAudioInfo, samples: [Float]
) throws {
    #expect(try SessionAudioStorageStore(layout: layout).load() == .recordingFLAC(info))
    let reader = try SessionAudioReaders.open(.recordedFLAC(info), layout: layout)
    #expect(try reader.readSamples(frameRange: 0..<info.committedFrames) == quantized(samples))
    #expect(!exists(layout.processingDirectory))
    #expect(!exists(layout.recordingFLACPartialURL))
}

private func compactOnce(_ layout: SessionLayout, interruptAt boundary: RecordingAudioCompactor.Boundary) throws {
    #expect(throws: Crash.self) {
        _ = try RecordingAudioCompactor(interrupt: { if $0 == boundary { throw Crash() } }).compact(layout: layout)
    }
}

private let recordingManifest = SessionManifest(
    sessionID: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000), source: .recording(.microphone)
)

private let freshCompactor = RecordingAudioCompactor(interrupt: nil)

@Test
func compactingAPCMRecordingStoresItsQuantizedSamplesAsFLAC() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let checkpoint = try await recordPCM(layout)

    let info = try freshCompactor.compact(layout: layout)

    #expect(info == (try checkpoint.info))
    try expectConverged(layout, info: info, samples: recordedSamples)
}

@Test
func compactingKeepsGapEventsInTheStoredInfo() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 0.5)
    try await writer.append(samples: Array(recordedSamples[0..<8_000]))
    try await writer.recordGap(startFrame: 8_000, frameCount: 4_000, reason: .overflow)
    try await writer.append(samples: [Float](repeating: 0, count: 4_000))
    try await writer.append(samples: Array(recordedSamples[12_000..<16_000]))
    let checkpoint = try await writer.finish()
    #expect(!checkpoint.gapEvents.isEmpty)

    let info = try freshCompactor.compact(layout: layout)

    #expect(info.gapEvents == checkpoint.gapEvents)
    #expect(try SessionAudioStorageStore(layout: layout).load() == .recordingFLAC(info))
}

@Test
func compactingASilentRecordingProducesSilentFLAC() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let silence = [Float](repeating: 0, count: 17_000)
    try await recordPCM(layout, samples: silence)

    let info = try freshCompactor.compact(layout: layout)

    try expectConverged(layout, info: info, samples: silence)
}

@Test
func compactingClampsOutOfRangeSamplesAndKeepsTheEndpoints() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let extremes: [Float] = [-1, 1, -2, 2, 0.99999, -0.99999, 0, 1.0 / 65_536, -1.0 / 65_536]
        + [Float](repeating: 0.25, count: 8_000)
    try await recordPCM(layout, samples: extremes)

    let info = try freshCompactor.compact(layout: layout)

    let reader = try SessionAudioReaders.open(.recordedFLAC(info), layout: layout)
    let decoded = try reader.readSamples(frameRange: 0..<info.committedFrames)
    #expect(decoded[0] == -1)
    #expect(decoded[1] == 32_767.0 / 32_768)
    #expect(decoded[2] == -1)
    #expect(decoded[3] == 32_767.0 / 32_768)
    #expect(decoded == quantized(extremes))
}

@Test
func aNonFiniteSampleFailsAndLeavesThePCMRecording() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let checkpoint = try await recordPCM(layout)
    let chunk = layout.processingDirectory.appending(path: checkpoint.chunkFiles[0])
    var bytes = try Data(contentsOf: chunk)
    bytes.replaceSubrange(36..<40, with: withUnsafeBytes(of: Float.nan.bitPattern.littleEndian) { Data($0) })
    try bytes.write(to: chunk)

    #expect(throws: RecordingFLACError.nonFiniteSample(frame: 9)) {
        _ = try freshCompactor.compact(layout: layout)
    }

    #expect(try SessionAudioStorageStore(layout: layout).load() == .recordingPCM)
    #expect(!exists(layout.recordingFLACURL))
    #expect(try AudioCheckpoint.loadRecovered(from: layout.processingDirectory) == checkpoint)
}

@Test
func aCorruptPCMChunkFailsAndNothingIsPublished() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let checkpoint = try await recordPCM(layout)
    try Data(count: 3).write(to: layout.processingDirectory.appending(path: checkpoint.chunkFiles[0]))

    #expect(throws: (any Error).self) {
        _ = try freshCompactor.compact(layout: layout)
    }

    #expect(try SessionAudioStorageStore(layout: layout).load() == .recordingPCM)
    #expect(!exists(layout.recordingFLACURL))
}

@Test
func aRecordingWithoutFramesIsRejected() throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }

    #expect(throws: RecordingAudioCompactorError.emptyRecording) {
        _ = try freshCompactor.compact(layout: layout)
    }
}

@Test
func anImportIsNotCompacted() throws {
    let layout = try makeLayout()
    try SessionAudioStorageStore(layout: layout).save(.importedOriginal(nil))
    defer { cleanUp(layout) }

    #expect(throws: RecordingAudioCompactorError.notARecording) {
        _ = try freshCompactor.compact(layout: layout)
    }
}

@Test(arguments: [
    RecordingAudioCompactor.Boundary.partialWritten, .partialSynchronized, .partialVerified,
    .published, .stateSaved, .pcmRemovalStarted,
])
func aCrashAtEveryBoundaryConvergesOnTheNextCompaction(boundary: RecordingAudioCompactor.Boundary) async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let checkpoint = try await recordPCM(layout)
    try compactOnce(layout, interruptAt: boundary)

    let info = try freshCompactor.compact(layout: layout)

    #expect(info == (try checkpoint.info))
    try expectConverged(layout, info: info, samples: recordedSamples)
}

@Test
func compactingAgainChangesNothing() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    try await recordPCM(layout)
    let info = try freshCompactor.compact(layout: layout)
    let flac = try Data(contentsOf: layout.recordingFLACURL)
    let storage = try Data(contentsOf: layout.audioStorageURL)

    #expect(try freshCompactor.compact(layout: layout) == info)

    #expect(try Data(contentsOf: layout.recordingFLACURL) == flac)
    #expect(try Data(contentsOf: layout.audioStorageURL) == storage)
}

@Test
func aCrashDuringEncodingLeavesAPartialThatIsReplaced() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    try await recordPCM(layout)
    try Data(repeating: 0x66, count: 123).write(to: layout.recordingFLACPartialURL)

    let info = try freshCompactor.compact(layout: layout)

    try expectConverged(layout, info: info, samples: recordedSamples)
}

@Test
func aStaleTruncatedPartialFromAnEarlierRunIsReplaced() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    try await recordPCM(layout)
    try compactOnce(layout, interruptAt: .partialWritten)
    let whole = try Data(contentsOf: layout.recordingFLACPartialURL)
    try whole.prefix(whole.count / 2).write(to: layout.recordingFLACPartialURL)

    let info = try freshCompactor.compact(layout: layout)

    try expectConverged(layout, info: info, samples: recordedSamples)
}

@Test
func aCorruptPublishedFLACUnderPCMStateIsReencodedFromPCM() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    try await recordPCM(layout)
    try compactOnce(layout, interruptAt: .published)
    let whole = try Data(contentsOf: layout.recordingFLACURL)
    try whole.prefix(whole.count / 2).write(to: layout.recordingFLACURL)

    let info = try freshCompactor.compact(layout: layout)

    try expectConverged(layout, info: info, samples: recordedSamples)
}

@Test
func aPublishedFLACThatDiffersFromThePCMIsReencoded() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    try await recordPCM(layout)
    let other = recordedSamples.map { $0 * 0.5 }
    let scratch = try makeLayout()
    defer { cleanUp(scratch) }
    try await recordPCM(scratch, samples: other)
    _ = try freshCompactor.compact(layout: scratch)
    try FileManager.default.copyItem(at: scratch.recordingFLACURL, to: layout.recordingFLACURL)

    let info = try freshCompactor.compact(layout: layout)

    try expectConverged(layout, info: info, samples: recordedSamples)
}

@Test
func aHalfDeletedPCMDirectoryUnderFLACStateIsFinishedOff() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let checkpoint = try await recordPCM(layout)
    try compactOnce(layout, interruptAt: .stateSaved)
    try FileManager.default.createDirectory(at: layout.processingDirectory, withIntermediateDirectories: true)
    try Data(count: 8).write(to: layout.processingDirectory.appending(path: checkpoint.chunkFiles[1]))

    let info = try freshCompactor.compact(layout: layout)

    try expectConverged(layout, info: info, samples: recordedSamples)
}

enum Damage: CaseIterable {
    case truncated, extraFrames, missing, garbage
}

@Test(arguments: Damage.allCases)
func anInvalidFLACUnderFLACStateFailsWithoutTouchingPCM(damage: Damage) async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let checkpoint = try await recordPCM(layout)
    let info = try checkpoint.info
    try SessionAudioStorageStore(layout: layout).save(.recordingFLAC(info))
    switch damage {
    case .truncated:
        let scratch = try makeLayout()
        defer { cleanUp(scratch) }
        try await recordPCM(scratch)
        _ = try freshCompactor.compact(layout: scratch)
        let whole = try Data(contentsOf: scratch.recordingFLACURL)
        try whole.prefix(whole.count / 2).write(to: layout.recordingFLACURL)
    case .extraFrames:
        let scratch = try makeLayout()
        defer { cleanUp(scratch) }
        try await recordPCM(scratch, samples: recordedSamples + [0.1, 0.2, 0.3])
        _ = try freshCompactor.compact(layout: scratch)
        try FileManager.default.copyItem(at: scratch.recordingFLACURL, to: layout.recordingFLACURL)
    case .garbage:
        try Data(repeating: 0x42, count: 5_000).write(to: layout.recordingFLACURL)
    case .missing:
        break
    }

    #expect(throws: FLACTimelineReaderError.self) {
        _ = try freshCompactor.compact(layout: layout)
    }

    #expect(try AudioCheckpoint.loadRecovered(from: layout.processingDirectory) == checkpoint)
    #expect(try SessionAudioStorageStore(layout: layout).load() == .recordingFLAC(info))
}

@Test(arguments: [1, 9, 191, 4_095, 4_096, 4_097, 8_193])
func aRecordingOfAnyLengthRoundTripsAndShortOnesArePaddedWithSilence(frames: Int) async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let samples = (0..<frames).map { sin(Float($0) * 0.31) * 0.9 + 0.05 }
    try await recordPCM(layout, samples: samples)

    let info = try freshCompactor.compact(layout: layout)

    try expectConverged(layout, info: info, samples: samples)
    let stored = Int64(max(frames, 4_096))
    let raw = try AVAudioFile(forReading: layout.recordingFLACURL, commonFormat: .pcmFormatFloat32, interleaved: false)
    #expect(raw.length == stored)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: raw.processingFormat, frameCapacity: AVAudioFrameCount(stored)))
    try raw.read(into: buffer, frameCount: AVAudioFrameCount(stored))
    let decoded = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    #expect(decoded.count == Int(stored))
    #expect(decoded[frames...].allSatisfy { $0 == 0 })
}

@Test
func nonSilentPaddingFailsValidationAndLeavesThePCM() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let scratch = try makeLayout()
    defer { cleanUp(scratch) }
    try await recordPCM(scratch, samples: [Float](repeating: 0.5, count: 4_096))
    _ = try freshCompactor.compact(layout: scratch)
    let checkpoint = try await recordPCM(layout, samples: [Float](repeating: 0.5, count: 100))
    try FileManager.default.copyItem(at: scratch.recordingFLACURL, to: layout.recordingFLACURL)
    try SessionAudioStorageStore(layout: layout).save(.recordingFLAC(try checkpoint.info))

    #expect(throws: FLACTimelineReaderError.paddingNotSilent(frame: 100)) {
        _ = try freshCompactor.compact(layout: layout)
    }

    #expect(try AudioCheckpoint.loadRecovered(from: layout.processingDirectory) == checkpoint)
}

@Test
func readingPastTheRecordedFramesOfAPaddedFLACIsRejected() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    try await recordPCM(layout, samples: [Float](repeating: 0.25, count: 100))
    let info = try freshCompactor.compact(layout: layout)
    let reader = try FLACTimelineReader(url: layout.recordingFLACURL, info: info)

    #expect(throws: ProcessingTimelineReaderError.invalidFrameRange) {
        _ = try reader.readSamples(frameRange: 0..<101)
    }
}

@Test
func aRecordingWithoutFramesIsNeverScheduledForCompaction() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 0.5)
    _ = try await writer.finish()
    try ProcessingMetadataStore(sessionURL: layout.sessionURL).save(ProcessingMetadata(
        finalizationAttempt: nil,
        activeRuns: ActiveRuns(
            segmentation: "seg", asr: "asr", diarization: "diar", scene: "scene", scope: "scope", contentPriority: "priority"
        ),
        pendingContentPrioritySegmentIDs: []
    ))

    #expect(try layout.audioSource(for: recordingManifest) == nil)
    #expect(try SessionStorageMaintenance.required(layout: layout, manifest: recordingManifest) == nil)
}

@Test
func theMaintainerCompactsARecordingAndRemovesItsTransients() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    try await recordPCM(layout)
    try FileManager.default.createDirectory(at: layout.derivedDirectory, withIntermediateDirectories: true)
    try Data(count: 1).write(to: layout.diarizationInputURL)
    let manifest = recordingManifest

    try SessionStorageMaintainer.run(.compactRecording, layout: layout, manifest: manifest)

    #expect(!exists(layout.derivedDirectory))
    try expectConverged(layout, info: try TimelineAudioInfo(committedFrames: Int64(recordedSamples.count), gapEvents: []), samples: recordedSamples)
}

@Test
func theMaintainerRemovesOnlyTransientsForRemoveTransients() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    try await recordPCM(layout)
    try Data(count: 1).write(to: layout.recordingFLACPartialURL)
    let manifest = recordingManifest

    try SessionStorageMaintainer.run(.removeTransients, layout: layout, manifest: manifest)

    #expect(!exists(layout.recordingFLACPartialURL))
    #expect(exists(layout.processingDirectory))
    #expect(try SessionAudioStorageStore(layout: layout).load() == .recordingPCM)
}
