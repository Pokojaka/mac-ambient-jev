import Foundation

/// File locations inside one session folder.
public struct SessionLayout: Sendable, Equatable {
    public let sessionURL: URL

    public init(sessionURL: URL) {
        self.sessionURL = sessionURL
    }

    public var manifestURL: URL {
        sessionURL.appending(path: "session.json")
    }

    public var eventsURL: URL {
        sessionURL.appending(path: "events.jsonl")
    }

    public var processingMetadataURL: URL {
        sessionURL.appending(path: "processing_metadata.json")
    }

    public var audioDirectory: URL {
        sessionURL.appending(path: "audio", directoryHint: .isDirectory)
    }

    public var processingDirectory: URL {
        audioDirectory.appending(path: "processing", directoryHint: .isDirectory)
    }

    public var derivedDirectory: URL {
        audioDirectory.appending(path: "derived", directoryHint: .isDirectory)
    }

    /// The imported source file: exactly one regular file named `original` or `original.*` in `audio/`.
    public func importedOriginalURL() throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: audioDirectory.path) else {
            throw SessionAudioSourceError.importedOriginalMissing
        }
        let originals = try fileManager.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.lastPathComponent == "original" || url.lastPathComponent.hasPrefix("original.")
        }
        var regularFiles: [URL] = []
        for url in originals
        where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            regularFiles.append(url)
        }
        switch regularFiles.count {
        case 0:
            throw SessionAudioSourceError.importedOriginalMissing
        case 1:
            return regularFiles[0]
        default:
            throw SessionAudioSourceError.multipleImportedOriginals(
                regularFiles.map(\.lastPathComponent).sorted()
            )
        }
    }

    /// The session's source audio, chosen only by how the session was created.
    /// Returns nil for a recording that captured no audio.
    public func audioSource(for manifest: SessionManifest) throws -> SessionAudioSource? {
        switch manifest.source {
        case .recording:
            guard let checkpoint = try AudioCheckpoint.loadRecovered(from: processingDirectory),
                  checkpoint.committedFrames > 0 else {
                return nil
            }
            try ProcessingTimelineReader(directory: processingDirectory, checkpoint: checkpoint)
                .validateChunkFiles()
            return .recordedTimeline(checkpoint)
        case .imported:
            return .importedOriginal(try importedOriginalURL())
        }
    }
}

public enum SessionAudioSource: Sendable, Equatable {
    /// A recording: the processing timeline is the source audio.
    case recordedTimeline(AudioCheckpoint)
    /// An import: the original file is the source audio; its timeline is rebuilt on every run.
    case importedOriginal(URL)
}

public enum SessionAudioSourceError: Error, LocalizedError, Equatable {
    case importedOriginalMissing
    case multipleImportedOriginals([String])

    public var errorDescription: String? {
        switch self {
        case .importedOriginalMissing:
            "取り込んだ元の音声ファイルがありません"
        case .multipleImportedOriginals(let names):
            "取り込んだ元の音声ファイルが複数あります: \(names.joined(separator: ", "))"
        }
    }
}
