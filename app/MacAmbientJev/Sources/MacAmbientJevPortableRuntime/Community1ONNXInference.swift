import Foundation
import MacAmbientJevDiarization
import MacAmbientJevONNX

enum Community1ONNXModelError: Error, LocalizedError {
    case incompatibleGraph(model: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .incompatibleGraph(model, reason):
            "Community-1 ONNX graph \(model) does not match the pinned contract: \(reason)"
        }
    }
}

/// The two Community-1 model operations on ONNX Runtime CPU sessions.
///
/// Segmentation maps one 160,000-sample window to 589 x 7 log-probabilities. The embedding graph
/// is `wespeaker-multimask-tail`: one trunk pass over the window's fbank and up to three masks
/// pre-sampled at the graph's nearest-neighbour pooling positions. The graph always returns
/// three rows, so an unused mask is zero-filled and its row dropped without being inspected.
/// Sessions are not thread-safe for concurrent state; the owning engine actor serializes calls.
final class Community1ONNXInference: Community1Inference {
    static let cpuMemoryArenaEnabled = false

    private static let segmentationInput = "input"
    private static let segmentationOutput = "output"
    private static let embeddingFbankInput = "fbank"
    private static let embeddingMasksInput = "masks"
    private static let embeddingOutput = "output"
    private static let maskSlots = 3
    private static let windowSamples = 160_000
    private static let segmentationFrames = 589
    private static let powersetClasses = 7
    private static let fbankFrames = 998
    private static let melBins = 80
    private static let embeddingDimensions = 256

    private let segmentation: ONNXSession
    private let embedding: ONNXSession

    init(
        environment: ONNXEnvironment,
        assets: Community1Assets,
        intraOpThreads: Int
    ) throws {
        segmentation = try ONNXSession(
            environment: environment,
            modelURL: assets.segmentationURL,
            intraOpThreads: intraOpThreads,
            cpuMemoryArenaEnabled: Self.cpuMemoryArenaEnabled,
            configEntries: [:]
        )
        try Self.validate(
            model: "segmentation",
            inputs: segmentation.inputMetadata(),
            expectedInputs: [(Self.segmentationInput, [1, 1, Int64(Self.windowSamples)])],
            outputs: segmentation.outputMetadata(),
            expectedOutputs: [(Self.segmentationOutput, [1, Int64(Self.segmentationFrames), Int64(Self.powersetClasses)])]
        )

        embedding = try ONNXSession(
            environment: environment,
            modelURL: assets.embeddingURL,
            intraOpThreads: intraOpThreads,
            cpuMemoryArenaEnabled: Self.cpuMemoryArenaEnabled,
            configEntries: [:]
        )
        try Self.validate(
            model: "embedding",
            inputs: embedding.inputMetadata(),
            expectedInputs: [
                (Self.embeddingFbankInput, [1, Int64(Self.fbankFrames), Int64(Self.melBins)]),
                (Self.embeddingMasksInput, [Int64(Self.maskSlots), Int64(Self.segmentationFrames)]),
            ],
            outputs: embedding.outputMetadata(),
            expectedOutputs: [(Self.embeddingOutput, [Int64(Self.maskSlots), Int64(Self.embeddingDimensions)])]
        )
    }

    func segment(_ window: WindowAudio) throws -> PowersetScores {
        guard window.samples.count == Self.windowSamples else {
            throw Community1Error.invalidModelOutput(
                stage: "segmentation",
                reason: "window has \(window.samples.count) samples; expected \(Self.windowSamples)"
            )
        }
        let values = try Self.floats(
            try segmentation.run(
                inputs: [(Self.segmentationInput, .float32(shape: [1, 1, Int64(Self.windowSamples)], values: window.samples))],
                outputNames: [Self.segmentationOutput]
            ),
            stage: "segmentation",
            shape: [1, Int64(Self.segmentationFrames), Int64(Self.powersetClasses)]
        )
        do {
            return try PowersetScores(logProbabilities: values)
        } catch {
            throw Community1Error.invalidModelOutput(stage: "segmentation", reason: "\(error)")
        }
    }

