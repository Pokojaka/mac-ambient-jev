import Testing
@testable import MacAmbientJevHaasASR

struct HaasASRModelTests {
    @Test
    func bundledManifest() throws {
        let manifest = try HaasASRModel.manifest()
        #expect(manifest.repository == "Sanami/haas-ja-onnx")
        #expect(manifest.commit == "354baedfd9612b00e74cc1ae87dff7f2c558db6f")
        #expect(Set(manifest.files.map(\.name)) == Set([
            "int8dyn/encoder.onnx", "int8dyn/encoder.onnx.data",
            "int8dyn/decoder_joint.onnx", "int8dyn/decoder_joint.onnx.data",
            "tokenizer.model", "LICENSE", "NOTICE"
        ]))
        #expect(manifest.files.allSatisfy { $0.byteCount > 0 })
    }
}
