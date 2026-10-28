import MacAmbientJevCore
import MacAmbientJevONNX
import Testing
@testable import MacAmbientJevPortableRuntime

struct Qwen3ASRONNXModelTests {
    @Test
    func metadataMatchesInspectedGraphsForBothSizesAndRuntimeBatches() throws {
        for size in ASRModelSize.allCases {
            for graph in [Qwen3ASRGraph.encoder, .decoderInit, .decoderStep] {
                let dynamicBatch = metadata(for: graph, size: size, batch: -1)
                try Qwen3ASRONNXModel.validateMetadata(
                    graph: graph,
                    inputs: dynamicBatch.inputs,
                    outputs: dynamicBatch.outputs,
                    size: size
                )

                let fixedRuntimeBatch = metadata(for: graph, size: size, batch: 1)
                try Qwen3ASRONNXModel.validateMetadata(
                    graph: graph,
                    inputs: fixedRuntimeBatch.inputs,
                    outputs: fixedRuntimeBatch.outputs,
                    size: size
                )
            }
        }
    }

    @Test
    func wrongNamesAndMissingOrExtraEntriesFailWithContext() {
        let fixture = metadata(for: .encoder, size: .small, batch: -1)
        var wrongNameInputs = fixture.inputs
        wrongNameInputs[0] = ONNXTensorMetadata(
            name: "mel_input",
            elementType: fixture.inputs[0].elementType,
            shape: fixture.inputs[0].shape
        )
        let wrongName = failureMessage(
            graph: .encoder,
            inputs: wrongNameInputs,
            outputs: fixture.outputs,
            size: .small
        )
        #expect(wrongName.contains("encoder"))
        #expect(wrongName.contains("expected names"))
        #expect(wrongName.contains("actual names"))

        let initFixture = metadata(for: .decoderInit, size: .small, batch: -1)
        let missing = failureMessage(
            graph: .decoderInit,
            inputs: Array(initFixture.inputs.dropFirst()),
            outputs: initFixture.outputs,
            size: .small
        )
        #expect(missing.contains("decoder_init"))
        #expect(missing.contains("input_ids"))
        #expect(missing.contains("missing names"))

        var extraInputs = initFixture.inputs
        extraInputs.append(ONNXTensorMetadata(name: "unexpected", elementType: .float32, shape: [1]))
        let extra = failureMessage(
            graph: .decoderInit,
            inputs: extraInputs,
            outputs: initFixture.outputs,
            size: .small
        )
        #expect(extra.contains("decoder_init"))
        #expect(extra.contains("unexpected"))
        #expect(extra.contains("extra names"))
    }

    @Test
    func wrongTypesHiddenSizesRanksAndCacheDimensionsFailClearly() {
        let initFixture = metadata(for: .decoderInit, size: .small, batch: -1)
        var wrongTypeInputs = initFixture.inputs
        wrongTypeInputs[0] = ONNXTensorMetadata(name: "input_ids", elementType: .float32, shape: [-1, -1])
        let wrongType = failureMessage(
            graph: .decoderInit,
            inputs: wrongTypeInputs,
            outputs: initFixture.outputs,
            size: .small
        )
        #expect(wrongType.contains("decoder_init"))
        #expect(wrongType.contains("input_ids"))
        #expect(wrongType.contains("element type expected"))
        #expect(wrongType.contains("actual"))

        let wrongHiddenSize = failureMessage(
            graph: .encoder,
            inputs: metadata(for: .encoder, size: .small, batch: -1).inputs,
            outputs: [ONNXTensorMetadata(name: "audio_features", elementType: .float32, shape: [1, -1, 2048])],
            size: .small
        )
        #expect(wrongHiddenSize.contains("encoder"))
        #expect(wrongHiddenSize.contains("audio_features"))
        #expect(wrongHiddenSize.contains("expected [1, -1, 1024]"))
        #expect(wrongHiddenSize.contains("actual [1, -1, 2048]"))

        var wrongRankInputs = initFixture.inputs
        wrongRankInputs[1] = ONNXTensorMetadata(name: "position_ids", elementType: .int64, shape: [1])
        let wrongRank = failureMessage(
            graph: .decoderInit,
            inputs: wrongRankInputs,
            outputs: initFixture.outputs,
            size: .small
        )
        #expect(wrongRank.contains("decoder_init"))
        #expect(wrongRank.contains("position_ids"))
        #expect(wrongRank.contains("shape expected"))
        #expect(wrongRank.contains("actual [1]"))

        var wrongCacheOutputs = initFixture.outputs
        wrongCacheOutputs[1] = ONNXTensorMetadata(
            name: "present_keys",
            elementType: .float32,
            shape: [28, -1, 7, -1, 128]
        )
        let wrongCache = failureMessage(
            graph: .decoderInit,
            inputs: initFixture.inputs,
            outputs: wrongCacheOutputs,
            size: .small
        )
        #expect(wrongCache.contains("decoder_init"))
        #expect(wrongCache.contains("present_keys"))
        #expect(wrongCache.contains("expected [28, -1, 8, -1, 128]"))
        #expect(wrongCache.contains("actual [28, -1, 7, -1, 128]"))
    }

