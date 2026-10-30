import Foundation
import MacAmbientJevCore
import MacAmbientJevONNX

public struct Qwen3ASRTranscription: Sendable, Equatable {
    public let text: String
    public let generatedIDs: [Int64]
}

protocol Qwen3ASRTranscribingModel: Sendable {
    func transcribe(samples: [Float], maxNewTokens: Int, noRepeatNgramSize: Int?) throws -> Qwen3ASRTranscription
}

/// Immutable model assets and sessions. The ONNX sessions, embedding table, and tokenizer are
/// shared read-only; callers serialize transcription runs via an actor. Per-run features and KV
/// caches stay local to `transcribe` and its decoder.
final class Qwen3ASRONNXModel: Qwen3ASRTranscribingModel, @unchecked Sendable {
    internal static let cpuMemoryArenaEnabled = false
    private static let vocabularySize = 151_936
    private static let layerCount: Int64 = 28
    private static let headCount: Int64 = 8
    private static let headSize: Int64 = 128

    private let environment: ONNXEnvironment
    private let encoderSession: ONNXSession
    private let decoderInitSession: ONNXSession
    private let decoderStepSession: ONNXSession
    private let embedding: Qwen3ASREmbeddingTable
    private let tokenizer: Qwen3ASRTokenDecoder
    private let frontend: Qwen3ASRMelFrontend

    init(
        modelDirectory: URL,
        size: ASRModelSize,
        intraOpThreads: Int,
        graphDirectory: URL,
        configEntriesByGraph: [String: [String: String]]
    ) throws {
        let expectedGraphNames: Set<String> = ["encoder", "decoder_init", "decoder_step"]
        guard Set(configEntriesByGraph.keys) == expectedGraphNames,
              let encoderConfigEntries = configEntriesByGraph["encoder"],
              let decoderInitConfigEntries = configEntriesByGraph["decoder_init"],
              let decoderStepConfigEntries = configEntriesByGraph["decoder_step"]
        else {
            throw Qwen3ASRModelError.invalid(
                "ONNX Runtime config entries must have exactly graph keys \(expectedGraphNames.sorted()), actual \(configEntriesByGraph.keys.sorted())"
            )
        }
        guard intraOpThreads > 0, Int32(exactly: intraOpThreads) != nil else {
            throw Qwen3ASRModelError.invalid(
                "ONNX Runtime intra-op thread count must be a positive Int32: \(intraOpThreads)"
            )
        }
        try size.validateModelDirectory(modelDirectory)

        let environment = try ONNXEnvironment.shared()
        let encoderSession = try ONNXSession(
            environment: environment,
            modelURL: graphDirectory.appendingPathComponent(size.encoderFilename),
            intraOpThreads: intraOpThreads,
            cpuMemoryArenaEnabled: Self.cpuMemoryArenaEnabled,
            configEntries: encoderConfigEntries
        )
        try Self.validateMetadata(
            graph: .encoder,
            inputs: encoderSession.inputMetadata(),
            outputs: encoderSession.outputMetadata(),
            size: size
        )

        let decoderInitSession = try ONNXSession(
            environment: environment,
            modelURL: graphDirectory.appendingPathComponent(size.decoderInitFilename),
            intraOpThreads: intraOpThreads,
            cpuMemoryArenaEnabled: Self.cpuMemoryArenaEnabled,
            configEntries: decoderInitConfigEntries
        )
        try Self.validateMetadata(
            graph: .decoderInit,
            inputs: decoderInitSession.inputMetadata(),
            outputs: decoderInitSession.outputMetadata(),
            size: size
        )

        let decoderStepSession = try ONNXSession(
            environment: environment,
            modelURL: graphDirectory.appendingPathComponent(size.decoderStepFilename),
            intraOpThreads: intraOpThreads,
            cpuMemoryArenaEnabled: Self.cpuMemoryArenaEnabled,
            configEntries: decoderStepConfigEntries
        )
        try Self.validateMetadata(
            graph: .decoderStep,
            inputs: decoderStepSession.inputMetadata(),
            outputs: decoderStepSession.outputMetadata(),
            size: size
        )

        let embedding = try Qwen3ASREmbeddingTable(
            contentsOf: modelDirectory.appendingPathComponent(size.embeddingFilename),
            vocabSize: Self.vocabularySize,
            hiddenSize: size.hiddenSize
        )
        guard embedding.hiddenSize == size.hiddenSize else {
            throw Qwen3ASRModelError.invalid(
                "encoder/audio_features hidden size expected \(size.hiddenSize), actual embedding hidden size \(embedding.hiddenSize)"
            )
        }
        let tokenizer = try Qwen3ASRTokenDecoder(
            contentsOf: modelDirectory.appendingPathComponent(size.tokenizerFilename)
        )

        self.environment = environment
        self.encoderSession = encoderSession
        self.decoderInitSession = decoderInitSession
        self.decoderStepSession = decoderStepSession
        self.embedding = embedding
        self.tokenizer = tokenizer
        self.frontend = Qwen3ASRMelFrontend()
    }

