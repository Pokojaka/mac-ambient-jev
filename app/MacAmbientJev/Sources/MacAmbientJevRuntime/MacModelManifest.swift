import Foundation
import MacAmbientJevCore
import MacAmbientJevHaasASR

public enum MacModelManifest {
    public static func bundled() throws -> [MacModel: ModelManifestEntry] {
        guard let url = Bundle.module.url(
            forResource: "fluid_vad_model",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            throw ModelManifestError.invalid("同梱モデルマニフェスト Resources/fluid_vad_model.json が見つかりません")
        }
        let vadEntry = try ModelManifest.decodeEntry(Data(contentsOf: url))
        return Dictionary(uniqueKeysWithValues: try MacModel.allCases.map { model in
            switch model {
            case .asr: (model, try HaasASRModel.manifest())
            case .vad: (model, vadEntry)
            }
        })
    }
}
