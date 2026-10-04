import Foundation
import MacAmbientJevCore

public enum SessionExportLayout {
    public static let transcriptFilename = "transcript.txt"

    /// `<yyyy-MM-dd HHmm> <stem> <first 8 characters of the session ID>`. The stem is the
    /// imported file's name without its extension, or `録音` for a recording.
    public static func folderName(
        for session: SavedSession,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"

        let stem = switch session.source {
        case .recording:
            "録音"
        case .imported(let originalFilename):
            (originalFilename as NSString).deletingPathExtension
        }
        return [
            formatter.string(from: session.createdAt),
            stem,
            String(session.sessionID.uuidString.prefix(8)),
        ]
        .joined(separator: " ")
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
    }

    public static func audioFilename(for source: SessionAudioSource) -> String {
        switch source {
        case .recordedTimeline:
            return "audio.flac"
        case .importedOriginal(let originalURL):
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

public enum TranscriptTextRendererError: Error, LocalizedError, Equatable {
    case missingSpeakerHeading(segmentID: String)

    public var errorDescription: String? {
        switch self {
        case .missingSpeakerHeading(let segmentID):
            "話者分離されていない発話（\(segmentID)）があるため書き出せません"
        }
    }
}

/// Writes the rows the screen shows, one line per utterance:
/// `[mm:ss] <speakers joined by " / ">: <text with line breaks replaced by spaces>`.
public enum TranscriptTextRenderer {
    public static func render(_ segments: [MaterializedTranscriptSegment]) throws -> String {
        try LiveTranscriptProjection().rows(for: segments).map { row in
            guard !row.displaySpeakerLabels.isEmpty else {
                throw TranscriptTextRendererError.missingSpeakerHeading(segmentID: row.segmentID)
            }
            let totalSeconds = row.startMilliseconds / 1000
            let time = String(format: "%02lld:%02lld", totalSeconds / 60, totalSeconds % 60)
            let speakers = row.displaySpeakerLabels.joined(separator: " / ")
            return "[\(time)] \(speakers): \(singleLine(row.text))\n"
        }
        .joined()
    }

    /// Each line break (CRLF, LF, CR, U+2028, U+2029) becomes one space.
    private static func singleLine(_ text: String) -> String {
        String(text.map { character in
            character.isNewline ? " " : character
        })
    }
}

public enum SessionExportError: Error, LocalizedError, Equatable {
    case audioUnavailable
    case transcriptCorrupted(String)
    case noTranscript
    case stagingNotRemoved(path: String, exportFailure: String, cleanupFailure: String)

    public var errorDescription: String? {
        switch self {
        case .audioUnavailable:
            "保存済み音声を使えないため書き出せません"
        case .transcriptCorrupted(let reason):
            "文字起こしデータが破損しているため書き出せません: \(reason)"
        case .noTranscript:
            "確定文字起こしがないため書き出せません"
        case .stagingNotRemoved(let path, let exportFailure, let cleanupFailure):
            "書き出せませんでした: \(exportFailure)。作業用フォルダー \(path) も削除できませんでした: \(cleanupFailure)"
        }
    }
}

public struct SessionExporter: Sendable {
    public init() {}

    /// Writes into a hidden sibling first so an interrupted export never leaves
    /// a half-written folder under the final name.
    @discardableResult
    public func export(
        session: SavedSession,
        sessionsRoot: URL,
        to directory: URL,
        timeZone: TimeZone
    ) throws -> URL {
        guard let audioSource = session.audioSource else { throw SessionExportError.audioUnavailable }
        if case .corrupted(let reason) = session.processingStatus {
            throw SessionExportError.transcriptCorrupted(reason)
        }

        let layout = SessionLayout(sessionURL: session.sessionURL)
        guard case .segments(let segments) = try SavedTranscriptLoader.load(
            sessionURL: layout.sessionURL,
            audioSource: audioSource
        ) else {
            throw SessionExportError.noTranscript
        }
        let transcript = try TranscriptTextRenderer.render(segments)

        let fileManager = FileManager.default
        let folderName = SessionExportLayout.folderName(for: session, timeZone: timeZone)
        let destination = directory.appending(path: folderName, directoryHint: .isDirectory)
        let staging = directory.appending(path: ".\(folderName).partial", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            try Data(transcript.utf8).write(
                to: staging.appending(path: SessionExportLayout.transcriptFilename)
            )
            let audioURL = staging.appending(path: SessionExportLayout.audioFilename(for: audioSource))
            switch audioSource {
            case .recordedTimeline(let checkpoint):
                try ProcessingTimelineAudioExporter(
                    framesPerBuffer: max(1, Int64(checkpoint.sampleRate * 10))
                ).export(
                    reader: ProcessingTimelineReader(
                        directory: layout.processingDirectory,
                        checkpoint: checkpoint
                    ),
                    to: audioURL,
                    encoding: .flac24
                )
            case .importedOriginal(let originalURL):
                try fileManager.copyItem(at: originalURL, to: audioURL)
            }

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            if fileManager.fileExists(atPath: staging.path) {
                do {
                    try fileManager.removeItem(at: staging)
                } catch let cleanupError {
                    throw SessionExportError.stagingNotRemoved(
                        path: staging.path,
                        exportFailure: error.localizedDescription,
                        cleanupFailure: cleanupError.localizedDescription
                    )
                }
            }
            throw error
        }
        return destination
    }
}
