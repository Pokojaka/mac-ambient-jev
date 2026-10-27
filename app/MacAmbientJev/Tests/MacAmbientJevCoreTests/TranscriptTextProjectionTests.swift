import Testing
@testable import MacAmbientJevCore

@Test
func projectionRemovesExplicitFillersAndMapsUTF16RangesWithoutJoiningAcrossDeletion() throws {
    let source = "😀 えー、鍵"
    let filler = try TextUTF16Range(start: 3, end: 5)
    let projected = try TranscriptTextProjector().project(sourceText: source, fillerRanges: [filler])
    #expect(projected.text == "😀 鍵")
    let removed = try TextUTF16Range(start: 3, end: 6)
    #expect(projected.removedRanges == [removed])
    let mapped = try projected.displayRanges(for: TextUTF16Range(start: 0, end: source.utf16.count))
    let retainedText = try mapped.map { String(try $0.substring(in: projected.text)) }
    #expect(retainedText == ["😀 ", "鍵"])
    let fillerOnly = try projected.displayRanges(for: filler)
    #expect(fillerOnly.isEmpty)
}

@Test
func projectionPreservesUnrelatedWhitespaceAndRemovesAttachedPunctuation() throws {
    let projector = TranscriptTextProjector()
    let standaloneFiller = try TextUTF16Range(start: 0, end: 3)
    #expect(try projector.project(sourceText: "えーと。", fillerRanges: [standaloneFiller]).text.isEmpty)

    let fillerAfterSpace = try TextUTF16Range(start: 1, end: 3)
    #expect(try projector.project(sourceText: " えー、\n今日は", fillerRanges: [fillerAfterSpace]).text == " \n今日は")

    let fillerBeforeParenthesis = try TextUTF16Range(start: 0, end: 2)
    #expect(try projector.project(sourceText: "えー、(RSA)", fillerRanges: [fillerBeforeParenthesis]).text == "(RSA)")
}

@Test
func projectionPreservesFillerLookingTextWithoutExplicitRanges() throws {
    let source = "まあ、あの、今日は損失関数の話をします。"
    let projected = try TranscriptTextProjector().project(sourceText: source, fillerRanges: [])
    #expect(projected.text == source)
}

@Test
func projectionCoalescesPunctuationExpandedFillerRangesAndRetainsOpeningPunctuationAndQuotes() throws {
    let projector = TranscriptTextProjector()
    let fillers = [
        try TextUTF16Range(start: 0, end: 2),
        try TextUTF16Range(start: 3, end: 5),
    ]
    let merged = try projector.project(sourceText: "まあ、あの、本文", fillerRanges: fillers)
    #expect(merged.text == "本文")
    #expect(merged.removedRanges == [try TextUTF16Range(start: 0, end: 6)])

    let filler = try TextUTF16Range(start: 0, end: 2)
    let quoted = try projector.project(sourceText: "まあ、(\"引用\")", fillerRanges: [filler])
    #expect(quoted.text == "(\"引用\")")
}

@Test
func textUTF16RangeRejectsInvalidBoundsAndNonCharacterBoundaries() throws {
    #expect(throws: TextUTF16RangeError.invalidBounds(start: -1, end: 0)) {
        try TextUTF16Range(start: -1, end: 0)
    }
    let source = "😀"
    let halfSurrogate = try TextUTF16Range(start: 1, end: 1)
    #expect(throws: TextUTF16RangeError.invalidCharacterBoundary(start: 1, end: 1)) {
        try halfSurrogate.substring(in: source)
    }
}

@Test
func projectionRejectsUnsortedOverlappingAdjacentEmptyAndOutOfBoundsFillerRanges() throws {
    let projector = TranscriptTextProjector()
    let unsorted = [
        try TextUTF16Range(start: 3, end: 4),
        try TextUTF16Range(start: 0, end: 1),
    ]
    #expect(throws: TextUTF16RangeError.invalidBounds(start: 0, end: 1)) {
        try projector.project(sourceText: "abcde", fillerRanges: unsorted)
    }

    let overlapping = [
        try TextUTF16Range(start: 0, end: 3),
        try TextUTF16Range(start: 2, end: 4),
    ]
    #expect(throws: TextUTF16RangeError.invalidBounds(start: 2, end: 4)) {
        try projector.project(sourceText: "abcde", fillerRanges: overlapping)
    }

    let adjacent = [
        try TextUTF16Range(start: 0, end: 2),
        try TextUTF16Range(start: 2, end: 4),
    ]
    #expect(throws: TextUTF16RangeError.invalidBounds(start: 2, end: 4)) {
        try projector.project(sourceText: "まああの、本文", fillerRanges: adjacent)
    }

    let empty = try TextUTF16Range(start: 1, end: 1)
    #expect(throws: TextUTF16RangeError.invalidBounds(start: 1, end: 1)) {
        try projector.project(sourceText: "abc", fillerRanges: [empty])
    }

    let outOfBounds = try TextUTF16Range(start: 2, end: 4)
    #expect(throws: TextUTF16RangeError.invalidBounds(start: 2, end: 4)) {
        try projector.project(sourceText: "abc", fillerRanges: [outOfBounds])
    }
}

@Test
func projectionRejectsFillerRangesSplittingSurrogatesOrCharacters() throws {
    let projector = TranscriptTextProjector()
    let splitSurrogate = try TextUTF16Range(start: 1, end: 2)
    #expect(throws: TextUTF16RangeError.invalidCharacterBoundary(start: 1, end: 2)) {
        try projector.project(sourceText: "😀x", fillerRanges: [splitSurrogate])
    }

    let splitCharacter = try TextUTF16Range(start: 0, end: 1)
    #expect(throws: TextUTF16RangeError.invalidCharacterBoundary(start: 0, end: 1)) {
        try projector.project(sourceText: "e\u{301}x", fillerRanges: [splitCharacter])
    }
}

@Test
func sourceMappingRejectsInvalidUnicodeBoundariesAndOutOfBoundsEvenForEmptyRanges() throws {
    let projector = TranscriptTextProjector()
    for (source, offset) in [("😀 えー、本文", 1), ("e\u{301} えー、本文", 1), ("🇯🇵 えー、本文", 2)] {
        let cleaned = try projector.project(sourceText: source, fillerRanges: [])
        let invalid = try TextUTF16Range(start: offset, end: offset)
        #expect(throws: TextUTF16RangeError.invalidCharacterBoundary(start: offset, end: offset)) {
            try cleaned.displayRanges(for: invalid)
        }
        #expect(throws: TextUTF16RangeError.invalidCharacterBoundary(start: offset, end: offset)) {
            try invalid.substring(in: source)
        }
    }
    let filler = try TextUTF16Range(start: 0, end: 2)
    let cleaned = try projector.project(sourceText: "えー、", fillerRanges: [filler])
    let outside = try TextUTF16Range(start: 4, end: 4)
    #expect(throws: TextUTF16RangeError.invalidBounds(start: 4, end: 4)) {
        try cleaned.displayRanges(for: outside)
    }
}
