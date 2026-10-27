import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevONNX
import MacAmbientJevPipeline
import MacAmbientJevVADFixtures
@testable import MacAmbientJevPortableRuntime

private func chunkProbabilities(of samples: [Float], scorer: SileroChunkScorer) throws -> [Float] {
    try stride(from: 0, to: samples.count, by: VADSegmentationParameters.chunkSamples).map { start in
        let end = min(start + VADSegmentationParameters.chunkSamples, samples.count)
        return try scorer.speechProbability(chunk: Array(samples[start..<end]))
    }
}

struct SileroVADParityTests {
    private let environment: ONNXEnvironment
    private let modelURL: URL
    private let clip: [Float]
    private let fixture: VADParityFile

    init() throws {
        modelURL = try SileroTestInputs.modelURL(environment: ProcessInfo.processInfo.environment)
        environment = try ONNXEnvironment(loggingID: "SileroVADParityTests")
        clip = try SileroTestInputs.speechClipSamples()
        fixture = try VADParityFile.load()
    }

    @Test(arguments: VADParityCase.all)
    func chunkProbabilitiesMatchFluidAudio(parityCase: VADParityCase) throws {
        let expectation = try fixture.expectation(named: parityCase.name)
        let samples = parityCase.samples(clip: clip)
        #expect(samples.count == expectation.sampleCount)

        let scorer = SileroChunkScorer(
            vad: try SileroVAD(environment: environment, modelURL: modelURL, intraOpThreads: 1)
        )
        let actual = try chunkProbabilities(of: samples, scorer: scorer)
        try #require(actual.count == expectation.chunkProbabilities.count)

        let differences = zip(actual, expectation.chunkProbabilities).map { abs($0 - $1) }
        let maximum = differences.max() ?? 0
        let mean = differences.reduce(0, +) / Float(max(differences.count, 1))
        print("\(parityCase.name): \(actual.count) chunks, max |ONNX - FluidAudio| = \(maximum), mean = \(mean)")
        #expect(maximum <= VADParityTolerance.onnxVersusCoreML)

        let decisionThresholds = [
            VADSegmentationParameters.speechProbabilityThreshold,
            VADStreamingStateMachine.negativeThreshold
        ]
        for (index, pair) in zip(actual, expectation.chunkProbabilities).enumerated() {
            for threshold in decisionThresholds {
                #expect(
                    (pair.0 >= threshold) == (pair.1 >= threshold),
                    "chunk \(index): ONNX \(pair.0), FluidAudio \(pair.1), threshold \(threshold)"
                )
            }
        }
    }

    @Test(arguments: VADParityCase.all)
    func segmentsMatchFluidAudioExactly(parityCase: VADParityCase) async throws {
        let expectation = try fixture.expectation(named: parityCase.name)
        let segmenter = SileroFinalTranscriptVADSegmenter(
            environment: environment, modelURL: modelURL, intraOpThreads: 1
        )
        let segments = try await segmenter.segment(
            reader: VADParityTimeline(samples: parityCase.samples(clip: clip)),
            runID: "parity"
        )
        let actual = segments.map {
            VADParityExpectation.Segment(startFrame: $0.startFrame, endFrame: $0.endFrame)
        }
        #expect(actual == expectation.segments)
        #expect(segments.map(\.segmentID) == segments.indices.map { String(format: "seg_%06d", $0 + 1) })
    }

}
