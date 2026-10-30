import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol

public struct EngineProfileDecisionStore: Sendable {
    private let root: URL

    public init(paths: AppPaths) { root = paths.root }

    private var fileURL: URL {
        root.appending(path: "accelerators/profile-decision.json", directoryHint: .notDirectory)
    }

    public func load() throws -> EngineProfileEvaluation? {
        guard let data = try SessionFileAccess.readIfPresent(fileURL, relativeTo: root) else { return nil }
        do {
            try EngineJSONValidator.validate(data)
            return try JSONDecoder().decode(EngineProfileEvaluation.self, from: data)
        } catch {
            throw EngineSettingsError.corrupt(path: fileURL.path, reason: "profile decision: \(error)")
        }
    }

    public func save(_ evaluation: EngineProfileEvaluation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(evaluation)
        let directory = root.appending(path: "accelerators", directoryHint: .isDirectory)
        try SessionFileAccess.createDirectory(root, relativeTo: root)
        try SessionFileAccess.createDirectory(directory, relativeTo: root)
        try SessionFileAccess.writeAtomically(data, to: fileURL, relativeTo: root)
    }
}
