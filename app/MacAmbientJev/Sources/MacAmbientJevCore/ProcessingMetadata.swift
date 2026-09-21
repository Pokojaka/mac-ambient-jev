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
        materializerSchemaVersion: Int
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
    }
}
