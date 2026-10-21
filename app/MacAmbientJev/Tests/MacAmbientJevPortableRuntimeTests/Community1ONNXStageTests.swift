import Foundation
import MacAmbientJevCore
import MacAmbientJevONNX
import Testing
@testable import MacAmbientJevDiarization
@testable import MacAmbientJevPortableRuntime

private enum StageTolerance {
    /// Non-silence segmentation: measured 1.2e-4 at most on the speech windows.
    static let segmentationMaxAbs: Float = 2e-4
    /// An all-zero window puts almost no mass on most classes, so the two runtimes differ widely in
    /// log-probability there (measured 2.45 against Core ML on ONNX Runtime 1.31 aarch64 Linux)
    /// but by 3.1e-4 in probability and never in the argmax.
    static let silenceLogProbabilityMaxAbs: Float = 3.0
    static let silenceProbabilityMaxAbs: Float = 1e-3
    static let embeddingCosine = 0.995
    /// One segmentation frame (160,000 / 589 samples, rounded up).
    static let frameSamples: Int64 = 272
}

private func argmaxAgreement(_ left: [Float], _ right: [Float]) -> Double {
    let classes = Community1Profile.powersetClasses
    func argmax(_ values: [Float], _ frame: Int) -> Int {
        var best = 0
        for index in 1..<classes where values[frame * classes + index] > values[frame * classes + best] { best = index }
        return best
    }
    let frames = Community1Profile.segmentationFrames
    return Double((0..<frames).filter { argmax(left, $0) == argmax(right, $0) }.count) / Double(frames)
}

private func maxAbsDifference(_ left: [Float], _ right: [Float]) -> Float {
    zip(left, right).map { abs($0 - $1) }.max() ?? 0
}

private func normalized(_ vector: [Float]) -> [Float] {
    let norm = max(vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot(), Double(Community1Profile.embeddingL2Floor))
    return vector.map { Float(Double($0) / norm) }
}

@Suite(.serialized)
struct Community1ONNXStageTests {
    private let fixture: Community1StageFixture
    private let samples: [Float]
    private let inference: Community1ONNXInference

    init() throws {
        fixture = try Community1StageFixture.load()
        samples = try Community1ONNXTestInputs.clipSamples()
        guard fixture.sampleCount == Int64(samples.count) else {
            throw Community1TestError.invalid("fixture sampleCount \(fixture.sampleCount) differs from the clip's \(samples.count)")
        }
        let assets = try Community1Assets(modelDirectory: try Community1ONNXTestInputs.modelDirectory())
        inference = try Community1ONNXInference(
            environment: try ONNXEnvironment(loggingID: "Community1ONNXStageTests"),
            assets: assets,
            intraOpThreads: 4
        )
    }

    private func mask(_ encoded: String) throws -> SpeakerMask {
        SpeakerMask(activity: try ActivityMask(values: try Community1StageFixture.floats(encoded)))
    }

