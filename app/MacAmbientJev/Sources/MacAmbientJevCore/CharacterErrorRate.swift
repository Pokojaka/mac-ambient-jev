import Foundation

public enum ReferenceTextError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalid(position: Int, reason: String)

    public var description: String {
        switch self {
        case let .invalid(position, reason):
            "Invalid reference text at position \(position): \(reason)"
        }
    }
}

public struct CharacterErrorRateResult: Codable, Sendable, Equatable {
    public let rate: Double
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int
    public let requiredReferenceCharacters: Int
    public let optionalReferenceCharacters: Int
    public let hypothesisCharacters: Int

    public init(
        rate: Double,
        substitutions: Int,
        deletions: Int,
        insertions: Int,
        requiredReferenceCharacters: Int,
        optionalReferenceCharacters: Int,
        hypothesisCharacters: Int
    ) {
        self.rate = rate
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.requiredReferenceCharacters = requiredReferenceCharacters
        self.optionalReferenceCharacters = optionalReferenceCharacters
        self.hypothesisCharacters = hypothesisCharacters
    }

    enum CodingKeys: String, CodingKey {
        case rate
        case substitutions
        case deletions
        case insertions
        case requiredReferenceCharacters = "required_reference_characters"
        case optionalReferenceCharacters = "optional_reference_characters"
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
    ) throws -> CharacterErrorRateResult {
        let pieces = try parseReference(reference)
        var referenceCharacters: [(character: Character, optional: Bool)] = []
        for piece in pieces {
            let normalized = JapaneseTextNormalizer.normalizeForCER(piece.text)
            referenceCharacters.append(contentsOf: normalized.map {
                (character: $0, optional: piece.optional)
            })
        }
        let hypothesisCharacters = Array(
            JapaneseTextNormalizer.normalizeForCER(hypothesis)
        )
        let requiredCount = referenceCharacters.filter { !$0.optional }.count
        let optionalCount = referenceCharacters.count - requiredCount

        var previous = (0...hypothesisCharacters.count).map { index in
            Cell(distance: index, substitutions: 0, deletions: 0, insertions: index)
        }

        for referenceCharacter in referenceCharacters {
            let deletionCost = referenceCharacter.optional ? 0 : 1
            var current = [
                Cell(
                    distance: previous[0].distance + deletionCost,
                    substitutions: previous[0].substitutions,
                    deletions: previous[0].deletions + (referenceCharacter.optional ? 0 : 1),
                    insertions: previous[0].insertions
                )
            ]

            for hypothesisIndex in hypothesisCharacters.indices {
                let hypothesisCharacter = hypothesisCharacters[hypothesisIndex]
                let matches = referenceCharacter.character == hypothesisCharacter
                let diagonalBase = previous[hypothesisIndex]
                let deletionBase = previous[hypothesisIndex + 1]
                let insertionBase = current[hypothesisIndex]
                let candidates = [
                    Cell(
                        distance: diagonalBase.distance + (matches ? 0 : 1),
                        substitutions: diagonalBase.substitutions + (matches ? 0 : 1),
                        deletions: diagonalBase.deletions,
                        insertions: diagonalBase.insertions
                    ),
                    Cell(
                        distance: deletionBase.distance + deletionCost,
                        substitutions: deletionBase.substitutions,
                        deletions: deletionBase.deletions + (referenceCharacter.optional ? 0 : 1),
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
        let rate = requiredCount == 0
            ? (result.distance == 0 ? 0 : 1)
            : Double(result.distance) / Double(requiredCount)
        return CharacterErrorRateResult(
            rate: rate,
            substitutions: result.substitutions,
            deletions: result.deletions,
            insertions: result.insertions,
            requiredReferenceCharacters: requiredCount,
            optionalReferenceCharacters: optionalCount,
            hypothesisCharacters: hypothesisCharacters.count
        )
    }

    private static func parseReference(
        _ reference: String
    ) throws -> [(text: String, optional: Bool)] {
        let characters = Array(reference)
        var pieces: [(text: String, optional: Bool)] = []
        var requiredText = ""
        var index = 0

        while index < characters.count {
            if characters[index] == "(" {
                if !requiredText.isEmpty {
                    pieces.append((text: requiredText, optional: false))
                    requiredText = ""
                }
                let openingPosition = index + 1
                guard index + 2 < characters.count,
                      characters[index + 2] == " ",
                      characters[index + 1] == "F" || characters[index + 1] == "D"
                else {
                    throw ReferenceTextError.invalid(
                        position: openingPosition,
                        reason: "expected an ASCII '(F ' or '(D ' marker"
                    )
                }
                index += 3
                var content = ""
                while index < characters.count && characters[index] != ")" {
                    guard characters[index] != "(" else {
                        throw ReferenceTextError.invalid(
                            position: index + 1,
                            reason: "nested ASCII '(' is not allowed"
                        )
                    }
                    content.append(characters[index])
                    index += 1
                }
                guard index < characters.count else {
                    throw ReferenceTextError.invalid(
                        position: openingPosition,
                        reason: "missing closing ASCII ')'"
                    )
                }
                pieces.append((text: content, optional: true))
                index += 1
            } else if characters[index] == ")" {
                throw ReferenceTextError.invalid(
                    position: index + 1,
                    reason: "stray ASCII ')'"
                )
            } else {
                requiredText.append(characters[index])
                index += 1
            }
        }
        if !requiredText.isEmpty {
            pieces.append((text: requiredText, optional: false))
        }
        return pieces
    }
}
