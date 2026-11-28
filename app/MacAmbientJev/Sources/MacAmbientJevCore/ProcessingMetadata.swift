import Foundation

public struct ProcessingMetadata: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable, Equatable {
        case running
        case paused
        case failed
        case complete
    }

    public let schemaVersion: Int
    public let generationID: UUID
    public let state: State
    public let failureReason: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generationID = "generation_id"
        case state
        case failureReason = "failure_reason"
    }

    public init(generationID: UUID, state: State, failureReason: String?) {
        self.schemaVersion = EventLogSchema.version
        self.generationID = generationID
        self.state = state
        self.failureReason = failureReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try? container.decode(Int.self, forKey: .schemaVersion),
              version == EventLogSchema.version else {
            throw ProcessingMetadataStoreError.unsupportedSchemaVersion
        }
        self.init(
            generationID: try container.decode(UUID.self, forKey: .generationID),
            state: try container.decode(State.self, forKey: .state),
            failureReason: try container.decodeIfPresent(String.self, forKey: .failureReason)
        )
    }
}

public enum ProcessingMetadataStoreError: Error, LocalizedError, Equatable {
    case unsupportedSchemaVersion
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion:
            "処理状態ファイルは対応していない形式です（schema_version \(EventLogSchema.version) のみ対応）"
        case .unreadable(let reason):
            "処理状態ファイルを読めません: \(reason)"
        }
    }
}

public struct ProcessingMetadataStore: Sendable {
    private let url: URL

    public init(sessionURL: URL) {
        self.url = SessionLayout(sessionURL: sessionURL).processingMetadataURL
    }

    public func load() throws -> ProcessingMetadata? {
        guard let data = try SessionFileAccess.readIfPresent(url, relativeTo: url.deletingLastPathComponent()) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ProcessingMetadata.self, from: data)
        } catch let error as DecodingError {
            throw ProcessingMetadataStoreError.unreadable(String(describing: error))
        }
    }

    public func save(_ metadata: ProcessingMetadata) throws {
        let data = try JSONEncoder().encode(metadata)
        try SessionFileAccess.writeAtomically(data, to: url, relativeTo: url.deletingLastPathComponent())
    }
}
