import Foundation

public enum CaptureSource: String, Codable, Sendable, Equatable, CaseIterable {
    case microphone
    case systemAudio
}

/// How a session's audio came into the app.
public enum SessionSource: Sendable, Equatable {
    case recording(CaptureSource)
    /// `originalFilename` is the imported file's name, never empty.
    case imported(originalFilename: String)
}

/// `session.json`. A recording stores `capture_source`; an import stores `original_filename`.
public struct SessionManifest: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let createdAt: Date
    public let source: SessionSource

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case createdAt = "created_at"
        case sourceKind = "source_kind"
        case captureSource = "capture_source"
        case originalFilename = "original_filename"
    }

    private enum SourceKind: String, Codable {
        case recording
        case imported
    }

    public init(sessionID: UUID, createdAt: Date, source: SessionSource) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        switch try container.decode(SourceKind.self, forKey: .sourceKind) {
        case .recording:
            source = .recording(try container.decode(CaptureSource.self, forKey: .captureSource))
        case .imported:
            let filename = try container.decode(String.self, forKey: .originalFilename)
            guard !filename.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .originalFilename,
                    in: container,
                    debugDescription: "original_filename is empty"
                )
            }
            source = .imported(originalFilename: filename)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(createdAt, forKey: .createdAt)
        switch source {
        case .recording(let captureSource):
            try container.encode(SourceKind.recording, forKey: .sourceKind)
            try container.encode(captureSource, forKey: .captureSource)
        case .imported(let originalFilename):
            try container.encode(SourceKind.imported, forKey: .sourceKind)
            try container.encode(originalFilename, forKey: .originalFilename)
        }
    }
}