    func transcribe(samples: [Float], maxNewTokens: Int, noRepeatNgramSize: Int?) throws -> Qwen3ASRTranscription {
        let mel = try frontend.compute(samples: samples)
        let melValue = try ONNXValue(
            environment: environment,
            tensor: .float32(
                shape: [1, 128, Int64(mel.frameCount)],
                values: mel.values
            )
        )
        let encoderOutputs = try encoderSession.runValues(
            inputs: [(name: "mel", value: melValue)],
            outputNames: ["audio_features"]
        )
        guard let audioFeatures = encoderOutputs.first else {
            throw Self.runtimeError(graph: .encoder, name: "audio_features", expected: "one output value", actual: "none")
        }
        let hiddenSize = Int64(embedding.hiddenSize)
        guard audioFeatures.shape.count == 3,
              audioFeatures.shape[0] == 1,
              audioFeatures.shape[1] > 0,
              audioFeatures.shape[2] == hiddenSize
        else {
            throw Self.runtimeError(
                graph: .encoder,
                name: "audio_features",
                expected: "[1, N, H] with N > 0 and H = \(embedding.hiddenSize)",
                actual: String(describing: audioFeatures.shape)
            )
        }
        guard let audioTokenCount = Int(exactly: audioFeatures.shape[1]) else {
            throw Self.runtimeError(
                graph: .encoder,
                name: "audio_features",
                expected: "audio token count representable as Int",
                actual: String(audioFeatures.shape[1])
            )
        }

        let prompt = try Qwen3ASRPrompt(audioTokenCount: audioTokenCount)
        let decoder = Decoder(
            audioFeatures: audioFeatures,
            expectedAudioTokenCount: audioTokenCount,
            environment: environment,
            decoderInitSession: decoderInitSession,
            decoderStepSession: decoderStepSession,
            embedding: embedding
        )
        let generation = try Qwen3ASRGreedyDecoder(model: decoder).generate(
            promptIDs: prompt.tokenIDs,
            audioOffset: Qwen3ASRPrompt.audioOffset,
            maxNewTokens: maxNewTokens,
            noRepeatNgramSize: noRepeatNgramSize
        )
        return Qwen3ASRTranscription(
            text: try tokenizer.transcript(
                generatedIDs: generation.generatedIDs,
                endedAtTokenCap: generation.endedAtTokenCap
            ),
            generatedIDs: generation.generatedIDs
        )
    }

    static func validateMetadata(
        graph: Qwen3ASRGraph,
        inputs: [ONNXTensorMetadata],
        outputs: [ONNXTensorMetadata],
        size: ASRModelSize
    ) throws {
        let expected = metadata(for: graph, hiddenSize: Int64(size.hiddenSize))
        try validateMetadataDirection(graph: graph, direction: "input", expected: expected.inputs, actual: inputs)
        try validateMetadataDirection(graph: graph, direction: "output", expected: expected.outputs, actual: outputs)
    }

