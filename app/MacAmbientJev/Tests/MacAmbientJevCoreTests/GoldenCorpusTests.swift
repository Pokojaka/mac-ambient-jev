import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func goldenCorpusKeepsRequiredTechnicalContent() throws {
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
            contentPriority: .primary,
            isDiarized: false
        )
    ]

    let report = try GoldenCorpusEvaluator.evaluate(
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
func goldenCorpusCountsFalseExclusionsConservatively() throws {
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
            contentPriority: .lowPriority,
            isDiarized: false
        )
    ]

    let report = try GoldenCorpusEvaluator.evaluate(
        segments: segments,
        manifest: manifest
    )

    #expect(report.falseLowPriorityCount == 1)
    #expect(report.falseBackgroundCount == 1)
}

@Test
func goldenCorpusReportsUnannotatedMetricsAsNull() throws {
    let manifest = GoldenCorpusManifest(
        id: "exploration-only",
        audio: "recording.m4a",
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

    #expect(report.technicalTermRetention == nil)
    #expect(report.falseLowPriorityCount == nil)
    #expect(report.falseBackgroundCount == nil)
    #expect(report.sceneTransitionErrorMilliseconds == nil)

    let data = try JSONEncoder().encode(report)
    let json = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(json["technical_term_retention"] is NSNull)
    #expect(json["false_low_priority_count"] is NSNull)
    #expect(json["false_background_count"] is NSNull)
    #expect(json["scene_transition_error_ms"] is NSNull)
}

@Test
func goldenCorpusRejectsOutOfRangeLowPriorityAnnotations() throws {
    let manifest = GoldenCorpusManifest(
        id: "invalid-low-priority-index",
        audio: "recording.m4a",
        annotations: GoldenCorpusAnnotations(
            sceneTransitions: [],
            mustKeepTerms: [],
            mustNotBeLowPriority: [1],
            mustNotBeBackground: []
        )
    )
    let segments = [goldenTestSegment()]

    var errorMessage: String?
    do {
        _ = try GoldenCorpusEvaluator.evaluate(
            segments: segments,
            manifest: manifest
        )
    } catch {
        errorMessage = error.localizedDescription
    }

    #expect(errorMessage?.contains("must_not_be_low_priority[1]") == true)
    #expect(errorMessage?.contains("1 件") == true)
}

@Test
func goldenCorpusRejectsOutOfRangeBackgroundAnnotations() throws {
    let manifest = GoldenCorpusManifest(
        id: "invalid-background-index",
        audio: "recording.m4a",
        annotations: GoldenCorpusAnnotations(
            sceneTransitions: [],
            mustKeepTerms: [],
            mustNotBeLowPriority: [],
            mustNotBeBackground: [1]
        )
    )
    let segments = [goldenTestSegment()]

    var errorMessage: String?
    do {
        _ = try GoldenCorpusEvaluator.evaluate(
            segments: segments,
            manifest: manifest
        )
    } catch {
        errorMessage = error.localizedDescription
    }

    #expect(errorMessage?.contains("must_not_be_background[1]") == true)
    #expect(errorMessage?.contains("1 件") == true)
}

@Test
func goldenCorpusRejectsEmptyRequiredTerms() throws {
    for invalidTerm in ["", " \n\t"] {
        let manifest = GoldenCorpusManifest(
            id: "invalid-required-term",
            audio: "recording.m4a",
            annotations: GoldenCorpusAnnotations(
                sceneTransitions: [],
                mustKeepTerms: [invalidTerm],
                mustNotBeLowPriority: [],
                mustNotBeBackground: []
            )
        )

        var errorMessage: String?
        do {
            _ = try GoldenCorpusEvaluator.evaluate(
                segments: [],
                manifest: manifest
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        #expect(errorMessage?.contains("must_keep_terms[0]") == true)
    }
}

@Test
func goldenCorpusReportsMissingSceneObservationAsUnmeasured() throws {
    let manifest = GoldenCorpusManifest(
        id: "scene-observation-not-provided",
        audio: "recording.m4a",
        annotations: GoldenCorpusAnnotations(
            sceneTransitions: [
                GoldenSceneTransition(timeMilliseconds: 5_000, to: .discussion)
            ],
            mustKeepTerms: [],
            mustNotBeLowPriority: [],
            mustNotBeBackground: []
        )
    )

    let report = try GoldenCorpusEvaluator.evaluate(
        segments: [],
        manifest: manifest
    )

    #expect(report.sceneTransitionErrorMilliseconds == nil)
    #expect(report.sceneOscillationCount == nil)

    let data = try JSONEncoder().encode(report)
    let json = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(json["scene_transition_error_ms"] is NSNull)
    #expect(json["scene_oscillation_count"] is NSNull)
}

@Test
func goldenCorpusCountsAnExplicitEmptySceneObservation() throws {
    let manifest = GoldenCorpusManifest(
        id: "scene-observation-has-no-transitions",
        audio: "recording.m4a",
        annotations: GoldenCorpusAnnotations(
            sceneTransitions: [
                GoldenSceneTransition(timeMilliseconds: 5_000, to: .discussion)
            ],
            mustKeepTerms: [],
            mustNotBeLowPriority: [],
            mustNotBeBackground: []
        )
    )

    let report = try GoldenCorpusEvaluator.evaluate(
        segments: [],
        manifest: manifest,
        observedSceneTransitions: []
    )

    #expect(report.sceneTransitionErrorMilliseconds == -1)
    #expect(report.sceneOscillationCount == 0)
}

private func goldenTestSegment() -> MaterializedTranscriptSegment {
    MaterializedTranscriptSegment(
        segmentID: "seg-0",
        startMilliseconds: 0,
        endMilliseconds: 1_000,
        text: "重要な内容",
        scene: .lecture,
        speakers: [],
        scopeSpans: [],
        contentPriority: .primary,
        isDiarized: false
    )
}
