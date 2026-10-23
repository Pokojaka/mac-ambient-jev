import Foundation
import MacAmbientJevCore

public enum SessionExportLayout {
    public static let transcriptFilename = "transcript.txt"

    public static func audioFilename(for source: SessionAudioSource) -> String {
        switch source {
        case .recordedPCM, .recordedFLAC:
            return "audio.flac"
        case .importedOriginal(let originalURL, _):
            let ext = originalURL.pathExtension
            return ext.isEmpty ? "audio" : "audio.\(ext)"
        }
    }

    /// An export is complete when its folder holds `transcript.txt` and the audio file.
    public static func isCompleteExport(folder: URL, audioSource: SessionAudioSource) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: folder.appending(path: transcriptFilename).path)
            && fileManager.fileExists(atPath: folder.appending(path: audioFilename(for: audioSource)).path)
    }
}

public enum SessionExportError: Error, LocalizedError, Equatable {
    case audioUnavailable
    case recordingNotCompacted
    case transcriptCorrupted(String)
    case noTranscript
    case stagingNotRemoved(path: String, exportFailure: String, cleanupFailure: String)
    case previousExportNotRestored(path: String, exportFailure: String, restoreFailure: String)
    case previousExportNotRemoved(path: String, cleanupFailure: String)

    public var errorDescription: String? {
        switch self {
        case .audioUnavailable:
            "保存済み音声を使えないため書き出せません"
        case .recordingNotCompacted:
            "録音の FLAC 化が終わっていないため書き出せません。確定処理をやり直してください"
        case .transcriptCorrupted(let reason):
            "文字起こしデータが破損しているため書き出せません: \(reason)"
        case .noTranscript:
            "確定文字起こしがないため書き出せません"
        case .stagingNotRemoved(let path, let exportFailure, let cleanupFailure):
            "書き出せませんでした: \(exportFailure)。作業用フォルダー \(path) も削除できませんでした: \(cleanupFailure)"
        case .previousExportNotRestored(let path, let exportFailure, let restoreFailure):
            "書き出せませんでした: \(exportFailure)。以前の書き出しを元の名前へ戻せませんでした（\(path) に残っています）: \(restoreFailure)"
        case .previousExportNotRemoved(let path, let cleanupFailure):
            "書き出しは完了しましたが、置き換えた以前の書き出し \(path) を削除できませんでした: \(cleanupFailure)"
        }
    }
}

/// Writes the GUI export bundle: a UTF-8 `transcript.txt` and the session's audio.
/// Every filesystem step runs through `SessionFileAccess`, anchored at the export directory.
public struct SessionExporter: Sendable {
    /// The directory removals and renames that publication depends on; tests substitute failing ones.
    struct DirectoryOperations: Sendable {
        var remove: @Sendable (_ url: URL, _ root: URL) throws -> Void
        var rename: @Sendable (_ source: URL, _ destination: URL, _ root: URL) throws -> Void

        static let live = DirectoryOperations(
            remove: { try SessionFileAccess.removeIfPresent($0, relativeTo: $1) },
            rename: { try SessionFileAccess.renameDirectory($0, to: $1, relativeTo: $2) }
        )
    }

    private let operations: DirectoryOperations

    public init() {
        self.init(operations: .live)
    }

    init(operations: DirectoryOperations) {
        self.operations = operations
    }

    /// Stages the bundle in a hidden sibling and publishes it under the session folder name.
    /// Replacing an earlier export moves it aside first and restores it if publication fails,
    /// so a failed export never deletes the old bundle.
    @discardableResult
    public func export(session: SavedSession, to directory: URL) throws -> URL {
        if case .corrupted(let reason) = session.processingStatus {
            throw SessionExportError.transcriptCorrupted(reason)
        }

        let layout = SessionLayout(sessionURL: session.sessionURL)
        guard let audioSource = try layout.audioSource(for: layout.loadManifest()) else {
            throw SessionExportError.audioUnavailable
        }
        guard case .segments(let segments) = try SavedTranscriptLoader.load(
            sessionURL: layout.sessionURL,
            audioSource: audioSource
        ) else {
            throw SessionExportError.noTranscript
        }
        let transcript = Data(try TranscriptTextRenderer.render(segments).utf8)
        let audioSourceURL: URL
        switch audioSource {
        case .recordedPCM:
            throw SessionExportError.recordingNotCompacted
        case .recordedFLAC(let info):
            try FLACTimelineReader(url: layout.recordingFLACURL, info: info, sessionURL: layout.sessionURL).validateAudio()
            audioSourceURL = layout.recordingFLACURL
        case .importedOriginal(let originalURL, _):
            audioSourceURL = originalURL
        }

        let folderName = session.sessionURL.lastPathComponent
        let sessionID = session.sessionID.uuidString.lowercased()
        // Symbolic links in the chosen destination resolve once here; everything below it must be real.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.resolvingSymlinksInPath()
        let destination = root.appending(path: folderName, directoryHint: .isDirectory)
        let staging = root.appending(path: ".export-\(sessionID).partial", directoryHint: .isDirectory)
        let previous = root.appending(path: ".export-\(sessionID).previous", directoryHint: .isDirectory)

        try recoverInterruptedReplacement(destination: destination, previous: previous, root: root)
        try SessionFileAccess.removeIfPresent(staging, relativeTo: root)
        try SessionFileAccess.createExclusiveDirectory(staging, relativeTo: root)

        do {
            try SessionFileAccess.writeAtomically(
                transcript,
                to: staging.appending(path: SessionExportLayout.transcriptFilename),
                relativeTo: root
            )
            try SessionFileAccess.copy(
                audioSourceURL, relativeTo: layout.sessionURL,
                to: staging.appending(path: SessionExportLayout.audioFilename(for: audioSource)), relativeTo: root
            )
            try publish(staging: staging, destination: destination, previous: previous, root: root)
        } catch {
            do {
                try operations.remove(staging, root)
            } catch let cleanupError {
                throw SessionExportError.stagingNotRemoved(
                    path: staging.path,
                    exportFailure: error.localizedDescription,
                    cleanupFailure: cleanupError.localizedDescription
                )
            }
            throw error
        }
        do {
            try operations.remove(previous, root)
        } catch {
            throw SessionExportError.previousExportNotRemoved(path: previous.path, cleanupFailure: error.localizedDescription)
        }
        return directory.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// A crash between moving the old bundle aside and publishing the new one leaves only the
    /// aside copy; put it back under its name, or drop it when a bundle was published since.
    private func recoverInterruptedReplacement(destination: URL, previous: URL, root: URL) throws {
        guard try SessionFileAccess.isDirectoryIfPresent(previous, relativeTo: root) != nil else { return }
        if try SessionFileAccess.isDirectoryIfPresent(destination, relativeTo: root) == nil {
            try operations.rename(previous, destination, root)
        } else {
            try operations.remove(previous, root)
        }
    }

    private func publish(staging: URL, destination: URL, previous: URL, root: URL) throws {
        guard try SessionFileAccess.isDirectoryIfPresent(destination, relativeTo: root) != nil else {
            try operations.rename(staging, destination, root)
            return
        }
        try operations.rename(destination, previous, root)
        do {
            try operations.rename(staging, destination, root)
        } catch let publishError {
            do {
                try operations.rename(previous, destination, root)
            } catch let restoreError {
                throw SessionExportError.previousExportNotRestored(
                    path: previous.path,
                    exportFailure: publishError.localizedDescription,
                    restoreFailure: restoreError.localizedDescription
                )
            }
            throw publishError
        }
    }
}
