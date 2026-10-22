import Foundation

/// Builds a processing timeline from a stored-original audio input.
/// The builder does not copy or import the original; callers provide
/// `SessionLayout.processingDirectory` as `processingDirectory`.
/// Decode errors propagate to the caller, and cleanup is owned by the session finalizer.
public protocol ImportedAudioTimelineBuilding: Sendable {
    func build(from sourceURL: URL, into processingDirectory: URL, sessionURL: URL) async throws -> AudioCheckpoint
}
