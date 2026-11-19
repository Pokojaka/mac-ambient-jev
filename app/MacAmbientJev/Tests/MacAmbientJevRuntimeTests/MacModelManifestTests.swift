import Testing
import MacAmbientJevCore
import MacAmbientJevHaasASR
@testable import MacAmbientJevRuntime

@Test
func bundledManifestDecodesAndPinsEveryModel() throws {
    let manifest = try MacModelManifest.bundled()
    #expect(Set(manifest.keys) == Set(MacModel.allCases))
    for entry in manifest.values {
        #expect(!entry.files.isEmpty)
    }
    #expect(manifest[.asr] == (try HaasASRModel.manifest()))
    #expect(manifest[.asr]?.files.map(\.name) == [
        "int8dyn/encoder.onnx", "int8dyn/encoder.onnx.data", "int8dyn/decoder_joint.onnx",
        "int8dyn/decoder_joint.onnx.data", "tokenizer.model", "LICENSE", "NOTICE"
    ])
    #expect(MacModel.asr.relativeDirectory == "haas-ja-onnx-int8dyn")
    #expect(manifest[.vad] == ModelManifestEntry(repository: "FluidInference/silero-vad-coreml",
        commit: "b419383c55c110e2c9271fa6ee0ea83d03c70d96", files: [
            .init(name: "silero-vad-unified-256ms-v6.2.1.mlmodelc/analytics/coremldata.bin", role: "vad_analytics", byteCount: 243, sha256: "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909"),
            .init(name: "silero-vad-unified-256ms-v6.2.1.mlmodelc/coremldata.bin", role: "vad_coremldata", byteCount: 625, sha256: "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41"),
            .init(name: "silero-vad-unified-256ms-v6.2.1.mlmodelc/metadata.json", role: "vad_metadata", byteCount: 3335, sha256: "2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6"),
            .init(name: "silero-vad-unified-256ms-v6.2.1.mlmodelc/model.mil", role: "vad_model", byteCount: 176918, sha256: "c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270"),
            .init(name: "silero-vad-unified-256ms-v6.2.1.mlmodelc/weights/weight.bin", role: "vad_weights", byteCount: 882304, sha256: "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063")
        ]))
}
