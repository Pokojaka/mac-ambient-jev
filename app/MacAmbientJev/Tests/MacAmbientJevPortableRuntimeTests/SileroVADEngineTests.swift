import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevONNX
import MacAmbientJevPipeline
import MacAmbientJevVADFixtures
@testable import MacAmbientJevPortableRuntime

struct SileroVADEngineTests {
    private let environment: ONNXEnvironment
    private let modelURL: URL
    private let clip: [Float]

    init() throws {
        modelURL = try SileroTestInputs.modelURL(environment: ProcessInfo.processInfo.environment)
        environment = try ONNXEnvironment(loggingID: "SileroVADEngineTests")
        clip = try SileroTestInputs.speechClipSamples()
    }

    private func makeScorer() throws -> SileroChunkScorer {
        SileroChunkScorer(
            vad: try SileroVAD(environment: environment, modelURL: modelURL, intraOpThreads: 1)
        )
    }

    private func makeEngine(measureMicInputLevels: Bool = false) throws -> SileroVADSegmentationEngine {
        try SileroVADSegmentationEngine(
            environment: environment,
            modelURL: modelURL,
            intraOpThreads: 1,
            segmentationRunID: "run",
            canonicalSampleRate: 16_000,
            measureMicInputLevels: measureMicInputLevels
        )
    }

    @Test
    func partialChunkScoresAsItsRepeatLastSamplePadding() throws {
        let tail = Array(clip.prefix(2_000))
        let padded = tail + [Float](
            repeating: tail[tail.count - 1], count: VADSegmentationParameters.chunkSamples - tail.count
        )
        let partial = try makeScorer().speechProbability(chunk: tail)
        let full = try makeScorer().speechProbability(chunk: padded)
        #expect(partial.bitPattern == full.bitPattern)
    }

    @Test
    func recurrentStateCarriesFromOneChunkToTheNext() throws {
        let chunkSamples = VADSegmentationParameters.chunkSamples
        let first = Array(clip[0..<chunkSamples])
        let second = Array(clip[chunkSamples..<(2 * chunkSamples)])
        let continuous = try makeScorer()
        _ = try continuous.speechProbability(chunk: first)
        let afterFirst = try continuous.speechProbability(chunk: second)
        let fresh = try makeScorer().speechProbability(chunk: second)
        #expect(afterFirst.bitPattern != fresh.bitPattern)
    }

    @Test
    func failedChunkLeavesTheStateUnchangedForARetry() throws {
        let chunkSamples = VADSegmentationParameters.chunkSamples
        let first = Array(clip[0..<chunkSamples])
        let second = Array(clip[chunkSamples..<(2 * chunkSamples)])
        var broken = second
        broken[5 * SileroVAD.frameSamples + 3] = .nan

        let retried = try makeScorer()
        _ = try retried.speechProbability(chunk: first)
        #expect(throws: ONNXRuntimeError.self) {
            _ = try retried.speechProbability(chunk: broken)
        }
        let afterRetry = try retried.speechProbability(chunk: second)

        let clean = try makeScorer()
        _ = try clean.speechProbability(chunk: first)
        let expected = try clean.speechProbability(chunk: second)
        #expect(afterRetry.bitPattern == expected.bitPattern)
    }

    @Test
    func engineRejectsNoncanonicalSampleRate() {
        #expect(throws: CanonicalAudioError.self) {
            _ = try SileroVADSegmentationEngine(
                environment: environment,
                modelURL: modelURL,
                intraOpThreads: 1,
                segmentationRunID: "run",
                canonicalSampleRate: 48_000,
                measureMicInputLevels: false
            )
        }
    }

    @Test
    func engineReportsSpeechLevelsOnlyWhenRequested() async throws {
        let chunk = Array(clip[0..<VADSegmentationParameters.chunkSamples])
        let silent = try makeEngine(measureMicInputLevels: false)
        #expect(try await silent.process16kChunk(chunk).micLevel == nil)

        let measuring = try makeEngine(measureMicInputLevels: true)
        var speechSeconds = 0.0
        for start in stride(from: 0, to: clip.count, by: VADSegmentationParameters.chunkSamples) {
            let end = min(start + VADSegmentationParameters.chunkSamples, clip.count)
            let level = try #require(try await measuring.process16kChunk(Array(clip[start..<end])).micLevel)
            speechSeconds += level.speechSeconds
        }
        #expect(speechSeconds > 1.0)
    }

    @Test
    func finalSegmenterRecordsSileroProvenance() {
        let provenance = SileroFinalTranscriptVADSegmenter(
            environment: environment, modelURL: modelURL, intraOpThreads: 3
        ).provenance
        #expect(provenance.engine == "onnxruntime-silero-vad")
        #expect(provenance.model == "silero_vad_16k_op15.onnx")
        #expect(provenance.version
            == "silero-vad@5cd7945676eb32225748052e2e6a0580e4686a08+onnxruntime@1.31.0")
        #expect(provenance.configuration == [
            "pre_roll_seconds": "0.1",
            "max_segment_seconds": "14.0",
            "min_silence_seconds": "0.75",
            "vad_threshold": "0.5",
            "split_search_window_seconds": "2.0",
            "split_energy_frame_seconds": "0.02",
            "minimum_independent_segment_seconds": "0.5",
            "negative_vad_threshold": "0.35",
            "chunk_samples": "4096",
            "frame_samples": "512",
            "frame_aggregation": "noisy-or",
            "model_sha256": "7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49",
            "intra_op_threads": "3",
        ])
    }

    @Test
    func liveSessionSegmentsDurableAudioLikeTheFinalSegmenter() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = try VADParityFile.load().expectation(named: "speech_clip")
        let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1, sessionURL: root)
        let half = clip.count / 2
        try await writer.append(samples: Array(clip[0..<half]))
        let firstCheckpoint = await writer.committedSnapshot()
        let session = try SileroLiveVADSessionFactory.make(
            environment: environment,
            modelURL: modelURL,
            intraOpThreads: 1,
            processingDirectory: root,
            sessionURL: root,
            initialCheckpoint: firstCheckpoint,
            measureMicInputLevels: true,
            segmentationRunID: "live"
        )
        var segments = try await session.processAvailable(checkpoint: firstCheckpoint).emittedSegments

        try await writer.append(samples: Array(clip[half...]))
        let finalCheckpoint = try await writer.finish()
        segments += try await session.finish(checkpoint: finalCheckpoint).emittedSegments

        #expect(finalCheckpoint.committedFrames == Int64(clip.count))
        #expect(segments.map(\.segmentationRunID) == Array(repeating: "live", count: segments.count))
        #expect(
            segments.map { VADParityExpectation.Segment(startFrame: $0.startFrame, endFrame: $0.endFrame) }
                == fixture.segments
        )
    }
}
