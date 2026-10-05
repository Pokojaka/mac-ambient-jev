import Testing
@testable import MacAmbientJevCore

@Test
func projectionRemovesFillersAndMapsUTF16RangesWithoutJoiningAcrossDeletion() throws {
    let source = "😀 えー、鍵"
    let projected = try TranscriptTextProjector(detector: FillerTextSpanDetector()).project(sourceText: source)
    #expect(projected.text == "😀 鍵")
    let removed = try TextUTF16Range(start: 3, end: 6)
    #expect(projected.removedRanges == [removed])
    let mapped = try projected.displayRanges(for: TextUTF16Range(start: 0, end: source.utf16.count))
    let retainedText = try mapped.map { String(try $0.substring(in: projected.text)) }
    #expect(retainedText == ["😀 ", "鍵"])
    let fillerOnly = try projected.displayRanges(for: removed)
    #expect(fillerOnly.isEmpty)
}

@Test
func projectionPreservesUnrelatedWhitespaceAndRemovesAttachedPunctuation() throws {
    let projector = TranscriptTextProjector(detector: FillerTextSpanDetector())
    #expect(try projector.project(sourceText: "えーと。").text.isEmpty)
    #expect(try projector.project(sourceText: " えー、\n今日は").text == " \n今日は")
    #expect(try projector.project(sourceText: "えー、(RSA)").text == "(RSA)")
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
func sourceMappingRejectsInvalidUnicodeBoundariesAndOutOfBoundsEvenForEmptyRanges() throws {
    let projector = TranscriptTextProjector(detector: FillerTextSpanDetector())
    for (source, offset) in [("😀 えー、本文", 1), ("e\u{301} えー、本文", 1), ("🇯🇵 えー、本文", 2)] {
        let cleaned = try projector.project(sourceText: source)
        let invalid = try TextUTF16Range(start: offset, end: offset)
        #expect(throws: TextUTF16RangeError.invalidCharacterBoundary(start: offset, end: offset)) {
            try cleaned.displayRanges(for: invalid)
        }
        #expect(throws: TextUTF16RangeError.invalidCharacterBoundary(start: offset, end: offset)) {
            try invalid.substring(in: source)
        }
    }
    let cleaned = try projector.project(sourceText: "えー、")
    let outside = try TextUTF16Range(start: 4, end: 4)
    #expect(throws: TextUTF16RangeError.invalidBounds(start: 4, end: 4)) {
        try cleaned.displayRanges(for: outside)
    }
}
