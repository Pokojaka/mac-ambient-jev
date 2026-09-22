import Testing
@testable import MacAmbientJevCore

@Test
func goldenCorpusKeepsRequiredTechnicalContent() {
    let manifest = GoldenCorpusManifest(
        id: "synthetic-ja-001",
        audio: "synthetic.wav",
        annotations: GoldenCorpusAnnotations(
            sceneTransitions: [
                GoldenSceneTransition(timeMilliseconds: 5_000, to: .discussion)
            ],
            mustKeepTerms: ["RSA", "公開鍵"],
            mustNotBeLowPriority: [0],
            mustNotBeBackground: [0]
        )
    )

    let segments = [
        MaterializedTranscriptSegment(
            segmentID: "seg-0",
            startMilliseconds: 0,
            endMilliseconds: 8_000,
            text: "RSAでは公開鍵を使います",
            scene: .lecture,
            speakers: [],
            scopeSpans: [],
            contentPriority: .primary
        )
    ]

    let report = GoldenCorpusEvaluator.evaluate(
        segments: segments,
        manifest: manifest,
        observedSceneTransitions: [
            GoldenSceneTransition(timeMilliseconds: 5_000, to: .discussion)
        ]
    )

    #expect(report.technicalTermRetention == 1)
    #expect(report.falseLowPriorityCount == 0)
    #expect(report.falseBackgroundCount == 0)
    #expect(report.sceneTransitionErrorMilliseconds == 0)
    #expect(report.sceneOscillationCount == 0)
}

@Test
func goldenCorpusCountsFalseExclusionsConservatively() {
    let manifest = GoldenCorpusManifest(
        id: "synthetic-ja-002",
        audio: "synthetic.wav",
        annotations: GoldenCorpusAnnotations(
            sceneTransitions: [],
            mustKeepTerms: [],
            mustNotBeLowPriority: [0],
            mustNotBeBackground: [0]
        )
    )

    let segments = [
        MaterializedTranscriptSegment(
            segmentID: "seg-0",
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "重要な内容",
            scene: .discussion,
            speakers: [],
            scopeSpans: [
                MaterializedScopeSpan(
                    startMilliseconds: 0,
                    endMilliseconds: 1_000,
                    scope: .background,
                    confidence: 0.95
                )
            ],
            contentPriority: .lowPriority
        )
    ]

    let report = GoldenCorpusEvaluator.evaluate(
        segments: segments,
        manifest: manifest
    )

    #expect(report.falseLowPriorityCount == 1)
    #expect(report.falseBackgroundCount == 1)
}
