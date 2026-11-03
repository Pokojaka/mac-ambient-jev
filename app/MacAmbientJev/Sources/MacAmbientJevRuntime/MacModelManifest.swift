import Foundation
import MacAmbientJevCore

public enum MacModelManifest {
    /// Decodes the bundled manifest. It must define exactly the cases of `MacModel`.
    public static func bundled() throws -> [MacModel: ModelManifestEntry] {
        guard let url = Bundle.module.url(
            forResource: "mac_models",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            throw ModelManifestError.invalid("同梱モデルマニフェスト Resources/mac_models.json が見つかりません")
        }
        let entries = try ModelManifest.decode(Data(contentsOf: url))
        guard Set(entries.keys) == Set(MacModel.allCases.map(\.rawValue)) else {
            throw ModelManifestError.invalid(
                "マニフェストは \(MacModel.allCases.map(\.rawValue).sorted()) だけを定義してください: \(entries.keys.sorted())"
            )
        }
        return Dictionary(uniqueKeysWithValues: MacModel.allCases.map { ($0, entries[$0.rawValue]!) })
    }
}