    private static func validateMetadataDirection(
        graph: Qwen3ASRGraph,
        direction: String,
        expected: [TensorMetadata],
        actual: [ONNXTensorMetadata]
    ) throws {
        let expectedNames = Set(expected.map(\.name))
        let actualNames = Set(actual.map(\.name))
        guard actual.count == expected.count, actualNames.count == actual.count, actualNames == expectedNames else {
            let missing = expectedNames.subtracting(actualNames).sorted()
            let extra = actualNames.subtracting(expectedNames).sorted()
            let duplicateNames = actual.map(\.name).filter { name in actual.filter { $0.name == name }.count > 1 }
            let detail: String
            if !duplicateNames.isEmpty {
                detail = "duplicate names \(Array(Set(duplicateNames)).sorted())"
            } else {
                detail = "missing names \(missing), extra names \(extra), expected count \(expected.count), actual count \(actual.count)"
            }
            throw Qwen3ASRModelError.invalid(
                "\(graph.label) \(direction) metadata expected names \(expectedNames.sorted()), actual names \(actual.map(\.name).sorted()): \(detail)"
            )
        }

        for specification in expected {
            guard let value = actual.first(where: { $0.name == specification.name }) else {
                throw Qwen3ASRModelError.invalid(
                    "\(graph.label) \(direction) \(specification.name) expected descriptor, actual missing"
                )
            }
            guard value.elementType == specification.elementType else {
                throw Qwen3ASRModelError.invalid(
                    "\(graph.label) \(direction) \(specification.name) element type expected \(specification.elementType), actual \(value.elementType)"
                )
            }
            guard dimensionsMatch(
                expected: specification.shape,
                actual: value.shape,
                batchAxis: specification.batchAxis
            ) else {
                throw Qwen3ASRModelError.invalid(
                    "\(graph.label) \(direction) \(specification.name) shape expected \(specification.shape), actual \(value.shape)"
                )
            }
        }
    }

    private static func dimensionsMatch(expected: [Int64], actual: [Int64], batchAxis: Int?) -> Bool {
        guard expected.count == actual.count else { return false }
        for index in expected.indices {
            if index == batchAxis, expected[index] == -1, (actual[index] == 1 || actual[index] == -1) {
                continue
            }
            guard expected[index] == actual[index] else { return false }
        }
        return true
    }

    private static func metadata(for graph: Qwen3ASRGraph, hiddenSize: Int64) -> (inputs: [TensorMetadata], outputs: [TensorMetadata]) {
        let float = ONNXTensorElementType.float32
        let integer = ONNXTensorElementType.int64
        switch graph {
        case .encoder:
            return (
                inputs: [TensorMetadata("mel", float, [1, 128, -1], batchAxis: nil)],
                outputs: [TensorMetadata("audio_features", float, [1, -1, hiddenSize], batchAxis: nil)]
            )
        case .decoderInit:
            return (
                inputs: [
                    TensorMetadata("input_ids", integer, [-1, -1], batchAxis: 0),
                    TensorMetadata("position_ids", integer, [-1, -1], batchAxis: 0),
                    TensorMetadata("audio_features", float, [-1, -1, hiddenSize], batchAxis: 0),
                    TensorMetadata("audio_offset", integer, [1], batchAxis: nil),
                ],
                outputs: [
                    TensorMetadata("logits", float, [-1, -1, Int64(vocabularySize)], batchAxis: 0),
                    TensorMetadata("present_keys", float, [layerCount, -1, headCount, -1, headSize], batchAxis: 1),
                    TensorMetadata("present_values", float, [layerCount, -1, headCount, -1, headSize], batchAxis: 1),
                ]
            )
        case .decoderStep:
            return (
                inputs: [
                    TensorMetadata("input_embeds", float, [-1, 1, hiddenSize], batchAxis: 0),
                    TensorMetadata("position_ids", integer, [-1, 1], batchAxis: 0),
                    TensorMetadata("past_keys", float, [layerCount, -1, headCount, -1, headSize], batchAxis: 1),
                    TensorMetadata("past_values", float, [layerCount, -1, headCount, -1, headSize], batchAxis: 1),
                ],
                outputs: [
                    TensorMetadata("logits", float, [-1, 1, Int64(vocabularySize)], batchAxis: 0),
                    TensorMetadata("present_keys", float, [layerCount, -1, headCount, -1, headSize], batchAxis: 1),
                    TensorMetadata("present_values", float, [layerCount, -1, headCount, -1, headSize], batchAxis: 1),
                ]
            )
        }
    }

