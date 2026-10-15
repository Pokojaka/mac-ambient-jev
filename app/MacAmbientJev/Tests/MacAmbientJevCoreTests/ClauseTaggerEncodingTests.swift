import Foundation
import Testing
@testable import MacAmbientJevCore

private func scalarIDs(_ piece: String) -> [Int] {
    piece.unicodeScalars.map { Int($0.value) }
}

private func scalarTokens(_ piece: String) throws -> [ClauseTaggerToken] {
    var offsetUTF16 = 0
    return try piece.unicodeScalars.map { scalar in
        let endUTF16 = offsetUTF16 + (scalar.value > 0xFFFF ? 2 : 1)
        let token = ClauseTaggerToken(
            id: Int(scalar.value),
            range: try TextUTF16Range(start: offsetUTF16, end: endUTF16)
        )
        offsetUTF16 = endUTF16
        return token
    }
}

private func boundaryRequest(text: String, next: String? = nil) throws -> ClauseBoundaryRequest {
    let source = try SegmentTextReference(
        segmentationRunID: "seg",
        segmentID: "s0001",
        asrRunID: "asr",
        asrEventSeq: 1
    )
    let nextHead: NextSegmentHead?
    if let next {
        let nextSource = try SegmentTextReference(
            segmentationRunID: "seg",
            segmentID: "s0002",
            asrRunID: "asr",
            asrEventSeq: 2
        )
        nextHead = try NextSegmentHead(source: nextSource, text: next)
    } else {
        nextHead = nil
    }
    return try ClauseBoundaryRequest(source: source, text: text, next: nextHead)
}

@Suite
struct ClauseTaggerEncodingTests {
    @Test
    func constantsAndWhitespaceArePreserved() throws {
        #expect(ClauseTaggerEncoding.punctuation == "、。？！?!")
        #expect(ClauseTaggerEncoding.maximumContentTokens == 190)
        #expect(ClauseTaggerEncoding.maximumTokens == 192)
        #expect(ClauseTaggerEncoding.clsTokenID == 6)
        #expect(ClauseTaggerEncoding.sepTokenID == 4)
        #expect(ClauseTaggerEncoding.commaTokenID == 275)

        let encoded = try ClauseTaggerEncoding.encode(text: "  x ", tokenizePiece: scalarTokens)
        #expect(encoded.inputIDs == [6, 32, 32, 120, 32, 4])
        #expect(encoded.candidateTokenIndices.isEmpty)
        #expect(encoded.junctionIndex == nil)

        let punctuationBeforeWhitespace = try ClauseTaggerEncoding.encode(
            text: " x! ",
            tokenizePiece: scalarTokens
        )
        #expect(punctuationBeforeWhitespace.inputIDs == [6, 32, 120, 275, 32, 4])
        #expect(punctuationBeforeWhitespace.candidateTokenIndices == [3: 3])

        let sourceSpecialIDs = try ClauseTaggerEncoding.encode(text: "x", tokenizePiece: { _ in
            try [6, 4, 275].map { id in
                ClauseTaggerToken(id: id, range: try TextUTF16Range(start: 0, end: 1))
            }
        })
        #expect(sourceSpecialIDs.inputIDs == [6, 6, 4, 275, 4])
        let unrestrictedIDs = try ClauseTaggerEncoding.encode(text: "x", tokenizePiece: { _ in
            try [-1, Int(Int32.max) + 1].map { id in
                ClauseTaggerToken(id: id, range: try TextUTF16Range(start: 0, end: 1))
            }
        })
        #expect(unrestrictedIDs.inputIDs == [6, -1, Int(Int32.max) + 1, 4])
    }

