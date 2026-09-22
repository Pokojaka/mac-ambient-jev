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
        )
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper().createSession(
        paths: paths,
        sessionID: sessionID,
        sourceKind: .live
    )
    let processingDirectory = sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory)

    let audioWriter = try DurableAudioWriter(
        directory: processingDirectory,
        sampleRate: 16_000,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
    try await audioWriter.append(
        samples: Array(repeating: Float(0.1), count: 16_000)
    )
    let checkpoint = await audioWriter.committedSnapshot()

    let asr = StubLiveProcessorASR()
    let processor = NativeSessionProcessor(
        paths: paths,
        allowExternalJev: false,
        asr: asr
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
