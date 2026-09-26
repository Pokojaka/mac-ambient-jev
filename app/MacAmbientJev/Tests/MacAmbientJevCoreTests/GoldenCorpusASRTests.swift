import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func goldenCorpusEvaluatesInlineASRReference() throws {
    let manifest = GoldenCorpusManifest(
        id: "asr-inline-reference",
        audio: "fixture.wav",
        annotations: GoldenCorpusAnnotations(
            sceneTransitions: [],
            mustKeepTerms: [],
            mustNotBeLowPriority: [],
            mustNotBeBackground: []
        ),
        reference: GoldenCorpusReference(
            text: "ＡＢＣ、公開鍵。"
        )
    )

    let segments = [
        MaterializedTranscriptSegment(
            segmentID: "seg-0",
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "ABC 公開鍵",
            scene: .lecture,
            speakers: [],
            scopeSpans: [],
            contentPriority: .primary
        )
    ]

    let report = try GoldenCorpusEvaluator.evaluate(
        segments: segments,
        manifest: manifest
    )
    let evaluation = try #require(
        report.asrEvaluation
    )

    #expect(evaluation.raw.rate > 0)
    #expect(evaluation.normalized.rate == 0)
}

@Test
func goldenCorpusWithoutReferenceLeavesASRUnmeasured() throws {
    let manifest = GoldenCorpusManifest(
        id: "legacy",
        audio: "legacy.wav",
        annotations: GoldenCorpusAnnotations(
            sceneTransitions: [],
            mustKeepTerms: [],
            mustNotBeLowPriority: [],
            mustNotBeBackground: []
        )
    )

    let report = try GoldenCorpusEvaluator.evaluate(
        segments: [],
        manifest: manifest
    )

    #expect(report.asrEvaluation == nil)
}
