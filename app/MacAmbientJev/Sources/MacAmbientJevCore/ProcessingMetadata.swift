import Foundation

public struct ProcessingMetadata: Codable, Sendable, Equatable {
    public let timelineVersion: Int
    public let vadVersion: String
    public let vadConfigHash: String
    public let asrEngine: String
    public let asrModel: String
    public let asrVersion: String
    public let diarizationVersion: String
    public let sceneAnalyzerVersion: Int
    public let jevSchemaVersion: Int
    public let policyVersion: Int
    public let materializerSchemaVersion: Int
    public let activeRuns: ActiveRuns?

    public init(
        timelineVersion: Int,
        vadVersion: String,
        vadConfigHash: String,
        asrEngine: String,
        asrModel: String,
        asrVersion: String,
        diarizationVersion: String,
        sceneAnalyzerVersion: Int,
        jevSchemaVersion: Int,
        policyVersion: Int,
        materializerSchemaVersion: Int,
        activeRuns: ActiveRuns? = nil
    ) {
        self.timelineVersion = timelineVersion
        self.vadVersion = vadVersion
        self.vadConfigHash = vadConfigHash
        self.asrEngine = asrEngine
        self.asrModel = asrModel
        self.asrVersion = asrVersion
        self.diarizationVersion = diarizationVersion
        self.sceneAnalyzerVersion = sceneAnalyzerVersion
        self.jevSchemaVersion = jevSchemaVersion
        self.policyVersion = policyVersion
        self.materializerSchemaVersion = materializerSchemaVersion
        self.activeRuns = activeRuns
    }

    public func withActiveRuns(_ activeRuns: ActiveRuns) -> ProcessingMetadata {
        ProcessingMetadata(
            timelineVersion: timelineVersion,
            vadVersion: vadVersion,
            vadConfigHash: vadConfigHash,
            asrEngine: asrEngine,
            asrModel: asrModel,
            asrVersion: asrVersion,
            diarizationVersion: diarizationVersion,
            sceneAnalyzerVersion: sceneAnalyzerVersion,
            jevSchemaVersion: jevSchemaVersion,
            policyVersion: policyVersion,
            materializerSchemaVersion: materializerSchemaVersion,
            activeRuns: activeRuns
        )
    }
}

public struct ProcessingMetadataStore: Sendable {
    public let url: URL

    public init(sessionURL: URL) {
        self.url = sessionURL.appending(path: "processing_metadata.json")
    }

    public func load() throws -> ProcessingMetadata? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ProcessingMetadata.self, from: data)
    }

    public func save(_ metadata: ProcessingMetadata) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }
}
