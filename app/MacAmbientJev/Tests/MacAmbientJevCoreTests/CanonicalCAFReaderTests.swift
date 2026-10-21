import Foundation
import MacAmbientJevCAFFixtures
import Testing
@testable import MacAmbientJevCore

private func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
}

private func descriptionBody(
    sampleRate: Double = 16_000, formatID: String = "lpcm", flags: UInt32 = 3,
    bytesPerPacket: UInt32 = 4, framesPerPacket: UInt32 = 1, channels: UInt32 = 1, bits: UInt32 = 32
) -> [UInt8] {
    bigEndian(sampleRate.bitPattern) + Array(formatID.utf8) + bigEndian(flags) + bigEndian(bytesPerPacket)
        + bigEndian(framesPerPacket) + bigEndian(channels) + bigEndian(bits)
}

private func chunk(_ type: String, body: [UInt8], declaredSize: Int64? = nil) -> [UInt8] {
    Array(type.utf8) + bigEndian(declaredSize ?? Int64(body.count)) + body
}

private func dataChunk(_ samples: [Float], declaredSize: Int64? = nil) -> [UInt8] {
    let payload = bigEndian(UInt32(0)) + samples.flatMap { sample in
        withUnsafeBytes(of: sample.bitPattern.littleEndian) { Array($0) }
    }
    return chunk("data", body: payload, declaredSize: declaredSize)
}

private func cafFile(version: UInt16 = 1, flags: UInt16 = 0, chunks: [[UInt8]]) -> [UInt8] {
    Array("caff".utf8) + bigEndian(version) + bigEndian(flags) + chunks.flatMap { $0 }
}

private let canonicalDescription = chunk("desc", body: descriptionBody())

private struct CAFFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CanonicalCAF-\(UUID().uuidString)")
        try SessionFileAccess.createDirectory(root, relativeTo: root)
    }

    func reader(_ bytes: [UInt8], name: String = "input.caf") throws -> CanonicalCAFReader {
        let url = root.appending(path: name)
        try SessionFileAccess.writeAtomically(Data(bytes), to: url, relativeTo: root)
        return try CanonicalCAFReader(url: url, sessionURL: root)
    }

    func cleanup() {
        try? SessionFileAccess.removeIfPresent(root, relativeTo: root.deletingLastPathComponent())
    }
}

private func expectRejected(_ bytes: [UInt8], _ expected: CanonicalCAFError) throws {
    let fixture = try CAFFixture()
    defer { fixture.cleanup() }
    #expect(throws: expected) { _ = try fixture.reader(bytes) }
}

@Test func canonicalCAFReaderReadsTheMacWrittenFixtureSampleForSampleOnEveryPlatform() throws {
    let expected = try CanonicalCAFFixture.expectedSamples()
    let fixture = try CAFFixture()
    defer { fixture.cleanup() }
    let reader = try fixture.reader(Array(Data(contentsOf: CanonicalCAFFixture.cafURL())))
    #expect(reader.sampleCount == Int64(expected.count))
    let end = Int64(expected.count)
    let ranges: [Range<Int64>] = [0..<end, 0..<1, 0..<6, 5..<6, 999..<2_001, 1_000..<1_000, 4_096..<end, end - 1..<end, end..<end]
    for range in ranges {
        let samples = try reader.readSamples(frames: range)
        #expect(samples.map(\.bitPattern) == expected[Int(range.lowerBound)..<Int(range.upperBound)].map(\.bitPattern))
    }
}

@Test func canonicalCAFReaderSkipsUnknownChunksAndIgnoresChunksAfterData() throws {
    let fixture = try CAFFixture()
    defer { fixture.cleanup() }
    let samples: [Float] = [0.25, -0.5, 0.75]
    let reader = try fixture.reader(cafFile(chunks: [
        canonicalDescription,
        chunk("free", body: [UInt8](repeating: 0, count: 17)),
        chunk("info", body: []),
        chunk("zzzz", body: [1, 2, 3]),
        dataChunk(samples),
        chunk("pakt", body: [9, 9])
    ]))
    #expect(reader.sampleCount == 3)
    #expect(try reader.readSamples(frames: 0..<3) == samples)
    #expect(try reader.readSamples(frames: 1..<3) == [-0.5, 0.75])
}

