import Foundation
import Testing
@testable import MacAmbientJevCore

private func scalarRanges(_ text: String) throws -> [TextUTF16Range] {
    var offsetUTF16 = 0
    return try text.unicodeScalars.map { scalar in
        let endUTF16 = offsetUTF16 + (scalar.value > 0xFFFF ? 2 : 1)
        let range = try TextUTF16Range(start: offsetUTF16, end: endUTF16)
        offsetUTF16 = endUTF16
        return range
    }
}

@Suite
struct ClauseTaggerSpanProjectionTests {
    @Test
    func labelsAreOZeroFOneDTwoBThreeAndTiesChooseTheLowestIndex() throws {
        let ranges = try (0..<4).map { try TextUTF16Range(start: $0, end: $0 + 1) }
        let removalRanges = try ClauseTaggerSpanProjection.removalRanges(
            sourceText: "abcd",
            tokenRanges: ranges,
            spanProbabilities: [
                [0.5, 0.5, 0, 0],
                [0, 0.5, 0.5, 0],
                [0.5, 0, 0, 0.5],
                [0, 0, 0.5, 0.5]
            ]
        )

        #expect(removalRanges == [try TextUTF16Range(start: 1, end: 2)])
    }

    @Test
    func allFourWayTiesChooseO() throws {
        let removalRanges = try ClauseTaggerSpanProjection.removalRanges(
            sourceText: "a",
            tokenRanges: [try TextUTF16Range(start: 0, end: 1)],
            spanProbabilities: [[0.25, 0.25, 0.25, 0.25]]
        )

        #expect(removalRanges.isEmpty)
    }

    @Test
    func tiesWithinAMixedCharacterKeepTheDAndBScalar() throws {
        let sourceText = "e\u{301}"
        let removalRanges = try ClauseTaggerSpanProjection.removalRanges(
            sourceText: sourceText,
            tokenRanges: try scalarRanges(sourceText),
            spanProbabilities: [
                [0, 0.5, 0, 0.5],
                [0, 0, 0.5, 0.5]
            ]
        )

        #expect(removalRanges.isEmpty)
    }

