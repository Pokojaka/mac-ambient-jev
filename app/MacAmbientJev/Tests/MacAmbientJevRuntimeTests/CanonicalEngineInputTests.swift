import AVFoundation
import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevPipeline
@testable import MacAmbientJevRuntime
import Synchronization
import Testing

@Test
func nativeQwenRejectsNoncanonicalRateBeforeModelLoading() async throws {
    let paths = AppPaths(applicationSupportURL: URL(fileURLWithPath: "/tmp/unused-support"),
        cacheURL: URL(fileURLWithPath: "/tmp/unused-cache"), sessionsRootOverride: nil)
    let engine = NativeQwen3ASREngine(models: try MacModelStore(paths: paths))
    await #expect(throws: CanonicalAudioError.self) {
        _ = try await engine.transcribe(ASRAudioInput(samples: [0], sampleRate: 48000))
    }
}

private struct EngineInputObservation: Equatable {
    var vad: [String] = []
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
        engines: SessionProcessingEngines(asr: ObservingASR(log: log), finalTranscriptVAD: ObservingVAD(log: log)),
        audioHandling: SessionProcessingAudio(timelineBuilder: AudioFileTimelineBuilder()),
        contentPriority: .disabled,
        sleep: { _ in }
    )

    let recordingID = UUID()
    let recordingURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: recordingID, source: .recording(.systemAudio),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!)
    let writer = try DurableAudioWriter(directory: SessionLayout(sessionURL: recordingURL).processingDirectory, chunkDurationSeconds: 0.5, sessionURL: recordingURL)
    let ring = AudioBlockRing(capacity: 8, blockFrameCapacity: 512, sampleRate: 48_000)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: 48_000))
    var device = (0..<96_000).map { (frame: Int) -> Float in
        let phase = 2 * Double.pi * 440 * Double(frame) / 48_000
        return Float(0.3 * sin(phase))
    }
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
        sessionID: recordingID, pacingMode: .normal, shouldPause: { nil }, onPhase: { _ in },
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
        sessionID: importID, pacingMode: .normal, shouldPause: { nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in })
    #expect(importResult.disposition == .completed)
    #expect(try Data(contentsOf: original) == originalBytes)

    #expect(log.state.withLock { $0 } == EngineInputObservation(
        vad: ["16000.0/1/float32LE", "16000.0/1/float32LE"],
        asr: ["16000/16000", "16000/16000"]
    ))
}
