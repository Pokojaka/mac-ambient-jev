import Foundation

/// One recording to evaluate: `{ "id", "audio", "reference": { "text" | "file" } }`.
public struct ASRSessionManifest: Decodable, Sendable, Equatable {
    public let id: String
    public let audio: String
    public let reference: ASRSessionReference

    public init(id: String, audio: String, reference: ASRSessionReference) {
        self.id = id
        self.audio = audio
        self.reference = reference
    }

    /// The reference transcript. A relative `file` is resolved against the manifest's directory.
    public func referenceText(manifestURL: URL) throws -> String {
        switch reference {
        case .text(let text):
            return text
        case .file(let path):
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : manifestURL.deletingLastPathComponent().appending(path: path)
            return try String(contentsOf: url.standardizedFileURL, encoding: .utf8)
        }
    }
}

public enum ASRSessionReference: Decodable, Sendable, Equatable {
    case text(String)
    case file(String)

    private enum CodingKeys: String, CodingKey {
        case text
        case file
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch (container.contains(.text), container.contains(.file)) {
        case (true, false):
            self = .text(try container.decode(String.self, forKey: .text))
        case (false, true):
            self = .file(try container.decode(String.self, forKey: .file))
        default:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "reference には text か file のどちらか一方だけを書いてください"
            ))
        }
    }
}

/// The keys of a `segments.json` entry that the evaluation reads.
public struct ASRSessionSegment: Decodable, Sendable, Equatable {
    public let startMilliseconds: Int64
    public let text: String
    public let scene: SceneState

    public init(startMilliseconds: Int64, text: String, scene: SceneState) {
        self.startMilliseconds = startMilliseconds
        self.text = text
        self.scene = scene
    }

    private enum CodingKeys: String, CodingKey {
        case startMilliseconds = "start_ms"
        case text
        case scene
    }
}

public struct ASRSessionReport: Encodable, Sendable, Equatable {
    public let id: String
    public let asrEvaluation: ASREvaluationResult
    public let sceneOscillationCount: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case asrEvaluation = "asr_evaluation"
        case sceneOscillationCount = "scene_oscillation_count"
    }
}

public enum ASRSessionEvaluator {
    /// A scene that returns within this window after switching away counts as one oscillation.
    public static let oscillationWindowMilliseconds: Int64 = 30_000

    /// Evaluates segments in their `segments.json` order.
    public static func evaluate(
        id: String,
        reference: String,
        segments: [ASRSessionSegment]
    ) -> ASRSessionReport {
        ASRSessionReport(
            id: id,
            asrEvaluation: ASREvaluation.evaluate(
                reference: reference,
                hypothesis: segments.map(\.text).joined(separator: "\n")
            ),
            sceneOscillationCount: sceneOscillationCount(segments)
        )
    }

    /// Counts A→B→A scene runs whose two A starts lie within the oscillation window.
    public static func sceneOscillationCount(_ segments: [ASRSessionSegment]) -> Int {
        var runs: [ASRSessionSegment] = []
        for segment in segments where runs.last?.scene != segment.scene {
            runs.append(segment)
        }
        return zip(runs, runs.dropFirst(2)).count { first, third in
            first.scene == third.scene
                && third.startMilliseconds - first.startMilliseconds <= oscillationWindowMilliseconds
        }
    }
}
