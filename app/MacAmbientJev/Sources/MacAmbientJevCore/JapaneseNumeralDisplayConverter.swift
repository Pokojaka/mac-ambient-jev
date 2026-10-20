// Supports 〇零一二三四五六七八九, 十百千万億, and 点 decimals. Positional groups
// descend through 千/百/十; 万 and 億 require explicit nonempty coefficients. Kanji block
// boundaries follow Unicode 17.0: https://www.unicode.org/versions/Unicode17.0.0/core-spec/chapter-18/.
internal enum JapaneseNumeralDisplayConverter {
    static func convert(_ text: String) -> String {
        let characters = Array(text)
        guard characters.contains(where: isNumeral) else { return text }
        let protectedPositions = precomputeProtectedPositions(in: characters)
        var output: [Character] = []
        var index = 0

        while index < characters.count {
            guard isNumeral(characters[index]) else {
                output.append(characters[index])
                index += 1
                continue
            }

            let runStart = index
            var runEnd = index + 1
            while runEnd < characters.count && isNumeral(characters[runEnd]) {
                runEnd += 1
            }

            var candidateEnd = runEnd
            var fractionalRange: Range<Int>?
            if runEnd + 1 < characters.count,
               isDecimalPoint(characters[runEnd]),
               isNumeral(characters[runEnd + 1]) {
                var fractionalEnd = runEnd + 2
                while fractionalEnd < characters.count && isNumeral(characters[fractionalEnd]) {
                    fractionalEnd += 1
                }
                fractionalRange = (runEnd + 1)..<fractionalEnd
                candidateEnd = fractionalEnd
            }

            let hasBlockingBoundary = hasBlockingBoundary(
                in: characters,
                before: runStart,
                after: candidateEnd
            )
            let overlapsProtection = protectedPositions[runStart..<candidateEnd].contains(true)
            var replacement: String?

            if !hasBlockingBoundary && !overlapsProtection {
                let integerCharacters = Array(characters[runStart..<runEnd])
                if let integer = parseInteger(integerCharacters) {
                    if let fractionalRange {
                        let fractionCharacters = Array(characters[fractionalRange])
                        if let fraction = parseFraction(fractionCharacters) {
                            replacement = "\(integer).\(fraction)"
                        }
                    } else {
                        replacement = integer
                    }
                }
            }

            if let replacement {
                output.append(contentsOf: replacement)
            } else {
                output.append(contentsOf: characters[runStart..<candidateEnd])
            }
            index = candidateEnd
        }

        return String(output)
    }

    private static let phraseIndex: [Character: [[Character]]] = {
        var index: [Character: [[Character]]] = [:]
        for phrase in JapaneseNumeralExclusionPhrases.phrases {
            let characters = Array(phrase)
            precondition(!characters.isEmpty, "Japanese numeral exclusion phrases must not be empty")
            index[characters[0], default: []].append(characters)
        }
        return index
    }()

    private static func precomputeProtectedPositions(in characters: [Character]) -> [Bool] {
        var protected = Array(repeating: false, count: characters.count)
        protectFractionRuns(in: characters, positions: &protected)
        protectExclusionPhraseNumerals(in: characters, positions: &protected)
        return protected
    }

    private static func protectFractionRuns(in characters: [Character], positions: inout [Bool]) {
        var index = 0
        while index < characters.count {
            guard isNumeral(characters[index]) else {
                index += 1
                continue
            }
            // In Japanese A分のB denotes B/A: the first run is the denominator.
            let denominatorStart = index
            var denominatorEnd = index + 1
            while denominatorEnd < characters.count && isNumeral(characters[denominatorEnd]) {
                denominatorEnd += 1
            }

            let numeratorStart = denominatorEnd + 2
            if denominatorEnd + 2 < characters.count,
               isFractionSeparator(at: denominatorEnd, in: characters),
               isNumeral(characters[numeratorStart]) {
                var numeratorEnd = numeratorStart + 1
                while numeratorEnd < characters.count && isNumeral(characters[numeratorEnd]) {
                    numeratorEnd += 1
                }
                for position in denominatorStart..<denominatorEnd {
                    positions[position] = true
                }
                for position in numeratorStart..<numeratorEnd {
                    positions[position] = true
                }
            }
            index = denominatorEnd
        }
    }

