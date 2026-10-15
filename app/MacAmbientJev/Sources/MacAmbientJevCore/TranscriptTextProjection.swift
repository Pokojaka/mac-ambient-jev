import Foundation

public struct RetainedTextRun: Sendable, Equatable {
    public let sourceRange: TextUTF16Range
    public let displayRange: TextUTF16Range
    public init(sourceRange: TextUTF16Range, displayRange: TextUTF16Range) {
        self.sourceRange = sourceRange
        self.displayRange = displayRange
    }
}

public struct CleanedTranscriptText: Sendable, Equatable {
    public let text: String
    public let removedRanges: [TextUTF16Range]
    public let retainedRuns: [RetainedTextRun]
    // Includes 0 and the source end, including boundaries inside deleted text.
    let sourceCharacterBoundaries: [Int]
    var sourceUTF16Length: Int { sourceCharacterBoundaries[sourceCharacterBoundaries.count - 1] }

    func validateSourceRange(_ range: TextUTF16Range) throws {
        guard range.end <= sourceUTF16Length else {
            throw TextUTF16RangeError.invalidBounds(start: range.start, end: range.end)
        }
        func isCharacterBoundary(_ offset: Int) -> Bool {
            var lower = 0
            var upper = sourceCharacterBoundaries.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if sourceCharacterBoundaries[middle] < offset {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower < sourceCharacterBoundaries.count && sourceCharacterBoundaries[lower] == offset
        }
        guard isCharacterBoundary(range.start), isCharacterBoundary(range.end) else {
            throw TextUTF16RangeError.invalidCharacterBoundary(start: range.start, end: range.end)
        }
    }

    public func displayRanges(for sourceRange: TextUTF16Range) throws -> [TextUTF16Range] {
        try validateSourceRange(sourceRange)
        var lowerBound = 0
        var upperBound = retainedRuns.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if retainedRuns[middle].sourceRange.end <= sourceRange.start {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        var result: [TextUTF16Range] = []
        for run in retainedRuns[lowerBound...] {
            guard run.sourceRange.start < sourceRange.end else { break }
            let start = max(sourceRange.start, run.sourceRange.start)
            let end = min(sourceRange.end, run.sourceRange.end)
            guard start < end else { continue }
            result.append(try TextUTF16Range(
                start: run.displayRange.start + start - run.sourceRange.start,
                end: run.displayRange.start + end - run.sourceRange.start
            ))
        }
        return result
    }
}

public struct TranscriptTextProjector: Sendable {
    private static let openingPunctuationCategories: Set<Unicode.GeneralCategory> = [.openPunctuation, .initialPunctuation]
    private static let ambiguousQuotes: Set<Unicode.Scalar> = ["\"", "'", "＂", "＇"]

    public init() {}

    public func project(sourceText: String, fillerRanges: [TextUTF16Range]) throws -> CleanedTranscriptText {
        var boundaries = [0]
        var boundaryIndices = [sourceText.startIndex]
        var sourceLength = 0
        var characterIndex = sourceText.startIndex
        while characterIndex < sourceText.endIndex {
            sourceLength += sourceText[characterIndex].utf16.count
            characterIndex = sourceText.index(after: characterIndex)
            boundaries.append(sourceLength)
            boundaryIndices.append(characterIndex)
        }

        func boundaryIndex(for offset: Int) -> Int? {
            var lower = 0
            var upper = boundaries.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if boundaries[middle] < offset {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower < boundaries.count && boundaries[lower] == offset ? lower : nil
        }

        var previousEnd: Int?
        var validatedEndIndices: [String.Index] = []
        for range in fillerRanges {
            guard range.start < range.end,
                  range.end <= sourceLength,
                  previousEnd.map({ range.start > $0 }) ?? true else {
                throw TextUTF16RangeError.invalidBounds(start: range.start, end: range.end)
            }
            guard boundaryIndex(for: range.start) != nil,
                  let endBoundary = boundaryIndex(for: range.end) else {
                throw TextUTF16RangeError.invalidCharacterBoundary(start: range.start, end: range.end)
            }
            validatedEndIndices.append(boundaryIndices[endBoundary])
            previousEnd = range.end
        }

        var removed: [TextUTF16Range] = []
        for (range, endIndex) in zip(fillerRanges, validatedEndIndices) {
            var expandedEnd = range.end
            var trailingIndex = endIndex
            while trailingIndex < sourceText.endIndex, Self.isTrailingPunctuation(sourceText[trailingIndex]) {
                expandedEnd += sourceText[trailingIndex].utf16.count
                trailingIndex = sourceText.index(after: trailingIndex)
            }

            if let previous = removed.last, range.start <= previous.end {
                removed[removed.count - 1] = try TextUTF16Range(
                    start: previous.start, end: max(previous.end, expandedEnd)
                )
            } else {
                removed.append(try TextUTF16Range(start: range.start, end: expandedEnd))
            }
        }

        let sourceUTF16 = sourceText.utf16
        var sourceIndex = sourceUTF16.startIndex
        var cursor = 0
        var displayOffset = 0
        var output = ""
        output.reserveCapacity(sourceText.utf8.count)
        var runs: [RetainedTextRun] = []
        // Advance from the previous endpoint; never rescan the source prefix per run.
        for index in 0...removed.count {
            let start = index < removed.count ? removed[index].start : sourceLength
            let end = index < removed.count ? removed[index].end : sourceLength
            let retainedEnd = sourceUTF16.index(sourceIndex, offsetBy: start - cursor)
            if cursor < start {
                guard let lower = String.Index(sourceIndex, within: sourceText),
                      let upper = String.Index(retainedEnd, within: sourceText) else {
                    throw TextUTF16RangeError.invalidCharacterBoundary(start: cursor, end: start)
                }
                let retained = try TextUTF16Range(start: cursor, end: start)
                let display = try TextUTF16Range(start: displayOffset, end: displayOffset + start - cursor)
                runs.append(RetainedTextRun(sourceRange: retained, displayRange: display))
                output.append(contentsOf: sourceText[lower..<upper])
                displayOffset = display.end
            }
            sourceIndex = sourceUTF16.index(retainedEnd, offsetBy: end - start)
            cursor = end
        }
        return CleanedTranscriptText(
            text: output, removedRanges: removed, retainedRuns: runs, sourceCharacterBoundaries: boundaries
        )
    }

    private static func isTrailingPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                && !openingPunctuationCategories.contains($0.properties.generalCategory)
                && !ambiguousQuotes.contains($0)
        }
    }
}
