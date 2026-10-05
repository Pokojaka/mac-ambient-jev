import AVFoundation
import Foundation
import Testing
@testable import MacAmbientJevAppleSupport
@testable import MacAmbientJevCore

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

/// Samples that are exact 16-bit values, so FLAC reads them back unchanged.
private let samples16: [Float] = (0..<20_000).map { (index: Int) -> Float in
    let level: Int = (index * 37) % 2_001 - 1_000
    return Float(level) / 32_768
}

private func writeFLAC(_ samples: [Float], to url: URL) throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: CanonicalAudio.sampleRate, channels: 1, interleaved: false
    ))
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: CanonicalAudio.sampleRate,
            AVNumberOfChannelsKey: 1,
        ],
        commonFormat: .pcmFormatInt16, interleaved: false
    )
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for (index, sample) in samples.enumerated() {
        buffer.int16ChannelData![0][index] = Int16(sample * 32_768)
    }
    try file.write(from: buffer)
}

@Test
func openingAPCMRecordingReadsItsChunks() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 0.5)
    try await writer.append(samples: samples16)
    let checkpoint = try await writer.finish()

    let reader = try SessionAudioReaders.open(.recordedPCM(checkpoint), layout: layout)

    #expect(reader.info == (try checkpoint.info))
    #expect(try reader.readSamples(frameRange: 100..<200) == Array(samples16[100..<200]))
}

@Test
func openingAPCMRecordingWithACorruptChunkThrows() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 0.5)
    try await writer.append(samples: samples16)
    let checkpoint = try await writer.finish()
    try Data(count: 3).write(to: layout.processingDirectory.appending(path: checkpoint.chunkFiles[0]))

    #expect(throws: ProcessingTimelineReaderError.self) {
        _ = try SessionAudioReaders.open(.recordedPCM(checkpoint), layout: layout)
    }
}

@Test
func openingAFLACRecordingReadsBoundedRangesAcrossBuffers() throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    try writeFLAC(samples16, to: layout.recordingFLACURL)
    let info = try TimelineAudioInfo(committedFrames: Int64(samples16.count), gapEvents: [])

    let reader = try SessionAudioReaders.open(.recordedFLAC(info), layout: layout)

    #expect(try reader.readSamples(frameRange: 8_000..<8_300) == Array(samples16[8_000..<8_300]))
    #expect(try reader.readSamples(frameRange: 0..<20_000) == samples16)
    #expect(try reader.readSamples(frameRange: 5..<5).isEmpty)
    #expect(throws: ProcessingTimelineReaderError.invalidFrameRange) {
        _ = try reader.readSamples(frameRange: 19_999..<20_001)
    }
}

@Test
func openingAFLACRecordingWithTheWrongLengthThrows() throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    try writeFLAC(samples16, to: layout.recordingFLACURL)
    let info = try TimelineAudioInfo(committedFrames: Int64(samples16.count) + 1, gapEvents: [])

    #expect(throws: FLACTimelineReaderError.self) {
        _ = try SessionAudioReaders.open(.recordedFLAC(info), layout: layout)
    }
}

@Test
func openingATruncatedFLACRecordingThrows() throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    try writeFLAC(samples16, to: layout.recordingFLACURL)
    let data = try Data(contentsOf: layout.recordingFLACURL)
    try data.prefix(data.count / 2).write(to: layout.recordingFLACURL)
    let info = try TimelineAudioInfo(committedFrames: Int64(samples16.count), gapEvents: [])

    #expect(throws: (any Error).self) {
        _ = try SessionAudioReaders.open(.recordedFLAC(info), layout: layout)
    }
}

@Test
func aFLACRecordingNeverFallsBackToPCMStillOnDisk() async throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 0.5)
    try await writer.append(samples: samples16)
    let checkpoint = try await writer.finish()

    #expect(throws: (any Error).self) {
        _ = try SessionAudioReaders.open(.recordedFLAC(try checkpoint.info), layout: layout)
    }
}

@Test
func anImportIsNotOpenedWithoutATimelineBuild() throws {
    let layout = try makeLayout()
    defer { cleanUp(layout) }

    #expect(throws: SessionAudioReadersError.importNeedsTimelineBuild) {
        _ = try SessionAudioReaders.open(
            .importedOriginal(layout.audioDirectory.appending(path: "original.wav"), timeline: nil), layout: layout
        )
    }
}
