import Foundation
import Testing
@testable import MacAmbientJevCore

private func be(_ value: UInt64, _ width: Int) -> [UInt8] {
    (0..<width).map { UInt8(truncatingIfNeeded: value >> UInt64(8 * (width - 1 - $0))) }
}

private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    be(UInt64(8 + payload.count), 4) + Array(type.utf8) + payload
}

private func elst(_ entries: [(duration: UInt32, mediaTime: Int32)]) -> [UInt8] {
    let body: [UInt8] = entries.flatMap { (e) -> [UInt8] in be(UInt64(e.duration), 4) + be(UInt64(UInt32(bitPattern: e.mediaTime)), 4) + [0, 1, 0, 0] }
    return box("edts", box("elst", [0, 0, 0, 0] + be(UInt64(entries.count), 4) + body))
}

private func smpb(_ text: String) -> [UInt8] {
    let item = box("mean", [0, 0, 0, 0] + Array("com.apple.iTunes".utf8))
        + box("name", [0, 0, 0, 0] + Array("iTunSMPB".utf8))
        + box("data", [0, 0, 0, 1, 0, 0, 0, 0] + Array(text.utf8))
    return box("udta", box("meta", [0, 0, 0, 0] + box("ilst", box("----", item))))
}

private func mp4(edts: [UInt8] = [], tags: [UInt8] = [], movieTimescale: UInt32 = 48_000, mediaTimescale: UInt32 = 48_000) -> Data {
    let mvhd = box("mvhd", [0, 0, 0, 0] + be(0, 8) + be(UInt64(movieTimescale), 4) + be(0, 4))
    let hdlr = box("hdlr", [0, 0, 0, 0, 0, 0, 0, 0] + Array("soun".utf8))
    let mdhd = box("mdhd", [0, 0, 0, 0] + be(0, 8) + be(UInt64(mediaTimescale), 4) + be(0, 4))
    let trak = box("trak", edts + box("mdia", mdhd + hdlr))
    return Data(box("ftyp", Array("M4A ".utf8)) + box("moov", mvhd + trak + tags))
}

private let smpbText = " 00000000 00000840 000003C0 0000000000003000 00000000"

@Test func editListGivesStartAndLength() throws {
    let priming = try MP4PrimingParser.parse(MP4DataSource(mp4(edts: elst([(12_288, 1_024)]))))
    #expect(priming == .editList(mediaTime: 1_024, segmentDuration: 12_288, movieTimescale: 48_000, mediaTimescale: 48_000))
    #expect(try priming.window(sampleRate: 48_000) == AACTrimWindow(start: 1_024, length: 12_288, slack: 1))
}

@Test func millisecondMovieTimescaleFloorsAndAllowsOneTickOfSlack() throws {
    let data = mp4(edts: elst([(207, 1_024)]), movieTimescale: 1_000, mediaTimescale: 44_100)
    let parsed = try MP4PrimingParser.parse(MP4DataSource(data))
    let window = try parsed.window(sampleRate: 44_100).unsafelyUnwrapped
    #expect(window == AACTrimWindow(start: 1_024, length: 9_128, slack: 45))
    #expect(throws: MP4PrimingError.self) { try window.checkDecodedTotal(1_024 + 9_128 - 46) }
    try window.checkDecodedTotal(1_024 + 9_128 - 45)
}

@Test func iTunSMPBGivesPrimingAndValidFrames() throws {
    let priming = try MP4PrimingParser.parse(MP4DataSource(mp4(tags: smpb(smpbText))))
    #expect(priming == .iTunSMPB(priming: 2_112, validFrames: 12_288))
}

@Test func editListWinsOverContradictoryiTunSMPB() throws {
    let data = mp4(edts: elst([(12_288, 1_024)]), tags: smpb("garbage"))
    #expect(try MP4PrimingParser.parse(MP4DataSource(data)).window(sampleRate: 48_000)?.start == 1_024)
}

@Test func noMetadataMeansNothingToTrim() throws {
    let priming = try MP4PrimingParser.parse(MP4DataSource(mp4()))
    #expect(priming == .none)
    #expect(try priming.window(sampleRate: 48_000) == nil)
}

@Test func unreadableMetadataIsAnError() throws {
    let valid = mp4(edts: elst([(12_288, 1_024)]))
    let cases: [Data] = [
        valid.prefix(valid.count - 5),
        mp4(edts: elst([(100, 0), (100, 0)])),
        mp4(edts: elst([(100, -1)])),
        mp4(tags: smpb(" 00000000 0000084 000003C0 0000000000003000")),
        Data(box("ftyp", []) + be(1, 4) + Array("moov".utf8) + be(UInt64.max, 8)),
        Data(box("ftyp", []) + be(1 << 40, 4) + Array("moov".utf8)),
    ]
    for data in cases {
        #expect(throws: MP4PrimingError.self) { try MP4PrimingParser.parse(MP4DataSource(data)) }
    }
    #expect(throws: MP4PrimingError.self) { try MP4Priming.iTunSMPB(priming: 1, validFrames: 0).window(sampleRate: 48_000) }
    #expect(throws: MP4PrimingError.self) {
        try MP4Priming.editList(mediaTime: 0, segmentDuration: .max, movieTimescale: 1, mediaTimescale: 48_000).window(sampleRate: 48_000)
    }
}

@Test func zeroDurationEditRunsToTheEndOnlyInFragmentedFiles() throws {
    let edts = elst([(0, 1_024)])
    let fragmented = try MP4PrimingParser.parse(MP4DataSource(mp4(edts: edts, tags: box("mvex", []))))
    #expect(try fragmented.window(sampleRate: 48_000) == AACTrimWindow(start: 1_024, length: nil, slack: 0))
    #expect(throws: MP4PrimingError.self) { try MP4PrimingParser.parse(MP4DataSource(mp4(edts: edts))) }
}

@Test func malformedUdtaDoesNotBlockAnEditListImport() throws {
    let quickTimeMeta = box("udta", box("meta", box("ilst", box("----", [1, 2, 3]))))
    let withEdit = try MP4PrimingParser.parse(MP4DataSource(mp4(edts: elst([(12_288, 1_024)]), tags: quickTimeMeta)))
    #expect(try withEdit.window(sampleRate: 48_000)?.start == 1_024)
    #expect(throws: MP4PrimingError.self) { try MP4PrimingParser.parse(MP4DataSource(mp4(tags: quickTimeMeta))) }
}
