import Foundation

/// `audio/storage.json`: which stored form of the session's audio is authoritative.
public enum SessionAudioStorage: Codable, Sendable, Equatable {
    /// The durable PCM chunks under `audio/processing` are the recording.
    case recordingPCM
    /// The verified `audio/recording.flac` is the recording; PCM is no longer used.
    case recordingFLAC(TimelineAudioInfo)
    /// The imported original is the source. The info is the canonical timeline the latest
    /// finalization built from it, or nil before the first build.
    case importedOriginal(TimelineAudioInfo?)

    private enum CodingKeys: String, CodingKey {
        case state, timeline
    }

    private enum State: String, Codable {
        case recordingPCM, recordingFLAC, importedOriginal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .recordingPCM:
            guard !container.contains(.timeline) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timeline, in: container, debugDescription: "recordingPCM has no timeline"
                )
            }
            self = .recordingPCM
        case .recordingFLAC:
            self = .recordingFLAC(try container.decode(TimelineAudioInfo.self, forKey: .timeline))
        case .importedOriginal:
            guard container.contains(.timeline) else {
                throw DecodingError.keyNotFound(CodingKeys.timeline, DecodingError.Context(
                    codingPath: container.codingPath, debugDescription: "importedOriginal requires timeline"
                ))
            }
            self = .importedOriginal(try container.decodeNil(forKey: .timeline)
                ? nil : container.decode(TimelineAudioInfo.self, forKey: .timeline))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .recordingPCM:
            try container.encode(State.recordingPCM, forKey: .state)
        case .recordingFLAC(let info):
            try container.encode(State.recordingFLAC, forKey: .state)
            try container.encode(info, forKey: .timeline)
        case .importedOriginal(let info):
            try container.encode(State.importedOriginal, forKey: .state)
            if let info {
                try container.encode(info, forKey: .timeline)
            } else {
                try container.encodeNil(forKey: .timeline)
            }
        }
    }

    /// The state a new session starts in.
    public static func initial(for source: SessionSource) -> SessionAudioStorage {
        switch source {
        case .recording: .recordingPCM
        case .imported: .importedOriginal(nil)
        }
    }

    /// Throws when the state cannot belong to a session created as `source`.
    public func validate(for source: SessionSource) throws {
        switch (source, self) {
        case (.recording, .recordingPCM), (.recording, .recordingFLAC), (.imported, .importedOriginal):
            return
        default:
            throw SessionAudioStorageError.sourceMismatch
        }
    }
}

public enum SessionAudioStorageError: Error, LocalizedError, Equatable {
    case missing
    case unreadable(String)
    case sourceMismatch

    public var errorDescription: String? {
        switch self {
        case .missing: "音声の保存状態ファイル audio/storage.json がありません"
        case .unreadable(let reason): "音声の保存状態ファイルを読めません: \(reason)"
        case .sourceMismatch: "音声の保存状態がセッションの作成方法と一致しません"
        }
    }
}

public struct SessionAudioStorageStore: Sendable {
    public let layout: SessionLayout

    public init(layout: SessionLayout) {
        self.layout = layout
    }

    public func load() throws -> SessionAudioStorage {
        let url = layout.audioStorageURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SessionAudioStorageError.missing
        }
        do {
            return try JSONDecoder().decode(SessionAudioStorage.self, from: Data(contentsOf: url))
        } catch {
            throw SessionAudioStorageError.unreadable(String(describing: error))
        }
    }

    /// Durable on return: the file and `audio/` are synchronized after the atomic rename.
    public func save(_ storage: SessionAudioStorage) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFile.replace(layout.audioStorageURL, with: encoder.encode(storage))
    }
}

/// Atomic same-directory replacement whose new contents and directory entry are both
/// synchronized before return.
public enum DurableFile {
    public static func replace(_ url: URL, with data: Data) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        try synchronize(temporary)
        try rename(temporary, to: url)
    }

    /// rename(2) replaces `destination` atomically, then the directory entry is synchronized.
    public static func rename(_ source: URL, to destination: URL) throws {
        guard Foundation.rename(source.path, destination.path) == 0 else {
            throw posixError(destination)
        }
        try synchronize(destination.deletingLastPathComponent())
    }

    /// Flushes a regular file or a directory to stable storage (`F_FULLFSYNC`).
    public static func synchronize(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError(url) }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw posixError(url) }
    }

    private static func posixError(_ url: URL) -> CocoaError {
        CocoaError(.fileWriteUnknown, userInfo: [
            NSFilePathErrorKey: url.path,
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)),
        ])
    }
}
