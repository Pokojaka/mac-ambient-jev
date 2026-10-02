import Foundation

/// What actually produced a processing result, as reported by the engine itself.
public struct RunProvenance: Codable, Sendable, Equatable {
    public let engine: String
    public let model: String?
    public let version: String
    public let configuration: [String: String]

    public init(
        engine: String,
        model: String?,
        version: String,
        configuration: [String: String]
    ) {
        self.engine = engine
        self.model = model
        self.version = version
        self.configuration = configuration
    }
}
