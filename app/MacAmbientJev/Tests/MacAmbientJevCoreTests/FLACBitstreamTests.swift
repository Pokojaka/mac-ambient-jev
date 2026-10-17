import Foundation
import Testing
@testable import MacAmbientJevCore

private struct FLACBitstreamFixture {
    let root: URL
    let fileURL: URL

    init(bytes: [UInt8]) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FLACBitstreamTests-\(UUID().uuidString)")
        root = directory
        fileURL = directory.appending(path: "input.flac")
        try SessionFileAccess.createDirectory(directory, relativeTo: directory)
        try SessionFileAccess.writeAtomically(Data(bytes), to: fileURL, relativeTo: directory)
    }

    func openReader() throws -> (FLACBitReader, FileHandle) {
        let handle = try SessionFileAccess.openHandle(fileURL, relativeTo: root)
        return (FLACBitReader(handle: handle), handle)
    }

    func cleanup() {
        try? SessionFileAccess.removeIfPresent(fileURL, relativeTo: root)
        try? SessionFileAccess.removeIfPresent(root, relativeTo: root.deletingLastPathComponent())
    }
}

@Test func flacCRCMatchesKnownCheckValues() {
    let bytes = Array("123456789".utf8)
    #expect(FLACChecksum.crc8(bytes) == 0xf4)
    #expect(FLACChecksum.crc16(bytes) == 0xfee8)
    #expect(bytes.reduce(UInt16(0), FLACChecksum.updateCRC16) == 0xfee8)
}

@Test func bitWriterAndReaderRoundTripAcrossBytesAndSignedWidths() throws {
    var writer = FLACBitWriter()
    writer.write(0b101, bits: 3)
    writer.write(0xabcd, bits: 16)
    writer.writeSigned(-1, bits: 64)
    writer.writeSigned(Int64.min, bits: 64)
    writer.writeSigned(-2, bits: 8)
    writer.writeUnary(9)
    #expect(writer.bitCount == 165)
    writer.align()
    #expect(writer.bitCount == writer.bytes.count * 8)

    let fixture = try FLACBitstreamFixture(bytes: writer.bytes)
    defer { fixture.cleanup() }
    let (reader, handle) = try fixture.openReader()
    defer { try? handle.close() }

    #expect(try reader.read(3) == 0b101)
    #expect(try reader.read(16) == 0xabcd)
    #expect(try reader.readSigned(64) == -1)
    #expect(try reader.readSigned(64) == Int64.min)
    #expect(try reader.readSigned(8) == -2)
    #expect(try reader.readUnary(maximum: 9) == 9)
    try reader.alignRequiringZero()
    #expect(reader.isByteAligned)
    #expect(reader.offset == UInt64(writer.bytes.count))
    #expect(try reader.atEnd())
}

@Test func unaryReaderHandlesZeroRunsAcrossEveryBitOffset() throws {
    let zeroRuns: [UInt64] = [0, 1, 7, 8, 9, 65_536]
    for startingOffset in 0...7 {
        for zeroRun in zeroRuns {
            var writer = FLACBitWriter()
            let prefix = startingOffset == 0 ? 0 : (1 << startingOffset) - 1
            writer.write(UInt64(prefix), bits: startingOffset)
            writer.writeUnary(zeroRun)
            writer.align()

            let fixture = try FLACBitstreamFixture(bytes: writer.bytes)
            defer { fixture.cleanup() }
            let (reader, handle) = try fixture.openReader()
            defer { try? handle.close() }

            #expect(try reader.read(startingOffset) == UInt64(prefix))
            #expect(try reader.readUnary(maximum: zeroRun) == zeroRun)
            try reader.alignRequiringZero()
            #expect(reader.offset == UInt64(writer.bytes.count))
            #expect(try reader.atEnd())
        }
    }
}

@Test func readerSeekAndRefillPreserveOffsetsAndCRCAt64KiBBoundary() throws {
    let bytes = (0..<65_540).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) }
    let fixture = try FLACBitstreamFixture(bytes: bytes)
    defer { fixture.cleanup() }
    let (reader, handle) = try fixture.openReader()
    defer { try? handle.close() }

    let boundaryOffset = UInt64(64 * 1024 - 1)
    for _ in 0..<Int(boundaryOffset) {
        _ = try reader.readByte()
    }
    reader.beginFrame()
    let expected = Array(bytes[Int(boundaryOffset)..<(Int(boundaryOffset) + 4)])
    let expectedValue = expected.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    #expect(try reader.read(32) == expectedValue)
    #expect(reader.offset == boundaryOffset + 4)
    #expect(reader.frameCRC == FLACChecksum.crc16(expected))

    try reader.seek(to: boundaryOffset)
    reader.beginFrame()
    var actual: [UInt8] = []
    for _ in 0..<4 {
        actual.append(try reader.readByte())
    }
    #expect(actual == expected)
    #expect(reader.offset == boundaryOffset + 4)
    #expect(reader.frameCRC == FLACChecksum.crc16(expected))
}

@Test func readerTracksFrameCRCIncludingFooter() throws {
    let payload = Array("123456789".utf8)
    let checksum = FLACChecksum.crc16(payload)
    let frame = payload + [UInt8(checksum >> 8), UInt8(truncatingIfNeeded: checksum)]
    let fixture = try FLACBitstreamFixture(bytes: frame)
    defer { fixture.cleanup() }
    let (reader, handle) = try fixture.openReader()
    defer { try? handle.close() }

    reader.beginFrame()
    var actual: [UInt8] = []
    for _ in 0..<frame.count {
        actual.append(try reader.readByte())
    }
    #expect(actual == frame)
    #expect(reader.frameCRC == 0)
    #expect(try reader.atEnd())
}

@Test func truncatedReadsReportLogicalNextByteOffset() throws {
    let fixture = try FLACBitstreamFixture(bytes: [0xa0])
    defer { fixture.cleanup() }
    let (reader, handle) = try fixture.openReader()
    defer { try? handle.close() }

    #expect(try reader.read(3) == 0b101)
    do {
        _ = try reader.read(6)
        Issue.record("Expected a truncated bitstream")
    } catch let error as FLACTimelineReaderError {
        #expect(error == .truncated(offset: 1))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func nonzeroAlignmentPaddingIsRejected() throws {
    let fixture = try FLACBitstreamFixture(bytes: [0b1010_0001])
    defer { fixture.cleanup() }
    let (reader, handle) = try fixture.openReader()
    defer { try? handle.close() }

    #expect(try reader.read(3) == 0b101)
    do {
        try reader.alignRequiringZero()
        Issue.record("Expected nonzero alignment padding to fail")
    } catch let error as FLACTimelineReaderError {
        #expect(error == .decodeFailed(frame: 0, reason: "バイト境界のパディングビットが0ではありません。"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
