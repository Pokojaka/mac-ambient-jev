import Testing
@testable import MacAmbientJevCore

@Test
func japaneseNumeralDisplayConvertsSupportedTranscriptExamples() {
    let cases = [
        ("測定値は二十八点四でした。", "測定値は28.4でした。"),
        ("エックスは二です", "エックスは2です"),
        ("二たす三は五", "2たす3は5"),
        ("五十％", "50％"),
        ("エックスイコール二", "エックスイコール2"),
        ("ワイは三エックス", "ワイは3エックス"),
        ("三", "3"),
        ("三。", "3。")
    ]

    for (input, expected) in cases {
        expectJapaneseNumeralDisplay(input, expected)
    }
}

@Test
func japaneseNumeralDisplayLeavesKanjiWordsAndHomophonesUnchanged() {
    let unchanged = [
        "に", "ニ", "二乗", "三分の一", "十二分の五", "二分の一の確率",
        "一時に集合", "三時二十分", "二十人", "十分に", "一回り", "一人で", "一々",
        "十人十色", "百人一首", "四六時中", "統一", "万一", "一点張り",
        "二千二十六年九月二十六日", "一緒"
    ]

    for input in unchanged {
        expectJapaneseNumeralDisplay(input, input)
    }
}

@Test
func japaneseNumeralDisplayTransliteratesDigitRunsAndParsesPositionalGroups() {
    let cases = [
        ("〇", "0"),
        ("〇零一二三四五六七八九", "00123456789"),
        ("〇〇一二", "0012"),
        ("一二三", "123"),
        ("二〇二六", "2026"),
        ("二千二十六", "2026"),
        ("十一", "11"),
        ("一千", "1000"),
        ("千", "1000"),
        ("百", "100"),
        ("一万", "10000"),
        ("一億二万三", "100020003"),
        ("一億二千万", "120000000"),
        ("十万", "100000"),
        ("九千九百九十九億九千九百九十九万九千九百九十九", "999999999999")
    ]

    for (input, expected) in cases {
        expectJapaneseNumeralDisplay(input, expected)
    }
}

@Test
func japaneseNumeralDisplayDistinguishesIdeographicAndCircleZero() {
    let cases = [
        ("〇", "0"),
        ("○", "○"),
        ("○二○", "○2○"),
        ("二〇二六", "2026")
    ]

    for (input, expected) in cases {
        expectJapaneseNumeralDisplay(input, expected)
    }
}

@Test
func japaneseNumeralDisplayPreservesArbitraryLengthDigitRunsAndFractions() {
    let longRun = String(repeating: "一", count: 40)
    let longDigits = String(repeating: "1", count: 40)
    let longFraction = String(repeating: "一", count: 40)
    let longFractionDigits = String(repeating: "1", count: 40)

    expectJapaneseNumeralDisplay(longRun, longDigits)
    expectJapaneseNumeralDisplay("二点\(longFraction)", "2.\(longFractionDigits)")
}

@Test
func japaneseNumeralDisplayConvertsDigitOnlyDecimalsWithoutDroppingZeros() {
    let cases = [
        ("二十八点四", "28.4"),
        ("二点一四", "2.14"),
        ("零点零四", "0.04"),
        ("二点〇四", "2.04"),
        ("二点一〇", "2.10"),
        ("〇〇点零〇", "00.00"),
        ("二〇点三", "20.3")
    ]

    for (input, expected) in cases {
        expectJapaneseNumeralDisplay(input, expected)
    }
}

@Test
func japaneseNumeralDisplayLeavesMalformedNumeralCandidatesWhole() {
    let malformed = [
        "一二万", "二〇二六万", "一百零二", "十十", "二二十", "百千", "一万億",
        "万万", "一万一億", "九千九百億億", "万", "億", "兆", "一兆", "兆一",
        "点二", "点四", "二十点", "二点", "二点十", "一点二点三", "一二万点三",
        "あ一二万い"
    ]

    for input in malformed {
        expectJapaneseNumeralDisplay(input, input)
    }
}

@Test
func japaneseNumeralDisplayRequiresNonKanjiBoundariesForIntegerAndDecimalCandidates() {
    let unchanged = [
        "漢二字", "々二々", "漢二点三", "二点三漢", "漢二点三字", "二点三点四",
        "二点三点", "前二点三後", "3二4", "3二", "二3", "２二", "二２",
        "二.五", "二．五", ".二点五", "二点五.", "．二点五", "二点五．",
        "3二点五", "二点五3", "２二点五", "二点五２"
    ]
    for input in unchanged {
        expectJapaneseNumeralDisplay(input, input)
    }

    let blockingCharacters = Array("0123456789０１２３４５６７８９.．")
    for blocker in blockingCharacters {
        for candidate in ["二", "二点五"] {
            let before = "\(blocker)\(candidate)"
            let after = "\(candidate)\(blocker)"
            expectJapaneseNumeralDisplay(before, before)
            expectJapaneseNumeralDisplay(after, after)
        }
    }

    let convertible = [
        ("abc二xyz", "abc2xyz"),
        (" 二 ", " 2 "),
        ("😀二!", "😀2!"),
        ("（二、）", "（2、）"),
        ("二％", "2％"),
        ("二%", "2%"),
        ("ー二ー", "ー2ー"),
        ("ｴｯｸｽｲｺｰﾙ二", "ｴｯｸｽｲｺｰﾙ2"),
        ("二\n三", "2\n3")
    ]
    for (input, expected) in convertible {
        expectJapaneseNumeralDisplay(input, expected)
    }

    expectJapaneseNumeralDisplay("", "")
}

