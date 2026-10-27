import Foundation
import MacAmbientJevCore

public enum SessionMaintenanceIssue: Sendable, Equatable {
    case failed(String)
    case interruptedByShutdown(String)

    public var message: String {
        switch self {
        case .failed(let message), .interruptedByShutdown(let message):
            message
        }
    }
}

public struct SessionRecoveryStatusSnapshot: Sendable, Equatable {
    public let processing: String?
    public let transcript: String

    public init(processing: String?, transcript: String) {
        self.processing = processing
        self.transcript = transcript
    }
}

public enum SessionRecoveryEvent: Sendable, Equatable {
    case maintenanceStarted(Int)
    case maintenanceFinished(count: Int, previous: SessionRecoveryStatusSnapshot)
    case recovering(Int)
    case reportedFailures(
        scanFailures: [SessionRecoveryFailure],
        maintenanceFailures: [UUID: SessionMaintenanceIssue],
        hasRecoveries: Bool
    )
    case failed(String)
    case retryEmpty
    case retryFailed(String)

    public static func maintenanceStatusText(count: Int) -> String {
        "保存済み録音の音声を整理しています（\(count)件）"
    }
}

public struct SessionRecoveryFailureReport: Sendable, Equatable {
    public let message: String
    public let marksPartialFailure: Bool

    public init(
        scanFailures: [SessionRecoveryFailure],
        maintenanceFailures: [UUID: SessionMaintenanceIssue],
        hasRecoveries: Bool
    ) {
        var sentences: [String] = []
        if !scanFailures.isEmpty {
            sentences.append(
                "復旧できないセッションが\(scanFailures.count)件あります。詳細は「保存済み録音」で確認できます"
            )
        }

        let failedMaintenance = maintenanceFailures.values.compactMap { issue -> String? in
            guard case .failed = issue else { return nil }
            return issue.message
        }.sorted()
        if !failedMaintenance.isEmpty {
            let details = failedMaintenance.joined(separator: " / ")
            sentences.append(
                "保存済み録音の音声を整理できなかったセッションが\(failedMaintenance.count)件あります: \(details)"
            )
        }

        let interruptedMaintenance = maintenanceFailures.values.compactMap { issue -> String? in
            guard case .interruptedByShutdown = issue else { return nil }
            return issue.message
        }.sorted()
        if !interruptedMaintenance.isEmpty {
            let details = interruptedMaintenance.joined(separator: " / ")
            sentences.append(
                "終了処理のため保存済み録音の音声整理が中断されたセッションが\(interruptedMaintenance.count)件あります。次回起動時に再実行します: \(details)"
            )
        }

        message = sentences.joined(separator: "。")
        marksPartialFailure = !hasRecoveries && (!scanFailures.isEmpty || !failedMaintenance.isEmpty)
    }
}

@MainActor
public protocol SessionRecoveryEffects: AnyObject, Sendable {
    var recordingSessionID: UUID? { get }
    var recoveryStatusSnapshot: SessionRecoveryStatusSnapshot { get }
    func recoveryDidChange(_ event: SessionRecoveryEvent)
}
