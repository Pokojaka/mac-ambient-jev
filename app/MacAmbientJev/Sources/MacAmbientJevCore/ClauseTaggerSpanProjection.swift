import Foundation

public enum ClauseTaggerSpanProjectionError: Error, Sendable, Equatable {
    case invalidPrediction
}

public enum ClauseTaggerSpanProjection {
    /// Labels UTF-16 positions from scalar-aligned tokens, then removes Characters whose positions are all F or B.
    public static func removalRanges(
        sourceText: String,
        tokenRanges: [TextUTF16Range],
        spanProbabilities: [[Double]]
    ) throws -> [TextUTF16Range] {
        guard tokenRanges.count == spanProbabilities.count else {
            throw ClauseTaggerSpanProjectionError.invalidPrediction
        }

        let sourceLength = sourceText.utf16.count
        var scalarBoundaries: Set<Int> = [0]
        var scalarOffset = 0
        for scalar in sourceText.unicodeScalars {
            scalarOffset += scalar.value > 0xFFFF ? 2 : 1
            scalarBoundaries.insert(scalarOffset)
        }
        guard scalarOffset == sourceLength else {
            throw ClauseTaggerSpanProjectionError.invalidPrediction
        }

        for (range, probabilities) in zip(tokenRanges, spanProbabilities) {
            guard range.start >= 0,
                  range.start < range.end,
                  range.end <= sourceLength,
                  scalarBoundaries.contains(range.start),
                  scalarBoundaries.contains(range.end),
                  probabilities.count == 4,
                  probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  abs(probabilities.reduce(0, +) - 1) <= taggerProbabilitySumTolerance else {
                throw ClauseTaggerSpanProjectionError.invalidPrediction
            }
        }

        // Class order is O, F, D, B; strict-greater argmax keeps the lowest index on ties.
        var labels = Array(repeating: 0, count: sourceLength)
        for (range, probabilities) in zip(tokenRanges, spanProbabilities) {
            var label = 0
            for index in 1..<probabilities.count where probabilities[index] > probabilities[label] {
                label = index
            }
            for offset in range.start..<range.end {
                labels[offset] = label
            }
        }

        var removalRanges: [TextUTF16Range] = []
        var removalStart: Int?
        var offset = 0
        for character in sourceText {
            let characterEnd = offset + character.utf16.count
            let isRemoved = labels[offset..<characterEnd].allSatisfy { $0 == 1 || $0 == 3 }
            if isRemoved {
                if removalStart == nil {
                    removalStart = offset
                }
            } else if let start = removalStart {
                removalRanges.append(try TextUTF16Range(start: start, end: offset))
                removalStart = nil
            }
            offset = characterEnd
        }
        if let start = removalStart {
            removalRanges.append(try TextUTF16Range(start: start, end: offset))
        }
        return removalRanges
    }
}
