import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func fillerAtStartOfMixedTextIsItsOwnExactFragment() {
    let text = "えー、今日は公開鍵暗号を説明します。"
    let fragments = FillerTextSpanDetector().fragments(in: text)

    #expect(fragments.filter(\.isFiller).map(\.text) == ["えー、"])
    #expect(fragments.filter { !$0.isFiller }.map(\.text) == ["今日は公開鍵暗号を説明します。"])
    #expect(fragments.map(\.text).joined() == text)
}

@Test
func attachedFillerAtUtteranceStartIsSeparatedFromFollowingContent() {
    for (text, filler) in [
        ("えー今日は公開鍵暗号を説明します。", "えー"),
        ("あー今日は公開鍵暗号を説明します。", "あー"),
        ("えっと今日は公開鍵暗号を説明します。", "えっと")
    ] {
        let fragments = FillerTextSpanDetector().fragments(in: text)

        #expect(fragments.filter(\.isFiller).map(\.text) == [filler])
        #expect(fragments.map(\.text).joined() == text)
    }
}

@Test
func fillerInsideSentenceIsDetectedWithoutMarkingSurroundingText() {
    let text = "今日は、えー、RSAです。"
    let fragments = FillerTextSpanDetector().fragments(in: text)

    #expect(fragments.filter(\.isFiller).map(\.text) == ["えー、"])
    #expect(fragments.map(\.text).joined() == text)
}

@Test
func fillerOnlyTextAndPunctuationVariantsRemainExact() {
    for text in ["えー", "えー。", "あー！", "うーん,", "えっと？"] {
        let fragments = FillerTextSpanDetector().fragments(in: text)

        #expect(fragments.filter(\.isFiller).map(\.text) == [text])
        #expect(fragments.map(\.text).joined() == text)
    }

    let repeated = "えー、あー、えっと。"
    let repeatedFragments = FillerTextSpanDetector().fragments(in: repeated)
    #expect(repeatedFragments.filter(\.isFiller).map(\.text) == ["えー、", "あー、", "えっと。"])
    #expect(repeatedFragments.map(\.text).joined() == repeated)
}

@Test
func similarCharactersInsideMeaningfulWordsAreNotDetectedAsFillers() {
    for text in ["ええじゃないか", "ああいう方法", "あーいう方法", "映画の説明"] {
        let fragments = FillerTextSpanDetector().fragments(in: text)

        #expect(fragments.allSatisfy { !$0.isFiller })
        #expect(fragments.map(\.text).joined() == text)
    }

    let plainText = "今日は公開鍵暗号を説明します。"
    let plainFragments = FillerTextSpanDetector().fragments(in: plainText)
    #expect(plainFragments.map(\.text) == [plainText])
    #expect(plainFragments.allSatisfy { !$0.isFiller })
}

@Test
func projectionBuildsFillerFragmentsForTranscriptRows() throws {
    let text = "えー、今日は公開鍵暗号を説明します。"
    let segment = MaterializedTranscriptSegment(
        segmentID: "mixed",
        startMilliseconds: 0,
        endMilliseconds: 1000,
        text: text,
        scene: .lecture,
        speakers: [],
        scopeSpans: [],
        contentPriority: .primary
    )
    let projection = LiveTranscriptProjection()
    let finalRow = try #require(projection.rows(for: [segment]).first)

    #expect(finalRow.textFragments.filter(\.isFiller).map(\.text) == ["えー、"])
    #expect(finalRow.textFragments.map(\.text).joined() == text)
    #expect(!finalRow.isLowPriority)
}

@Test
func punctuationOpeningContentMustNotBeStyledAsFiller() {
    let text = "えー、(RSAを説明します)"
    let fragments = FillerTextSpanDetector().fragments(in: text)

    #expect(fragments.filter(\.isFiller).map(\.text) == ["えー、"])
    #expect(fragments.filter { !$0.isFiller }.map(\.text) == ["(RSAを説明します)"])
    #expect(fragments.map(\.text).joined() == text)
}

@Test(arguments: ["＂", "＇"])
func fullwidthOpeningQuoteStaysWithFollowingContent(quote: String) {
    let content = "\(quote)RSA\(quote)を説明します"
    let text = "えー、\(content)"
    let fragments = FillerTextSpanDetector().fragments(in: text)

    #expect(fragments.filter(\.isFiller).map(\.text) == ["えー、"])
    #expect(fragments.filter { !$0.isFiller }.map(\.text) == [content])
    #expect(fragments.map(\.text).joined() == text)
}
