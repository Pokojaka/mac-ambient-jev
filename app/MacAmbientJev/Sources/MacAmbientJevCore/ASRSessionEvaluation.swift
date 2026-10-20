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
            let url = URL(fileURLWithPath: path, relativeTo: manifestURL.deletingLastPathComponent())
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

    public init(startMilliseconds: Int64, text: String) {
        self.startMilliseconds = startMilliseconds
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case startMilliseconds = "start_ms"
        case text
    }
}

public struct ASRSessionReport: Encodable, Sendable, Equatable {
    public let id: String
    public let asrEvaluation: ASREvaluationResult

    private enum CodingKeys: String, CodingKey {
        case id
        case asrEvaluation = "asr_evaluation"
    }
}

public enum ASRSessionEvaluator {
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
            )
        )
    }
}
