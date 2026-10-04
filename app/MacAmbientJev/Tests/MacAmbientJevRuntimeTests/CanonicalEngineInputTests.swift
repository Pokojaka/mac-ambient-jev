import AVFoundation
import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevCore
@testable import MacAmbientJevRuntime
import Synchronization
import Testing

@Test
func canonicalCAFAudioSourceReadsBoundedRandomRangesWithoutAudioCopies() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "canonical.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: CanonicalAudio.sampleRate, channels: 1))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
    let channels = try #require(buffer.floatChannelData)
    buffer.frameLength = buffer.frameCapacity
    for block in 0..<8 {
        for frame in 0..<16000 { channels[0][frame] = Float((block * 16000 + frame) % 997) / 997 }
        try file.write(from: buffer)
    }
    file.close()
    let originalSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    let source = try CanonicalCAFAudioSource(fileURL: url)
    #expect(source.sampleCount == 128000)
    for (offset, count) in [(8203, 20017), (127993, 7), (0, 320), (503, 8192)] {
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { destination.deallocate() }
        try source.copySamples(into: destination, offset: offset, count: count)
        for index in 0..<count { #expect(destination[index] == Float((offset + index) % 997) / 997) }
    }
    let destination = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    defer { destination.deallocate() }
    #expect(throws: ProcessingTimelineReaderError.invalidFrameRange) {
        try source.copySamples(into: destination, offset: source.sampleCount, count: 1)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["canonical.caf"])
    #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == originalSize)
}

@Test
func nativeQwenRejectsNoncanonicalRateBeforeModelLoading() async throws {
    let paths = AppPaths(applicationSupportURL: URL(fileURLWithPath: "/tmp/unused-support"),
        cacheURL: URL(fileURLWithPath: "/tmp/unused-cache"), sessionsRootOverride: nil)
    let engine = NativeQwen3ASREngine(modelStore: ModelStore(paths: paths))
    await #expect(throws: CanonicalAudioError.self) {
        _ = try await engine.transcribe(ASRAudioInput(samples: [0], sampleRate: 48000))
    }
}

private struct EngineInputObservation: Equatable {
    var vad: [String] = []
    var diarization: [String] = []
    var asr: [String] = []
}

private final class EngineInputLog: Sendable {
    let state = Mutex(EngineInputObservation())
}

private let engineInputProvenance = RunProvenance(engine: "engine-input-probe", model: nil, version: "1", configuration: [:])

private struct ObservingVAD: FinalTranscriptVADSegmenter {
    let log: EngineInputLog
    let provenance = engineInputProvenance

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        let info = reader.info
        log.state.withLock {
            $0.vad.append("\(info.sampleRate)/\(info.channelCount)/\(CanonicalAudio.sampleFormat)")
        }
        return [SegmentReference(segmentationRunID: runID, segmentID: "probe", startFrame: 0, endFrame: 16_000)]
    }
}

private struct ObservingDiarizer: DiarizationEngine {
    let log: EngineInputLog
    let provenance = engineInputProvenance
    func prepare() async throws {}
    func unload() async {}

    func diarize(fileURL: URL, canonicalSampleRate: Double) async throws -> [SpeakerSpan] {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.fileFormat
        log.state.withLock {
            $0.diarization.append("\(canonicalSampleRate)/\(format.sampleRate)/\(format.channelCount)/\(file.length)")
        }
        return [SpeakerSpan(speakerID: "probe", startFrame: 0, endFrame: 16_000, confidence: 1)]
    }
}

private struct ObservingASR: ASREngine {
    let log: EngineInputLog
    let provenance = engineInputProvenance
    func prepare() async throws {}
    func unload() async {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        log.state.withLock { $0.asr.append("\(input.sampleRate)/\(input.samples.count)") }
        return ASRResult(text: "probe", detectedLanguage: "ja")
    }
}

private func writeTone(to url: URL, sampleRate: Double, channels: AVAudioChannelCount, frames: Int) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = buffer.frameCapacity
    let data = try #require(buffer.floatChannelData)
    for frame in 0..<frames {
        for channel in 0..<Int(channels) {
            data[channel][frame] = Float(0.3 * sin(2 * .pi * 440 * Double(frame) / sampleRate)) / Float(channel + 1)
        }
    }
    try file.write(from: buffer)
}

@Test
func finalizationEnginesReceiveCanonicalAudioForRecordedAndImportedSessions() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root.appending(path: "support"), cacheURL: root.appending(path: "cache"),
        sessionsRootOverride: root.appending(path: "sessions"))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let log = EngineInputLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(asr: ObservingASR(log: log), diarization: ObservingDiarizer(log: log),
            finalTranscriptVAD: ObservingVAD(log: log)),
        contentPriority: .disabled
    )

    let recordingID = UUID()
    let recordingURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: recordingID, source: .recording(.systemAudio),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!)
    let writer = try DurableAudioWriter(directory: SessionLayout(sessionURL: recordingURL).processingDirectory,
        chunkDurationSeconds: 0.5)
    let ring = AudioBlockRing(capacity: 8, blockFrameCapacity: 512, sampleRate: 48_000)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: 48_000))
    var device = (0..<96_000).map { Float(0.3 * sin(2 * .pi * 440 * Double($0) / 48_000)) }
    var offset = 0
    while offset < device.count {
        let count = min(offset % 3 == 0 ? 512 : 301, device.count - offset)
        let accepted = device.withUnsafeMutableBufferPointer { samples in
            var channel = samples.baseAddress!.advanced(by: offset)
            return withUnsafePointer(to: &channel) {
                ring.pushPlanarFloat32(channelData: $0, channelCount: 1, frameCount: count, startFrame: Int64(offset))
            }
        }
        #expect(accepted)
        _ = try await drain.drainAvailable()
        offset += count
    }
    ring.finish(tailFrame: Int64(device.count))
    let recorded = try await drain.finish()
    #expect(recorded.committedFrames == 32_000)
    let recordingResult = await processor.processSession(
        sessionID: recordingID, pacingMode: .normal, shouldPause: { false }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in })
    #expect(recordingResult.disposition == .completed)

    let importID = UUID()
    let source = root.appending(path: "stereo-44100.caf")
    try writeTone(to: source, sampleRate: 44_100, channels: 2, frames: 88_200)
    let importURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: importID, source: .imported(originalFilename: source.lastPathComponent),
        createdAt: Date(timeIntervalSince1970: 1_700_000_001), timeZone: TimeZone(secondsFromGMT: 0)!)
    let original = try AudioImporter().importFile(source, into: importURL).originalURL
    let originalBytes = try Data(contentsOf: original)
    let importResult = await processor.processSession(
        sessionID: importID, pacingMode: .normal, shouldPause: { false }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in })
    #expect(importResult.disposition == .completed)
    #expect(try Data(contentsOf: original) == originalBytes)

    #expect(log.state.withLock { $0 } == EngineInputObservation(
        vad: ["16000.0/1/float32LE", "16000.0/1/float32LE"],
        diarization: ["16000.0/16000.0/1/32000", "16000.0/16000.0/1/32000"],
        asr: ["16000/16000", "16000/16000"]
    ))
}
