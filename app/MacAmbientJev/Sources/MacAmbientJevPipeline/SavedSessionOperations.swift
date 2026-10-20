import Foundation
import MacAmbientJevCore

public enum SessionExportState: Sendable, Equatable {
    case exporting
    case exported(URL)
    case failed(String)
}

public enum SessionExportStart: Sendable, Equatable {
    case alreadyExporting
    case blocked(String)
    case ready
}

public struct SavedSessionOperations: Sendable {
    public private(set) var sessions: [SavedSessionSummary] = []
    public private(set) var selectedSessionURL: URL?
    public private(set) var exports: [UUID: SessionExportState] = [:]

    public init() {}

    mutating func replaceSessions(_ sessions: [SavedSessionSummary]) {
        self.sessions = sessions
    }

    public mutating func refresh(sessionsRoot: URL) throws {
        sessions = try SavedSessionCatalog(fileManager: .default).list(sessionsRoot: sessionsRoot)
    }

    @discardableResult
    public mutating func select(sessionURL: URL, isRecording: Bool) -> Bool {
        guard SavedSessionSelectionPolicy.canSelect(isRecording: isRecording) else {
            return false
        }
        selectedSessionURL = sessionURL
        return true
    }

    public mutating func clearSelection() {
        selectedSessionURL = nil
    }

    public func readableSession(_ id: UUID) -> SavedSession? {
        let matches = sessions.filter { $0.sessionID == id }
        guard matches.count == 1, case .readable(let session) = matches[0] else {
            return nil
        }
        return session
    }

    public mutating func resetExportDestination() {
        exports = [:]
    }

    public mutating func beginExport(
        _ session: SavedSession,
        isMaintainingStorage: Bool
    ) -> SessionExportStart {
        guard exports[session.sessionID] != .exporting else {
            return .alreadyExporting
        }
        if isMaintainingStorage, case .recordedPCM = session.audioSource {
            let message = "保存済み録音の音声を整理しています。整理が終わってから書き出してください"
            exports[session.sessionID] = .failed(message)
            return .blocked(message)
        }
        exports[session.sessionID] = .exporting
        return .ready
    }

    public mutating func completeExport(sessionID: UUID, folder: URL) {
        exports[sessionID] = .exported(folder)
    }

    public mutating func failExport(sessionID: UUID, message: String) {
        exports[sessionID] = .failed(message)
    }

    public mutating func recordExistingExport(_ state: SessionExportState, sessionID: UUID) {
        guard exports[sessionID] == nil else {
            return
        }
        exports[sessionID] = state
    }
}
