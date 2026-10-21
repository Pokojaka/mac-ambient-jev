#if os(macOS)
@preconcurrency import CoreML
import FluidAudio
import Foundation
import MacAmbientJevCore
@testable import MacAmbientJevDiarization
@testable import MacAmbientJevRuntime
import Testing

/// Core ML stage outputs and FluidAudio spans for the Linux ONNX tests, stored as
/// `diarization_onnx_stages.json` under the portable runtime test resources.
private struct StageFixture: Codable {
    struct Mask: Codable {
        let slot: Int
        let activity: String
        let embedding: String
    }

    struct Window: Codable {
        let name: String
        let startSample: Int64
        let segmentation: String
        let masks: [Mask]
    }

    struct Scattered: Codable {
        let windowName: String
        let construction: String
        let activity: String
        let embedding: String
    }

    struct Span: Codable {
        let speakerID: String
        let startFrame: Int64
        let endFrame: Int64
    }

    let schemaVersion: Int
    let fluidAudioRevision: String
    let clip: String
    let sampleCount: Int64
    let comparisonRule: String
    let windows: [Window]
    let silenceSegmentation: String
    let scattered: Scattered
    let spans: [Span]
}

private enum StageFixtureError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(reason): return "Community-1 ONNX stage fixture: \(reason)"
        }
    }
}

private enum StageFixtureCodec {
    static let windowIndices = [0, 2, 4, 6]
    static let scatteredConstruction =
        "589 frames; value 1 where (7 * frame + 3) % 10 < 3, else 0; fbank and Core ML graph input from window-0"
    static let maximumBytes = 1_048_576
    static let segmentationCheckAbsoluteError: Float = 1e-3
    static let embeddingCheckCosine = 0.999
    static let spanCheckSamples: Int64 = 272

    static func base64(_ values: [Float]) -> String {
        var data = Data(capacity: values.count * 4)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }

    static func floats(_ text: String) throws -> [Float] {
        guard let data = Data(base64Encoded: text), data.count % 4 == 0 else {
            throw StageFixtureError.invalid("payload is not base64 Float32")
        }
        return data.withUnsafeBytes { raw in
            (0..<data.count / 4).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
    }

    static func scatteredActivity() throws -> ActivityMask {
        try ActivityMask(values: (0..<Community1Profile.segmentationFrames).map { (7 * $0 + 3) % 10 < 3 ? 1 : 0 })
    }

    static func cosine(_ left: [Float], _ right: [Float]) -> Double {
        var dot = 0.0
        var leftNorm = 0.0
        var rightNorm = 0.0
        for (a, b) in zip(left, right) {
            dot += Double(a) * Double(b)
            leftNorm += Double(a) * Double(a)
            rightNorm += Double(b) * Double(b)
        }
        return dot / (leftNorm.squareRoot() * rightNorm.squareRoot())
    }

    static func argmaxAgreement(_ left: [Float], _ right: [Float]) -> Double {
        let classes = Community1Profile.powersetClasses
        func argmax(_ values: [Float], _ frame: Int) -> Int {
            var best = 0
            for index in 1..<classes where values[frame * classes + index] > values[frame * classes + best] { best = index }
            return best
        }
        let frames = Community1Profile.segmentationFrames
        let matching = (0..<frames).filter { argmax(left, $0) == argmax(right, $0) }.count
        return Double(matching) / Double(frames)
    }

    static func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacAmbientJevPortableRuntimeTests/Resources/diarization_onnx_stages.json")
    }
}

