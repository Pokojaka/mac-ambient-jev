import Foundation
import Testing
@testable import MacAmbientJevCore

private func scalarIDs(_ piece: String) -> [Int] {
    piece.unicodeScalars.map { Int($0.value) }
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

        let encoded = try ClauseTaggerEncoding.encode(text: "  x ", tokenizePiece: scalarIDs)
        #expect(encoded.inputIDs == [6, 32, 32, 120, 32, 4])
        #expect(encoded.candidateTokenIndices.isEmpty)
        #expect(encoded.junctionIndex == nil)

        let punctuationBeforeWhitespace = try ClauseTaggerEncoding.encode(
            text: " x! ",
            tokenizePiece: scalarIDs
        )
        #expect(punctuationBeforeWhitespace.inputIDs == [6, 32, 120, 275, 32, 4])
        #expect(punctuationBeforeWhitespace.candidateTokenIndices == [3: 3])

        let sourceSpecialIDs = try ClauseTaggerEncoding.encode(text: "x", tokenizePiece: { _ in [6, 4, 275] })
        #expect(sourceSpecialIDs.inputIDs == [6, 6, 4, 275, 4])
        let unrestrictedIDs = try ClauseTaggerEncoding.encode(text: "x", tokenizePiece: { _ in [-1, Int(Int32.max) + 1] })
        #expect(unrestrictedIDs.inputIDs == [6, -1, Int(Int32.max) + 1, 4])
    }

    @Test
    func allConfiguredPunctuationBecomesCommaCandidates() throws {
        let encoded = try ClauseTaggerEncoding.encode(
            text: "A、B。C？D！E?F!G",
            tokenizePiece: scalarIDs
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
            return scalarIDs(piece)
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
            return scalarIDs(piece)
        }

        #expect(pieces == ["a,b", "c"])
        #expect(scalarIDs(pieces[0]) == [97, 44, 98])
        #expect(encoded.inputIDs == [6, 97, 44, 98, 275, 99, 4])
        #expect(encoded.candidateTokenIndices == [4: 4])
    }

    @Test
    func candidateOffsetUsesScalarUTF16WidthsWithoutNormalizingCombiningText() throws {
        let text = "😀e\u{301}。x!"
        let request = try boundaryRequest(text: text)
        var pieces: [String] = []
        let inputs = try ClauseTaggerEncoding.boundaryInputs(request) { piece in
            pieces.append(piece)
            return scalarIDs(piece)
        }

        #expect(pieces == ["😀e\u{301}", "x"])
        #expect(inputs.count == 1)
        #expect(inputs[0].candidateTokenIndices == [5: 4])
        #expect(inputs[0].inputIDs == [6, 0x1F600, 101, 0x301, 275, 120, 4])
    }

    @Test
    func boundaryEncodingUsesOnlyTheRequestText() throws {
        let request = try boundaryRequest(text: "A。B", next: "NEXT")
        var pieces: [String] = []
        let inputs = try ClauseTaggerEncoding.boundaryInputs(request) { piece in
            pieces.append(piece)
            return scalarIDs(piece)
        }

        #expect(pieces == ["A", "B"])
        #expect(inputs.count == 1)
        #expect(inputs[0].inputIDs == [6, 65, 275, 66, 4])
    }

    @Test
    func trailingPunctuationRunContributesNoCandidatesOrWindows() throws {
        let request = try boundaryRequest(text: "a。!")
        var tokenizeCalls = 0
        let inputs = try ClauseTaggerEncoding.boundaryInputs(request) { piece in
            tokenizeCalls += 1
            return scalarIDs(piece)
        }

        #expect(request.candidates.isEmpty)
        #expect(inputs.isEmpty)
        #expect(tokenizeCalls == 0)
    }

    @Test
    func internalCandidatesRemainWhenTrailingPunctuationIsStripped() throws {
        let request = try boundaryRequest(text: "a。!b？！")
        let inputs = try ClauseTaggerEncoding.boundaryInputs(request, tokenizePiece: scalarIDs)

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
        let inputs = try ClauseTaggerEncoding.boundaryInputs(request, tokenizePiece: scalarIDs)
        let assignedOffsets = inputs.flatMap { Array($0.candidateTokenIndices.keys) }.sorted()

        #expect(inputs.count > 1)
        #expect(assignedOffsets == request.candidates.map(\.offsetUTF16).sorted())
        #expect(Set(assignedOffsets).count == request.candidates.count)
        #expect(inputs.allSatisfy { $0.inputIDs.count <= ClauseTaggerEncoding.maximumTokens })
        #expect(inputs.allSatisfy { $0.inputIDs.first == ClauseTaggerEncoding.clsTokenID })
        #expect(inputs.allSatisfy { $0.inputIDs.last == ClauseTaggerEncoding.sepTokenID })
    }

    @Test
    func boundaryWindowSelectionMaximizesContextAndBreaksTiesByEarliestStart() throws {
        let groups = ["a", "b", "c", "d", "e"].map { String(repeating: $0, count: 40) }
        let text = groups.joined(separator: "。")
        let request = try boundaryRequest(text: text)
        let full = try ClauseTaggerEncoding.encode(text: text, tokenizePiece: scalarIDs)
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

        let inputs = try ClauseTaggerEncoding.boundaryInputs(request, tokenizePiece: scalarIDs)
        let targetInput = try #require(inputs.first { $0.candidateTokenIndices[targetOffset] != nil })
        #expect(targetInput.inputIDs[1] == scalarIDs(groups[1])[0])
        #expect(targetInput.candidateTokenIndices[targetOffset] == candidatePosition - 41 + 1)
    }

    @Test
    func encodeKeepsWholeTextUpToTheContentLimit() throws {
        let text = String(repeating: "a", count: 100) + "。" + String(repeating: "b", count: 89)
        let encoded = try ClauseTaggerEncoding.encode(text: text, tokenizePiece: scalarIDs)

        #expect(encoded.inputIDs.count == ClauseTaggerEncoding.maximumTokens)
        #expect(encoded.inputIDs.first == 6)
        #expect(encoded.inputIDs.last == 4)
        #expect(encoded.candidateTokenIndices == [101: 101])
    }

    @Test
    func encodeTruncatesToTheFirst190ContentTokensAndDropsLaterCandidates() throws {
        let text = String(repeating: "a", count: 100) + "。" + String(repeating: "b", count: 100)
            + "。" + String(repeating: "c", count: 10)
        let encoded = try ClauseTaggerEncoding.encode(text: text, tokenizePiece: scalarIDs)

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
        let encoded = try ClauseTaggerEncoding.encode(text: text, tokenizePiece: scalarIDs)
        #expect(encoded.inputIDs.count == ClauseTaggerEncoding.maximumTokens)

        #expect(throws: ClauseTaggerEncodingError.pieceTooLong(tokenCount: 192)) {
            try ClauseTaggerEncoding.boundaryInputs(
                try boundaryRequest(text: text + "。x"),
                tokenizePiece: scalarIDs
            )
        }
    }

    @Test
    func punctuationOnlyBoundaryRequestHasNoCandidatesOrWindows() throws {
        let request = try boundaryRequest(text: "、。？！?!")
        var tokenizeCalls = 0
        let inputs = try ClauseTaggerEncoding.boundaryInputs(request) { piece in
            tokenizeCalls += 1
            return scalarIDs(piece)
        }
        #expect(request.candidates.isEmpty)
        #expect(inputs.isEmpty)
        #expect(tokenizeCalls == 0)
    }

    @Test
    func continuationStripsTextSuffixAndInsertsOneJunctionComma() throws {
        let request = try boundaryRequest(text: "left。", next: "right")
        var pieces: [String] = []
        let encoded = try ClauseTaggerEncoding.continuationInput(request) { piece in
            pieces.append(piece)
            return scalarIDs(piece)
        }

        #expect(pieces == ["left", "right"])
        #expect(encoded.inputIDs == [6, 108, 101, 102, 116, 275, 114, 105, 103, 104, 116, 4])
        #expect(encoded.junctionIndex == 5)
        #expect(encoded.candidateTokenIndices.isEmpty)
    }

    @Test
    func encodeMapsPunctuationFromTheNextTextAndKeepsJunctionDistinct() throws {
        let encoded = try ClauseTaggerEncoding.encode(
            text: "left。",
            next: "ri。ght",
            tokenizePiece: scalarIDs
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
        let encoded = try ClauseTaggerEncoding.continuationInput(request, tokenizePiece: scalarIDs)

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
            try ClauseTaggerEncoding.continuationInput(noNext, tokenizePiece: scalarIDs)
        }

        let punctuationNext = try boundaryRequest(text: "text", next: "!!!")
        #expect(throws: ClauseTaggerEncodingError.missingJunction) {
            try ClauseTaggerEncoding.continuationInput(punctuationNext, tokenizePiece: scalarIDs)
        }

        let nextText = String(repeating: "b", count: 50)
        let adjacentPiecesTooLarge = try boundaryRequest(
            text: String(repeating: "a", count: 100),
            next: nextText
        )
        #expect(throws: ClauseTaggerEncodingError.contextWindowUnavailable) {
            try ClauseTaggerEncoding.continuationInput(adjacentPiecesTooLarge) { piece in
                piece == nextText ? Array(repeating: 98, count: 100) : scalarIDs(piece)
            }
        }
    }
}