@Test func canonicalCAFReaderReturnsStoredSamplesWithoutValidatingThem() throws {
    let fixture = try CAFFixture()
    defer { fixture.cleanup() }
    let stored: [Float] = [.nan, .infinity, -.infinity, -0.0, 1.5]
    let reader = try fixture.reader(cafFile(chunks: [canonicalDescription, dataChunk(stored)]))
    #expect(try reader.readSamples(frames: 0..<5).map(\.bitPattern) == stored.map(\.bitPattern))
}

@Test func canonicalCAFReaderAcceptsAnEmptyDataChunk() throws {
    let fixture = try CAFFixture()
    defer { fixture.cleanup() }
    let reader = try fixture.reader(cafFile(chunks: [canonicalDescription, dataChunk([])]))
    #expect(reader.sampleCount == 0)
    #expect(try reader.readSamples(frames: 0..<0) == [])
}

@Test func canonicalCAFReaderRejectsRangesOutsideTheFile() throws {
    let fixture = try CAFFixture()
    defer { fixture.cleanup() }
    let reader = try fixture.reader(cafFile(chunks: [canonicalDescription, dataChunk([1, 2, 3])]))
    for range in [-1..<1, 0..<4, 4..<4, Int64.min..<0, 0..<Int64.max] as [Range<Int64>] {
        #expect(throws: ProcessingTimelineReaderError.invalidFrameRange) { _ = try reader.readSamples(frames: range) }
    }
}

@Test func canonicalCAFReaderRejectsEveryTruncationOfACanonicalFile() throws {
    let full = cafFile(chunks: [canonicalDescription, chunk("free", body: [0, 0, 0]), dataChunk([0.5, -0.5])])
    let fixture = try CAFFixture()
    defer { fixture.cleanup() }
    for length in 0..<full.count {
        #expect(throws: CanonicalCAFError.self, "length \(length)") {
            _ = try fixture.reader(Array(full.prefix(length)))
        }
    }
    #expect(try fixture.reader(full).sampleCount == 2)
}

@Test func canonicalCAFReaderRejectsMalformedContainers() throws {
    let valid = [canonicalDescription, dataChunk([0.5])]
    try expectRejected(Array("RIFF".utf8) + [UInt8](repeating: 0, count: 40), .notCAF)
    try expectRejected(cafFile(version: 2, chunks: valid), .unsupportedVersion(2))
    try expectRejected(cafFile(flags: 1, chunks: valid), .unsupportedFileFlags(1))
    try expectRejected(cafFile(chunks: [dataChunk([0.5])]), .missingDescription)
    try expectRejected(cafFile(chunks: [chunk("free", body: []), canonicalDescription, dataChunk([0.5])]), .missingDescription)
    try expectRejected(cafFile(chunks: [canonicalDescription]), .missingData)
    try expectRejected(cafFile(chunks: [canonicalDescription, chunk("free", body: [0])]), .missingData)
    try expectRejected(cafFile(chunks: [canonicalDescription, canonicalDescription, dataChunk([0.5])]),
                       .noncanonicalFormat("descチャンクが複数あります"))
    try expectRejected(cafFile(chunks: [chunk("desc", body: descriptionBody() + [0]), dataChunk([0.5])]),
                       .invalidDescriptionSize(33))
    try expectRejected(cafFile(chunks: [chunk("desc", body: Array(descriptionBody().dropLast())), dataChunk([0.5])]),
                       .invalidDescriptionSize(31))
}

