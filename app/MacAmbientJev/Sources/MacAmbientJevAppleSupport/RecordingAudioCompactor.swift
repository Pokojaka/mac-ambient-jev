import Foundation
import MacAmbientJevCore

public enum RecordingAudioCompactorError: LocalizedError, Equatable {
    case notARecording
    case emptyRecording

    public var errorDescription: String? {
        switch self {
        case .notARecording:
            "録音ではないセッションの音声は FLAC に変換できません"
        case .emptyRecording:
            "FLAC に変換できる録音音声がありません"
        }
    }
}

/// Converts a finalized PCM recording to `audio/recording.flac` and removes the PCM.
/// `audio/storage.json` switches authority only after the FLAC is verified and published.
public struct RecordingAudioCompactor: Sendable {
    /// Durable boundaries where tests can stop the process. Production passes nil.
    public enum Boundary: Sendable, Equatable {
        case partialWritten, partialSynchronized, partialVerified, published, stateSaved, pcmRemovalStarted
    }

    private let interrupt: (@Sendable (Boundary) throws -> Void)?

    public init(interrupt: (@Sendable (Boundary) throws -> Void)?) {
        self.interrupt = interrupt
    }

    /// Converges whatever is on disk to: storage `recordingFLAC(info)`, a verified
    /// `audio/recording.flac`, no `audio/processing`, no partial. Idempotent; safe to call
    /// again after a crash at any boundary. Returns the stored info.
    public func compact(layout: SessionLayout) throws -> TimelineAudioInfo {
        let store = SessionAudioStorageStore(layout: layout)
        let info: TimelineAudioInfo
        switch try store.load() {
        case .importedOriginal:
            throw RecordingAudioCompactorError.notARecording
        case .recordingFLAC(let stored):
            try FLACTimelineReader(url: layout.recordingFLACURL, info: stored).validateAudio()
            info = stored
        case .recordingPCM:
            info = try publishFLAC(layout: layout)
            try store.save(.recordingFLAC(info))
            try interrupt?(.stateSaved)
        }
        try removePCM(layout: layout)
        return info
    }

    private func publishFLAC(layout: SessionLayout) throws -> TimelineAudioInfo {
        guard let checkpoint = try AudioCheckpoint.loadRecovered(from: layout.processingDirectory),
              checkpoint.committedFrames > 0 else {
            throw RecordingAudioCompactorError.emptyRecording
        }
        let pcm = try ProcessingTimelineReader(directory: layout.processingDirectory, checkpoint: checkpoint)
        try pcm.validateAudio()
        try removeIfPresent(layout.recordingFLACPartialURL)

        if FileManager.default.fileExists(atPath: layout.recordingFLACURL.path) {
            do {
                try FLACTimelineReader(url: layout.recordingFLACURL, info: pcm.info).validateAudio(against: pcm)
                return pcm.info
            } catch {
                try removeIfPresent(layout.recordingFLACURL)
            }
        }

        let partial = layout.recordingFLACPartialURL
        try RecordingFLAC.write(reader: pcm, to: partial)
        try interrupt?(.partialWritten)
        try DurableFile.synchronize(partial)
        try interrupt?(.partialSynchronized)
        try FLACTimelineReader(url: partial, info: pcm.info).validateAudio(against: pcm)
        try interrupt?(.partialVerified)
        try DurableFile.rename(partial, to: layout.recordingFLACURL)
        try interrupt?(.published)
        return pcm.info
    }

    private func removePCM(layout: SessionLayout) throws {
        if FileManager.default.fileExists(atPath: layout.processingDirectory.path) {
            try interrupt?(.pcmRemovalStarted)
            try FileManager.default.removeItem(at: layout.processingDirectory)
            try DurableFile.synchronize(layout.audioDirectory)
        }
        try removeIfPresent(layout.recordingFLACPartialURL)
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Runs the storage work `SessionStorageMaintenance.required` reported for a session.
public enum SessionStorageMaintainer {
    public static func run(
        _ maintenance: SessionStorageMaintenance, layout: SessionLayout, manifest: SessionManifest
    ) throws {
        switch maintenance {
        case .compactRecording:
            _ = try RecordingAudioCompactor(interrupt: nil).compact(layout: layout)
        case .removeTransients:
            break
        }
        try SessionTransientAudio.remove(layout: layout, source: manifest.source)
    }
}

extension SessionStorageMaintainer {
    /// Runs every item to completion, one after another, and returns each failed session's message
    /// by session ID. `willMaintain` receives the item count first; an empty list returns at once.
    public static func maintain(
        _ items: [SessionMaintenanceCandidate],
        willMaintain: @Sendable (Int) async -> Void
    ) async -> [UUID: String] {
        guard !items.isEmpty else { return [:] }
        await willMaintain(items.count)
        var failures: [UUID: String] = [:]
        for item in items {
            do {
                let layout = SessionLayout(sessionURL: item.sessionURL)
                try run(item.maintenance, layout: layout, manifest: try layout.loadManifest())
            } catch {
                failures[item.sessionID] = "\(item.sessionURL.lastPathComponent): \(error.localizedDescription)"
            }
        }
        return failures
    }
}
