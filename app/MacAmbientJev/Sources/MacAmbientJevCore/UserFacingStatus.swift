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
    case liveTranscriptionThermalSuspended
    case preparingDiarization
    case diarizing
    case classifyingContent
    case decisionDeferred
    case finalizationPausedForHeat

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
        case .liveTranscriptionThermalSuspended:
            return "発熱のためライブ表示を一時停止中"
        case .preparingDiarization:
            return "話者分離を準備しています"
        case .diarizing:
            return "話者を分離しています"
        case .classifyingContent:
            return "発話文の境界と優先度を判定しています"
        case .decisionDeferred:
            return "発話文の判定を保留しました"
        case .finalizationPausedForHeat:
            return "発熱のため確定処理を一時停止中"
        }
    }
}
extension MicInputWarning {
    public var text: String {
        switch self {
        case .low:
            "声が小さく録音されています。マイクに近づくか、入力音量を確認してください。"
        case .clipping:
            "音が大きすぎて、声がひずんでいます。マイクから少し離れるか、入力音量を下げてください。"
        }
    }
}

extension MicInputStatus {
    public static let speechMonitoringUnavailableText =
        "発話検出が止まったため、声の大きさを確認できません。マイクの位置と入力音量を確認してください。"
}

extension MicInputAdjustment {
    public var text: String {
        switch self {
        case .active:
            "声の大きさに合わせて入力音量を自動調整しています。"
        case .disabledBySetting:
            "入力音量の自動調整はオフです。"
        case .unsupportedDevice:
            "このマイクは入力音量を変更できないため、自動調整を使えません。"
        case .pausedByExternalChange:
            "入力設定が変更されたため、この録音では自動調整を止めています。"
        case .pausedByDefaultDeviceChange:
            "既定の入力デバイスが変わったため、この録音では自動調整を止めています。録音前の入力音量には戻しません。"
        case .failed(let failure):
            "入力音量を自動調整できませんでした（\(failure.text)）。この録音では自動調整を止めています。"
        case .restoreFailed(let failure):
            "入力音量を元に戻せませんでした（\(failure.text)）。システム設定の「サウンド」で入力音量を確認してください。"
        }
    }

    /// Failures stay visible after the recording ends because the input volume may not be what the user set.
    public var isFailure: Bool {
        switch self {
        case .failed, .restoreFailed:
            true
        case .active, .disabledBySetting, .unsupportedDevice, .pausedByExternalChange,
             .pausedByDefaultDeviceChange:
            false
        }
    }
}

extension MicInputVolumeFailure {
    public var text: String {
        switch self {
        case .deviceIdentityUnverified:
            "録音中のマイクを確認できません"
        case .propertyUnavailable:
            "入力音量を読み取れません"
        case .invalidValue:
            "入力音量の値が正しくありません"
        case .listenerRegistrationFailed:
            "入力音量の変更を監視できません"
        case .listenerRemovalFailed:
            "入力音量の監視を解除できません"
        case .notBound:
            "マイクとの接続が切れています"
        case .staleExpectedValues:
            "入力音量が別の操作で変更されました"
        case .writeRejected:
            "マイクが変更を受け付けませんでした"
        case .noMovement:
            "入力音量が変わりませんでした"
        case .unexpectedMovement:
            "入力音量が予期しない値になりました"
        case .partialWrite:
            "一部のチャンネルだけが変更されました"
        case .acknowledgementTimeout:
            "変更の確認が時間内に届きませんでした"
        case .writeUnresolved:
            "変更が完了したか確認できませんでした"
        }
    }
}
