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
    public let schemaVersion: Int
    public let spans: [DiarizationArtifactSpan]
    public let rawSpans: [DiarizationRawSpan]?

    public init(
        schemaVersion: Int,
        spans: [DiarizationArtifactSpan],
        rawSpans: [DiarizationRawSpan]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.spans = spans
        self.rawSpans = rawSpans
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case spans
        case rawSpans = "raw_spans"
    }
}

public struct DiarizationEvaluationReport:
    Codable, Sendable, Equatable
{
    public let standard: StandardDiarizationMetrics?
    public let collapsed: CollapsedDiarizationMetrics

    public init(
        standard: StandardDiarizationMetrics?,
        collapsed: CollapsedDiarizationMetrics
    ) {
        self.standard = standard
        self.collapsed = collapsed
    }
}

public enum DiarizationArtifactEvaluationError:
    Error, Sendable, Equatable
{
    case unsupportedSchemaVersion(Int)
}

public enum DiarizationArtifactEvaluator {
    public static func evaluate(
        reference: [SourceSpeakerSpan],
        artifact: DiarizationEvaluationArtifact
    ) throws -> DiarizationEvaluationReport {
        guard artifact.schemaVersion == 1 else {
            throw DiarizationArtifactEvaluationError
                .unsupportedSchemaVersion(artifact.schemaVersion)
        }

        let collapsedReference = try SpeakerArrivalCollapser
            .collapse(reference)
        let collapsedHypothesis = artifact.spans.map {
            SpeakerEvaluationSpan(
                startMilliseconds: $0.startMilliseconds,
                endMilliseconds: $0.endMilliseconds,
                speaker: $0.speaker
            )
        }
        let collapsed = CollapsedDiarizationEvaluator.evaluate(
            reference: collapsedReference,
            hypothesis: collapsedHypothesis
        )

        let standard = artifact.rawSpans.map { rawSpans in
            StandardDiarizationEvaluator.evaluate(
                reference: reference,
                hypothesis: rawSpans.map(\.sourceSpan)
            )
        }

        return DiarizationEvaluationReport(
            standard: standard,
            collapsed: collapsed
        )
    }
}
