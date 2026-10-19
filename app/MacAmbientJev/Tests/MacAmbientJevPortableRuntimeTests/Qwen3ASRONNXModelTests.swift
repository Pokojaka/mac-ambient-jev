import MacAmbientJevONNX
import Testing
@testable import MacAmbientJevPortableRuntime

struct Qwen3ASRONNXModelTests {
    @Test
    func metadataMatchesInspectedGraphsForBothSizesAndRuntimeBatches() throws {
        for size in Qwen3ASRModelSize.allCases {
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
    func modelSizeManifestNamesSizesAndPinsAreExact() {
        let expected: [(size: Qwen3ASRModelSize, hiddenSize: Int, repository: String, commit: String, names: [String], bytes: [Int64], hashes: [String])] = [
            (
                .small,
                1024,
                "andrewleech/qwen3-asr-0.6b-onnx",
                "4fc24a1402e74db89c4d2ef256875e71680128c4",
                ["encoder.onnx", "decoder_init.int4.onnx", "decoder_step.int4.onnx", "decoder_weights.int4.data", "embed_tokens.bin", "tokenizer.json"],
                [745_762_694, 355_390, 354_888, 962_460_672, 311_164_928, 11_429_377],
                [
                    "3c027f880f677615de85e1f6934906e1d5d77624b724096d33accef99c753eed",
                    "6d54633bbb9e6b1ecf372f218d04adb3bf6f2bfc442ce55c988526d532896faa",
                    "7eaa4f31d5eb6ae2937ff45222c32f692f2d5ac29b46cbae9046da332a9f317d",
                    "d68cd1c0695a7ba42651d06b1bc1158e2e58af5f9adbb6dba874fbbb8a4f22cf",
                    "e80150119fa5f7e56e85aed64c3a02d5c78eb7a37cfdcb973d0987316f15bee2",
                    "bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92",
                ]
            ),
            (
                .large,
                2048,
                "andrewleech/qwen3-asr-1.7b-onnx",
                "df916193ac67e59347769891a21e10d81d12acdd",
                ["encoder.onnx", "decoder_init.int4.onnx", "decoder_step.int4.onnx", "decoder_weights.int4.data", "embed_tokens.bin", "tokenizer.json"],
                [1_270_241_779, 356_165, 355_662, 2_226_321_408, 622_329_856, 11_429_377],
                [
                    "c19ff8d702707693877a509ba1867472b0ad964593b93751091891a143edffec",
                    "c638585ada629b3cf65ce9cb068b7b980fccc9454a7f05e2333b8813730c1999",
                    "fa138c025c26f6559e12be51cfbba5204a0b6993a1f3bb1177f80a0a65873bb5",
                    "3f8d8fb695bcffc20ce8d8e823471e011404420785adf7678aac31057ef67333",
                    "1489075dbd08fcd6b87bc69c5feca278014d29fa5693bd4aa61e47c1a3a160d4",
                    "bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92",
                ]
            ),
        ]

        for fixture in expected {
            #expect(fixture.size.hiddenSize == fixture.hiddenSize)
            #expect(fixture.size.repository == fixture.repository)
            #expect(fixture.size.commit == fixture.commit)
            #expect(fixture.size.files.count == Qwen3ASRModelFileRole.allCases.count)
            let filesByRole = Dictionary(uniqueKeysWithValues: fixture.size.files.map { ($0.role, $0) })
            for (role, name) in zip(Qwen3ASRModelFileRole.allCases, fixture.names) {
                #expect(filesByRole[role]?.name == name)
            }
            for (role, byteCount) in zip(Qwen3ASRModelFileRole.allCases, fixture.bytes) {
                #expect(filesByRole[role]?.byteCount == byteCount)
            }
            for (role, sha256) in zip(Qwen3ASRModelFileRole.allCases, fixture.hashes) {
                #expect(filesByRole[role]?.sha256 == sha256)
            }

            #expect(fixture.size.encoderFilename == filesByRole[.encoder]?.name)
            #expect(fixture.size.decoderInitFilename == filesByRole[.decoderInit]?.name)
            #expect(fixture.size.decoderStepFilename == filesByRole[.decoderStep]?.name)
            #expect(fixture.size.decoderWeightsFilename == filesByRole[.decoderWeights]?.name)
            #expect(fixture.size.embeddingFilename == filesByRole[.embedTokens]?.name)
            #expect(fixture.size.tokenizerFilename == filesByRole[.tokenizer]?.name)
        }
    }

    @Test
    func unsupportedRawModelSizesAreRejected() {
        #expect(Qwen3ASRModelSize(rawValue: "0.6") == nil)
        #expect(Qwen3ASRModelSize(rawValue: "1.7") == nil)
        #expect(Qwen3ASRModelSize(rawValue: "0.6B") == nil)
        #expect(Qwen3ASRModelSize(rawValue: "unknown") == nil)
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
        size: Qwen3ASRModelSize,
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
        size: Qwen3ASRModelSize
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
