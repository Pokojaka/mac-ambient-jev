import Foundation

public struct ASREvaluationResult: Codable, Sendable, Equatable {
    public let raw: CharacterErrorRateResult
    public let normalized: CharacterErrorRateResult
    public let normalizerVersion: String

    enum CodingKeys: String, CodingKey {
        case raw
        case normalized
        case normalizerVersion = "normalizer_version"
    }
}

public enum ASREvaluation {
    public static func evaluate(
        reference: String,
        hypothesis: String
    ) -> ASREvaluationResult {
        ASREvaluationResult(
            raw: CharacterErrorRate.evaluate(
                reference: reference,
                hypothesis: hypothesis
            ),
            normalized: CharacterErrorRate.evaluate(
                reference:
                    JapaneseTextNormalizer.normalizeForCER(reference),
                hypothesis:
                    JapaneseTextNormalizer.normalizeForCER(hypothesis)
            ),
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
        return ASREvaluation.evaluate(
            reference: reference,
            hypothesis: segment.text
        )
    }
}
