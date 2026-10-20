import FluidAudio
import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevPipeline
import MacAmbientJevVADFixtures
@testable import MacAmbientJevRuntime

/// `Tests/MacAmbientJevVADFixtures/vad_parity.json` is what FluidAudio produces for the parity
/// cases. The Linux and Windows Silero engine is tested against it, so it must stay equal to the
/// Mac engine's output.
private func fluidExpectation(
    for parityCase: VADParityCase, clip: [Float]
) async throws -> VADParityExpectation {
    let samples = parityCase.samples(clip: clip)
    let manager = try await VadManager(config: FluidVADSegmentationEngine.vadConfig)
    let probabilities = try await manager.process(samples).map(\.probability)
    let segments = try await FluidFinalTranscriptVADSegmenter().segment(
        reader: VADParityTimeline(samples: samples), runID: "parity"
    )
    return VADParityExpectation(
        name: parityCase.name,
        sampleCount: samples.count,
        chunkProbabilities: probabilities,
        segments: segments.map {
            VADParityExpectation.Segment(startFrame: $0.startFrame, endFrame: $0.endFrame)
        }
    )
}

@Suite("VADParityFixtureTests")
struct VADParityFixtureTests {
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["MAC_AMBIENT_JEV_WRITE_VAD_PARITY"] == "1",
        "MAC_AMBIENT_JEV_WRITE_VAD_PARITY=1 のときだけ fixture を書き換える"
    ))
    func writeParityFixture() async throws {
        let clip = try SileroTestInputs.speechClipSamples()
        var cases: [VADParityExpectation] = []
        for parityCase in VADParityCase.all {
            cases.append(try await fluidExpectation(for: parityCase, clip: clip))
        }
        try VADParityFile(
            generator: "\(FluidFinalTranscriptVADSegmenter.version) \(Repo.vad.rawValue)",
            cases: cases
        ).write()
    }

    @Test(arguments: VADParityCase.all)
    func committedFixtureMatchesFluidAudio(parityCase: VADParityCase) async throws {
        let committed = try VADParityFile.load().expectation(named: parityCase.name)
        let actual = try await fluidExpectation(
            for: parityCase, clip: SileroTestInputs.speechClipSamples()
        )

        #expect(actual.sampleCount == committed.sampleCount)
        try #require(actual.chunkProbabilities.count == committed.chunkProbabilities.count)
        let maximum = zip(actual.chunkProbabilities, committed.chunkProbabilities)
            .map { abs($0 - $1) }.max() ?? 0
        #expect(maximum <= VADParityTolerance.coreMLVersusCommitted)
        #expect(actual.segments == committed.segments)
    }

    /// Isolates the port from the model: FluidAudio's own probabilities through the ported
    /// state machine must give FluidAudio's segments.
    @Test(arguments: VADParityCase.all)
    func portedStateMachineReproducesFluidAudioSegments(parityCase: VADParityCase) throws {
        let committed = try VADParityFile.load().expectation(named: parityCase.name)
        let samples = parityCase.samples(clip: try SileroTestInputs.speechClipSamples())
        let chunkSamples = VADSegmentationParameters.chunkSamples
        try #require(committed.chunkProbabilities.count == (samples.count + chunkSamples - 1) / chunkSamples)

        var segmenter = VADProbabilitySegmenter(segmentationRunID: "parity", canonicalSampleRate: 16_000)
        var segments: [SegmentReference] = []
        for (index, probability) in committed.chunkProbabilities.enumerated() {
            let start = index * chunkSamples
            segments += segmenter.process(
                samples: Array(samples[start..<min(start + chunkSamples, samples.count)]),
                probability: probability
            )
        }
        segments += segmenter.finish(totalCanonicalFrames: Int64(samples.count))
        #expect(segments.map {
            VADParityExpectation.Segment(startFrame: $0.startFrame, endFrame: $0.endFrame)
        } == committed.segments)
    }

    @Test
    func committedFixtureNamesTheCurrentFluidAudioModel() throws {
        #expect(try VADParityFile.load().generator
            == "\(FluidFinalTranscriptVADSegmenter.version) \(Repo.vad.rawValue)")
    }
}
