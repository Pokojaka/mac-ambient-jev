import Foundation
import MacAmbientJevCore

public struct HaasASRModelFiles: Sendable, Equatable {
    let encoder: URL
    let decoderJoint: URL
    let tokenizer: URL

    public init(verifiedDirectory: URL) {
        let int8Directory = verifiedDirectory.appendingPathComponent("int8dyn")
        encoder = int8Directory.appendingPathComponent("encoder.onnx")
        decoderJoint = int8Directory.appendingPathComponent("decoder_joint.onnx")
        tokenizer = verifiedDirectory.appendingPathComponent("tokenizer.model")
    }
}

public enum HaasASRModel {
    public static func manifest() throws -> ModelManifestEntry {
        guard let url = Bundle.module.url(
            forResource: "haas_asr_model",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            throw ModelManifestError.invalid("同梱モデルマニフェスト Resources/haas_asr_model.json が見つかりません")
        }
        return try ModelManifest.decodeEntry(Data(contentsOf: url))
    }
}
