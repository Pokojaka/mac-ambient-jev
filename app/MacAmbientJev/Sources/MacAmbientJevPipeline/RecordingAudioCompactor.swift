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
    /// Optional callback at durable boundaries; production checks cancellation at each boundary.
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
        try Task.checkCancellation()
        let store = SessionAudioStorageStore(layout: layout)
        let info: TimelineAudioInfo
        switch try store.load() {
        case .importedOriginal:
            throw RecordingAudioCompactorError.notARecording
        case .recordingFLAC(let stored):
            try FLACTimelineReader(url: layout.recordingFLACURL, info: stored, sessionURL: layout.sessionURL).validateAudio()
            info = stored
        case .recordingPCM:
            info = try publishFLAC(layout: layout)
            try store.save(.recordingFLAC(info))
            try notify(.stateSaved)
        }
        try removePCM(layout: layout)
        return info
    }

    private func publishFLAC(layout: SessionLayout) throws -> TimelineAudioInfo {
        guard let checkpoint = try AudioCheckpoint.loadRecovered(from: layout.processingDirectory, relativeTo: layout.sessionURL),
              checkpoint.committedFrames > 0 else {
            throw RecordingAudioCompactorError.emptyRecording
        }
        let pcm = try ProcessingTimelineReader(directory: layout.processingDirectory, checkpoint: checkpoint, sessionURL: layout.sessionURL)
        try pcm.validateAudio()
        try Task.checkCancellation()
        try SessionFileAccess.removeIfPresent(layout.recordingFLACPartialURL, relativeTo: layout.sessionURL)

        if try SessionFileAccess.isDirectoryIfPresent(layout.recordingFLACURL, relativeTo: layout.sessionURL) != nil {
            let isValid = try validatePublishedFLACOrRemoveIfInvalid(
                validation: {
                    try FLACTimelineReader(url: layout.recordingFLACURL, info: pcm.info, sessionURL: layout.sessionURL)
                        .validateAudio(against: pcm)
                },
                removeInvalid: {
                    try SessionFileAccess.removeIfPresent(layout.recordingFLACURL, relativeTo: layout.sessionURL)
                }
            )
            if isValid { return pcm.info }
        }

        let partial = layout.recordingFLACPartialURL
        try RecordingFLAC.write(reader: pcm, to: partial, sessionURL: layout.sessionURL)
        try notify(.partialWritten)
        try DurableFile.synchronize(partial, relativeTo: layout.sessionURL)
        try notify(.partialSynchronized)
        try FLACTimelineReader(url: partial, info: pcm.info, sessionURL: layout.sessionURL).validateAudio(against: pcm)
        try notify(.partialVerified)
        try DurableFile.rename(partial, to: layout.recordingFLACURL, relativeTo: layout.sessionURL)
        try notify(.published)
        return pcm.info
    }

    private func removePCM(layout: SessionLayout) throws {
        try Task.checkCancellation()
        if try SessionFileAccess.isDirectoryIfPresent(layout.processingDirectory, relativeTo: layout.sessionURL) != nil {
            try notify(.pcmRemovalStarted)
            try Task.checkCancellation()
            try SessionFileAccess.removeIfPresent(layout.processingDirectory, relativeTo: layout.sessionURL)
            try DurableFile.synchronize(layout.audioDirectory, relativeTo: layout.sessionURL, isDirectory: true)
        }
        try Task.checkCancellation()
        try SessionFileAccess.removeIfPresent(layout.recordingFLACPartialURL, relativeTo: layout.sessionURL)
    }

    private func notify(_ boundary: Boundary) throws {
        try Task.checkCancellation()
        try interrupt?(boundary)
        try Task.checkCancellation()
    }

}

func validatePublishedFLACOrRemoveIfInvalid(
    validation: () throws -> Void,
    removeInvalid: () throws -> Void
) throws -> Bool {
    do {
        try validation()
        return true
    } catch let error as CancellationError {
        throw error
    } catch {
        try Task.checkCancellation()
        try removeInvalid()
        return false
    }
}

/// Runs the storage work `SessionStorageMaintenance.required` reported for a session.
public enum SessionStorageMaintainer {
    public static func run(
        _ maintenance: SessionStorageMaintenance, layout: SessionLayout, manifest: SessionManifest
    ) throws {
        try Task.checkCancellation()
        switch maintenance {
        case .compactRecording:
            _ = try RecordingAudioCompactor(interrupt: { _ in try Task.checkCancellation() }).compact(layout: layout)
        case .removeTransients:
            break
        }
        try Task.checkCancellation()
        try SessionTransientAudio.remove(layout: layout, source: manifest.source)
    }
}

extension SessionStorageMaintainer {
    /// Runs each item in order and returns failed or uncompleted sessions by session ID.
    /// If cancelled, the current and all unprocessed items are reported as uncompleted;
    /// completed items are absent. `willMaintain` receives the item count first, and an empty
    /// list returns at once.
    public static func maintain(
        _ items: [SessionMaintenanceCandidate],
        willMaintain: @Sendable (Int) async -> Void
    ) async -> [UUID: String] {
        await maintain(items, willMaintain: willMaintain, perform: { item in
            let layout = SessionLayout(sessionURL: item.sessionURL)
            try run(item.maintenance, layout: layout, manifest: try layout.loadManifest())
        })
    }

    static func maintain(
        _ items: [SessionMaintenanceCandidate],
        willMaintain: @Sendable (Int) async -> Void,
        perform: @Sendable (SessionMaintenanceCandidate) throws -> Void
    ) async -> [UUID: String] {
        guard !items.isEmpty else { return [:] }
        await willMaintain(items.count)
        var failures: [UUID: String] = [:]
        func markUncompleted(from index: Int) {
            for item in items[index...] {
                failures[item.sessionID] = "\(item.sessionURL.lastPathComponent): 保存整理が中断されたため未完了です"
            }
        }

        for (index, item) in items.enumerated() {
            if Task.isCancelled {
                markUncompleted(from: index)
                break
            }
            do {
                try perform(item)
            } catch is CancellationError {
                markUncompleted(from: index)
                break
            } catch {
                failures[item.sessionID] = "\(item.sessionURL.lastPathComponent): \(error.localizedDescription)"
                if Task.isCancelled {
                    markUncompleted(from: index + 1)
                    break
                }
            }
        }
        return failures
    }
}
