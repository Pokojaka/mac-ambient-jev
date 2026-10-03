import Foundation

public struct DiarizationArtifactSpan:
    Codable, Sendable, Equatable
{
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let speaker: SpeakerIdentity

    public init(
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        speaker: SpeakerIdentity
    ) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.speaker = speaker
    }

    enum CodingKeys: String, CodingKey {
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case speaker
    }
}

public struct DiarizationRawSpan:
    Codable, Sendable, Equatable
{
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let speakerLabel: String

    public init(
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        speakerLabel: String
    ) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.speakerLabel = speakerLabel
    }

    enum CodingKeys: String, CodingKey {
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case speakerLabel = "speaker_label"
    }

    public var sourceSpan: SourceSpeakerSpan {
        SourceSpeakerSpan(
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            speakerLabel: speakerLabel
        )
    }
}

public struct DiarizationEvaluationArtifact:
    Codable, Sendable, Equatable
{
    public struct OverflowResolver: Codable, Sendable, Equatable {
        public let minCleanSpeechMilliseconds: Int64

        public init(minCleanSpeechMilliseconds: Int64) {
            self.minCleanSpeechMilliseconds = minCleanSpeechMilliseconds
        }

        enum CodingKeys: String, CodingKey {
            case minCleanSpeechMilliseconds = "min_clean_speech_ms"
        }
    }

    public let schemaVersion: Int
    public let spans: [DiarizationArtifactSpan]
    public let rawSpans: [DiarizationRawSpan]
    public let overflowResolver: OverflowResolver

    public init(
        schemaVersion: Int,
        spans: [DiarizationArtifactSpan],
        rawSpans: [DiarizationRawSpan],
        overflowResolver: OverflowResolver
    ) {
        self.schemaVersion = schemaVersion
        self.spans = spans
        self.rawSpans = rawSpans
        self.overflowResolver = overflowResolver
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case spans
        case rawSpans = "raw_spans"
        case overflowResolver = "overflow_resolver"
    }
}

public struct DiarizationEvaluationReport:
    Codable, Sendable, Equatable
{
    public let standard: StandardDiarizationMetrics
    public let collapsed: CollapsedDiarizationMetrics
    public let evaluatorVersion: String

    enum CodingKeys: String, CodingKey {
        case standard
        case collapsed
        case evaluatorVersion = "evaluator_version"
    }
}

public enum DiarizationArtifactEvaluationError:
    Error, Sendable, Equatable
{
    case unsupportedSchemaVersion(Int)
    case invalidMinCleanSpeech(Int64)
    case invalidReferenceSpan(index: Int)
    case emptyReferenceSpeakerLabel(index: Int)
    case invalidPublicSpan(index: Int)
    case invalidRawSpan(index: Int)
    case emptyRawSpeakerLabel(index: Int)
}

public enum DiarizationArtifactEvaluator {
    public static let schemaVersion = 2
    /// Identifies the reference-collapse and metric rules. Change it
    /// whenever they change so baselines never compare across rules.
    public static let version = "1"

    public static func evaluate(
        reference: [SourceSpeakerSpan],
        artifact: DiarizationEvaluationArtifact
    ) throws -> DiarizationEvaluationReport {
        guard artifact.schemaVersion == schemaVersion else {
            throw DiarizationArtifactEvaluationError
                .unsupportedSchemaVersion(artifact.schemaVersion)
        }
        let minCleanSpeech =
            artifact.overflowResolver.minCleanSpeechMilliseconds
        guard minCleanSpeech > 0 else {
            throw DiarizationArtifactEvaluationError
                .invalidMinCleanSpeech(minCleanSpeech)
        }

        for (index, span) in reference.enumerated() {
            guard
                span.startMilliseconds >= 0,
                span.endMilliseconds > span.startMilliseconds
            else {
                throw DiarizationArtifactEvaluationError
                    .invalidReferenceSpan(index: index)
            }
            guard !span.speakerLabel.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw DiarizationArtifactEvaluationError
                    .emptyReferenceSpeakerLabel(index: index)
            }
        }
        for (index, span) in artifact.spans.enumerated() {
            guard
                span.startMilliseconds >= 0,
                span.endMilliseconds > span.startMilliseconds
            else {
                throw DiarizationArtifactEvaluationError
                    .invalidPublicSpan(index: index)
            }
        }
        for (index, span) in artifact.rawSpans.enumerated() {
            guard
                span.startMilliseconds >= 0,
                span.endMilliseconds > span.startMilliseconds
            else {
                throw DiarizationArtifactEvaluationError
                    .invalidRawSpan(index: index)
            }
            guard !span.speakerLabel.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw DiarizationArtifactEvaluationError
                    .emptyRawSpeakerLabel(index: index)
            }
        }

        let collapsedReference = try SpeakerArrivalCollapser.collapse(
            reference,
            minCleanSpeechMilliseconds: minCleanSpeech
        )
        let collapsedHypothesis = artifact.spans.map {
            SpeakerEvaluationSpan(
                startMilliseconds: $0.startMilliseconds,
                endMilliseconds: $0.endMilliseconds,
                speaker: $0.speaker
            )
        }

        return DiarizationEvaluationReport(
            standard: StandardDiarizationEvaluator.evaluate(
                reference: reference,
                hypothesis: artifact.rawSpans.map(\.sourceSpan)
            ),
            collapsed: CollapsedDiarizationEvaluator.evaluate(
                reference: collapsedReference,
                hypothesis: collapsedHypothesis
            ),
            evaluatorVersion: version
        )
    }
}
