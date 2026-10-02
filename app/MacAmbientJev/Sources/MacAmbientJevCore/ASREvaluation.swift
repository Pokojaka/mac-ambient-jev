import Foundation

public struct ASREvaluationResult: Codable, Sendable, Equatable {
    public let raw: CharacterErrorRateResult
    public let normalized: CharacterErrorRateResult

    public init(
        raw: CharacterErrorRateResult,
        normalized: CharacterErrorRateResult
    ) {
        self.raw = raw
        self.normalized = normalized
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
            )
        )
    }
}
