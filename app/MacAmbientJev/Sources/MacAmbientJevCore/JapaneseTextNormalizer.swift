import Foundation

public enum JapaneseTextNormalizer {
    public static func normalizeForCER(_ text: String) -> String {
        let normalized = text.precomposedStringWithCompatibilityMapping
        return String(normalized.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
        })
    }
}
