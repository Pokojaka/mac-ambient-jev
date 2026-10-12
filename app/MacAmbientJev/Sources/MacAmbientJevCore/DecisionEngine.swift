public enum DecisionEngineChoice: String, Codable, Hashable, CaseIterable, Sendable {
    case jev = "jev"
    case localModel = "local-coreml"

    public var displayName: String {
        switch self {
        case .jev:
            "Jev（API）"
        case .localModel:
            "ローカルモデル"
        }
    }
}
