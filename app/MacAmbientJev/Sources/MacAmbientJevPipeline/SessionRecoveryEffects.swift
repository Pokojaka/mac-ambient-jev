import Foundation
import MacAmbientJevCore

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
        maintenanceFailures: [UUID: String],
        hasRecoveries: Bool
    )
    case failed(String)
    case retryEmpty
    case retryFailed(String)
}

@MainActor
public protocol SessionRecoveryEffects: AnyObject, Sendable {
    var recordingSessionID: UUID? { get }
    var recoveryStatusSnapshot: SessionRecoveryStatusSnapshot { get }
    func recoveryDidChange(_ event: SessionRecoveryEvent)
}