    @Test
    func pureBLabelsAreRemoved() throws {
        let ranges = try (0..<3).map { try TextUTF16Range(start: $0, end: $0 + 1) }
        let removalRanges = try ClauseTaggerSpanProjection.removalRanges(
            sourceText: "abc",
            tokenRanges: ranges,
            spanProbabilities: [
                [0, 0, 0, 1],
                [1, 0, 0, 0],
                [0, 0, 0, 1]
            ]
        )

        #expect(removalRanges == [
            try TextUTF16Range(start: 0, end: 1),
            try TextUTF16Range(start: 2, end: 3)
        ])
    }

    @Test
    func alternatingFAndBLabelsCoalesceIntoOneRemovalRange() throws {
        let ranges = try (0..<4).map { try TextUTF16Range(start: $0, end: $0 + 1) }
        let removalRanges = try ClauseTaggerSpanProjection.removalRanges(
            sourceText: "abcd",
            tokenRanges: ranges,
            spanProbabilities: [
                [0, 1, 0, 0],
                [0, 0, 0, 1],
                [0, 1, 0, 0],
                [0, 0, 0, 1]
            ]
        )

        #expect(removalRanges == [try TextUTF16Range(start: 0, end: 4)])
    }

    @Test
    func mixedFAndBScalarsRemoveDecomposedKanaAndEmojiCharacters() throws {
        for sourceText in ["e\u{301}", "ｶﾞ", "👍🏻"] {
            let ranges = try scalarRanges(sourceText)
            #expect(sourceText.count == 1)
            #expect(ranges.count == 2)

            let labelOrders: [[[Double]]] = [
                [[0, 1, 0, 0], [0, 0, 0, 1]],
                [[0, 0, 0, 1], [0, 1, 0, 0]]
            ]
            for spanProbabilities in labelOrders {
                let removalRanges = try ClauseTaggerSpanProjection.removalRanges(
                    sourceText: sourceText,
                    tokenRanges: ranges,
                    spanProbabilities: spanProbabilities
                )

                #expect(removalRanges == [try TextUTF16Range(start: 0, end: sourceText.utf16.count)])
            }
        }
    }

    @Test
    func anyORetainedDMixtureWithEitherFOrBKeepsTheWholeCharacterInEitherScalarOrder() throws {
        let removableRows: [[Double]] = [
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 0.0, 1.0]
        ]
        let retainedRows = [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0]
        ]

        for sourceText in ["e\u{301}", "ｶﾞ", "👍🏻"] {
            let ranges = try scalarRanges(sourceText)
            #expect(sourceText.count == 1)
            #expect(ranges.count == 2)

            for removableRow in removableRows {
                for retainedRow in retainedRows {
                    for spanProbabilities in [
                        [removableRow, retainedRow],
                        [retainedRow, removableRow]
                    ] {
                        let removalRanges = try ClauseTaggerSpanProjection.removalRanges(
                            sourceText: sourceText,
                            tokenRanges: ranges,
                            spanProbabilities: spanProbabilities
                        )
                        #expect(removalRanges.isEmpty)
                    }
                }
            }
        }
    }

    @Test
    func laterOverlappingLabelsOverwriteEarlierLabelsInBothDirections() throws {
        let scalarRanges = try (0..<4).map { try TextUTF16Range(start: $0, end: $0 + 1) }
        let tokenRanges = [
            scalarRanges[0], scalarRanges[0],
            scalarRanges[1], scalarRanges[1],
            scalarRanges[2], scalarRanges[2],
            scalarRanges[3], scalarRanges[3]
        ]
        let removalRanges = try ClauseTaggerSpanProjection.removalRanges(
            sourceText: "abcd",
            tokenRanges: tokenRanges,
            spanProbabilities: [
                [0, 0, 0, 1], [1, 0, 0, 0],
                [0, 0, 0, 1], [0, 0, 1, 0],
                [1, 0, 0, 0], [0, 0, 0, 1],
                [0, 0, 1, 0], [0, 0, 0, 1]
            ]
        )

        #expect(removalRanges == [try TextUTF16Range(start: 2, end: 4)])
    }

    @Test
    func supplementaryAndDecomposedScalarsUseUTF16Offsets() throws {
        let sourceText = "😀e\u{301}!"
        let removalRanges = try ClauseTaggerSpanProjection.removalRanges(
            sourceText: sourceText,
            tokenRanges: [
                try TextUTF16Range(start: 0, end: 2),
                try TextUTF16Range(start: 2, end: 3),
                try TextUTF16Range(start: 3, end: 4),
                try TextUTF16Range(start: 4, end: 5)
            ],
            spanProbabilities: [
                [0, 0, 0, 1],
                [0, 1, 0, 0],
                [0, 0, 0, 1],
                [1, 0, 0, 0]
            ]
        )

        #expect(removalRanges == [try TextUTF16Range(start: 0, end: 4)])
        #expect(String(try removalRanges[0].substring(in: sourceText)) == "😀e\u{301}")
    }

    @Test
    func uncoveredTextRemainsO() throws {
        let sourceText = "まあ、"
        let removalRanges = try ClauseTaggerSpanProjection.removalRanges(
            sourceText: sourceText,
            tokenRanges: [
                try TextUTF16Range(start: 0, end: 1),
                try TextUTF16Range(start: 1, end: 2)
            ],
            spanProbabilities: [
                [0, 1, 0, 0],
                [0, 0, 0, 1]
            ]
        )

        #expect(removalRanges == [try TextUTF16Range(start: 0, end: 2)])
        #expect(String(try removalRanges[0].substring(in: sourceText)) == "まあ")
    }

    @Test
    func removalProjectionKeepsTheLiteralTargetAndDRepair() throws {
        let sourceText = "まあ、あの、今日は損失関数の話をします。"
        let sourceRanges = try scalarRanges(sourceText)
        let spanProbabilities = sourceRanges.indices.map { index in
            index < 6 ? [0.0, 1.0, 0.0, 0.0] : [1.0, 0.0, 0.0, 0.0]
        }
        let removalRanges = try ClauseTaggerSpanProjection.removalRanges(
            sourceText: sourceText,
            tokenRanges: sourceRanges,
            spanProbabilities: spanProbabilities
        )

        #expect(removalRanges == [try TextUTF16Range(start: 0, end: 6)])
        let projected = try TranscriptTextProjector().project(sourceText: sourceText, fillerRanges: removalRanges)
        #expect(projected.text == "今日は損失関数の話をします。")

        let repairText = "今日は今日は損失関数の話をします。"
        let repairRanges = try scalarRanges(repairText)
        let repairProbabilities = repairRanges.indices.map { index in
            index < 3 ? [0.0, 0.0, 1.0, 0.0] : [1.0, 0.0, 0.0, 0.0]
        }
        let repairRemovalRanges = try ClauseTaggerSpanProjection.removalRanges(
            sourceText: repairText,
            tokenRanges: repairRanges,
            spanProbabilities: repairProbabilities
        )

        #expect(repairRemovalRanges.isEmpty)
        let repairProjected = try TranscriptTextProjector().project(
            sourceText: repairText,
            fillerRanges: repairRemovalRanges
        )
        #expect(repairProjected.text == "今日は今日は損失関数の話をします。")
    }

    @Test
    func invalidPredictionShapeProbabilitiesAndRangesFail() throws {
        let validRange = try TextUTF16Range(start: 0, end: 1)
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.removalRanges(
                sourceText: "a",
                tokenRanges: [validRange],
                spanProbabilities: []
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.removalRanges(
                sourceText: "a",
                tokenRanges: [validRange],
                spanProbabilities: [[1, 0]]
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.removalRanges(
                sourceText: "a",
                tokenRanges: [validRange],
                spanProbabilities: [[0.4, 0.4, 0, 0]]
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.removalRanges(
                sourceText: "a",
                tokenRanges: [validRange],
                spanProbabilities: [[1.1, -0.1, 0, 0]]
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.removalRanges(
                sourceText: "a",
                tokenRanges: [validRange],
                spanProbabilities: [[.nan, 0, 1, 0]]
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.removalRanges(
                sourceText: "a",
                tokenRanges: [try TextUTF16Range(start: 0, end: 0)],
                spanProbabilities: [[1, 0, 0, 0]]
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.removalRanges(
                sourceText: "😀",
                tokenRanges: [try TextUTF16Range(start: 1, end: 2)],
                spanProbabilities: [[1, 0, 0, 0]]
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.removalRanges(
                sourceText: "a",
                tokenRanges: [try TextUTF16Range(start: 0, end: 2)],
                spanProbabilities: [[1, 0, 0, 0]]
            )
        }
    }
}
