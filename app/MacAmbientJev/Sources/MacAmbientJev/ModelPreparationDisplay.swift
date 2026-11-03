import Foundation
import MacAmbientJevCore

extension ModelPreparationStatus {
    /// The status shown while recording and queued work wait for the models.
    var waitingText: String {
        switch phase {
        case .failed(let reason): "モデルを準備できませんでした: \(Self.withRetryHint(reason))"
        case .idle, .downloading, .loading, .ready: Self.waitingForModelsText
        }
    }

    var summaryText: String {
        switch phase {
        case .idle: "未準備"
        case .downloading: "モデルをダウンロード中（\(percentText)）"
        case .loading: "モデルを確認・読み込み中"
        case .ready: "準備完了"
        case .failed(let reason): "準備できませんでした: \(Self.withRetryHint(reason))"
        }
    }

    private static func withRetryHint(_ reason: String) -> String {
        let stop = reason.hasSuffix("。") ? "" : "。"
        return "\(reason)\(stop)設定の「モデルを取得」で再試行できます"
    }

    var fractionDone: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0
    }

    var percentText: String {
        "\(Int(fractionDone * 100))% · \(Self.megabytes(bytesDone)) / \(Self.megabytes(bytesTotal))"
    }

    private static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension MacModelState {
    var text: String {
        switch self {
        case .idle: "録音開始時に準備します"
        case .downloading: "ダウンロード待ち・中"
        case .verifying: "確認・読み込み中"
        case .ready: "準備完了"
        case .failed(let reason): "失敗: \(reason)"
        }
    }
}
