import Foundation

public enum SessionSourceKind: String, Codable, Sendable, Equatable {
    case live
    case importedFile
}

public struct SessionManifest: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let createdAt: Date
    public let sourceKind: SessionSourceKind
    public let originalFilename: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case createdAt = "created_at"
        case sourceKind = "source_kind"
        case originalFilename = "original_filename"
    }

    public init(
        sessionID: UUID,
        createdAt: Date,
        sourceKind: SessionSourceKind,
        originalFilename: String? = nil
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.sourceKind = sourceKind
        self.originalFilename = originalFilename
    }
}
