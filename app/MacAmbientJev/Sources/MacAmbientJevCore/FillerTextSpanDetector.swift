import Foundation

public struct TranscriptTextFragment: Sendable, Equatable {
    public let text: String
    public let isFiller: Bool

    public init(text: String, isFiller: Bool) {
        self.text = text
        self.isFiller = isFiller
    }
}

public struct FillerTextSpanDetector: Sendable {
    private static let fillerPhrases = [
        "えーと", "ええと", "えっと", "うーん", "えー", "ええ", "あー", "ああ", "んー"
    ]
    private static let attachableLeadingFillers: Set<String> = ["えー", "あー", "えっと"]
    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
    private static let openingPunctuationCategories: Set<Unicode.GeneralCategory> = [
        .openPunctuation, .initialPunctuation
    ]
    private static let ambiguousQuotes: Set<Unicode.Scalar> = ["\"", "'"]

    public init() {}

    public func fragments(in text: String) -> [TranscriptTextFragment] {
        guard !text.isEmpty else { return [] }

        var fragments: [TranscriptTextFragment] = []
        var fragmentStart = text.startIndex
        var searchIndex = text.startIndex

        while searchIndex < text.endIndex {
            guard isBoundary(before: searchIndex, in: text),
                  let fillerRange = fillerRange(
                    at: searchIndex,
                    in: text,
                    allowAttachedLeading: isUtteranceLeading(searchIndex, in: text)
                  ) else {
                searchIndex = text.index(after: searchIndex)
                continue
            }

            var fillerEnd = fillerRange.upperBound
            while fillerEnd < text.endIndex,
                  isTrailingPunctuation(text[fillerEnd]) {
                fillerEnd = text.index(after: fillerEnd)
            }

            if fragmentStart < searchIndex {
                fragments.append(TranscriptTextFragment(
                    text: String(text[fragmentStart..<searchIndex]),
                    isFiller: false
                ))
            }
            fragments.append(TranscriptTextFragment(
                text: String(text[searchIndex..<fillerEnd]),
                isFiller: true
            ))
            fragmentStart = fillerEnd
            searchIndex = fillerEnd
        }

        if fragmentStart < text.endIndex {
            fragments.append(TranscriptTextFragment(
                text: String(text[fragmentStart..<text.endIndex]),
                isFiller: false
            ))
        }

        if fragments.isEmpty {
            return [TranscriptTextFragment(text: text, isFiller: false)]
        }
        return fragments
    }

    private func fillerRange(
        at index: String.Index,
        in text: String,
        allowAttachedLeading: Bool
    ) -> Range<String.Index>? {
        for phrase in Self.fillerPhrases {
            guard let range = text.range(
                of: phrase,
                options: [.anchored],
                range: index..<text.endIndex
            ) else {
                continue
            }

            guard isBoundary(at: range.upperBound, in: text)
                    || (allowAttachedLeading
                        && Self.attachableLeadingFillers.contains(phrase)
                        && !isKana(at: range.upperBound, in: text)) else {
                continue
            }
            return range
        }
        return nil
    }

    private func isBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        return isSeparator(text[text.index(before: index)])
    }

    private func isUtteranceLeading(_ index: String.Index, in text: String) -> Bool {
        text[..<index].unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
    }

    private func isKana(at index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return false }
        return text[index].unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x31F0...0x31FF).contains(scalar.value)
        }
    }

    private func isBoundary(at index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return true }
        return isSeparator(text[index])
    }

    private func isSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(Self.separators.contains)
    }

    private func isTrailingPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.punctuationCharacters.contains(scalar)
                && !Self.openingPunctuationCategories.contains(scalar.properties.generalCategory)
                && !Self.ambiguousQuotes.contains(scalar)
        }
    }
}
