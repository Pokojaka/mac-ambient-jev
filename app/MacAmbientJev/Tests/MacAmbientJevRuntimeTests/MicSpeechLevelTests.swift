import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private enum ScriptedVADFailure: Error { case injected }

/// Scripted VAD probabilities stand in for the model; measurement is the production helper.
private actor ScriptedProbabilityVAD: VADChunkSegmenting {
    private let measures: Bool
    private let probability: @Sendable (Int) -> Float
    private var failingCall: Int?
    private var calls = 0
    private var processedSamples = 0
    private(set) var measuredSampleCount = 0

    init(measures: Bool, failingCall: Int? = nil, probability: @escaping @Sendable (Int) -> Float) {
        self.measures = measures
        self.failingCall = failingCall
        self.probability = probability
    }

    func process16kChunk(_ samples: [Float]) async throws -> VADChunkOutput {
        calls += 1
        if calls == failingCall {
            failingCall = nil
            throw ScriptedVADFailure.injected
        }
        let chunkIndex = processedSamples / 4_096
        let startSeconds = Double(processedSamples) / 16_000
        processedSamples += samples.count
        guard measures else { return VADChunkOutput(segments: [], micLevel: nil) }
        measuredSampleCount += samples.count
        return VADChunkOutput(
            segments: [SegmentReference(
                segmentationRunID: "seg", segmentID: "chunk-\(chunkIndex)",
                startFrame: Int64(chunkIndex * 4_096), endFrame: Int64(processedSamples)
            )],
            micLevel: MicSpeechLevelMeasurement.measure(
                samples: samples, startSeconds: startSeconds,
                speechProbability: probability(chunkIndex)
            )
        )
    }

    func finish(totalCanonicalFrames: Int64) async -> [SegmentReference] { [] }
}

