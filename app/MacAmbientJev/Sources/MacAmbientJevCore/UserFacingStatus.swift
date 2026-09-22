import Foundation

public enum UserFacingStatus: Sendable, Equatable {
    case idle
    case checkingMicrophone
    case startingRecording
    case importingAudio
    case convertingTimeline
    case detectingSpeech
    case preparingASR
    case loadingASR
    case asrBacklogged
    case preparingDiarization
    case diarizing
    case analyzingScene
    case analyzingScope
    case jevDeferred

    public var text: String {
        switch self {
        case .idle:
            return "待機中"
        case .checkingMicrophone:
            return "マイクへのアクセスを確認しています"
        case .startingRecording:
            return "録音を開始しています"
        case .importingAudio:
            return "音声ファイルを読み込んでいます"
        case .convertingTimeline:
            return "音声ファイルを処理用タイムラインへ変換しています"
        case .detectingSpeech:
            return "発話区間を検出しています"
        case .preparingASR:
            return "音声認識モデルを準備しています"
        case .loadingASR:
            return "音声認識モデルを読み込んでいます"
        case .asrBacklogged:
            return "文字起こし処理が遅れています"
        case .preparingDiarization:
            return "話者分離を準備しています"
        case .diarizing:
            return "話者を分離しています"
        case .analyzingScene:
            return "会話の場面を判定しています"
        case .analyzingScope:
            return "発話の音響範囲を整理しています"
        case .jevDeferred:
            return "意味分類を後で再試行します"
        }
    }
}