    private func features(ofWindow name: String) throws -> Community1FbankFeatures {
        let entry = try #require(fixture.windows.first { $0.name == name })
        return Community1Fbank.shared.features(
            of: try Community1ONNXTestInputs.window(of: samples, at: Int(entry.startSample / Int64(Community1Profile.stepSamples)))
        )
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"))
    func segmentationMatchesCoreMLOnSpeechWindows() throws {
        #expect(fixture.windows.count >= 3)
        for entry in fixture.windows {
            let window = try Community1ONNXTestInputs.window(
                of: samples,
                at: Int(entry.startSample / Int64(Community1Profile.stepSamples))
            )
            let actual = try inference.segment(window).values
            let expected = try Community1StageFixture.floats(entry.segmentation)
            let maxError = maxAbsDifference(actual, expected)
            let agreement = argmaxAgreement(actual, expected)
            print("COMMUNITY1ONNX segmentation \(entry.name) maxAbs=\(maxError) argmaxAgreement=\(agreement)")
            #expect(maxError <= StageTolerance.segmentationMaxAbs, "\(entry.name)")
            #expect(agreement == 1, "\(entry.name)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"))
    func segmentationMatchesCoreMLOnSilence() throws {
        let actual = try inference.segment(try Community1ONNXTestInputs.silenceWindow()).values
        let expected = try Community1StageFixture.floats(fixture.silenceSegmentation)
        let maxError = maxAbsDifference(actual, expected)
        let agreement = argmaxAgreement(actual, expected)
        let probabilityError = zip(actual, expected).map { abs(exp($0) - exp($1)) }.max() ?? 0
        print("COMMUNITY1ONNX segmentation silence maxAbs=\(maxError) maxProbabilityAbs=\(probabilityError) argmaxAgreement=\(agreement)")
        #expect(agreement == 1)
        #expect(maxError <= StageTolerance.silenceLogProbabilityMaxAbs)
        #expect(probabilityError <= StageTolerance.silenceProbabilityMaxAbs)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"))
    func embeddingsMatchCoreMLForEachSelectedMask() throws {
        var compared = 0
        for entry in fixture.windows {
            let features = try features(ofWindow: entry.name)
            for stored in entry.masks {
                let vectors = try inference.embed(features: features, masks: [try mask(stored.activity)])
                #expect(vectors.count == 1)
                let cosine = Community1ONNXTestInputs.cosine(vectors[0], try Community1StageFixture.floats(stored.embedding))
                print("COMMUNITY1ONNX embedding \(entry.name) slot \(stored.slot) cosine=\(cosine)")
                #expect(cosine >= StageTolerance.embeddingCosine, "\(entry.name) slot \(stored.slot)")
                compared += 1
            }
        }
        #expect(compared > 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"))
    func embeddingMatchesCoreMLForAScatteredMask() throws {
        let vectors = try inference.embed(
            features: try features(ofWindow: fixture.scattered.windowName),
            masks: [try mask(fixture.scattered.activity)]
        )
        let cosine = Community1ONNXTestInputs.cosine(vectors[0], try Community1StageFixture.floats(fixture.scattered.embedding))
        print("COMMUNITY1ONNX embedding scattered cosine=\(cosine)")
        #expect(cosine >= StageTolerance.embeddingCosine)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"))
    func multimaskRowsKeepTheirSlotIdentity() throws {
        let entry = try #require(fixture.windows.first { $0.name == fixture.scattered.windowName })
        let stored = try #require(entry.masks.first)
        let windowReference = try Community1StageFixture.floats(stored.embedding)
        let scatteredReference = try Community1StageFixture.floats(fixture.scattered.embedding)
        #expect(Community1ONNXTestInputs.cosine(windowReference, scatteredReference) < StageTolerance.embeddingCosine)

        let windowMask = try mask(stored.activity)
        let scatteredMask = try mask(fixture.scattered.activity)
        let features = try features(ofWindow: entry.name)

        let two = try inference.embed(features: features, masks: [scatteredMask, windowMask])
        #expect(two.count == 2)
        #expect(Community1ONNXTestInputs.cosine(two[0], scatteredReference) >= StageTolerance.embeddingCosine)
        #expect(Community1ONNXTestInputs.cosine(two[1], windowReference) >= StageTolerance.embeddingCosine)

        let three = try inference.embed(features: features, masks: [windowMask, scatteredMask, windowMask])
        #expect(three.count == 3)
        #expect(Community1ONNXTestInputs.cosine(three[0], windowReference) >= StageTolerance.embeddingCosine)
        #expect(Community1ONNXTestInputs.cosine(three[1], scatteredReference) >= StageTolerance.embeddingCosine)
        #expect(Community1ONNXTestInputs.cosine(three[2], windowReference) >= StageTolerance.embeddingCosine)
        #expect(zip(normalized(two[1]), normalized(three[0])).map { abs($0 - $1) }.max()! < 1e-3)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"))
    func rejectsMaskCountsTheGraphCannotTake() throws {
        let entry = try #require(fixture.windows.first { !$0.masks.isEmpty })
        let stored = try #require(entry.masks.first)
        let features = try features(ofWindow: entry.name)
        let oneMask = try mask(stored.activity)
        #expect(throws: Community1Error.self) { _ = try inference.embed(features: features, masks: []) }
        #expect(throws: Community1Error.self) {
            _ = try inference.embed(features: features, masks: [oneMask, oneMask, oneMask, oneMask])
        }
    }
}

@Suite(.serialized)
struct Community1ONNXEndToEndTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"))
    func engineReturnsTheFluidAudioSpansWithinOneFrame() async throws {
        let fixture = try Community1StageFixture.load()
        let samples = try Community1ONNXTestInputs.clipSamples()
        #expect(fixture.sampleCount == Int64(samples.count))
        let session = try Community1CAFSession(samples: samples)
        defer { session.cleanup() }

        let engine = try ONNXCommunity1DiarizationEngine(
            modelDirectory: try Community1ONNXTestInputs.modelDirectory(),
            intraOpThreads: 4
        )
        try await engine.prepare()
        try await engine.prepare()
        let first = try await engine.diarize(
            fileURL: session.cafURL, canonicalSampleRate: CanonicalAudio.sampleRate, sessionURL: session.root
        )
        let second = try await engine.diarize(
            fileURL: session.cafURL, canonicalSampleRate: CanonicalAudio.sampleRate, sessionURL: session.root
        )
        await engine.unload()
        await engine.unload()

        #expect(first == second)
        print("COMMUNITY1ONNX spans onnx=\(first.map { "\($0.speakerID) \($0.startFrame)-\($0.endFrame)" }) fluid=\(fixture.spans.map { "\($0.speakerID) \($0.startFrame)-\($0.endFrame)" })")
        #expect(Set(first.map(\.speakerID)).count == Set(fixture.spans.map(\.speakerID)).count)
        try #require(first.count == fixture.spans.count)
        for (actual, expected) in zip(first, fixture.spans) {
            #expect(actual.speakerID == expected.speakerID)
            #expect(abs(actual.startFrame - expected.startFrame) <= StageTolerance.frameSamples)
            #expect(abs(actual.endFrame - expected.endFrame) <= StageTolerance.frameSamples)
        }

        await #expect(throws: ONNXCommunity1DiarizationEngineError.notPrepared) {
            _ = try await engine.diarize(
                fileURL: session.cafURL, canonicalSampleRate: CanonicalAudio.sampleRate, sessionURL: session.root
            )
        }
    }
}