    private static func isFractionSeparator(at index: Int, in characters: [Character]) -> Bool {
        isScalar(characters[index], value: 0x5206) && isScalar(characters[index + 1], value: 0x306E)
    }

    private static func protectExclusionPhraseNumerals(
        in characters: [Character],
        positions: inout [Bool]
    ) {
        for start in characters.indices {
            guard let candidates = phraseIndex[characters[start]] else { continue }
            for phrase in candidates {
                guard phrase.count <= characters.count - start else { continue }
                var matches = true
                for offset in phrase.indices {
                    guard characters[start + offset].unicodeScalars.elementsEqual(phrase[offset].unicodeScalars) else {
                        matches = false
                        break
                    }
                }
                guard matches else { continue }
                let end = start + phrase.count
                // A phrase never cuts a numeral run: 二百五 does not match inside 二百五十.
                if isNumeral(phrase[0]), start > 0, isNumeral(characters[start - 1]) { continue }
                if isNumeral(phrase[phrase.count - 1]), end < characters.count, isNumeral(characters[end]) { continue }
                for position in start..<end where isNumeral(characters[position]) {
                    positions[position] = true
                }
            }
        }
    }

    private static func isNumeral(_ character: Character) -> Bool {
        guard let scalar = singleScalar(character) else { return false }
        return digitValue(scalar) != nil || smallUnitValue(scalar) != nil || bigUnit(scalar) != nil
    }

    private static func isDecimalPoint(_ character: Character) -> Bool {
        isScalar(character, value: 0x70B9)
    }

    private static func isScalar(_ character: Character, value: UInt32) -> Bool {
        guard let scalar = singleScalar(character) else { return false }
        return scalar.value == value
    }

    private static func singleScalar(_ character: Character) -> Unicode.Scalar? {
        guard character.unicodeScalars.count == 1 else { return nil }
        return character.unicodeScalars.first
    }

