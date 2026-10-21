import Foundation

public enum RecordingFinishOutcome: Sendable, Equatable {
    case saved(
        result: AudioCaptureStopResult,
        failureMessage: String?,
        vadFailureText: String?,
        vadSegmentCount: Int
    )
    case failed(String?)
}

@MainActor
public protocol RecordingFinishEffects: AnyObject {
    func stopCapture() async throws -> AudioCaptureStopResult
    func captureStopped(dropoutCount: UInt64)
    func recordingDidFinish(_ outcome: RecordingFinishOutcome)
    func refreshSavedSessions()
    func releaseIdleResourcesIfIdle()
}
