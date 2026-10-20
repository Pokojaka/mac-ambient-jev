import Foundation
import MacAmbientJevCore

public enum AudioCaptureEngineError: LocalizedError {
    case alreadyRecording
    case notRecording
    case invalidInputFormat
    case inputUnavailable
    case noSystemAudioCaptured
    case noAudioCaptured
    case writerFailure(String)
    case insufficientDiskSpace(Int64)
    case diskSpaceUnavailable(String)
    case cancelled
    case captureFailure(String)
    case micInputVolumeNotConfigured

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "すでに録音中です"
        case .notRecording:
            "録音は開始されていません"
        case .invalidInputFormat:
            "マイクの音声形式を利用できません"
        case .inputUnavailable:
            "マイクから音声を取得できませんでした"
        case .noAudioCaptured:
            "マイクから音声が届きませんでした。入力デバイスとマイク権限を確認してください"
        case .noSystemAudioCaptured:
            "システム音声が届きませんでした。再生中の音声とシステムオーディオ録音の権限を確認してください"
        case .writerFailure(let cause):
            "録音の保存に失敗しました: \(cause)"
        case .insufficientDiskSpace(let bytes):
            "90分の録音に必要な空き容量がありません（必要: \(bytes / 1_000_000) MB）"
        case .diskSpaceUnavailable(let cause):
            "空き容量を確認できないため録音を開始できません: \(cause)"
        case .cancelled:
            "録音の開始を中止しました"
        case .captureFailure(let message):
            message
        case .micInputVolumeNotConfigured:
            "マイク入力音量の設定が録音開始前に指定されていません"
        }
    }
}

public struct AudioCaptureStopResult: Sendable, Equatable {
    public let checkpoint: AudioCheckpoint
    public let didOverflow: Bool
    public let dropoutCount: UInt64
    public let gapCount: Int
    public let totalGapFrames: Int64
    public let sleepAssertionHeld: Bool
    /// The storage failure that ended the recording; `checkpoint` is then the healthy durable prefix.
    public let writerFailure: String?
    /// Core Audio refused to release part of the system-audio tap.
    public let systemAudioReleaseFailure: String?

    public init(
        checkpoint: AudioCheckpoint, didOverflow: Bool,
        dropoutCount: UInt64, gapCount: Int,
        totalGapFrames: Int64, sleepAssertionHeld: Bool,
        writerFailure: String?, systemAudioReleaseFailure: String?
    ) {
        self.checkpoint = checkpoint
        self.didOverflow = didOverflow || !checkpoint.gapEvents.isEmpty
        self.dropoutCount = dropoutCount
        self.gapCount = gapCount
        self.totalGapFrames = totalGapFrames
        self.sleepAssertionHeld = sleepAssertionHeld
        self.writerFailure = writerFailure
        self.systemAudioReleaseFailure = systemAudioReleaseFailure
    }
}