    func embed(features: Community1FbankFeatures, masks: [SpeakerMask]) throws -> [[Float]] {
        guard (1...Self.maskSlots).contains(masks.count) else {
            throw Community1Error.invalidModelOutput(
                stage: "embedding",
                reason: "\(masks.count) masks supplied; the graph takes 1 to \(Self.maskSlots)"
            )
        }
        guard features.values.count == Self.fbankFrames * Self.melBins else {
            throw Community1Error.invalidModelOutput(
                stage: "embedding",
                reason: "fbank has \(features.values.count) values; expected \(Self.fbankFrames * Self.melBins)"
            )
        }
        var maskValues = [Float](repeating: 0, count: Self.maskSlots * Self.segmentationFrames)
        for (slot, mask) in masks.enumerated() {
            guard mask.pooling.values.count == Self.segmentationFrames else {
                throw Community1Error.invalidModelOutput(
                    stage: "embedding",
                    reason: "mask \(slot) has \(mask.pooling.values.count) values; expected \(Self.segmentationFrames)"
                )
            }
            maskValues.replaceSubrange(
                slot * Self.segmentationFrames..<(slot + 1) * Self.segmentationFrames,
                with: mask.pooling.values
            )
        }
        let rows = try Self.floats(
            try embedding.run(
                inputs: [
                    (Self.embeddingFbankInput, .float32(shape: [1, Int64(Self.fbankFrames), Int64(Self.melBins)], values: features.values)),
                    (Self.embeddingMasksInput, .float32(shape: [Int64(Self.maskSlots), Int64(Self.segmentationFrames)], values: maskValues)),
                ],
                outputNames: [Self.embeddingOutput]
            ),
            stage: "embedding",
            shape: [Int64(Self.maskSlots), Int64(Self.embeddingDimensions)]
        )
        return (0..<masks.count).map { slot in
            Array(rows[slot * Self.embeddingDimensions..<(slot + 1) * Self.embeddingDimensions])
        }
    }

    private static func floats(_ outputs: [ONNXTensor], stage: String, shape expected: [Int64]) throws -> [Float] {
        guard outputs.count == 1, case let .float32(shape, values) = outputs[0] else {
            throw Community1Error.invalidModelOutput(stage: stage, reason: "expected one float32 tensor")
        }
        let expectedCount = expected.reduce(1) { $0 * Int($1) }
        guard shape == expected, values.count == expectedCount else {
            throw Community1Error.invalidModelOutput(
                stage: stage,
                reason: "output shape \(shape) with \(values.count) values; expected \(expected)"
            )
        }
        return values
    }

    private static func validate(
        model: String,
        inputs: [ONNXTensorMetadata],
        expectedInputs: [(name: String, shape: [Int64])],
        outputs: [ONNXTensorMetadata],
        expectedOutputs: [(name: String, shape: [Int64])]
    ) throws {
        try validate(model: model, direction: "input", actual: inputs, expected: expectedInputs)
        try validate(model: model, direction: "output", actual: outputs, expected: expectedOutputs)
    }

    /// A dimension reported as `-1` is dynamic in the graph and accepts the expected size.
    private static func validate(
        model: String,
        direction: String,
        actual: [ONNXTensorMetadata],
        expected: [(name: String, shape: [Int64])]
    ) throws {
        guard actual.map(\.name) == expected.map(\.name) else {
            throw Community1ONNXModelError.incompatibleGraph(
                model: model,
                reason: "\(direction) names \(actual.map(\.name)); expected \(expected.map(\.name))"
            )
        }
        for (tensor, wanted) in zip(actual, expected) {
            let matches = tensor.elementType == .float32
                && tensor.shape.count == wanted.shape.count
                && zip(tensor.shape, wanted.shape).allSatisfy { $0 == -1 || $0 == $1 }
            guard matches else {
                throw Community1ONNXModelError.incompatibleGraph(
                    model: model,
                    reason: "\(direction) \(tensor.name) is \(tensor.elementType) \(tensor.shape); expected float32 \(wanted.shape)"
                )
            }
        }
    }
}
