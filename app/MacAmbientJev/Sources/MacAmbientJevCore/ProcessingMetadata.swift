import Foundation

public struct FinalizationAttempt: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable, Equatable {
        case running
        case failed
        case complete
    }

    public let attemptID: String
    public let state: State
    public let failureReason: String?

    private enum CodingKeys: String, CodingKey {
        case attemptID = "attemptId"
        case state
        case failureReason = "failureReason"
    }

    public init(
        attemptID: String,
        state: State,
        failureReason: String? = nil
    ) {
        self.attemptID = attemptID
        self.state = state
        self.failureReason = failureReason
    }
}

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
    public let finalizationAttempt: FinalizationAttempt?
    public let pendingContentPrioritySegmentIDs: [String]?

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
        activeRuns: ActiveRuns? = nil,
        finalizationAttempt: FinalizationAttempt? = nil,
        pendingContentPrioritySegmentIDs: [String]? = nil
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
        self.finalizationAttempt = finalizationAttempt
        self.pendingContentPrioritySegmentIDs = pendingContentPrioritySegmentIDs
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
            activeRuns: activeRuns,
            finalizationAttempt: finalizationAttempt,
            pendingContentPrioritySegmentIDs: pendingContentPrioritySegmentIDs
        )
    }

    public func withFinalizationAttempt(
        _ finalizationAttempt: FinalizationAttempt?
    ) -> ProcessingMetadata {
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
            activeRuns: activeRuns,
            finalizationAttempt: finalizationAttempt,
            pendingContentPrioritySegmentIDs: pendingContentPrioritySegmentIDs
        )
    }

    public func withCompletedFinalization(
        attemptID: String,
        activeRuns: ActiveRuns
    ) -> ProcessingMetadata {
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
            activeRuns: activeRuns,
            finalizationAttempt: FinalizationAttempt(
                attemptID: attemptID,
                state: .complete
            ),
            pendingContentPrioritySegmentIDs: pendingContentPrioritySegmentIDs
        )
    }

    public func withPendingContentPrioritySegmentIDs(
        _ segmentIDs: [String]
    ) -> ProcessingMetadata {
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
            activeRuns: activeRuns,
            finalizationAttempt: finalizationAttempt,
            pendingContentPrioritySegmentIDs: segmentIDs.isEmpty ? nil : segmentIDs
        )
    }
}

public enum ProcessingMetadataStoreError: Error, Equatable {
    case metadataMissing
    case finalizationAttemptMismatch
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

    public func beginFinalization(
        attemptID: String,
        defaultMetadata: ProcessingMetadata? = nil
    ) throws {
        let metadata: ProcessingMetadata
        if let existing = try load() {
            metadata = existing
        } else if let defaultMetadata {
            metadata = defaultMetadata
        } else {
            throw ProcessingMetadataStoreError.metadataMissing
        }
        try save(metadata.withFinalizationAttempt(FinalizationAttempt(
            attemptID: attemptID,
            state: .running
        )))
    }

    public func failFinalization(
        attemptID: String,
        reason: String
    ) throws {
        let metadata = try matchingFinalizationAttempt(attemptID: attemptID)
        try save(metadata.withFinalizationAttempt(FinalizationAttempt(
            attemptID: attemptID,
            state: .failed,
            failureReason: reason
        )))
    }

    public func completeFinalization(
        attemptID: String,
        activeRuns: ActiveRuns
    ) throws {
        let metadata = try matchingFinalizationAttempt(attemptID: attemptID)
        try save(metadata.withCompletedFinalization(
            attemptID: attemptID,
            activeRuns: activeRuns
        ))
    }

    private func matchingFinalizationAttempt(
        attemptID: String
    ) throws -> ProcessingMetadata {
        guard let metadata = try load(),
              metadata.finalizationAttempt?.attemptID == attemptID else {
            throw ProcessingMetadataStoreError.finalizationAttemptMismatch
        }
        return metadata
    }
}
