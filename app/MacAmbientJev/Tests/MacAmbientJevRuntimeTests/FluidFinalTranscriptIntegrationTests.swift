import AVFoundation
import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevPipeline
import MacAmbientJevAppleSupport
@testable import MacAmbientJevRuntime

private actor FinalizationCallLog {
    private var values: [String] = []

    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor FinalizationSleepRecorder {
    private var durations: [Duration] = []

    func append(_ duration: Duration) { durations.append(duration) }
    func snapshot() -> [Duration] { durations }
}

private struct FakeFinalVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "fake-vad", model: nil, version: "test", configuration: [:])
    let segments: [SegmentReference]
    let log: FinalizationCallLog

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        await log.append("vad")
        return segments.map {
            SegmentReference(
                segmentationRunID: runID,
                segmentID: $0.segmentID,
                startFrame: $0.startFrame,
                endFrame: $0.endFrame
            )
        }
    }
}

private actor FakeFinalASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private let log: FinalizationCallLog
    private let values: [String]
    private var callIndex = 0

    init(log: FinalizationCallLog, values: [String]) {
        self.log = log
        self.values = values
    }

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        let index = callIndex
        callIndex += 1
        await log.append("asr:\(index)")
        return ASRResult(text: values[index], detectedLanguage: "ja")
    }

    func unload() async {}
}

private func finalizationFixture(
    frames: Int = 16_000,
    samples: [Float]? = nil,
    sessionID: UUID = UUID()
) async throws -> (AppPaths, URL, AudioCheckpoint) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths,
        sessionID: sessionID,
        source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let processingDirectory = sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory)
    let writer = try DurableAudioWriter(
        directory: processingDirectory,
        chunkDurationSeconds: 1, sessionURL: sessionURL
    )
    try await writer.append(samples: samples ?? Array(repeating: 0.1, count: frames))
    return (paths, sessionURL, await writer.committedSnapshot())
}

@Test
func finalTranscriptPipelineForwardsPacingAndPauseToASR() async throws {
    let sourceSessionID = UUID()
    let (paths, sourceSessionURL, checkpoint) = try await finalizationFixture(sessionID: sourceSessionID)
    defer { try? FileManager.default.removeItem(at: sourceSessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let sessionID = UUID()
    let importURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .imported(originalFilename: "fixture.wav"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let originalURL = importURL.appending(path: "audio/original.caf")
    do {
        let reader = try ProcessingTimelineReader(
            directory: sourceSessionURL.appending(path: "audio/processing", directoryHint: .isDirectory),
            checkpoint: checkpoint, sessionURL: sourceSessionURL
        )
        let samples = try reader.readSamples(frameRange: 0..<checkpoint.committedFrames)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: CanonicalAudio.sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: originalURL, settings: format.settings)
        try file.write(from: buffer)
    }
    let log = FinalizationCallLog()
    let sleepRecorder = FinalizationSleepRecorder()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["前半", "後半"]),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [
                    SegmentReference(segmentationRunID: "ignored", segmentID: "vad_1", startFrame: 0, endFrame: 8_000),
                    SegmentReference(segmentationRunID: "ignored", segmentID: "vad_2", startFrame: 8_000, endFrame: 16_000)
                ],
                log: log
            )
        ),
        audioHandling: SessionProcessingAudio(timelineBuilder: AudioFileTimelineBuilder()),
        contentPriority: .disabled,
        sleep: { await sleepRecorder.append($0) }
    )

    let result = await processor.processSession(
        sessionID: sessionID,
        pacingMode: .lowHeat,
        shouldPause: {
            await log.append("pause")
            return nil
        },
        onPhase: { _ in },
        metadataPolicy: .reject,
        onStatus: { _ in },
        onUpdate: { _, _ in }
    )

    #expect(result.disposition == .completed)
    #expect(result.metrics?.pacingWaitCount == 1)
    #expect(await log.snapshot() == ["vad", "pause", "asr:0", "pause", "asr:1"])
    #expect(await sleepRecorder.snapshot() == [.seconds(2)])
}
