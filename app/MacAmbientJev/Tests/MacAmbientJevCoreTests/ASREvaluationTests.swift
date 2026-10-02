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
}