    private static func runtimeError(graph: Qwen3ASRGraph, name: String, expected: String, actual: String) -> Qwen3ASRModelError {
        .invalid("\(graph.label) \(name) runtime shape expected \(expected), actual \(actual)")
    }

    private struct TensorMetadata {
        let name: String
        let elementType: ONNXTensorElementType
        let shape: [Int64]
        let batchAxis: Int?

        init(_ name: String, _ elementType: ONNXTensorElementType, _ shape: [Int64], batchAxis: Int?) {
            self.name = name
            self.elementType = elementType
            self.shape = shape
            self.batchAxis = batchAxis
        }
    }

    private struct Decoder: Qwen3ASRDecoderModel {
        struct Cache {
            let keys: ONNXValue
            let values: ONNXValue
        }

        let audioFeatures: ONNXValue
        let expectedAudioTokenCount: Int
        let environment: ONNXEnvironment
        let decoderInitSession: ONNXSession
        let decoderStepSession: ONNXSession
        let embedding: Qwen3ASREmbeddingTable

        func prefill(promptIDs: [Int64], audioOffset: Int64) throws -> (lastLogits: [Float], cache: Cache) {
            let expectedPrompt = try Qwen3ASRPrompt(audioTokenCount: expectedAudioTokenCount)
            guard promptIDs == expectedPrompt.tokenIDs else {
                throw Qwen3ASRModelError.invalid(
                    "decoder_init input_ids expected exact prompt for \(expectedAudioTokenCount) audio tokens (\(expectedPrompt.tokenIDs.count) ids), actual \(promptIDs.count) ids"
                )
            }
            guard audioOffset == Qwen3ASRPrompt.audioOffset else {
                throw Qwen3ASRModelError.invalid(
                    "decoder_init audio_offset expected \(Qwen3ASRPrompt.audioOffset), actual \(audioOffset)"
                )
            }
            guard let sequenceLength = Int64(exactly: promptIDs.count) else {
                throw Qwen3ASRModelError.invalid("decoder_init input_ids prompt length cannot be represented as Int64: \(promptIDs.count)")
            }

            let inputIDs = try ONNXValue(
                environment: environment,
                tensor: .int64(shape: [1, sequenceLength], values: promptIDs)
            )
            let positionIDs = try ONNXValue(
                environment: environment,
                tensor: .int64(shape: [1, sequenceLength], values: Array(0..<sequenceLength))
            )
            let offset = try ONNXValue(
                environment: environment,
                tensor: .int64(shape: [1], values: [audioOffset])
            )
            let outputs = try decoderInitSession.runValues(
                inputs: [
                    (name: "input_ids", value: inputIDs),
                    (name: "position_ids", value: positionIDs),
                    (name: "audio_features", value: audioFeatures),
                    (name: "audio_offset", value: offset),
                ],
                outputNames: ["logits", "present_keys", "present_values"]
            )
            guard outputs.count == 3 else {
                throw Self.runtimeError(graph: .decoderInit, name: "outputs", expected: "3 values", actual: "\(outputs.count) values")
            }
            let expectedLogitsShape: [Int64] = [1, sequenceLength, Int64(Qwen3ASRONNXModel.vocabularySize)]
            try Self.validateShape(outputs[0], graph: .decoderInit, name: "logits", expected: expectedLogitsShape)
            let expectedCacheShape = Self.cacheShape(sequenceLength: sequenceLength)
            try Self.validateShape(outputs[1], graph: .decoderInit, name: "present_keys", expected: expectedCacheShape)
            try Self.validateShape(outputs[2], graph: .decoderInit, name: "present_values", expected: expectedCacheShape)
            return (
                lastLogits: try outputs[0].float32LastRow(),
                cache: Cache(keys: outputs[1], values: outputs[2])
            )
        }