    private static func digitValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x3007, 0x96F6: return 0
        case 0x4E00: return 1
        case 0x4E8C: return 2
        case 0x4E09: return 3
        case 0x56DB: return 4
        case 0x4E94: return 5
        case 0x516D: return 6
        case 0x4E03: return 7
        case 0x516B: return 8
        case 0x4E5D: return 9
        default: return nil
        }
    }

    private static func smallUnitValue(_ scalar: Unicode.Scalar) -> Int64? {
        switch scalar.value {
        case 0x5341: return 10
        case 0x767E: return 100
        case 0x5343: return 1_000
        default: return nil
        }
    }

    private static func bigUnit(_ scalar: Unicode.Scalar) -> (rank: Int, scale: Int64)? {
        switch scalar.value {
        case 0x4E07: return (1, 10_000)
        case 0x5104: return (2, 100_000_000)
        default: return nil
        }
    }

    private static func parseInteger(_ characters: [Character]) -> String? {
        guard !characters.isEmpty else { return nil }
        let hasUnits = characters.contains { character in
            guard let scalar = singleScalar(character) else { return false }
            return smallUnitValue(scalar) != nil || bigUnit(scalar) != nil
        }

        if !hasUnits {
            var digits = ""
            for character in characters {
                guard let scalar = singleScalar(character), let digit = digitValue(scalar) else {
                    return nil
                }
                digits.append(contentsOf: String(digit))
            }
            return digits
        }

        return parsePositionalInteger(characters).map { String($0) }
    }

    private static func parsePositionalInteger(_ characters: [Character]) -> Int64? {
        var total: Int64 = 0
        var groupStart = 0
        var previousBigUnitRank = Int.max

        for index in characters.indices {
            guard let scalar = singleScalar(characters[index]), let unit = bigUnit(scalar) else {
                continue
            }
            guard unit.rank < previousBigUnitRank, groupStart < index else { return nil }
            let groupCharacters = Array(characters[groupStart..<index])
            guard let group = parseSmallGroup(groupCharacters), group > 0, group <= 9_999 else {
                return nil
            }
            let (scaledGroup, multiplyOverflow) = group.multipliedReportingOverflow(by: unit.scale)
            guard !multiplyOverflow else { return nil }
            let (updatedTotal, addOverflow) = total.addingReportingOverflow(scaledGroup)
            guard !addOverflow else { return nil }
            total = updatedTotal
            previousBigUnitRank = unit.rank
            groupStart = index + 1
        }

        if groupStart < characters.count {
            let remainderCharacters = Array(characters[groupStart..<characters.count])
            guard let remainder = parseSmallGroup(remainderCharacters) else { return nil }
            let (updatedTotal, addOverflow) = total.addingReportingOverflow(remainder)
            guard !addOverflow else { return nil }
            total = updatedTotal
        }
        return total
    }

    private static func parseSmallGroup(_ characters: [Character]) -> Int64? {
        guard !characters.isEmpty else { return nil }

        var value: Int64 = 0
        var previousUnitValue: Int64 = Int64.max
        var index = 0

        while index < characters.count {
            guard let scalar = singleScalar(characters[index]) else { return nil }

            if let digit = digitValue(scalar) {
                guard digit > 0 else { return nil }
                if index + 1 < characters.count,
                   let nextScalar = singleScalar(characters[index + 1]),
                   smallUnitValue(nextScalar) != nil {
                    index += 1
                } else {
                    guard index == characters.count - 1 else { return nil }
                    let (updatedValue, addOverflow) = value.addingReportingOverflow(Int64(digit))
                    guard !addOverflow else { return nil }
                    value = updatedValue
                    index += 1
                    continue
                }
            }

            guard let unitScalar = singleScalar(characters[index]),
                  let unitValue = smallUnitValue(unitScalar),
                  unitValue < previousUnitValue else {
                return nil
            }
            let multiplier: Int64
            if index > 0,
               let previousScalar = singleScalar(characters[index - 1]),
               let previousDigit = digitValue(previousScalar) {
                guard previousDigit > 0 else { return nil }
                multiplier = Int64(previousDigit)
            } else {
                multiplier = 1
            }
            let (contribution, multiplyOverflow) = multiplier.multipliedReportingOverflow(by: unitValue)
            guard !multiplyOverflow else { return nil }
            let (updatedValue, addOverflow) = value.addingReportingOverflow(contribution)
            guard !addOverflow else { return nil }
            value = updatedValue
            previousUnitValue = unitValue
            index += 1
        }

        return value
    }

    private static func parseFraction(_ characters: [Character]) -> String? {
        guard !characters.isEmpty else { return nil }
        var digits = ""
        for character in characters {
            guard let scalar = singleScalar(character), let digit = digitValue(scalar) else {
                return nil
            }
            digits.append(contentsOf: String(digit))
        }
        return digits
    }

    private static func hasBlockingBoundary(
        in characters: [Character],
        before start: Int,
        after end: Int
    ) -> Bool {
        (start > 0 && isBoundaryBlocker(characters[start - 1]))
            || (end < characters.count && isBoundaryBlocker(characters[end]))
    }

    private static func isBoundaryBlocker(_ character: Character) -> Bool {
        if isKanji(character) { return true }
        for scalar in character.unicodeScalars {
            let value = scalar.value
            if (0x30...0x39).contains(value)
                || (0xFF10...0xFF19).contains(value)
                || value == 0x2E
                || value == 0xFF0E {
                return true
            }
        }
        return false
    }

    private static func isKanji(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            let value = scalar.value
            if value == 0x3005
                || (0x3400...0x4DBF).contains(value)
                || (0x4E00...0x9FFF).contains(value)
                || (0xF900...0xFAFF).contains(value)
                || (0x20000...0x2A6DF).contains(value)
                || (0x2A700...0x2B73F).contains(value)
                || (0x2B740...0x2B81F).contains(value)
                || (0x2B820...0x2CEAF).contains(value)
                || (0x2CEB0...0x2EBEF).contains(value)
                || (0x2EBF0...0x2EE5F).contains(value)
                || (0x2F800...0x2FA1F).contains(value)
                || (0x30000...0x3134F).contains(value)
                || (0x31350...0x323AF).contains(value)
                || (0x323B0...0x3347F).contains(value) {
                return true
            }
        }
        return false
    }
}
