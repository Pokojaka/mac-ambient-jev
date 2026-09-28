import Foundation

public enum SessionSourceKind: String, Codable, Sendable, Equatable {
    case live
    case importedFile
}

public enum CaptureSource: String, Codable, Sendable, Equatable, CaseIterable {
    case microphone
    case systemAudio
}

public struct SessionManifest: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let createdAt: Date
    public let sourceKind: SessionSourceKind
    public let captureSource: CaptureSource
    public let originalFilename: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case createdAt = "created_at"
        case sourceKind = "source_kind"
        case captureSource = "capture_source"
        case originalFilename = "original_filename"
    }

    public init(
        sessionID: UUID,
        createdAt: Date,
        sourceKind: SessionSourceKind,
        originalFilename: String? = nil,
        captureSource: CaptureSource = .microphone
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.sourceKind = sourceKind
        self.originalFilename = originalFilename
        self.captureSource = captureSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sourceKind = try container.decode(SessionSourceKind.self, forKey: .sourceKind)
        originalFilename = try container.decodeIfPresent(String.self, forKey: .originalFilename)
        captureSource = try container.decodeIfPresent(CaptureSource.self, forKey: .captureSource)
            ?? .microphone
    }
}
