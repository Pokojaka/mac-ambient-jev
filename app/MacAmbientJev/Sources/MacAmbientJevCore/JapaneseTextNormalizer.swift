import Foundation

public enum JapaneseTextNormalizer {
    /// Identifies the CER normalization rules below. Change it whenever
    /// normalizeForCER changes so baselines never compare across rules.
    public static let version = "1"

    public static func normalizeForCER(_ text: String) -> String {
        let normalized = text.precomposedStringWithCompatibilityMapping
        return String(normalized.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
        })
    }
}
