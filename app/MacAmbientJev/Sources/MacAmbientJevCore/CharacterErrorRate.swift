import Foundation

public struct CharacterErrorRateResult: Codable, Sendable, Equatable {
    public let rate: Double
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int
    public let referenceCharacters: Int
    public let hypothesisCharacters: Int

    public init(
        rate: Double,
        substitutions: Int,
        deletions: Int,
        insertions: Int,
        referenceCharacters: Int,
        hypothesisCharacters: Int
    ) {
        self.rate = rate
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceCharacters = referenceCharacters
        self.hypothesisCharacters = hypothesisCharacters
    }

    enum CodingKeys: String, CodingKey {
        case rate
        case substitutions
        case deletions
        case insertions
        case referenceCharacters = "reference_characters"
        case hypothesisCharacters = "hypothesis_characters"
    }
}

public enum CharacterErrorRate {
    private struct Cell {
        let distance: Int
        let substitutions: Int
        let deletions: Int
        let insertions: Int
    }

    public static func evaluate(
        reference: String,
        hypothesis: String
    ) -> CharacterErrorRateResult {
        let referenceCharacters = Array(reference)
        let hypothesisCharacters = Array(hypothesis)

        if referenceCharacters.isEmpty {
            let insertions = hypothesisCharacters.count
            return CharacterErrorRateResult(
                rate: insertions == 0 ? 0 : 1,
                substitutions: 0,
                deletions: 0,
                insertions: insertions,
                referenceCharacters: 0,
                hypothesisCharacters: hypothesisCharacters.count
            )
        }

        var previous = (0...hypothesisCharacters.count).map { index in
            Cell(
                distance: index,
                substitutions: 0,
                deletions: 0,
                insertions: index
            )
        }

        for (referenceIndex, referenceCharacter)
            in referenceCharacters.enumerated() {
            var current = [
                Cell(
                    distance: referenceIndex + 1,
                    substitutions: 0,
                    deletions: referenceIndex + 1,
                    insertions: 0
                )
            ]

            for hypothesisIndex in hypothesisCharacters.indices {
                let hypothesisCharacter =
                    hypothesisCharacters[hypothesisIndex]
                if referenceCharacter == hypothesisCharacter {
                    current.append(previous[hypothesisIndex])
                    continue
                }

                let substitutionBase = previous[hypothesisIndex]
                let deletionBase = previous[hypothesisIndex + 1]
                let insertionBase = current[hypothesisIndex]
                let candidates = [
                    Cell(
                        distance: substitutionBase.distance + 1,
                        substitutions:
                            substitutionBase.substitutions + 1,
                        deletions: substitutionBase.deletions,
                        insertions: substitutionBase.insertions
                    ),
                    Cell(
                        distance: deletionBase.distance + 1,
                        substitutions: deletionBase.substitutions,
                        deletions: deletionBase.deletions + 1,
                        insertions: deletionBase.insertions
                    ),
                    Cell(
                        distance: insertionBase.distance + 1,
                        substitutions: insertionBase.substitutions,
                        deletions: insertionBase.deletions,
                        insertions: insertionBase.insertions + 1
                    )
                ]
                current.append(candidates.min { lhs, rhs in
                    if lhs.distance != rhs.distance {
                        return lhs.distance < rhs.distance
                    }
                    if lhs.substitutions != rhs.substitutions {
                        return lhs.substitutions < rhs.substitutions
                    }
                    if lhs.deletions != rhs.deletions {
                        return lhs.deletions < rhs.deletions
                    }
                    return lhs.insertions < rhs.insertions
                }!)
            }
            previous = current
        }

        let result = previous[hypothesisCharacters.count]
        return CharacterErrorRateResult(
            rate: Double(result.distance)
                / Double(referenceCharacters.count),
            substitutions: result.substitutions,
            deletions: result.deletions,
            insertions: result.insertions,
            referenceCharacters: referenceCharacters.count,
            hypothesisCharacters: hypothesisCharacters.count
        )
    }
}