private func alternating(_ amplitude: Float, count: Int) -> [Float] {
    (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
}

private func sine(amplitude: Float, frequency: Double, sampleRate: Double, count: Int) -> [Float] {
    (0..<count).map { Float(Double(amplitude) * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
}

@Suite("MicSpeechLevelTests")
struct MicSpeechLevelTests {
    @Test
    func confirmedQuietSpeechReportsItsEnergy() throws {
        let window = MicSpeechLevelMeasurement.measure(
            samples: alternating(0.01, count: 4_096), startSeconds: 2.048, speechProbability: 0.9
        )
        #expect(window.startSeconds == 2.048)
        #expect(window.endSeconds == 2.048 + 0.256)
        #expect(window.speechSeconds == 0.256)
        let meanSquare = try #require(window.speechMeanSquare)
        #expect(abs(meanSquare - 1e-4) < 1e-10)
        #expect(window.speechPeak == 0.01)
        #expect(window.inputPeak == 0)
        #expect(window.clippedFraction == 0)
    }

    @Test
    func unconfirmedOrSilentChunksNeverCountAsSpeech() {
        let loudRejected = MicSpeechLevelMeasurement.measure(
            samples: alternating(0.5, count: 4_096), startSeconds: 0, speechProbability: 0.849
        )
        let zeros = MicSpeechLevelMeasurement.measure(
            samples: Array(repeating: 0, count: 4_096), startSeconds: 0, speechProbability: 0.99
        )
        for window in [loudRejected, zeros] {
            #expect(window.speechSeconds == 0)
            #expect(window.speechMeanSquare == nil)
            #expect(window.speechPeak == 0)
            #expect(window.endSeconds == 0.256)
        }
    }

    @Test
    func probabilityThresholdIsInclusive() {
        let samples = alternating(0.02, count: 4_096)
        let atThreshold = MicSpeechLevelMeasurement.measure(
            samples: samples, startSeconds: 0, speechProbability: 0.85
        )
        let belowThreshold = MicSpeechLevelMeasurement.measure(
            samples: samples, startSeconds: 0, speechProbability: Float(0.85).nextDown
        )
        let certain = MicSpeechLevelMeasurement.measure(
            samples: samples, startSeconds: 0, speechProbability: 1
        )
        #expect(atThreshold.speechSeconds == 0.256)
        #expect(certain.speechSeconds == 0.256)
        #expect(belowThreshold.speechSeconds == 0)
    }

    @Test
    func invalidInputsProduceNoSpeechEvidence() {
        let valid = alternating(0.02, count: 4_096)
        var withNaN = valid
        withNaN[100] = .nan
        var withInfinity = valid
        withInfinity[7] = .infinity
        let windows = [
            MicSpeechLevelMeasurement.measure(samples: valid, startSeconds: 0, speechProbability: .nan),
            MicSpeechLevelMeasurement.measure(samples: valid, startSeconds: 0, speechProbability: 1.01),
            MicSpeechLevelMeasurement.measure(samples: valid, startSeconds: 0, speechProbability: -1),
            MicSpeechLevelMeasurement.measure(samples: valid, startSeconds: .nan, speechProbability: 0.9),
            MicSpeechLevelMeasurement.measure(samples: valid, startSeconds: -0.1, speechProbability: 0.9),
            MicSpeechLevelMeasurement.measure(samples: withNaN, startSeconds: 0, speechProbability: 0.9),
            MicSpeechLevelMeasurement.measure(samples: withInfinity, startSeconds: 0, speechProbability: 0.9),
            MicSpeechLevelMeasurement.measure(samples: [], startSeconds: 0, speechProbability: 0.9),
        ]
        for window in windows {
            #expect(window.speechSeconds == 0)
            #expect(window.speechMeanSquare == nil)
            #expect(window.speechPeak == 0)
        }
    }

    @Test
    func finalPartialChunkUsesItsActualLength() throws {
        let window = MicSpeechLevelMeasurement.measure(
            samples: alternating(0.03, count: 3_328), startSeconds: 0.768, speechProbability: 0.95
        )
        #expect(window.speechSeconds == 0.208)
        #expect(abs(window.endSeconds - 0.976) < 1e-12)
        #expect(abs(try #require(window.speechMeanSquare) - 9e-4) < 1e-10)
    }

    @Test
    func liveSessionDeliversEachChunkLevelExactlyOnce() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try DurableAudioWriter(
            directory: root, sampleRate: 16_000, channelCount: 1, chunkDurationSeconds: 1
        )
        try await writer.append(samples: alternating(0.01, count: 16_000))
        let checkpoint = await writer.committedSnapshot()
        let vad = ScriptedProbabilityVAD(measures: true) { _ in 0.9 }
        let session = LiveVADSession(
            segmentationRunID: "seg",
            processor: FluidVADTimelineProcessor(
                reader: ProcessingTimelineReader(directory: root, checkpoint: checkpoint),
                engine: vad
            ),
            initialCommittedFrames: 0
        )

        let first = try await session.processAvailable(checkpoint: checkpoint)
        #expect(first.micSpeechLevels.map(\.startSeconds) == [0, 0.256, 0.512])
        #expect(first.emittedSegments.count == 3)
        let repeated = try await session.processAvailable(checkpoint: checkpoint)
        #expect(repeated.micSpeechLevels.isEmpty)
        let final = try await session.finish(checkpoint: checkpoint)
        #expect(final.micSpeechLevels.map(\.startSeconds) == [0.768])
        #expect(final.micSpeechLevels.map(\.speechSeconds) == [3_712.0 / 16_000])
        let repeatedFinish = try await session.finish(checkpoint: checkpoint)
        #expect(repeatedFinish.micSpeechLevels.isEmpty)

        let all = first.micSpeechLevels + final.micSpeechLevels
        #expect(abs(all.map(\.speechSeconds).reduce(0, +) - 1.0) < 1e-12)
        for window in all {
            #expect(abs(try #require(window.speechMeanSquare) - 1e-4) < 1e-10)
        }
        #expect(await vad.measuredSampleCount == 16_000)
    }

    @Test
    func rejectedChunksBetweenSpeechAreNotReported() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try DurableAudioWriter(
            directory: root, sampleRate: 16_000, channelCount: 1, chunkDurationSeconds: 1
        )
        try await writer.append(samples: alternating(0.2, count: 16_000))
        let checkpoint = await writer.committedSnapshot()
        let processor = FluidVADTimelineProcessor(
            reader: ProcessingTimelineReader(directory: root, checkpoint: checkpoint),
            engine: ScriptedProbabilityVAD(measures: true) { $0 == 1 ? 0.3 : 0.9 }
        )
        _ = try await processor.processAvailable(checkpoint: checkpoint)
        #expect(await processor.takeMicSpeechLevels().map(\.startSeconds) == [0, 0.512])
    }

    @Test
    func chunkFailureNeitherDropsNorDuplicatesLevels() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try DurableAudioWriter(
            directory: root, sampleRate: 16_000, channelCount: 1, chunkDurationSeconds: 1
        )
        try await writer.append(samples: alternating(0.01, count: 16_000))
        let checkpoint = await writer.committedSnapshot()
        let processor = FluidVADTimelineProcessor(
            reader: ProcessingTimelineReader(directory: root, checkpoint: checkpoint),
            engine: ScriptedProbabilityVAD(measures: true, failingCall: 2) { _ in 0.9 }
        )
        await #expect(throws: ScriptedVADFailure.injected) {
            try await processor.processAvailable(checkpoint: checkpoint)
        }
        let segments = try await processor.processAvailable(checkpoint: checkpoint)
        #expect(segments.map(\.segmentID) == ["chunk-0", "chunk-1", "chunk-2"])
        #expect(await processor.takeMicSpeechLevels().map(\.startSeconds) == [0, 0.256, 0.512])
        #expect(await processor.takeMicSpeechLevels().isEmpty)
    }

    @Test
    func windowTouchingReplacementSilenceIsExcluded() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try DurableAudioWriter(
            directory: root, sampleRate: 16_000, channelCount: 1, chunkDurationSeconds: 1
        )
        try await writer.append(samples: alternating(0.01, count: 6_000))
        try await writer.recordGap(startFrame: 6_000, frameCount: 1_000, reason: .missingCallback)
        try await writer.append(samples: Array(repeating: 0, count: 1_000))
        try await writer.append(samples: alternating(0.01, count: 9_000))
        let checkpoint = await writer.committedSnapshot()
        #expect(checkpoint.gapEvents.count == 1)
        let processor = FluidVADTimelineProcessor(
            reader: ProcessingTimelineReader(directory: root, checkpoint: checkpoint),
            engine: ScriptedProbabilityVAD(measures: true) { _ in 0.9 }
        )
        _ = try await processor.processAvailable(checkpoint: checkpoint)
        #expect(await processor.takeMicSpeechLevels().map(\.startSeconds) == [0, 0.512])
    }

    @Test
    func disabledMeasurementDeliversNoLevels() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try DurableAudioWriter(
            directory: root, sampleRate: 16_000, channelCount: 1, chunkDurationSeconds: 1
        )
        try await writer.append(samples: alternating(0.01, count: 16_000))
        let checkpoint = await writer.committedSnapshot()
        let vad = ScriptedProbabilityVAD(measures: false) { _ in 0.9 }
        let session = LiveVADSession(
            segmentationRunID: "seg",
            processor: FluidVADTimelineProcessor(
                reader: ProcessingTimelineReader(directory: root, checkpoint: checkpoint),
                engine: vad
            ),
            initialCommittedFrames: 0
        )
        let progress = try await session.processAvailable(checkpoint: checkpoint)
        let final = try await session.finish(checkpoint: checkpoint)
        #expect(progress.micSpeechLevels.isEmpty)
        #expect(final.micSpeechLevels.isEmpty)
        #expect(await vad.measuredSampleCount == 0)
    }

    /// The durable timeline reaches the VAD through the production resampler. Interior windows
    /// avoid converter start-up and flush transients; 1% in mean square (~0.04 dB) bounds the
    /// converter's passband ripple at 440 Hz, far below the policy's multi-dB thresholds.
    @Test(arguments: [16_000.0, 96_000.0])
    func resampledToneKeepsItsMeanSquare(sampleRate: Double) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try DurableAudioWriter(
            directory: root, sampleRate: sampleRate, channelCount: 1, chunkDurationSeconds: 1
        )
        let amplitude: Float = 0.02
        try await writer.append(samples: sine(
            amplitude: amplitude, frequency: 440, sampleRate: sampleRate, count: Int(sampleRate * 2)
        ))
        let checkpoint = await writer.committedSnapshot()
        let processor = FluidVADTimelineProcessor(
            reader: ProcessingTimelineReader(directory: root, checkpoint: checkpoint),
            engine: ScriptedProbabilityVAD(measures: true) { _ in 0.9 }
        )
        _ = try await processor.processAvailable(checkpoint: checkpoint)
        let levels = await processor.takeMicSpeechLevels()
        #expect(levels.count == 7)
        let expected = Double(amplitude * amplitude) / 2
        for window in levels.dropFirst().dropLast() {
            let meanSquare = try #require(window.speechMeanSquare)
            #expect(abs(meanSquare - expected) / expected < 0.01, "window \(window.startSeconds): \(meanSquare)")
        }
    }
}