@Test
func japaneseNumeralDisplayRecognizesKanjiInEverySpecifiedUnicodeBlock() {
    let kanji = [
        "\u{3400}", "\u{4E2D}", "\u{F900}", "\u{FAFF}", "\u{20000}", "𠮟",
        "\u{2A700}", "\u{2B740}", "\u{2B820}", "\u{2CEB0}", "\u{2EBF0}",
        "\u{2F800}", "\u{30000}", "\u{31350}", "\u{323B0}", "々"
    ]

    for character in kanji {
        let numeralBefore = "二\(character)"
        let kanjiBefore = "\(character)二"
        expectJapaneseNumeralDisplay(numeralBefore, numeralBefore)
        expectJapaneseNumeralDisplay(kanjiBefore, kanjiBefore)
    }
}

@Test
func japaneseNumeralDisplayUsesKanjiScalarsInVariationSequenceNeighbours() {
    let withVariationBefore = "漢\u{E0100}二"
    let withVariationAfter = "二漢\u{E0100}"
    let numeralWithVariation = "二\u{E0100}三"

    expectJapaneseNumeralDisplay(withVariationBefore, withVariationBefore)
    expectJapaneseNumeralDisplay(withVariationAfter, withVariationAfter)
    expectJapaneseNumeralDisplay(numeralWithVariation, numeralWithVariation)
}

@Test
func japaneseNumeralDisplayProtectsOnlyLiteralSeedPhrases() {
    let phraseOccurrences = [
        "!万が一!",
        "!一か八か!",
        "!千と千尋の神隠し!",
        "!くノ一!"
    ]
    for input in phraseOccurrences {
        expectJapaneseNumeralDisplay(input, input)
    }

    let cases = [
        ("万が一に備えて二つ", "万が一に備えて2つ"),
        ("一か八かで二つ", "一か八かで2つ"),
        ("千と千尋の神隠しを見た", "千と千尋の神隠しを見た"),
        ("千と千尋の神隠しと二つ", "千と千尋の神隠しと2つ"),
        ("くノ一と二つ", "くノ一と2つ"),
        ("一か八かと一か八かで二つ", "一か八かと一か八かで2つ"),
        ("八千と千を足す", "8000と1000を足す"),
        ("千と千", "1000と1000"),
        ("万か\u{3099}一", "万か\u{3099}1")
    ]
    for (input, expected) in cases {
        expectJapaneseNumeralDisplay(input, expected)
    }
}

@Test
func japaneseNumeralDisplayNeverMatchesAPhraseInsideALongerNumeralRun() {
    expectJapaneseNumeralDisplay("九九を覚える", "九九を覚える")
    expectJapaneseNumeralDisplay("七五三の写真", "七五三の写真")
    expectJapaneseNumeralDisplay("九九九です", "999です")
    expectJapaneseNumeralDisplay("二百五十です", "250です")
}

@Test
func japaneseNumeralDisplayNeverJoinsRunsAcrossRemovedText() {
    // 二えー三 shown as 二三 once the filler is removed.
    #expect(JapaneseNumeralDisplayConverter.convert("二三です", removalJoins: [1]) == "二三です")
    #expect(JapaneseNumeralDisplayConverter.convert("二点三です", removalJoins: [1]) == "二点三です")
    #expect(JapaneseNumeralDisplayConverter.convert("二点三です", removalJoins: [2]) == "二点三です")
    // A join next to a non-numeral keeps the usual neighbour rules on the shown text.
    #expect(JapaneseNumeralDisplayConverter.convert("二つと三つ", removalJoins: [2]) == "2つと3つ")
    #expect(JapaneseNumeralDisplayConverter.convert("二人", removalJoins: [1]) == "二人")
    #expect(JapaneseNumeralDisplayConverter.convert("𠮟二と三", removalJoins: [2, 4, 5]) == "𠮟二と3")
}

@Test
func japaneseNumeralDisplayProtectsBothRunsOfFractionExpressions() {
    let unchanged = [
        "三分の一", "十二分の五", "二分の一の確率", "十十分の一",
        "三分の一分の二", "二点三分の一"
    ]
    for input in unchanged {
        expectJapaneseNumeralDisplay(input, input)
    }

    expectJapaneseNumeralDisplay("三分の一と二", "三分の一と2")
}

@Test
func japaneseNumeralDisplayPreservesOtherScalarsAndEmptyInput() {
    let original = "e\u{301}二😀"
    let expected = "e\u{301}2😀"
    let converted = expectJapaneseNumeralDisplay(original, expected)
    let numeralWithVariation = "e\u{301}二\u{E0100}😀"

    #expect(Array(converted.unicodeScalars) == Array(expected.unicodeScalars))
    expectJapaneseNumeralDisplay(numeralWithVariation, numeralWithVariation)
    expectJapaneseNumeralDisplay("", "")
}

@discardableResult
private func expectJapaneseNumeralDisplay(_ input: String, _ expected: String) -> String {
    let converted = JapaneseNumeralDisplayConverter.convert(input, removalJoins: [])
    #expect(converted == expected)
    #expect(JapaneseNumeralDisplayConverter.convert(converted, removalJoins: []) == converted)
    return converted
}
