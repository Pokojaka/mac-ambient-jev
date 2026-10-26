import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

struct EnginePresentation {
    var recordingStatusText = UserFacingStatus.idle.text
    var recordingTone: EngineRecordingTone = .neutral
    var preparationPhase: EnginePreparationPhase = .idle
    var preparationStatusText: String? = nil
    var recoveryStatusText: String? = nil
    var processingStatusText: String? = nil
    var liveFailureNotices: [String] = []
    var isSilent = false
    var isWaitingForDevice = false
    var audioGapCount: UInt64 = 0
    var processingState: ProcessingState = .idle
    var preparationID: UUID? = nil
}

extension EngineApplicationCore {
    func presentationState() throws -> EnginePresentationState {
        let isRecording = recording.phase == .recording
        let silenceWarningText: String?
        if isRecording && !presentation.isWaitingForDevice {
            guard let activeRecording else {
                preconditionFailure("an active recording has a source for presentation")
            }
            if presentation.isSilent {
                switch activeRecording.source {
                case .microphone:
                    silenceWarningText = "マイク入力が30秒以上無音です。ミュート設定を確認してください"
                case .systemAudio:
                    silenceWarningText = "システム音声が30秒以上無音です"
                }
            } else {
                silenceWarningText = nil
            }
        } else {
            silenceWarningText = nil
        }

        let audioGapText = isRecording && presentation.audioGapCount > 0
            ? "音声の欠落: \(presentation.audioGapCount) 回"
            : nil
        let processingIndicator: EngineProcessingIndicator
        switch presentation.processingState {
        case .idle:
            processingIndicator = .idle
        case .running:
            processingIndicator = .running
        case .backlogged:
            processingIndicator = .backlogged
        case .complete:
            processingIndicator = .complete
        case .partialFailure:
            processingIndicator = .partialFailure
        }

        return try EnginePresentationState(
            recordingStatusText: presentation.recordingStatusText,
            recordingTone: presentation.recordingTone,
            preparationPhase: presentation.preparationPhase,
            preparationStatusText: presentation.preparationStatusText,
            recoveryStatusText: presentation.recoveryStatusText,
            processingStatusText: presentation.processingStatusText,
            liveFailureNotices: presentation.liveFailureNotices,
            silenceWarningActive: silenceWarningText != nil,
            silenceWarningText: silenceWarningText,
            audioGapCount: presentation.audioGapCount,
            audioGapText: audioGapText,
            processingIndicator: processingIndicator
        )
    }

    func setRecordingStatus(_ text: String, tone: EngineRecordingTone) {
        presentation.recordingStatusText = text
        presentation.recordingTone = tone
    }

    func addLiveFailureNotice(_ text: String) {
        precondition(!text.isEmpty, "a live failure notice must not be empty")
        if !presentation.liveFailureNotices.contains(text) {
            presentation.liveFailureNotices.append(text)
        }
        if presentation.liveFailureNotices.count > Self.failureLimit {
            presentation.liveFailureNotices.removeFirst(
                presentation.liveFailureNotices.count - Self.failureLimit
            )
        }
        stateDidChange()
    }

    static func formatRecordingDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }

        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
