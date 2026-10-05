import Foundation


public struct FillerTextSpanDetector: Sendable {
    private static let fillerPhrases = [
        "えーと", "ええと", "えっと", "うーん", "えー", "ええ", "あー", "ああ", "んー"
    ]
    private static let attachableLeadingFillers: Set<String> = ["えー", "あー", "えっと"]
    private static let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    private static let openingPunctuationCategories: Set<Unicode.GeneralCategory> = [.openPunctuation, .initialPunctuation]
    private static let ambiguousQuotes: Set<Unicode.Scalar> = ["\"", "'", "＂", "＇"]

    public init() {}

    public func ranges(in text: String) throws -> [TextUTF16Range] {
        guard !text.isEmpty else { return [] }
        var result: [TextUTF16Range] = []
        var sourceOffset = 0
        var searchIndex = text.startIndex
        var isLeadingWhitespace = true
        while searchIndex < text.endIndex {
            guard isBoundary(before: searchIndex, in: text),
                  let phraseRange = fillerRange(at: searchIndex, in: text,
                                                allowAttachedLeading: isLeadingWhitespace) else {
                if !text[searchIndex].unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) {
                    isLeadingWhitespace = false
                }
                sourceOffset += text[searchIndex].utf16.count
                searchIndex = text.index(after: searchIndex)
                continue
            }
            var fillerEnd = phraseRange.upperBound
            while fillerEnd < text.endIndex, isTrailingPunctuation(text[fillerEnd]) {
                fillerEnd = text.index(after: fillerEnd)
            }
            let start = sourceOffset
            sourceOffset += text[searchIndex..<fillerEnd].utf16.count
            isLeadingWhitespace = false
            result.append(try TextUTF16Range(start: start, end: sourceOffset))
            searchIndex = fillerEnd
        }
        return result
    }

    private func fillerRange(at index: String.Index, in text: String, allowAttachedLeading: Bool) -> Range<String.Index>? {
        for phrase in Self.fillerPhrases {
            guard let range = text.range(of: phrase, options: [.anchored], range: index..<text.endIndex) else { continue }
            guard isBoundary(at: range.upperBound, in: text)
                    || (allowAttachedLeading && Self.attachableLeadingFillers.contains(phrase)
                        && !isKana(at: range.upperBound, in: text)) else { continue }
            return range
        }
        return nil
    }

    private func isBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        return isSeparator(text[text.index(before: index)])
    }
    private func isKana(at index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return false }
        return text[index].unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x31F0...0x31FF).contains($0.value) }
    }
    private func isBoundary(at index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return true }
        return isSeparator(text[index])
    }
    private func isSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(Self.separators.contains)
    }
    private func isTrailingPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                && !Self.openingPunctuationCategories.contains($0.properties.generalCategory)
                && !Self.ambiguousQuotes.contains($0)
        }
    }
}
