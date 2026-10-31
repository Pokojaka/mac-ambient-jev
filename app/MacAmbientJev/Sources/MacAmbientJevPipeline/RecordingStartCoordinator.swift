import Foundation
import MacAmbientJevCore

public enum RecordingStartFailure: Sendable, Equatable {
    case cancelled
    case failed(String)
}

/// Host-specific effects of starting a recording. The host owns the lifecycle value,
/// presentation, permission prompts and device configuration; `RecordingStartCoordinator`
/// owns the order of the steps and the cleanup after a failed start.
@MainActor
public protocol RecordingStartEffects: AnyObject {
    var recording: RecordingLifecycle { get set }
    /// Called right after the lifecycle enters `.starting`.
    func recordingStartDidBegin(sessionID: UUID)
    /// Creates the session folder and its initial files, and returns the session URL.
    func bootstrapSession(sessionID: UUID) throws -> URL
    /// Starts capture. `onFailure` reports a capture failure raised after this call began.
    func startCapture(
        sessionID: UUID,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async throws
    /// Called once capture runs. Moves the lifecycle to `.recording` and begins live transcription state.
    func markRecordingStarted(sessionID: UUID)
    /// Runs the failure stop path for a capture failure that arrived while starting.
    func captureDidFailDuringStart(sessionID: UUID, message: String)
    /// Called once capture runs and no failure is pending.
    func recordingDidStart(sessionID: UUID)
    /// Creates the live session. A throw leaves the recording running.
    func startLiveSession(sessionID: UUID) async throws
    func liveSessionStartDidFail(sessionID: UUID, error: any Error)
    /// Called before the failed start's session folder is judged.
    func recordingStartWillCleanUp()
    func recordingStartDidFail(_ failure: RecordingStartFailure)
    func refreshSavedSessions()
    func releaseIdleResourcesIfIdle()
}

public struct RecordingStartCoordinator {
    private let sessionsRoot: URL

    public init(sessionsRoot: URL) {
        self.sessionsRoot = sessionsRoot
    }

    @MainActor
    public func start(sessionID: UUID, effects: any RecordingStartEffects) async {
        effects.recording.start(sessionID: sessionID)
        effects.recordingStartDidBegin(sessionID: sessionID)

        var createdSessionURL: URL?
        do {
            createdSessionURL = try effects.bootstrapSession(sessionID: sessionID)
            try await effects.startCapture(
                sessionID: sessionID,
                onFailure: { [weak effects] message in
                    guard let effects else { return }
                    if !effects.recording.deferFailureWhileStarting(sessionID: sessionID, message: message) {
                        effects.captureDidFailDuringStart(sessionID: sessionID, message: message)
                    }
                }
            )
            effects.markRecordingStarted(sessionID: sessionID)
            if let failure = effects.recording.takePendingFailure(sessionID: sessionID) {
                effects.captureDidFailDuringStart(sessionID: sessionID, message: failure)
                return
            }
            effects.recordingDidStart(sessionID: sessionID)
            effects.refreshSavedSessions()
            do {
                try await effects.startLiveSession(sessionID: sessionID)
            } catch {
                guard effects.recording.isCurrentRecording(sessionID) else { return }
                effects.liveSessionStartDidFail(sessionID: sessionID, error: error)
            }
        } catch {
            _ = effects.recording.takePendingFailure(sessionID: sessionID)
            effects.recordingStartWillCleanUp()
            let removalFailure = cleanUpFailedStart(sessionURL: createdSessionURL, effects: effects)
            effects.recording.finish()
            if case AudioCaptureEngineError.cancelled = error, removalFailure == nil {
                effects.recordingStartDidFail(.cancelled)
            } else {
                effects.recordingStartDidFail(
                    .failed(
                        [error.localizedDescription, removalFailure]
                            .compactMap { $0 }.joined(separator: "。")
                    )
                )
            }
            effects.releaseIdleResourcesIfIdle()
        }
    }

    /// Keeps a session that holds captured audio or damaged durable data; removes an empty one.
    @MainActor
    private func cleanUpFailedStart(sessionURL: URL?, effects: any RecordingStartEffects) -> String? {
        guard let sessionURL else { return nil }
        let processing = SessionLayout(sessionURL: sessionURL).processingDirectory
        let keepSession: Bool
        do {
            let checkpoint = try AudioCheckpoint.loadRecovered(from: processing, relativeTo: sessionURL)
            keepSession = try checkpoint?.info.hasCapturedAudio ?? false
        } catch {
            // Damaged durable data must remain available for recovery/diagnosis.
            keepSession = true
        }
        if keepSession {
            effects.refreshSavedSessions()
            return nil
        }
        do {
            try SessionFileAccess.removeIfPresent(sessionURL, relativeTo: sessionsRoot)
            return nil
        } catch {
            effects.refreshSavedSessions()
            return "空の録音フォルダを削除できませんでした: \(error.localizedDescription)"
        }
    }
}