    @Test
    func allConfiguredPunctuationBecomesCommaCandidates() throws {
        let encoded = try ClauseTaggerEncoding.encode(
            text: "A、B。C？D！E?F!G",
            tokenizePiece: scalarTokens
        )
        #expect(encoded.inputIDs == [
            6, 65, 275, 66, 275, 67, 275, 68, 275, 69, 275, 70, 275, 71, 4
        ])
        #expect(encoded.candidateTokenIndices == [2: 2, 4: 4, 6: 6, 8: 8, 10: 10, 12: 12])
    }

    @Test
    func splittingRetainsEmptyPiecesAndConsecutivePunctuation() throws {
        var pieces: [String] = []
        let encoded = try ClauseTaggerEncoding.encode(text: "、。x") { piece in
            pieces.append(piece)
            return try scalarTokens(piece)
        }

        #expect(pieces == ["", "", "x"])
        #expect(encoded.inputIDs == [6, 275, 275, 120, 4])
        #expect(encoded.candidateTokenIndices == [1: 1, 2: 2])
    }

    @Test
    func asciiCommaStaysInTokenizerPieceBeforeJapaneseComma() throws {
        var pieces: [String] = []
        let encoded = try ClauseTaggerEncoding.encode(text: "a,b、c") { piece in
            pieces.append(piece)
            return try scalarTokens(piece)
        }

        #expect(pieces == ["a,b", "c"])
        #expect(scalarIDs(pieces[0]) == [97, 44, 98])
        #expect(encoded.inputIDs == [6, 97, 44, 98, 275, 99, 4])
        #expect(encoded.candidateTokenIndices == [4: 4])
    }

    @Test
    func punctuationNormalizationKeepsRawUTF16Ranges() throws {
        let inputs = try ClauseTaggerEncoding.boundaryInputs(
            try boundaryRequest(text: "a。b?!c"),
            tokenizePiece: scalarTokens
        )
        try #require(inputs.count == 1)
        let encoded = inputs[0]

        #expect(encoded.inputIDs == [6, 97, 275, 98, 275, 275, 99, 4])
        #expect(encoded.candidateTokenIndices == [2: 2, 4: 4, 5: 5])
        let expectedRanges: [TextUTF16Range?] = [
            nil,
            try TextUTF16Range(start: 0, end: 1),
            try TextUTF16Range(start: 1, end: 2),
            try TextUTF16Range(start: 2, end: 3),
            try TextUTF16Range(start: 3, end: 4),
            try TextUTF16Range(start: 4, end: 5),
            try TextUTF16Range(start: 5, end: 6),
            nil
        ]
        #expect(encoded.sourceTokenRanges == expectedRanges)
    }

    @Test
    func candidateOffsetUsesScalarUTF16WidthsWithoutNormalizingCombiningText() throws {
        let text = "😀e\u{301}。x!"
        let request = try boundaryRequest(text: text)
        var pieces: [String] = []
        let inputs = try ClauseTaggerEncoding.boundaryInputs(request) { piece in
            pieces.append(piece)
            return try scalarTokens(piece)
        }

        #expect(pieces == ["😀e\u{301}", "x"])
        #expect(inputs.count == 1)
        #expect(inputs[0].candidateTokenIndices == [5: 4])
        #expect(inputs[0].inputIDs == [6, 0x1F600, 101, 0x301, 275, 120, 4])
        let expectedRanges: [TextUTF16Range?] = [
            nil,
            try TextUTF16Range(start: 0, end: 2),
            try TextUTF16Range(start: 2, end: 3),
            try TextUTF16Range(start: 3, end: 4),
            try TextUTF16Range(start: 4, end: 5),
            try TextUTF16Range(start: 5, end: 6),
            nil
        ]
        #expect(inputs[0].sourceTokenRanges == expectedRanges)
    }

    @Test
    func boundaryEncodingUsesOnlyTheRequestText() throws {
        let request = try boundaryRequest(text: "A。B", next: "NEXT")
        var pieces: [String] = []
        let inputs = try ClauseTaggerEncoding.boundaryInputs(request) { piece in
            pieces.append(piece)
            return try scalarTokens(piece)
        }

        #expect(pieces == ["A", "B"])
        #expect(inputs.count == 1)
        #expect(inputs[0].inputIDs == [6, 65, 275, 66, 4])
        #expect(inputs[0].junctionIndex == nil)
        #expect(inputs[0].sourceTokenRanges == [
            nil,
            try TextUTF16Range(start: 0, end: 1),
            try TextUTF16Range(start: 1, end: 2),
            try TextUTF16Range(start: 2, end: 3),
            nil
        ])
    }

    @Test
    func boundaryInputsRunForCandidateFreeTrailingPunctuation() throws {
        let request = try boundaryRequest(text: "a。!")
        var pieces: [String] = []
        let inputs = try ClauseTaggerEncoding.boundaryInputs(request) { piece in
            pieces.append(piece)
            return try scalarTokens(piece)
        }

        #expect(request.candidates.isEmpty)
        #expect(pieces == ["a"])
        #expect(inputs.count == 1)
        #expect(inputs[0].inputIDs == [6, 97, 4])
        #expect(inputs[0].spanTokenIndices == [1])
        #expect(inputs[0].sourceTokenRanges == [
            nil,
            try TextUTF16Range(start: 0, end: 1),
            nil
        ])
    }

    @Test
    func internalCandidatesRemainWhenTrailingPunctuationIsStripped() throws {
        let request = try boundaryRequest(text: "a。!b？！")
        let inputs = try ClauseTaggerEncoding.boundaryInputs(request, tokenizePiece: scalarTokens)

        #expect(request.candidates.map(\.offsetUTF16) == [2, 3])
        #expect(inputs.count == 1)
        #expect(inputs[0].candidateTokenIndices.keys.sorted() == [2, 3])
    }

    @Test
    func boundaryRequestsKeepEveryCandidateAcrossLongInputWindows() throws {
        let text = "a" + String(repeating: "b", count: 40) + "。"
            + String(repeating: "c", count: 40) + "。"
            + String(repeating: "d", count: 40) + "。"
            + String(repeating: "e", count: 40) + "。"
            + String(repeating: "f", count: 40) + "。"
            + String(repeating: "g", count: 40)
        let request = try boundaryRequest(text: text)
        let inputs = try ClauseTaggerEncoding.boundaryInputs(request, tokenizePiece: scalarTokens)
        let assignedOffsets = inputs.flatMap { Array($0.candidateTokenIndices.keys) }.sorted()

        #expect(inputs.count > 1)
        #expect(assignedOffsets == request.candidates.map(\.offsetUTF16).sorted())
        #expect(Set(assignedOffsets).count == request.candidates.count)
        #expect(inputs.allSatisfy { $0.inputIDs.count <= ClauseTaggerEncoding.maximumTokens })
        #expect(inputs.allSatisfy { $0.inputIDs.first == ClauseTaggerEncoding.clsTokenID })
        #expect(inputs.allSatisfy { $0.inputIDs.last == ClauseTaggerEncoding.sepTokenID })

        let ownedGlobalTokenIndices = inputs.flatMap { input in
            input.spanTokenIndices.map { input.contentStartTokenIndex + $0 - 1 }
        }
        #expect(ownedGlobalTokenIndices.sorted() == Array(0..<text.unicodeScalars.count))
        #expect(Set(ownedGlobalTokenIndices).count == text.unicodeScalars.count)
        let ownedRanges = inputs.flatMap { input in
            input.spanTokenIndices.compactMap { input.sourceTokenRanges[$0] }
        }.sorted { $0.start < $1.start }
        let expectedRanges = try (0..<text.utf16.count).map { offset in
            try TextUTF16Range(start: offset, end: offset + 1)
        }
        #expect(ownedRanges == expectedRanges)
    }

    @Test
    func boundaryWindowSelectionMaximizesContextAndBreaksTiesByEarliestStart() throws {
        let groups = ["a", "b", "c", "d", "e"].map { String(repeating: $0, count: 40) }
        let text = groups.joined(separator: "。")
        let request = try boundaryRequest(text: text)
        let full = try ClauseTaggerEncoding.encode(text: text, tokenizePiece: scalarTokens)
        let targetOffset = 164
        let candidatePosition = try #require(full.candidateTokenIndices[targetOffset]) - 1
        let pieceSizes = [41, 41, 41, 41, 40]

        var expectedStart: Int?
        var bestScore = -1
        for start in pieceSizes.indices {
            var end = start
            var contentCount = 0
            while end < pieceSizes.count, contentCount + pieceSizes[end] <= ClauseTaggerEncoding.maximumContentTokens {
                contentCount += pieceSizes[end]
                end += 1
            }
            let windowStart = pieceSizes[..<start].reduce(0, +)
            let windowEnd = windowStart + contentCount
            guard candidatePosition >= windowStart && candidatePosition < windowEnd else { continue }
            let score = min(candidatePosition - windowStart, windowEnd - candidatePosition - 1)
            if score > bestScore {
                bestScore = score
                expectedStart = start
            }
        }
        #expect(expectedStart == 1)

        let inputs = try ClauseTaggerEncoding.boundaryInputs(request, tokenizePiece: scalarTokens)
        let targetInput = try #require(inputs.first { $0.candidateTokenIndices[targetOffset] != nil })
        #expect(targetInput.inputIDs[1] == scalarIDs(groups[1])[0])
        #expect(targetInput.candidateTokenIndices[targetOffset] == candidatePosition - 41 + 1)
    }

    @Test
    func encodeKeepsWholeTextUpToTheContentLimit() throws {
        let text = String(repeating: "a", count: 100) + "。" + String(repeating: "b", count: 89)
        let encoded = try ClauseTaggerEncoding.encode(text: text, tokenizePiece: scalarTokens)

        #expect(encoded.inputIDs.count == ClauseTaggerEncoding.maximumTokens)
        #expect(encoded.inputIDs.first == 6)
        #expect(encoded.inputIDs.last == 4)
        #expect(encoded.candidateTokenIndices == [101: 101])
    }

    @Test
    func encodeTruncatesToTheFirst190ContentTokensAndDropsLaterCandidates() throws {
        let text = String(repeating: "a", count: 100) + "。" + String(repeating: "b", count: 100)
            + "。" + String(repeating: "c", count: 10)
        let encoded = try ClauseTaggerEncoding.encode(text: text, tokenizePiece: scalarTokens)

        #expect(encoded.inputIDs.count == ClauseTaggerEncoding.maximumTokens)
        #expect(encoded.inputIDs.first == ClauseTaggerEncoding.clsTokenID)
        #expect(encoded.inputIDs.last == ClauseTaggerEncoding.sepTokenID)
        #expect(Array(encoded.inputIDs.dropFirst().dropLast()) == Array((scalarIDs(String(repeating: "a", count: 100))
            + [ClauseTaggerEncoding.commaTokenID] + scalarIDs(String(repeating: "b", count: 89)))))
        #expect(encoded.candidateTokenIndices == [101: 101])
    }

    @Test
    func aSinglePieceAbove190TokensIsTruncatedByEncodeButRejectedForBoundaries() throws {
        let text = String(repeating: "a", count: 191)
        let encoded = try ClauseTaggerEncoding.encode(text: text, tokenizePiece: scalarTokens)
        #expect(encoded.inputIDs.count == ClauseTaggerEncoding.maximumTokens)

        #expect(throws: ClauseTaggerEncodingError.pieceTooLong(tokenCount: 192)) {
            try ClauseTaggerEncoding.boundaryInputs(
                try boundaryRequest(text: text + "。x"),
                tokenizePiece: scalarTokens
            )
        }
    }

    @Test
    func boundaryInputsRunOnceForPunctuationOnlyText() throws {
        let request = try boundaryRequest(text: "、。？！?!")
        var pieces: [String] = []
        let inputs = try ClauseTaggerEncoding.boundaryInputs(request) { piece in
            pieces.append(piece)
            return try scalarTokens(piece)
        }
        #expect(request.candidates.isEmpty)
        #expect(pieces == [""])
        #expect(inputs.count == 1)
        #expect(inputs[0].inputIDs == [6, 4])
        #expect(inputs[0].spanTokenIndices.isEmpty)
        #expect(inputs[0].sourceTokenRanges == [nil, nil])
    }

    @Test
    func continuationStripsTextSuffixAndInsertsOneJunctionComma() throws {
        let request = try boundaryRequest(text: "left。", next: "right")
        var pieces: [String] = []
        let encoded = try ClauseTaggerEncoding.continuationInput(request) { piece in
            pieces.append(piece)
            return try scalarTokens(piece)
        }

        #expect(pieces == ["left", "right"])
        #expect(encoded.inputIDs == [6, 108, 101, 102, 116, 275, 114, 105, 103, 104, 116, 4])
        #expect(encoded.junctionIndex == 5)
        #expect(encoded.candidateTokenIndices.isEmpty)
    }

    @Test
    func nonBoundaryInputsOmitSourceRangesAndSpanIndices() throws {
        let encoded = try ClauseTaggerEncoding.encode(text: "a。b", tokenizePiece: scalarTokens)
        #expect(encoded.sourceTokenRanges.isEmpty)
        #expect(encoded.spanTokenIndices.isEmpty)

        let continuation = try ClauseTaggerEncoding.continuationInput(
            try boundaryRequest(text: "left。", next: "right"),
            tokenizePiece: scalarTokens
        )
        #expect(continuation.sourceTokenRanges.isEmpty)
        #expect(continuation.spanTokenIndices.isEmpty)
    }

    @Test
    func encodeMapsPunctuationFromTheNextTextAndKeepsJunctionDistinct() throws {
        let encoded = try ClauseTaggerEncoding.encode(
            text: "left。",
            next: "ri。ght",
            tokenizePiece: scalarTokens
        )

        #expect(encoded.junctionIndex == 5)
        #expect(encoded.candidateTokenIndices == [5: 5, 8: 8])
        #expect(encoded.inputIDs == [6, 108, 101, 102, 116, 275, 114, 105, 275, 103, 104, 116, 4])
    }

    @Test
    func continuationOver192TokensKeepsNearestWholePrefixPiecesAndNextText() throws {
        let prefix = String(repeating: "a", count: 50) + "。"
            + String(repeating: "b", count: 50) + "。"
            + String(repeating: "c", count: 50) + "。"
            + String(repeating: "d", count: 50) + "。"
            + String(repeating: "e", count: 50)
        let request = try boundaryRequest(text: prefix, next: String(repeating: "N", count: 20))
        let encoded = try ClauseTaggerEncoding.continuationInput(request, tokenizePiece: scalarTokens)

        #expect(encoded.inputIDs.count <= ClauseTaggerEncoding.maximumTokens)
        #expect(encoded.inputIDs[1] == 99)
        #expect(encoded.inputIDs.suffix(21).dropLast().allSatisfy { $0 == 78 })
        #expect(encoded.candidateTokenIndices.isEmpty)
        #expect(encoded.junctionIndex != nil)
    }

    @Test
    func continuationRequiresNextTokenizerTokenAndAdjacentPiecesToFit() throws {
        let noNext = try boundaryRequest(text: "text")
        #expect(throws: ClauseTaggerEncodingError.missingJunction) {
            try ClauseTaggerEncoding.continuationInput(noNext, tokenizePiece: scalarTokens)
        }

        let punctuationNext = try boundaryRequest(text: "text", next: "!!!")
        #expect(throws: ClauseTaggerEncodingError.missingJunction) {
            try ClauseTaggerEncoding.continuationInput(punctuationNext, tokenizePiece: scalarTokens)
        }

        let nextText = String(repeating: "b", count: 50)
        let adjacentPiecesTooLarge = try boundaryRequest(
            text: String(repeating: "a", count: 100),
            next: nextText
        )
        #expect(throws: ClauseTaggerEncodingError.contextWindowUnavailable) {
            try ClauseTaggerEncoding.continuationInput(adjacentPiecesTooLarge) { piece in
                if piece == nextText {
                    return try (0..<100).map { index in
                        let localOffset = index % nextText.utf16.count
                        return ClauseTaggerToken(
                            id: 98,
                            range: try TextUTF16Range(start: localOffset, end: localOffset + 1)
                        )
                    }
                }
                return try scalarTokens(piece)
            }
        }
    }
}
