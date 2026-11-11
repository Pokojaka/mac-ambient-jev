import Foundation

public struct ASREvaluationResult: Codable, Sendable, Equatable {
    public let cer: CharacterErrorRateResult
    public let normalizerVersion: String

    enum CodingKeys: String, CodingKey {
        case cer
        case normalizerVersion = "normalizer_version"
    }
}

public enum ASREvaluation {
    public static func evaluate(
        reference: String,
        hypothesis: String
    ) throws -> ASREvaluationResult {
        let cer = try CharacterErrorRate.evaluate(
            reference: reference,
            hypothesis: hypothesis
        )
        return ASREvaluationResult(
            cer: cer,
            normalizerVersion: JapaneseTextNormalizer.version
        )
    }
}

/// The Linux ASR artifact. Its single segment spans the whole audio and
/// exists only as the hypothesis envelope for CER.
public struct ASRArtifact: Decodable, Sendable, Equatable {
    public struct Segment: Decodable, Sendable, Equatable {
        public let startMilliseconds: Int64
        public let endMilliseconds: Int64
        public let text: String

        enum CodingKeys: String, CodingKey {
            case startMilliseconds = "start_ms"
            case endMilliseconds = "end_ms"
            case text
        }
    }

    public let schemaVersion: Int
    public let segments: [Segment]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case segments
    }
}

public enum ASRArtifactEvaluationError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case segmentCount(Int)
    case invalidSegmentRange
}

public enum ASRArtifactEvaluator {
    public static let schemaVersion = 2

    public static func evaluate(
        reference: String,
        artifact: ASRArtifact
    ) throws -> ASREvaluationResult {
        guard artifact.schemaVersion == schemaVersion else {
            throw ASRArtifactEvaluationError
                .unsupportedSchemaVersion(artifact.schemaVersion)
        }
        guard artifact.segments.count == 1 else {
            throw ASRArtifactEvaluationError
                .segmentCount(artifact.segments.count)
        }
        let segment = artifact.segments[0]
        guard
            segment.startMilliseconds == 0,
            segment.endMilliseconds > segment.startMilliseconds
        else {
            throw ASRArtifactEvaluationError.invalidSegmentRange
        }
        return try ASREvaluation.evaluate(
            reference: reference,
            hypothesis: segment.text
        )
    }
}
