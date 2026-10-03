import Foundation
import Testing
@testable import MacAmbientJevCore

private let resolver = DiarizationEvaluationArtifact.OverflowResolver(
    minCleanSpeechMilliseconds: 500
)

@Test
func diarizationArtifactDecodesRawAndPublicSpans() throws {
    let data = Data(#"""
    {
      "schema_version": 2,
      "spans": [
        {"start_ms":0,"end_ms":1000,"speaker":{"kind":"tracked","index":1}}
      ],
      "raw_spans": [
        {"start_ms":0,"end_ms":1000,"speaker_label":"speaker_0"}
      ],
      "overflow_resolver": {
        "embedding_model": "titanet",
        "embedding_revision": "rev",
        "match_threshold": 0.8,
        "ambiguity_margin": 0.05,
        "min_clean_speech_ms": 500
      }
    }
    """#.utf8)

    let artifact = try JSONDecoder().decode(
        DiarizationEvaluationArtifact.self,
        from: data
    )

    #expect(artifact.schemaVersion == 2)
    #expect(artifact.spans.count == 1)
    #expect(artifact.rawSpans.first?.speakerLabel == "speaker_0")
    #expect(artifact.overflowResolver.minCleanSpeechMilliseconds == 500)
}

@Test
func diarizationArtifactEvaluationSeparatesStandardAndCollapsedDER()
    throws
{
    let reference = (1...8).map { index in
        SourceSpeakerSpan(
            startMilliseconds: Int64((index - 1) * 1_000),
            endMilliseconds: Int64(index * 1_000),
            speakerLabel: "person-\(index)"
        )
    }
    var publicSpans: [DiarizationArtifactSpan] = []
    var rawSpans: [DiarizationRawSpan] = []
    for index in 1...8 {
        let start = Int64((index - 1) * 1_000)
        let end = Int64(index * 1_000)
        let speaker: SpeakerIdentity = index <= 7
            ? try SpeakerIdentity.tracked(index)
            : .other
        publicSpans.append(
            DiarizationArtifactSpan(
                startMilliseconds: start,
                endMilliseconds: end,
                speaker: speaker
            )
        )
        rawSpans.append(
            DiarizationRawSpan(
                startMilliseconds: start,
                endMilliseconds: end,
                speakerLabel: "stream-\(index)"
            )
        )
    }
    let artifact = DiarizationEvaluationArtifact(
        schemaVersion: 2,
        spans: publicSpans,
        rawSpans: rawSpans,
        overflowResolver: resolver
    )

    let report = try DiarizationArtifactEvaluator.evaluate(
        reference: reference,
        artifact: artifact
    )

    #expect(report.standard.der == 0)
    #expect(report.collapsed.der == 0)
    #expect(report.evaluatorVersion == DiarizationArtifactEvaluator.version)
}

@Test
func diarizationArtifactEvaluationRejectsUnknownSchema() {
    let artifact = DiarizationEvaluationArtifact(
        schemaVersion: 1,
        spans: [],
        rawSpans: [],
        overflowResolver: resolver
    )

    #expect(
        throws:
            DiarizationArtifactEvaluationError
            .unsupportedSchemaVersion(1)
    ) {
        _ = try DiarizationArtifactEvaluator.evaluate(
            reference: [],
            artifact: artifact
        )
    }
}


@Test
func speakerIdentityDecodingRejectsIndexOnOther() {
    let data = Data(
        #"{\"kind\":\"other\",\"index\":1}"#.utf8
    )
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(
            SpeakerIdentity.self,
            from: data
        )
    }
}

@Test
func diarizationArtifactEvaluationRejectsInvalidPublicSpan()
    throws
{
    let artifact = DiarizationEvaluationArtifact(
        schemaVersion: 2,
        spans: [
            DiarizationArtifactSpan(
                startMilliseconds: 1_000,
                endMilliseconds: 1_000,
                speaker: try .tracked(1)
            )
        ],
        rawSpans: [],
        overflowResolver: resolver
    )

    #expect(
        throws:
            DiarizationArtifactEvaluationError
            .invalidPublicSpan(index: 0)
    ) {
        _ = try DiarizationArtifactEvaluator.evaluate(
            reference: [],
            artifact: artifact
        )
    }
}

@Test
func diarizationArtifactEvaluationRejectsEmptyRawSpeakerLabel() {
    let artifact = DiarizationEvaluationArtifact(
        schemaVersion: 2,
        spans: [],
        rawSpans: [
            DiarizationRawSpan(
                startMilliseconds: 0,
                endMilliseconds: 1_000,
                speakerLabel: "  "
            )
        ],
        overflowResolver: resolver
    )

    #expect(
        throws:
            DiarizationArtifactEvaluationError
            .emptyRawSpeakerLabel(index: 0)
    ) {
        _ = try DiarizationArtifactEvaluator.evaluate(
            reference: [],
            artifact: artifact
        )
    }
}

@Test
func diarizationArtifactEvaluationRejectsInvalidReferenceSpan() {
    let artifact = DiarizationEvaluationArtifact(
        schemaVersion: 2,
        spans: [],
        rawSpans: [],
        overflowResolver: resolver
    )
    let reference = [
        SourceSpeakerSpan(
            startMilliseconds: -1,
            endMilliseconds: 1_000,
            speakerLabel: "person-1"
        )
    ]

    #expect(
        throws:
            DiarizationArtifactEvaluationError
            .invalidReferenceSpan(index: 0)
    ) {
        _ = try DiarizationArtifactEvaluator.evaluate(
            reference: reference,
            artifact: artifact
        )
    }
}

@Test
func diarizationArtifactEvaluationRejectsInvalidRawSpan() {
    let artifact = DiarizationEvaluationArtifact(
        schemaVersion: 2,
        spans: [],
        rawSpans: [
            DiarizationRawSpan(
                startMilliseconds: 1_000,
                endMilliseconds: 999,
                speakerLabel: "stream-1"
            )
        ],
        overflowResolver: resolver
    )

    #expect(
        throws:
            DiarizationArtifactEvaluationError
            .invalidRawSpan(index: 0)
    ) {
        _ = try DiarizationArtifactEvaluator.evaluate(
            reference: [],
            artifact: artifact
        )
    }
}

@Test
func diarizationArtifactEvaluationRejectsNonPositiveCleanSpeechGate() {
    let artifact = DiarizationEvaluationArtifact(
        schemaVersion: 2,
        spans: [],
        rawSpans: [],
        overflowResolver: .init(minCleanSpeechMilliseconds: 0)
    )

    #expect(
        throws: DiarizationArtifactEvaluationError.invalidMinCleanSpeech(0)
    ) {
        _ = try DiarizationArtifactEvaluator.evaluate(
            reference: [],
            artifact: artifact
        )
    }
}

@Test
func diarizationReportWritesUnmeasurableMetricsAsNull() throws {
    let artifact = DiarizationEvaluationArtifact(
        schemaVersion: 2,
        spans: [
            DiarizationArtifactSpan(
                startMilliseconds: 0,
                endMilliseconds: 1_000,
                speaker: try .tracked(1)
            )
        ],
        rawSpans: [
            DiarizationRawSpan(
                startMilliseconds: 0,
                endMilliseconds: 1_000,
                speakerLabel: "stream-1"
            )
        ],
        overflowResolver: resolver
    )
    let report = try DiarizationArtifactEvaluator.evaluate(
        reference: [
            SourceSpeakerSpan(
                startMilliseconds: 0,
                endMilliseconds: 1_000,
                speakerLabel: "person-1"
            )
        ],
        artifact: artifact
    )

    let object = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(report)
    ) as! [String: Any]
    let collapsed = object["collapsed"] as! [String: Any]
    let standard = object["standard"] as! [String: Any]

    #expect(collapsed["other_precision"] is NSNull)
    #expect(collapsed["overflow_detection_recall"] is NSNull)
    #expect(standard["overlap_recall"] is NSNull)
    #expect(standard["speaker_switch_boundary_mae_ms"] is NSNull)
}
