import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func diarizationArtifactDecodesRawAndPublicSpans() throws {
    let data = Data(#"""
    {
      "schema_version": 1,
      "spans": [
        {"start_ms":0,"end_ms":1000,"speaker":{"kind":"tracked","index":1}}
      ],
      "raw_spans": [
        {"start_ms":0,"end_ms":1000,"speaker_label":"speaker_0"}
      ]
    }
    """#.utf8)

    let artifact = try JSONDecoder().decode(
        DiarizationEvaluationArtifact.self,
        from: data
    )

    #expect(artifact.schemaVersion == 1)
    #expect(artifact.spans.count == 1)
    #expect(
        artifact.rawSpans?.first?.speakerLabel == "speaker_0"
    )
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
        schemaVersion: 1,
        spans: publicSpans,
        rawSpans: rawSpans
    )

    let report = try DiarizationArtifactEvaluator.evaluate(
        reference: reference,
        artifact: artifact
    )

    #expect(report.standard?.der == 0)
    #expect(report.collapsed.der == 0)
}

@Test
func diarizationArtifactEvaluationKeepsStandardUnmeasuredWithoutRawSpans()
    throws
{
    let artifact = DiarizationEvaluationArtifact(
        schemaVersion: 1,
        spans: [
            DiarizationArtifactSpan(
                startMilliseconds: 0,
                endMilliseconds: 1_000,
                speaker: try .tracked(1)
            )
        ],
        rawSpans: nil
    )
    let reference = [
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speakerLabel: "person-1"
        )
    ]

    let report = try DiarizationArtifactEvaluator.evaluate(
        reference: reference,
        artifact: artifact
    )

    #expect(report.standard == nil)
    #expect(report.collapsed.der == 0)
}

@Test
func diarizationArtifactEvaluationRejectsUnknownSchema() {
    let artifact = DiarizationEvaluationArtifact(
        schemaVersion: 2,
        spans: [],
        rawSpans: []
    )

    #expect(
        throws:
            DiarizationArtifactEvaluationError
            .unsupportedSchemaVersion(2)
    ) {
        _ = try DiarizationArtifactEvaluator.evaluate(
            reference: [],
            artifact: artifact
        )
    }
}
