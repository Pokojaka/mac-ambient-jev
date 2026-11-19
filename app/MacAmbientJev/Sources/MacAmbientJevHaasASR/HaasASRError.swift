import Foundation

public enum HaasASRError: Error, Equatable, LocalizedError {
    case notPrepared
    case inputTooLong(seconds: Double)
    case unexpectedGraph(String)
    case invalidTokenizer(String)

    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            "Haas ASRモデルが準備されていません"
        case let .inputTooLong(seconds):
            "Haas ASRの入力が長すぎます（\(seconds) 秒）"
        case let .unexpectedGraph(details):
            "Haas ASRモデルのグラフが想定外です: \(details)"
        case let .invalidTokenizer(details):
            "Haas ASRトークナイザーが無効です: \(details)"
        }
    }
}
