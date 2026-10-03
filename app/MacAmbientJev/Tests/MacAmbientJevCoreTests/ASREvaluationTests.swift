import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func normalizerAppliesNFKCAndDropsWhitespaceAndPunctuation() {
    #expect(
        JapaneseTextNormalizer.normalizeForCER(
            "ＡＢＣ　公開鍵、暗号。\n"
        ) == "ABC公開鍵暗号"
    )
}

@Test
func characterErrorRateCountsJapaneseDeletionAndInsertion() {
    let result = CharacterErrorRate.evaluate(
        reference: "公開鍵暗号",
        hypothesis: "公開暗号X"
    )

    #expect(result.substitutions == 0)
    #expect(result.deletions == 1)
    #expect(result.insertions == 1)
    #expect(result.referenceCharacters == 5)
    #expect(result.hypothesisCharacters == 5)
    #expect(abs(result.rate - 0.4) < 0.000_001)
}

@Test
func characterErrorRateCountsSubstitution() {
    let result = CharacterErrorRate.evaluate(
        reference: "猫",
        hypothesis: "犬"
    )

    #expect(result.substitutions == 1)
    #expect(result.deletions == 0)
    #expect(result.insertions == 0)
    #expect(result.rate == 1)
}

@Test
func emptyReferenceNeverProducesNonFiniteRate() {
    let bothEmpty = CharacterErrorRate.evaluate(
        reference: "",
        hypothesis: ""
    )
    #expect(bothEmpty.rate == 0)

    let insertionOnly = CharacterErrorRate.evaluate(
        reference: "",
        hypothesis: "abc"
    )
    #expect(insertionOnly.insertions == 3)
    #expect(insertionOnly.rate == 1)
}

@Test
func asrEvaluationReturnsRawAndNormalizedMetrics() {
    let result = ASREvaluation.evaluate(
        reference: "ＡＢＣ、公開鍵。",
        hypothesis: "ABC 公開鍵"
    )

    #expect(result.raw.rate > 0)
    #expect(result.normalized.rate == 0)
    #expect(result.normalizerVersion == JapaneseTextNormalizer.version)
}

private func decodeASRArtifact(_ json: String) throws -> ASRArtifact {
    try JSONDecoder().decode(ASRArtifact.self, from: Data(json.utf8))
}

@Test
func asrArtifactEvaluationScoresTheWholeAudioSegment() throws {
    let artifact = try decodeASRArtifact(#"""
    {
      "schema_version": 2,
      "segments": [
        {"start_ms": 0, "end_ms": 1500, "text": "公開鍵", "language": "Japanese"}
      ]
    }
    """#)

    let result = try ASRArtifactEvaluator.evaluate(
        reference: "公開鍵。",
        artifact: artifact
    )

    #expect(result.normalized.rate == 0)
}

@Test
func asrArtifactEvaluationRejectsOtherSchemaVersions() throws {
    let artifact = try decodeASRArtifact(#"""
    {"schema_version": 1, "segments": [{"start_ms": 0, "end_ms": 10, "text": "x"}]}
    """#)

    #expect(
        throws: ASRArtifactEvaluationError.unsupportedSchemaVersion(1)
    ) {
        _ = try ASRArtifactEvaluator.evaluate(
            reference: "x",
            artifact: artifact
        )
    }
}

@Test
func asrArtifactEvaluationRequiresExactlyOneSegment() throws {
    let artifact = try decodeASRArtifact(#"""
    {
      "schema_version": 2,
      "segments": [
        {"start_ms": 0, "end_ms": 10, "text": "a"},
        {"start_ms": 10, "end_ms": 20, "text": "b"}
      ]
    }
    """#)

    #expect(throws: ASRArtifactEvaluationError.segmentCount(2)) {
        _ = try ASRArtifactEvaluator.evaluate(
            reference: "ab",
            artifact: artifact
        )
    }
}

@Test
func asrArtifactEvaluationRejectsSegmentNotStartingAtZero() throws {
    let artifact = try decodeASRArtifact(#"""
    {"schema_version": 2, "segments": [{"start_ms": 5, "end_ms": 10, "text": "x"}]}
    """#)

    #expect(throws: ASRArtifactEvaluationError.invalidSegmentRange) {
        _ = try ASRArtifactEvaluator.evaluate(
            reference: "x",
            artifact: artifact
        )
    }
}

@Test
func asrArtifactDecodingRejectsNonStringText() {
    #expect(throws: DecodingError.self) {
        _ = try decodeASRArtifact(#"""
        {"schema_version": 2, "segments": [{"start_ms": 0, "end_ms": 10, "text": 3}]}
        """#)
    }
}