        func step(tokenID: Int64, position: Int64, cache: Cache) throws -> (logits: [Float], cache: Cache) {
            let pastLength = try Self.validateCache(cache)
            guard position == pastLength else {
                throw Qwen3ASRModelError.invalid(
                    "decoder_step position_ids expected past cache length \(pastLength), actual \(position)"
                )
            }
            let (nextLength, overflow) = pastLength.addingReportingOverflow(1)
            guard !overflow else {
                throw Qwen3ASRModelError.invalid("decoder_step cache sequence length overflows Int64: \(pastLength)")
            }

            let inputEmbeds = try ONNXValue(
                environment: environment,
                tensor: .float32(
                    shape: [1, 1, Int64(embedding.hiddenSize)],
                    values: try embedding.row(tokenID)
                )
            )
            let positionIDs = try ONNXValue(
                environment: environment,
                tensor: .int64(shape: [1, 1], values: [position])
            )
            let outputs = try decoderStepSession.runValues(
                inputs: [
                    (name: "input_embeds", value: inputEmbeds),
                    (name: "position_ids", value: positionIDs),
                    (name: "past_keys", value: cache.keys),
                    (name: "past_values", value: cache.values),
                ],
                outputNames: ["logits", "present_keys", "present_values"]
            )
            guard outputs.count == 3 else {
                throw Self.runtimeError(graph: .decoderStep, name: "outputs", expected: "3 values", actual: "\(outputs.count) values")
            }
            let expectedLogitsShape: [Int64] = [1, 1, Int64(Qwen3ASRONNXModel.vocabularySize)]
            try Self.validateShape(outputs[0], graph: .decoderStep, name: "logits", expected: expectedLogitsShape)
            let expectedCacheShape = Self.cacheShape(sequenceLength: nextLength)
            try Self.validateShape(outputs[1], graph: .decoderStep, name: "present_keys", expected: expectedCacheShape)
            try Self.validateShape(outputs[2], graph: .decoderStep, name: "present_values", expected: expectedCacheShape)
            return (
                logits: try outputs[0].float32LastRow(),
                cache: Cache(keys: outputs[1], values: outputs[2])
            )
        }

        private static func validateCache(_ cache: Cache) throws -> Int64 {
            let keys = cache.keys.shape
            let values = cache.values.shape
            guard keys.count == 5,
                  keys[0] == Qwen3ASRONNXModel.layerCount,
                  keys[1] == 1,
                  keys[2] == Qwen3ASRONNXModel.headCount,
                  keys[3] > 0,
                  keys[4] == Qwen3ASRONNXModel.headSize
            else {
                throw Self.runtimeError(
                    graph: .decoderStep,
                    name: "past_keys",
                    expected: "[28, 1, 8, P, 128] with P > 0",
                    actual: String(describing: keys)
                )
            }
            guard values == keys else {
                throw Self.runtimeError(
                    graph: .decoderStep,
                    name: "past_values",
                    expected: String(describing: keys),
                    actual: String(describing: values)
                )
            }
            return keys[3]
        }

        private static func cacheShape(sequenceLength: Int64) -> [Int64] {
            [
                Qwen3ASRONNXModel.layerCount,
                1,
                Qwen3ASRONNXModel.headCount,
                sequenceLength,
                Qwen3ASRONNXModel.headSize,
            ]
        }

        private static func validateShape(
            _ value: ONNXValue,
            graph: Qwen3ASRGraph,
            name: String,
            expected: [Int64]
        ) throws {
            guard value.shape == expected else {
                throw Self.runtimeError(
                    graph: graph,
                    name: name,
                    expected: String(describing: expected),
                    actual: String(describing: value.shape)
                )
            }
        }

        private static func runtimeError(
            graph: Qwen3ASRGraph,
            name: String,
            expected: String,
            actual: String
        ) -> Qwen3ASRModelError {
            .invalid("\(graph.label) \(name) runtime shape expected \(expected), actual \(actual)")
        }
    }
}

enum Qwen3ASRGraph {
    case encoder
    case decoderInit
    case decoderStep

    var label: String {
        switch self {
        case .encoder: "encoder"
        case .decoderInit: "decoder_init"
        case .decoderStep: "decoder_step"
        }
    }
}