    private func metadata(
        for graph: Qwen3ASRGraph,
        size: ASRModelSize,
        batch: Int64
    ) -> (inputs: [ONNXTensorMetadata], outputs: [ONNXTensorMetadata]) {
        let float = ONNXTensorElementType.float32
        let integer = ONNXTensorElementType.int64
        let hidden = Int64(size.hiddenSize)
        switch graph {
        case .encoder:
            return (
                [ONNXTensorMetadata(name: "mel", elementType: float, shape: [1, 128, -1])],
                [ONNXTensorMetadata(name: "audio_features", elementType: float, shape: [1, -1, hidden])]
            )
        case .decoderInit:
            return (
                [
                    ONNXTensorMetadata(name: "input_ids", elementType: integer, shape: [batch, -1]),
                    ONNXTensorMetadata(name: "position_ids", elementType: integer, shape: [batch, -1]),
                    ONNXTensorMetadata(name: "audio_features", elementType: float, shape: [batch, -1, hidden]),
                    ONNXTensorMetadata(name: "audio_offset", elementType: integer, shape: [1]),
                ],
                [
                    ONNXTensorMetadata(name: "logits", elementType: float, shape: [batch, -1, 151_936]),
                    ONNXTensorMetadata(name: "present_keys", elementType: float, shape: [28, batch, 8, -1, 128]),
                    ONNXTensorMetadata(name: "present_values", elementType: float, shape: [28, batch, 8, -1, 128]),
                ]
            )
        case .decoderStep:
            return (
                [
                    ONNXTensorMetadata(name: "input_embeds", elementType: float, shape: [batch, 1, hidden]),
                    ONNXTensorMetadata(name: "position_ids", elementType: integer, shape: [batch, 1]),
                    ONNXTensorMetadata(name: "past_keys", elementType: float, shape: [28, batch, 8, -1, 128]),
                    ONNXTensorMetadata(name: "past_values", elementType: float, shape: [28, batch, 8, -1, 128]),
                ],
                [
                    ONNXTensorMetadata(name: "logits", elementType: float, shape: [batch, 1, 151_936]),
                    ONNXTensorMetadata(name: "present_keys", elementType: float, shape: [28, batch, 8, -1, 128]),
                    ONNXTensorMetadata(name: "present_values", elementType: float, shape: [28, batch, 8, -1, 128]),
                ]
            )
        }
    }

    private func failureMessage(
        graph: Qwen3ASRGraph,
        inputs: [ONNXTensorMetadata],
        outputs: [ONNXTensorMetadata],
        size: ASRModelSize
    ) -> String {
        do {
            try Qwen3ASRONNXModel.validateMetadata(graph: graph, inputs: inputs, outputs: outputs, size: size)
            return "metadata validation unexpectedly succeeded"
        } catch let Qwen3ASRModelError.invalid(message) {
            return message
        } catch {
            return "unexpected error: \(error)"
        }
    }
}
