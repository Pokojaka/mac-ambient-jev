import Foundation
import MacAmbientJevCore

public enum SessionExportLayout {
    public static let transcriptFilename = "transcript.txt"

    public static func folderName(
        for session: SavedSessionSummary,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"

        let stem = session.originalFilename
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "録音"
        let parts = [
            session.createdAt.map(formatter.string(from:)),
            stem,
            String(session.sessionID.uuidString.prefix(8)),
        ]
        return parts.compactMap { $0 }.joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    public static func audioFilename(for source: SavedSessionAudioSource) -> String {
        switch source {
        case .processingTimeline:
            return "audio.flac"
        case .importedOriginal(let originalURL):
            let ext = originalURL.pathExtension
            return ext.isEmpty ? "audio" : "audio.\(ext)"
        }
    }
}

public enum TranscriptTextRenderer {
    public static func render(_ segments: [MaterializedTranscriptSegment]) -> String {
        LiveTranscriptProjection().rows(for: segments).map { row in
            let totalSeconds = row.startMilliseconds / 1000
            let time = String(format: "%02lld:%02lld", totalSeconds / 60, totalSeconds % 60)
            let speaker = row.displaySpeakerLabels.first
                ?? SpeakerDisplayMapper.label(for: nil, labels: [:])
            return "[\(time)] \(speaker): \(row.text)\n"
        }
        .joined()
    }
}

public enum SessionExportError: Error, LocalizedError, Equatable {
    case sessionUnreadable
    case audioUnavailable
    case noTranscript

    public var errorDescription: String? {
        switch self {
        case .sessionUnreadable:
            "保存セッションを読み込めないため書き出せません"
        case .audioUnavailable:
            "保存済み音声がないため書き出せません"
        case .noTranscript:
            "確定文字起こしがないため書き出せません"
        }
    }
}

public struct SessionExporter: Sendable {
    public init() {}

    /// Writes into a hidden sibling first so an interrupted export never leaves
    /// a half-written folder under the final name.
    @discardableResult
    public func export(
        session: SavedSessionSummary,
        sessionsRoot: URL,
        to directory: URL
    ) throws -> URL {
        guard session.errorMessage == nil else { throw SessionExportError.sessionUnreadable }
        guard let audioSource = session.audioSource else { throw SessionExportError.audioUnavailable }

        let sessionURL = sessionsRoot.appending(
            path: session.sessionID.uuidString,
            directoryHint: .isDirectory
        )
        guard case .segments(let segments) = try SavedTranscriptLoader.load(
            sessionURL: sessionURL,
            audioSource: audioSource
        ) else {
            throw SessionExportError.noTranscript
        }

        let fileManager = FileManager.default
        let folderName = SessionExportLayout.folderName(for: session)
        let destination = directory.appending(path: folderName, directoryHint: .isDirectory)
        let staging = directory.appending(path: ".\(folderName).partial", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            try Data(TranscriptTextRenderer.render(segments).utf8).write(
                to: staging.appending(path: SessionExportLayout.transcriptFilename)
            )
            let audioURL = staging.appending(path: SessionExportLayout.audioFilename(for: audioSource))
            switch audioSource {
            case .processingTimeline(let checkpoint):
                try ProcessingTimelineAudioExporter(
                    framesPerBuffer: max(1, Int64(checkpoint.sampleRate * 10))
                ).export(
                    reader: ProcessingTimelineReader(
                        directory: sessionURL.appending(path: "audio/processing", directoryHint: .isDirectory),
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
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return destination
    }
}