@Test func canonicalCAFReaderRejectsInvalidAndOverflowingChunkSizes() throws {
    try expectRejected(
        cafFile(chunks: [canonicalDescription, chunk("free", body: [], declaredSize: -2), dataChunk([0.5])]),
        .invalidChunkSize(chunk: "free", size: -2)
    )
    try expectRejected(
        cafFile(chunks: [canonicalDescription, chunk("free", body: [], declaredSize: Int64.max), dataChunk([0.5])]),
        .truncated(offset: UInt64(cafFile(chunks: [canonicalDescription, chunk("free", body: [], declaredSize: Int64.max), dataChunk([0.5])]).count))
    )
    try expectRejected(
        cafFile(chunks: [canonicalDescription, chunk("data", body: [0, 0, 0, 0], declaredSize: Int64.min)]),
        .invalidChunkSize(chunk: "data", size: Int64.min)
    )
    try expectRejected(
        cafFile(chunks: [canonicalDescription, chunk("data", body: [0, 0, 0, 0], declaredSize: Int64.max)]),
        .dataShorterThanDeclared(declared: Int64.max, available: 4)
    )
}

@Test func canonicalCAFReaderRejectsUnfinalizedDataChunks() throws {
    try expectRejected(
        cafFile(chunks: [canonicalDescription, dataChunk([0.5, 0.25], declaredSize: -1)]),
        .unfinalizedData
    )
}

@Test func canonicalCAFReaderRejectsDataShorterThanDeclared() throws {
    let bytes = cafFile(chunks: [canonicalDescription, dataChunk([0.5, 0.25], declaredSize: 13)])
    try expectRejected(bytes, .dataShorterThanDeclared(declared: 13, available: 12))
}

@Test func canonicalCAFReaderRejectsDataLayoutsThatAreNotWholeFloatFrames() throws {
    try expectRejected(
        cafFile(chunks: [canonicalDescription, chunk("data", body: [0, 0, 0])]),
        .invalidDataLayout("編集カウントを含められません")
    )
    try expectRejected(
        cafFile(chunks: [canonicalDescription, chunk("data", body: [0, 0, 0, 0, 1, 2, 3])]),
        .invalidDataLayout("PCM payloadが4 bytesの倍数ではありません")
    )
}

@Test func canonicalCAFReaderRejectsEveryNoncanonicalFormatWithoutConverting() throws {
    let cases: [(String, [UInt8])] = [
        ("sample rate 48000.0", descriptionBody(sampleRate: 48_000)),
        ("sample rate 16000.5", descriptionBody(sampleRate: 16_000.5)),
        ("format ulaw", descriptionBody(formatID: "ulaw")),
        ("format flags 2", descriptionBody(flags: 2)),
        ("format flags 1", descriptionBody(flags: 1)),
        ("format flags 4", descriptionBody(flags: 4)),
        ("channels 2", descriptionBody(bytesPerPacket: 8, channels: 2)),
        ("bits 16", descriptionBody(bytesPerPacket: 2, bits: 16)),
        ("bits 64", descriptionBody(bytesPerPacket: 8, bits: 64)),
        ("packet 8 bytes / 1 frames", descriptionBody(bytesPerPacket: 8)),
        ("packet 4 bytes / 2 frames", descriptionBody(framesPerPacket: 2))
    ]
    for (detail, body) in cases {
        try expectRejected(
            cafFile(chunks: [chunk("desc", body: body), dataChunk([0.5])]),
            .noncanonicalFormat(detail)
        )
    }
}

@Test func canonicalCAFReaderRefusesFilesOutsideTheSessionDirectory() throws {
    let fixture = try CAFFixture()
    defer { fixture.cleanup() }
    let session = fixture.root.appending(path: "session")
    let outside = fixture.root.appending(path: "outside")
    try SessionFileAccess.createDirectory(session, relativeTo: fixture.root)
    try SessionFileAccess.createDirectory(outside, relativeTo: fixture.root)
    let url = outside.appending(path: "input.caf")
    try SessionFileAccess.writeAtomically(
        Data(cafFile(chunks: [canonicalDescription, dataChunk([0.5])])), to: url, relativeTo: fixture.root
    )
    #expect(throws: CocoaError.self) { _ = try CanonicalCAFReader(url: url, sessionURL: session) }
    #expect(throws: CocoaError.self) {
        _ = try CanonicalCAFReader(url: session.appending(path: "missing.caf"), sessionURL: session)
    }
}
