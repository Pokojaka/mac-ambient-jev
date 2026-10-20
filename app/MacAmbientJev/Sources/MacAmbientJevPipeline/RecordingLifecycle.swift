import Foundation

public enum RecordingPhase: Sendable, Equatable {
    case idle
    case requestingPermission
    case starting
    case recording
    case stopping
    case importing
}

public struct RecordingLifecycle: Sendable {
    public private(set) var phase: RecordingPhase = .idle
    public private(set) var sessionID: UUID?
    private var pendingFailure: (sessionID: UUID, message: String)?

    public init() {}

    public mutating func requestPermission() {
        precondition(phase == .idle, "権限要求を開始できるのは待機中だけです")
        phase = .requestingPermission
    }

    public mutating func start(sessionID: UUID) {
        precondition(
            phase == .idle || phase == .requestingPermission,
            "録音を開始できるのは待機中または権限要求中だけです"
        )
        self.sessionID = sessionID
        phase = .starting
        pendingFailure = nil
    }

    public mutating func didStart(sessionID: UUID) {
        precondition(
            phase == .starting && self.sessionID == sessionID,
            "録音開始通知のセッションが開始中のセッションと一致しません"
        )
        phase = .recording
    }

    public mutating func beginStopping(sessionID: UUID) -> Bool {
        guard isCurrentRecording(sessionID) else { return false }
        phase = .stopping
        return true
    }

    public mutating func beginImport() {
        precondition(phase == .idle, "インポートを開始できるのは待機中だけです")
        phase = .importing
    }

    public mutating func finish() {
        sessionID = nil
        pendingFailure = nil
        phase = .idle
    }

    public func isCurrentRecording(_ sessionID: UUID) -> Bool {
        self.sessionID == sessionID && phase == .recording
    }

    public mutating func deferFailureWhileStarting(sessionID: UUID, message: String) -> Bool {
        guard phase == .starting && self.sessionID == sessionID else { return false }
        pendingFailure = (sessionID, message)
        return true
    }

    public mutating func takePendingFailure(sessionID: UUID) -> String? {
        guard let pendingFailure, pendingFailure.sessionID == sessionID else { return nil }
        self.pendingFailure = nil
        return pendingFailure.message
    }
}
