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

    public func loadManifest() throws -> SessionManifest {
        let data = try SessionFileAccess.read(manifestURL, relativeTo: sessionURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SessionManifest.self, from: data)
        } catch let error as DecodingError {
            throw SessionRecoveryScannerError.unreadableManifest(String(describing: error))
        }
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

    /// Exists only while a finalization runs; it holds the diarization input CAF.
    public var derivedDirectory: URL {
        audioDirectory.appending(path: "derived", directoryHint: .isDirectory)
    }

    public var diarizationInputURL: URL {
        derivedDirectory.appending(path: "diarization-input.caf")
    }

    public var audioStorageURL: URL {
        audioDirectory.appending(path: "storage.json")
    }

    public var recordingFLACURL: URL {
        audioDirectory.appending(path: "recording.flac")
    }

    public var recordingFLACPartialURL: URL {
        audioDirectory.appending(path: ".recording.flac.partial")
    }

    /// The imported source file: exactly one regular file named `original` or `original.*` in `audio/`.
    public func importedOriginalURL() throws -> URL {
        let originals: [URL]
        do {
            originals = try SessionFileAccess.contentsOfDirectory(audioDirectory, relativeTo: sessionURL)
                .filter { $0.lastPathComponent == "original" || $0.lastPathComponent.hasPrefix("original.") }
        } catch let error as CocoaError where (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOENT) {
            throw SessionAudioSourceError.importedOriginalMissing
        }
        for url in originals {
            _ = try SessionFileAccess.fileSize(url, relativeTo: sessionURL)
        }
        let regularFiles = originals
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

    /// The session's source audio, chosen by the authoritative `audio/storage.json` state.
    /// Returns nil for a recording that captured no audio. Structural checks only: a FLAC
    /// recording must still be decoded and verified before its samples are used.
    public func audioSource(for manifest: SessionManifest) throws -> SessionAudioSource? {
        let storage = try SessionAudioStorageStore(layout: self).load()
        try storage.validate(for: manifest.source)
        switch storage {
        case .recordingPCM:
            guard let checkpoint = try AudioCheckpoint.loadRecovered(from: processingDirectory, relativeTo: sessionURL),
                  checkpoint.committedFrames > 0 else {
                return nil
            }
            try ProcessingTimelineReader(directory: processingDirectory, checkpoint: checkpoint, sessionURL: sessionURL).validateAudio()
            return .recordedPCM(checkpoint)
        case .recordingFLAC(let info):
            guard info.committedFrames > 0 else { throw SessionAudioSourceError.emptyRecordingFLAC }
            do { _ = try SessionFileAccess.fileSize(recordingFLACURL, relativeTo: sessionURL) }
            catch let error as CocoaError where (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOENT) {
                throw SessionAudioSourceError.recordingFLACMissing
            }
            return .recordedFLAC(info)
        case .importedOriginal(let info):
            return .importedOriginal(try importedOriginalURL(), timeline: info)
        }
    }
}

public enum SessionAudioSource: Sendable, Equatable {
    /// A recording whose durable PCM chunks are still authoritative.
    case recordedPCM(AudioCheckpoint)
    /// A finalized recording stored as `audio/recording.flac`.
    case recordedFLAC(TimelineAudioInfo)
    /// An import: the original file is the source audio; its timeline is rebuilt on every run.
    /// `timeline` is the canonical info of the latest build, nil before the first one.
    case importedOriginal(URL, timeline: TimelineAudioInfo?)

    /// The canonical timeline, when one is known.
    public var timeline: TimelineAudioInfo? {
        get throws {
            switch self {
            case .recordedPCM(let checkpoint): try checkpoint.info
            case .recordedFLAC(let info): info
            case .importedOriginal(_, let timeline): timeline
            }
        }
    }
}

public enum SessionAudioSourceError: Error, LocalizedError, Equatable {
    case importedOriginalMissing
    case multipleImportedOriginals([String])
    case recordingFLACMissing
    case emptyRecordingFLAC

    public var errorDescription: String? {
        switch self {
        case .importedOriginalMissing:
            "取り込んだ元の音声ファイルがありません"
        case .multipleImportedOriginals(let names):
            "取り込んだ元の音声ファイルが複数あります: \(names.joined(separator: ", "))"
        case .recordingFLACMissing:
            "保存状態は FLAC ですが audio/recording.flac がありません"
        case .emptyRecordingFLAC:
            "保存状態の FLAC 録音の長さが 0 です"
        }
    }
}
