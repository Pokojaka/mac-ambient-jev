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
    func labelsAreOZeroFOneDTwoAndArgmaxTiesChooseTheFirstIndex() throws {
        let ranges = try (0..<4).map { try TextUTF16Range(start: $0, end: $0 + 1) }
        let fillerRanges = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: "abcd",
            tokenRanges: ranges,
            spanProbabilities: [
                [0.5, 0.5, 0],
                [0, 0.5, 0.5],
                [0, 0, 1],
                [0, 1, 0]
            ]
        )

        #expect(fillerRanges == [
            try TextUTF16Range(start: 1, end: 2),
            try TextUTF16Range(start: 3, end: 4)
        ])
    }

    @Test
    func onlyAdjacentFLabelsCoalesceAndDOStayOutsideFillerRanges() throws {
        let ranges = try (0..<6).map { try TextUTF16Range(start: $0, end: $0 + 1) }
        let fillerRanges = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: "abcdef",
            tokenRanges: ranges,
            spanProbabilities: [
                [0, 1, 0],
                [0, 1, 0],
                [0, 0, 1],
                [0, 1, 0],
                [1, 0, 0],
                [0, 1, 0]
            ]
        )

        #expect(fillerRanges == [
            try TextUTF16Range(start: 0, end: 2),
            try TextUTF16Range(start: 3, end: 4),
            try TextUTF16Range(start: 5, end: 6)
        ])
    }

    @Test
    func laterOverlappingOAndDLabelsOverwriteFIncludingDuplicateScalarRanges() throws {
        let firstScalar = try TextUTF16Range(start: 0, end: 1)
        let secondScalar = try TextUTF16Range(start: 1, end: 2)
        let fillerRanges = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: "ab",
            tokenRanges: [firstScalar, firstScalar, secondScalar, secondScalar],
            spanProbabilities: [
                [0, 1, 0],
                [1, 0, 0],
                [0, 1, 0],
                [0, 0, 1]
            ]
        )

        #expect(fillerRanges.isEmpty)
    }

    @Test
    func supplementaryAndDecomposedScalarsUseEvaluationUTF16Offsets() throws {
        let sourceText = "😀e\u{301}!"
        let fillerRanges = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: sourceText,
            tokenRanges: [
                try TextUTF16Range(start: 0, end: 2),
                try TextUTF16Range(start: 2, end: 3),
                try TextUTF16Range(start: 3, end: 4),
                try TextUTF16Range(start: 4, end: 5)
            ],
            spanProbabilities: [
                [0, 1, 0],
                [0, 1, 0],
                [0, 1, 0],
                [1, 0, 0]
            ]
        )

        #expect(fillerRanges == [try TextUTF16Range(start: 0, end: 4)])
        #expect(String(try fillerRanges[0].substring(in: sourceText)) == "😀e\u{301}")
    }

    @Test
    func everyScalarInAnFillerCharacterMustBeF() throws {
        let sourceText = "えｶﾞ"
        let ranges = try scalarRanges(sourceText)
        #expect(ranges == [
            try TextUTF16Range(start: 0, end: 1),
            try TextUTF16Range(start: 1, end: 2),
            try TextUTF16Range(start: 2, end: 3)
        ])

        let fillerThenO = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: sourceText,
            tokenRanges: ranges,
            spanProbabilities: [[0, 1, 0], [0, 1, 0], [1, 0, 0]]
        )
        #expect(fillerThenO == [try TextUTF16Range(start: 0, end: 1)])
        let fillerThenOProjection = try TranscriptTextProjector().project(
            sourceText: sourceText,
            fillerRanges: fillerThenO
        )
        #expect(fillerThenOProjection.text == "ｶﾞ")

        let mixedCluster = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: sourceText,
            tokenRanges: ranges,
            spanProbabilities: [[0, 1, 0], [1, 0, 0], [0, 1, 0]]
        )
        #expect(mixedCluster == [try TextUTF16Range(start: 0, end: 1)])
        let mixedClusterProjection = try TranscriptTextProjector().project(
            sourceText: sourceText,
            fillerRanges: mixedCluster
        )
        #expect(mixedClusterProjection.text == "ｶﾞ")

        let fillerThenD = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: sourceText,
            tokenRanges: ranges,
            spanProbabilities: [[0, 1, 0], [0, 0, 1], [0, 1, 0]]
        )
        #expect(fillerThenD == [try TextUTF16Range(start: 0, end: 1)])
        let fillerThenDProjection = try TranscriptTextProjector().project(
            sourceText: sourceText,
            fillerRanges: fillerThenD
        )
        #expect(fillerThenDProjection.text == "ｶﾞ")

        let allF = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: sourceText,
            tokenRanges: ranges,
            spanProbabilities: [[0, 1, 0], [0, 1, 0], [0, 1, 0]]
        )
        #expect(allF == [try TextUTF16Range(start: 0, end: 3)])
    }

    @Test
    func allScalarsInAnEmojiCharacterMustBeF() throws {
        let sourceText = "👍🏻"
        let ranges = try scalarRanges(sourceText)
        #expect(ranges == [
            try TextUTF16Range(start: 0, end: 2),
            try TextUTF16Range(start: 2, end: 4)
        ])

        let fillerThenO = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: sourceText,
            tokenRanges: ranges,
            spanProbabilities: [[0, 1, 0], [1, 0, 0]]
        )
        #expect(fillerThenO.isEmpty)
        let fillerThenOProjection = try TranscriptTextProjector().project(
            sourceText: sourceText,
            fillerRanges: fillerThenO
        )
        #expect(fillerThenOProjection.text == sourceText)

        let oThenFiller = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: sourceText,
            tokenRanges: ranges,
            spanProbabilities: [[1, 0, 0], [0, 1, 0]]
        )
        #expect(oThenFiller.isEmpty)
        let oThenFillerProjection = try TranscriptTextProjector().project(
            sourceText: sourceText,
            fillerRanges: oThenFiller
        )
        #expect(oThenFillerProjection.text == sourceText)

        let allF = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: sourceText,
            tokenRanges: ranges,
            spanProbabilities: [[0, 1, 0], [0, 1, 0]]
        )
        #expect(allF == [try TextUTF16Range(start: 0, end: 4)])
        let allFProjection = try TranscriptTextProjector().project(
            sourceText: sourceText,
            fillerRanges: allF
        )
        #expect(allFProjection.text.isEmpty)
    }

    @Test
    func uncoveredTextAndTrailingPunctuationRemainO() throws {
        let fillerRanges = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: "まあ、",
            tokenRanges: [
                try TextUTF16Range(start: 0, end: 1),
                try TextUTF16Range(start: 1, end: 2)
            ],
            spanProbabilities: [[0, 1, 0], [0, 1, 0]]
        )

        #expect(fillerRanges == [try TextUTF16Range(start: 0, end: 2)])
        #expect(String(try fillerRanges[0].substring(in: "まあ、")) == "まあ")
    }

    @Test
    func fillerProjectionKeepsTheLiteralTargetAndDRepair() throws {
        let sourceText = "まあ、あの、今日は損失関数の話をします。"
        let sourceRanges = try scalarRanges(sourceText)
        let spanProbabilities = sourceRanges.indices.map { index in
            index < 6 ? [0.0, 1.0, 0.0] : [1.0, 0.0, 0.0]
        }
        let fillerRanges = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: sourceText,
            tokenRanges: sourceRanges,
            spanProbabilities: spanProbabilities
        )

        #expect(fillerRanges == [try TextUTF16Range(start: 0, end: 6)])
        let projected = try TranscriptTextProjector().project(sourceText: sourceText, fillerRanges: fillerRanges)
        #expect(projected.text == "今日は損失関数の話をします。")

        let repairText = "今日は今日は損失関数の話をします。"
        let repairRanges = try scalarRanges(repairText)
        let repairProbabilities = repairRanges.indices.map { index in
            index < 3 ? [0.0, 0.0, 1.0] : [1.0, 0.0, 0.0]
        }
        let repairFillers = try ClauseTaggerSpanProjection.fillerRanges(
            sourceText: repairText,
            tokenRanges: repairRanges,
            spanProbabilities: repairProbabilities
        )

        #expect(repairFillers.isEmpty)
        let repairProjected = try TranscriptTextProjector().project(
            sourceText: repairText,
            fillerRanges: repairFillers
        )
        #expect(repairProjected.text == "今日は今日は損失関数の話をします。")
    }

    @Test
    func invalidPredictionShapeProbabilitiesAndRangesFail() throws {
        let validRange = try TextUTF16Range(start: 0, end: 1)
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.fillerRanges(
                sourceText: "a",
                tokenRanges: [validRange],
                spanProbabilities: []
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.fillerRanges(
                sourceText: "a",
                tokenRanges: [validRange],
                spanProbabilities: [[1, 0]]
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.fillerRanges(
                sourceText: "a",
                tokenRanges: [validRange],
                spanProbabilities: [[0.4, 0.4, 0.0]]
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.fillerRanges(
                sourceText: "a",
                tokenRanges: [validRange],
                spanProbabilities: [[1.1, -0.1, 0.0]]
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.fillerRanges(
                sourceText: "a",
                tokenRanges: [validRange],
                spanProbabilities: [[.nan, 0, 1]]
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.fillerRanges(
                sourceText: "a",
                tokenRanges: [try TextUTF16Range(start: 0, end: 0)],
                spanProbabilities: [[1, 0, 0]]
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.fillerRanges(
                sourceText: "😀",
                tokenRanges: [try TextUTF16Range(start: 1, end: 2)],
                spanProbabilities: [[1, 0, 0]]
            )
        }
        #expect(throws: ClauseTaggerSpanProjectionError.invalidPrediction) {
            try ClauseTaggerSpanProjection.fillerRanges(
                sourceText: "a",
                tokenRanges: [try TextUTF16Range(start: 0, end: 2)],
                spanProbabilities: [[1, 0, 0]]
            )
        }
    }
}
