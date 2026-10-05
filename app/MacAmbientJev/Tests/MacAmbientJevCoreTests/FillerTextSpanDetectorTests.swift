import Testing
@testable import MacAmbientJevCore

@Test
func fillerDetectorReturnsExpectedOriginalTextRanges() throws {
    let detector = FillerTextSpanDetector()
    let source = "えー、今日は、えー、RSAです。"
    let ranges = try detector.ranges(in: source)
    let removed = try ranges.map { String(try $0.substring(in: source)) }
    #expect(removed == ["えー、", "えー、"])
}

@Test
func fillerDetectorKeepsExistingWordAndAttachmentBoundaries() throws {
    let detector = FillerTextSpanDetector()
    for source in ["ええじゃないか", "ああいう方法", "あーいう方法", "えーと低優先度本文", "映画の説明", "今日はえー今日は"] {
        #expect(try detector.ranges(in: source).isEmpty)
    }
    for (source, removed) in [("えー今日はです", "えー"), ("あー、今日は", "あー、"), ("えっと(内容)", "えっと")] {
        let ranges = try detector.ranges(in: source)
        let removedText = try ranges.map { String(try $0.substring(in: source)) }
        #expect(removedText == [removed])
    }
}

@Test
func fillerDetectorPreservesParenthesesAndQuotesFollowingFiller() throws {
    let detector = FillerTextSpanDetector()
    let source = "えー、(\"RSA\"を説明します)"
    let ranges = try detector.ranges(in: source)
    let removed = try ranges.map { String(try $0.substring(in: source)) }
    #expect(removed == ["えー、"])
}
