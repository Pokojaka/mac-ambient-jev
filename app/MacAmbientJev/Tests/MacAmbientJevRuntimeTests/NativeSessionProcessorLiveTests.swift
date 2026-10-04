import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private actor LiveUpdateRecorder {
    private var segments: [MaterializedTranscriptSegment] = []

    func record(_ value: [MaterializedTranscriptSegment]) {
        segments = value
    }

    func snapshot() -> [MaterializedTranscriptSegment] {
        segments
    }
}

private actor StubLiveProcessorASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var prepareCount = 0
    private var transcribeCount = 0

    func prepare() async throws {
        prepareCount += 1
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        transcribeCount += 1
        return ASRResult(
            text: "ライブ文字起こし\(transcribeCount)",
            detectedLanguage: "ja"
        )
    }

    func unload() async {}

    func counts() -> (prepare: Int, transcribe: Int) {
        (prepareCount, transcribeCount)
    }
}

@Test
func nativeSessionProcessorStreamsLiveSegmentsWithoutRealModel() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = AppPaths(
        applicationSupportURL: root.appending(
            path: "support",
            directoryHint: .isDirectory
        ),
        cacheURL: root.appending(
            path: "cache",
            directoryHint: .isDirectory
        ),
        sessionsRootOverride: nil
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths,
        sessionID: sessionID,
        source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let processingDirectory = sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory)

    let audioWriter = try DurableAudioWriter(directory: processingDirectory, chunkDurationSeconds: 1)
    try await audioWriter.append(
        samples: Array(repeating: Float(0.1), count: 16_000)
    )
    let checkpoint = await audioWriter.committedSnapshot()

    let asr = StubLiveProcessorASR()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            diarization: FluidOfflineDiarizationEngine(paths: paths),
            finalTranscriptVAD: FluidFinalTranscriptVADSegmenter()
        ),
        contentPriority: .disabled
    )
    let segmentationRunID = "seg_live_test"

    _ = try await processor.startLiveTranscription(
        sessionID: sessionID,
        segmentationRunID: segmentationRunID,
        sampleRate: checkpoint.sampleRate
    )

    let segments = [
        SegmentReference(
            segmentationRunID: segmentationRunID,
            segmentID: "seg_000001",
            startFrame: 0,
            endFrame: 4_000
        ),
        SegmentReference(
            segmentationRunID: segmentationRunID,
            segmentID: "seg_000002",
            startFrame: 4_000,
            endFrame: 8_000
        )
    ]

    _ = try await processor.registerLiveSegments(
        sessionID: sessionID,
        segments: segments
    )

    let recorder = LiveUpdateRecorder()
    let progress = try await processor.processLiveSegments(
        sessionID: sessionID,
        segments: segments,
        checkpoint: checkpoint,
        onStatus: nil,
        onUpdate: { segments, _ in
            await recorder.record(segments)
        }
    )

    #expect(progress.completedCount == 2)
    #expect(progress.failedCount == 0)
    #expect(progress.pendingCount == 0)
    #expect(progress.materializedSegments.map(\.text) == [
        "ライブ文字起こし1",
        "ライブ文字起こし2"
    ])
    #expect(
        await recorder.snapshot() == progress.materializedSegments
    )

    let counts = await asr.counts()
    #expect(counts.prepare == 1)
    #expect(counts.transcribe == 2)
}

private actor GatedLiveProcessorASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var release: CheckedContinuation<Void, Never>?
    private var waitingForStart: CheckedContinuation<Void, Never>?

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        waitingForStart?.resume()
        waitingForStart = nil
        await withCheckedContinuation { continuation in
            release = continuation
        }
        return ASRResult(text: "取り消し後の結果", detectedLanguage: nil)
    }

    func waitUntilTranscribing() async {
        if release != nil { return }
        await withCheckedContinuation { continuation in
            waitingForStart = continuation
        }
    }

    func resume() {
        release?.resume()
        release = nil
    }

    func unload() async {}
}

private actor UpdateCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@Test
func cancelledLiveTranscriptionDoesNotPublishInFlightResult() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let audioWriter = try DurableAudioWriter(directory: sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory), chunkDurationSeconds: 1)
    try await audioWriter.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audioWriter.committedSnapshot()
    let asr = GatedLiveProcessorASR()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            diarization: FluidOfflineDiarizationEngine(paths: paths),
            finalTranscriptVAD: FluidFinalTranscriptVADSegmenter()
        ),
        contentPriority: .disabled
    )
    _ = try await processor.startLiveTranscription(
        sessionID: sessionID, segmentationRunID: "seg_live_test",
        sampleRate: checkpoint.sampleRate
    )
    let segment = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000001",
        startFrame: 0, endFrame: 4_000
    )
    let updates = UpdateCounter()

    let processing = Task {
        try await processor.processLiveSegments(
            sessionID: sessionID, segments: [segment], checkpoint: checkpoint,
            onStatus: nil,
            onUpdate: { _, _ in await updates.increment() }
        )
    }
    await asr.waitUntilTranscribing()
    await processor.cancelLiveTranscription(sessionID: sessionID)
    await asr.resume()
    _ = try await processing.value

    #expect(await updates.count == 0)
}
