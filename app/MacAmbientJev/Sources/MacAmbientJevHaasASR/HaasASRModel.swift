import Foundation
import MacAmbientJevCore

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