extension Community1DiarizerCoreMLParityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"))
    func onnxStageFixtureMatchesCoreML() async throws {
        let clip = "qwen3_asr_voicevox_long"
        let directory = try modelDirectory()
        var modelURLs: [String: URL] = [:]
        for name in ["Segmentation.mlmodelc", "Embedding.mlmodelc", "FBank.mlmodelc", "PldaRho.mlmodelc"] {
            modelURLs[name] = directory.appendingPathComponent(name, isDirectory: true)
        }
        let models = try await loadOfflineDiarizerModelsUsingStaging(
            modelURLs: modelURLs,
            pldaJSONURL: directory.appendingPathComponent("plda-parameters.json", isDirectory: false)
        )
        let inference = try CoreMLCommunity1Inference(
            segmentation: models.segmentationModel,
            embedding: models.embeddingModel
        )
        let samples = try clipSamples(named: clip)
        let sampleCount = Int64(samples.count)
        let plan = try Community1WindowPlan(sampleCount: sampleCount)
        try #require(plan.count > StageFixtureCodec.windowIndices.max()!)

        var windows: [StageFixture.Window] = []
        var firstWindowFeatures: Community1FbankFeatures?
        for index in StageFixtureCodec.windowIndices {
            let window = try plan.window(at: index) { range in Array(samples[Int(range.lowerBound)..<Int(range.upperBound)]) }
            let scores = try inference.segment(window)
            let selected = try Community1Frontend.selectMasks(Community1Frontend.decode(scores))
            let features = Community1Fbank.shared.features(of: window)
            if index == 0 { firstWindowFeatures = features }
            let masks = selected.map { SpeakerMask(activity: $0.mask) }
            let vectors = masks.isEmpty ? [] : try inference.embed(features: features, masks: masks)
            windows.append(StageFixture.Window(
                name: "window-\(index)",
                startSample: window.startFrame,
                segmentation: StageFixtureCodec.base64(scores.values),
                masks: zip(selected, zip(masks, vectors)).map { selection, pair in
                    StageFixture.Mask(
                        slot: selection.speakerIndex,
                        activity: StageFixtureCodec.base64(pair.0.activity.values),
                        embedding: StageFixtureCodec.base64(pair.1)
                    )
                }
            ))
        }
        try #require(windows.contains { !$0.masks.isEmpty }, "the speech windows must select at least one mask")

        let silencePlan = try Community1WindowPlan(sampleCount: Int64(Community1Profile.windowSamples))
        let silence = try silencePlan.window(at: 0) { range in [Float](repeating: 0, count: Int(range.count)) }
        let silenceScores = try inference.segment(silence)

        let scatteredMask = SpeakerMask(activity: try StageFixtureCodec.scatteredActivity())
        let scatteredVector = try inference.embed(
            features: try #require(firstWindowFeatures),
            masks: [scatteredMask]
        )[0]

        let config = FluidOfflineDiarizationEngine.configuration
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let result = try await manager.process(audio: samples)
        let spans = try FluidOfflineDiarizationEngine.mapSegments(
            result.segments,
            sampleCount: samples.count,
            config: config
        )

        let fresh = StageFixture(
            schemaVersion: 1,
            fluidAudioRevision: "87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc",
            clip: clip,
            sampleCount: sampleCount,
            comparisonRule: "segmentation max abs <= \(StageFixtureCodec.segmentationCheckAbsoluteError) and equal argmax; embedding cosine >= \(StageFixtureCodec.embeddingCheckCosine); spans equal count and speaker with boundaries within \(StageFixtureCodec.spanCheckSamples) samples. Never compared by bytes.",
            windows: windows,
            silenceSegmentation: StageFixtureCodec.base64(silenceScores.values),
            scattered: StageFixture.Scattered(
                windowName: "window-0",
                construction: StageFixtureCodec.scatteredConstruction,
                activity: StageFixtureCodec.base64(scatteredMask.activity.values),
                embedding: StageFixtureCodec.base64(scatteredVector)
            ),
            spans: spans.map {
                StageFixture.Span(speakerID: $0.speakerID, startFrame: $0.startFrame, endFrame: $0.endFrame)
            }
        )

        let url = StageFixtureCodec.fixtureURL()
        if ProcessInfo.processInfo.environment["MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var contents = try encoder.encode(fresh)
            contents.append(0x0A)
            try #require(contents.count <= StageFixtureCodec.maximumBytes, "fixture is \(contents.count) bytes")
            try contents.write(to: url, options: .atomic)
            print("STAGEFIXTURE wrote \(contents.count) bytes, \(spans.count) spans, speakers \(Set(spans.map(\.speakerID)).sorted())")
            return
        }

        let committed = try JSONDecoder().decode(StageFixture.self, from: Data(contentsOf: url))
        try #require(committed.schemaVersion == fresh.schemaVersion && committed.clip == fresh.clip)
        try #require(committed.sampleCount == fresh.sampleCount)
        try #require(committed.fluidAudioRevision == fresh.fluidAudioRevision)
        try #require(committed.windows.map(\.name) == fresh.windows.map(\.name))
        for (old, new) in zip(committed.windows, fresh.windows) {
            #expect(old.startSample == new.startSample)
            let oldScores = try StageFixtureCodec.floats(old.segmentation)
            let newScores = try StageFixtureCodec.floats(new.segmentation)
            try #require(oldScores.count == newScores.count)
            let maxError = zip(oldScores, newScores).map { abs($0 - $1) }.max() ?? 0
            #expect(maxError <= StageFixtureCodec.segmentationCheckAbsoluteError, "\(old.name) segmentation max abs \(maxError)")
            #expect(StageFixtureCodec.argmaxAgreement(oldScores, newScores) == 1, "\(old.name) argmax")
            try #require(old.masks.map(\.slot) == new.masks.map(\.slot), "\(old.name) mask slots")
            for (oldMask, newMask) in zip(old.masks, new.masks) {
                #expect(try StageFixtureCodec.floats(oldMask.activity) == StageFixtureCodec.floats(newMask.activity))
                let cosine = StageFixtureCodec.cosine(
                    try StageFixtureCodec.floats(oldMask.embedding),
                    try StageFixtureCodec.floats(newMask.embedding)
                )
                #expect(cosine >= StageFixtureCodec.embeddingCheckCosine, "\(old.name) slot \(oldMask.slot) cosine \(cosine)")
            }
        }
        let oldSilence = try StageFixtureCodec.floats(committed.silenceSegmentation)
        let newSilence = try StageFixtureCodec.floats(fresh.silenceSegmentation)
        #expect(zip(oldSilence, newSilence).map { abs($0 - $1) }.max() ?? 0 <= StageFixtureCodec.segmentationCheckAbsoluteError)
        #expect(StageFixtureCodec.argmaxAgreement(oldSilence, newSilence) == 1)
        #expect(committed.scattered.construction == fresh.scattered.construction)
        #expect(try StageFixtureCodec.floats(committed.scattered.activity) == StageFixtureCodec.floats(fresh.scattered.activity))
        #expect(StageFixtureCodec.cosine(
            try StageFixtureCodec.floats(committed.scattered.embedding),
            try StageFixtureCodec.floats(fresh.scattered.embedding)
        ) >= StageFixtureCodec.embeddingCheckCosine)
        try #require(committed.spans.count == fresh.spans.count, "span count")
        for (old, new) in zip(committed.spans, fresh.spans) {
            #expect(old.speakerID == new.speakerID)
            #expect(abs(old.startFrame - new.startFrame) <= StageFixtureCodec.spanCheckSamples)
            #expect(abs(old.endFrame - new.endFrame) <= StageFixtureCodec.spanCheckSamples)
        }
    }
}
#endif
