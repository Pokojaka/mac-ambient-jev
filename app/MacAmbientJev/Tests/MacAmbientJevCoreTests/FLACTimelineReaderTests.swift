import Foundation
import Testing
@testable import MacAmbientJevCore

private let portableFLACTimelineLengths = [1, 4_095, 4_096, 4_097, 3 * 4_096 + 17]
private let portableFLACTimelineSignals = ["noise", "silence", "clipped-alternating", "sine"]

private let referenceFLACExecutable: URL? = {
    #if os(Windows)
    let executableName = "flac.exe"
    let pathSeparator: Character = ";"
    #else
    let executableName = "flac"
    let pathSeparator: Character = ":"
    #endif
    guard let searchPath = flacSearchPath(in: ProcessInfo.processInfo.environment) else { return nil }
    for directory in searchPath.split(separator: pathSeparator, omittingEmptySubsequences: false) {
        let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appending(path: executableName)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
}()

private struct PortableFLACProcessFailure: LocalizedError {
    let arguments: [String]
    let status: Int32
    let output: String

    var errorDescription: String? {
        "flac \(arguments.joined(separator: " ")) が終了コード \(status) で失敗しました: \(output)"
    }
}

private func runReferenceFLAC(_ executable: URL, arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    try process.run()
    let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw PortableFLACProcessFailure(
            arguments: arguments,
            status: process.terminationStatus,
            output: output
        )
    }
}

private struct DeterministicTimelineAudio: TimelineAudioReading {
    let info: TimelineAudioInfo
    private let samples: [Float]
    private let returnsShortRead: Bool

    init(samples: [Float], committedFrames: Int64? = nil, returnsShortRead: Bool = false) throws {
        self.samples = samples
        self.returnsShortRead = returnsShortRead
        self.info = try TimelineAudioInfo(
            committedFrames: committedFrames ?? Int64(samples.count),
            gapEvents: []
        )
    }

    func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        var result = Array(samples[Int(frameRange.lowerBound)..<Int(frameRange.upperBound)])
        if returnsShortRead && !result.isEmpty { result.removeLast() }
        return result
    }

    func validateAudio() throws {}
}

private struct PortableFLACTimelineFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PortableFLACTimeline-\(UUID().uuidString)")
        try SessionFileAccess.createDirectory(root, relativeTo: root)
    }

    func file(_ name: String = "recording.flac") -> URL {
        root.appending(path: name)
    }

    func write(_ samples: [Float], to url: URL? = nil) throws -> URL {
        let destination = url ?? file()
        let source = try DeterministicTimelineAudio(samples: samples)
        try RecordingFLAC.write(reader: source, to: destination, sessionURL: root)
        return destination
    }

    func reader(at url: URL, committedFrames: Int64) throws -> FLACTimelineReader {
        let info = try TimelineAudioInfo(committedFrames: committedFrames, gapEvents: [])
        return try FLACTimelineReader(url: url, info: info, sessionURL: root)
    }

    func cleanup() {
        try? SessionFileAccess.removeIfPresent(root, relativeTo: root.deletingLastPathComponent())
    }
}

private func portableFLACTimelineSignal(_ name: String, count: Int) -> [Float] {
    switch name {
    case "noise":
        var state: UInt32 = 0x6d2b_79f5
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            let sample = Int32(state >> 16) - 32_768
            return Float(sample) / 32_768
        }
    case "silence":
        return [Float](repeating: 0, count: count)
    case "clipped-alternating":
        let sequence: [Float] = [1.25, -1.25, 1, -1, 2, -2]
        return (0..<count).map { sequence[$0 % sequence.count] }
    case "sine":
        return (0..<count).map { index in
            Float(0.73 * sin(2.0 * .pi * 440.0 * Double(index) / 16_000.0))
        }
    default:
        preconditionFailure("未知の決定的 FLAC 信号です: \(name)")
    }
}

private func quantizedTimelineSamples(_ samples: [Float]) -> [Float] {
    samples.map { sample in
        guard let quantized = RecordingFLAC.quantize16(sample) else {
            preconditionFailure("このフィクスチャでは有限値のサンプルが必要です")
        }
        return Float(quantized) / 32_768
    }
}

private func deterministicRanges(frameCount: Int, seed: UInt32) -> [Range<Int64>] {
    var ranges: [Range<Int64>] = []
    if frameCount > 4_096 {
        ranges.append(4_093..<Int64(min(frameCount, 4_101)))
    }
    if frameCount > 8_192 {
        ranges.append(8_189..<Int64(min(frameCount, 8_197)))
    }

    var state = seed
    for _ in 0..<12 {
        state = state &* 1_664_525 &+ 1_013_904_223
        let start = Int(state % UInt32(frameCount))
        state = state &* 1_664_525 &+ 1_013_904_223
        let maximumLength = min(67, frameCount - start)
        let length = 1 + Int(state % UInt32(maximumLength))
        ranges.append(Int64(start)..<Int64(start + length))
    }
    return ranges
}

private func readUInt24(_ bytes: [UInt8], at offset: Int) -> Int {
    Int(bytes[offset]) << 16 | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
}

private func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(bytes[offset + $1]) }
}

private func writeUInt64(_ value: UInt64, to bytes: inout [UInt8], at offset: Int) {
    for index in 0..<8 {
        bytes[offset + index] = UInt8(truncatingIfNeeded: value >> ((7 - index) * 8))
    }
}

private func replaceFixedFrameNumber(
    _ frameNumber: UInt8,
    in bytes: inout [UInt8],
    frameStart: Int,
    frameEnd: Int
) {
    precondition(bytes[frameStart + 4] < 0x80, "小さなフレーム番号は1バイトで符号化されます")
    bytes[frameStart + 4] = frameNumber

    let sizeAndRate = bytes[frameStart + 2]
    let blockSizeCode = Int(sizeAndRate >> 4)
    let sampleRateCode = Int(sizeAndRate & 0x0f)
    let blockSizeExtraCount = blockSizeCode == 6 ? 1 : (blockSizeCode == 7 ? 2 : 0)
    let sampleRateExtraCount = sampleRateCode == 12 ? 1 : ([13, 14].contains(sampleRateCode) ? 2 : 0)
    let headerCRCOffset = frameStart + 5 + blockSizeExtraCount + sampleRateExtraCount
    bytes[headerCRCOffset] = FLACChecksum.crc8(Array(bytes[frameStart..<headerCRCOffset]))

    let frameCRCOffset = frameEnd - 2
    let frameCRC = FLACChecksum.crc16(Array(bytes[frameStart..<frameCRCOffset]))
    bytes[frameCRCOffset] = UInt8(truncatingIfNeeded: frameCRC >> 8)
    bytes[frameCRCOffset + 1] = UInt8(truncatingIfNeeded: frameCRC)
}

private func malformedFixedBlockStream(
    in fixture: PortableFLACTimelineFixture
) throws -> (bytes: [UInt8], frameCount: Int64) {
    let recording = try canonicalConstantFLAC(in: fixture)
    let firstFrameSize = readUInt24(recording.bytes, at: 15)
    let secondFrameStart = 42 + firstFrameSize
    let shortFrameURL = fixture.file("short-frame.flac")
    let shortSamples = [Float](repeating: 0.25, count: 17)
    _ = try fixture.write(shortSamples, to: shortFrameURL)
    let shortFrameBytes = Array(try SessionFileAccess.read(shortFrameURL, relativeTo: fixture.root))

    var bytes = Array(recording.bytes.prefix(secondFrameStart))
    bytes.append(contentsOf: recording.bytes[secondFrameStart...])
    let thirdFrameStart = bytes.count
    bytes.append(contentsOf: shortFrameBytes.dropFirst(42))
    replaceFixedFrameNumber(2, in: &bytes, frameStart: thirdFrameStart, frameEnd: bytes.count)

    let frameCount = Int64(recording.samples.count + shortSamples.count)
    bytes[8] = 0
    bytes[9] = 17
    bytes[10] = 0x10
    bytes[11] = 0
    for index in 12..<18 { bytes[index] = 0 }
    let totalMask = (UInt64(1) << 36) - 1
    let formatAndTotal = readUInt64(bytes, at: 18)
    writeUInt64((formatAndTotal & ~totalMask) | UInt64(frameCount), to: &bytes, at: 18)
    var digest = FLACMD5()
    digest.update(samples: [Int16](repeating: 8_192, count: Int(frameCount)))
    bytes.replaceSubrange(26..<42, with: digest.finalize())
    return (bytes, frameCount)
}

private func canonicalConstantFLAC(in fixture: PortableFLACTimelineFixture) throws -> (url: URL, samples: [Float], bytes: [UInt8]) {
    let samples = [Float](repeating: 0.25, count: 4_096 + 17)
    let url = try fixture.write(samples)
    let bytes = Array(try SessionFileAccess.read(url, relativeTo: fixture.root))
    return (url, samples, bytes)
}

private func rawSignedPCM16(_ samples: [Float]) -> Data {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(samples.count * 2)
    for sample in samples {
        guard let value = RecordingFLAC.quantize16(sample) else {
            preconditionFailure("参照 FLAC のサンプルは有限値でなければなりません")
        }
        let bits = UInt16(bitPattern: value)
        bytes.append(UInt8(truncatingIfNeeded: bits))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
    }
    return Data(bytes)
}

private func mixedReferenceSamples(count: Int) -> [Float] {
    var state: UInt32 = 0x91e1_0da5
    return (0..<count).map { index in
        state = state &* 1_664_525 &+ 1_013_904_223
        let noise = (Double(Int32(state >> 16) - 32_768) / 32_768) * 0.16
        let sine = 0.62 * sin(2.0 * .pi * 523.25 * Double(index) / 16_000.0)
        return Float(noise + sine)
    }
}

@Suite("portable FLAC timeline")
struct PortableFLACTimelineTests {
    @Test(arguments: portableFLACTimelineLengths, portableFLACTimelineSignals)
    func flacTimelineRoundTripsDeterministicSignals(length: Int, signal: String) throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let samples = portableFLACTimelineSignal(signal, count: length)
        let expected = quantizedTimelineSamples(samples)
        let source = try DeterministicTimelineAudio(samples: samples)
        let url = fixture.file()

        try RecordingFLAC.write(reader: source, to: url, sessionURL: fixture.root)
        let reader = try fixture.reader(at: url, committedFrames: Int64(length))
        try reader.validateAudio()
        try reader.validateAudio(against: source)
        #expect(reader.info.committedFrames == Int64(length))
        let full = try reader.readSamples(frameRange: 0..<Int64(length))
        #expect(full == expected)

        let seed = signal.utf8.reduce(UInt32(length)) { partial, byte in
            partial &* 31 &+ UInt32(byte)
        }
        for range in deterministicRanges(frameCount: length, seed: seed) {
            #expect(try reader.readSamples(frameRange: range) == Array(full[Int(range.lowerBound)..<Int(range.upperBound)]))
        }
        #expect(try reader.readSamples(frameRange: Int64(length)..<Int64(length)) == [])
        #expect(throws: ProcessingTimelineReaderError.invalidFrameRange) {
            try reader.readSamples(frameRange: Int64(length)..<Int64(length + 1))
        }
    }

    @Test(.enabled(if: referenceFLACExecutable != nil, "PATH に flac がありません"))
    func flacTimelineReadsReferenceEncoderFixedAndLPCStreams() throws {
        guard let executable = referenceFLACExecutable else {
            throw PortableFLACProcessFailure(
                arguments: [],
                status: -1,
                output: "PATH に flac がありません。有効化されたテストで実行ファイルを解決できませんでした。"
            )
        }
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let mixedSamples = mixedReferenceSamples(count: 3 * 4_096 + 17)
        let quantizedMixed = mixedSamples.map { sample -> Int16 in
            guard let value = RecordingFLAC.quantize16(sample) else {
                preconditionFailure("このフィクスチャでは有限値のサンプルが必要です")
            }
            return value
        }
        let wastedBitQuantized = quantizedMixed.map { value in (value / 8) * 8 }
        #expect(wastedBitQuantized.allSatisfy { $0.isMultiple(of: 8) })
        #expect(wastedBitQuantized.contains { $0 != 0 })
        let wastedBitSamples = wastedBitQuantized.map { Float($0) / 32_768 }

        let cases: [(name: String, samples: [Float], arguments: [String], laxLargeBlock: Bool)] = [
            ("mixed-fixed", mixedSamples, ["-0"], false),
            ("mixed-lpc", mixedSamples, ["-8"], false),
            ("wasted-bits", wastedBitSamples, ["-8"], false),
            (
                "lax-large-block",
                mixedReferenceSamples(count: 65_535 + 17),
                ["-8", "--lax", "-b", "65535", "-l", "32"],
                true
            ),
        ]

        for testCase in cases {
            let source = try DeterministicTimelineAudio(samples: testCase.samples)
            let expected = quantizedTimelineSamples(testCase.samples)
            let rawURL = fixture.file("\(testCase.name).raw")
            let outputURL = fixture.file("\(testCase.name).flac")
            try SessionFileAccess.writeAtomically(rawSignedPCM16(testCase.samples), to: rawURL, relativeTo: fixture.root)
            try runReferenceFLAC(executable, arguments: [
                "--force-raw-format", "--endian=little", "--sign=signed",
                "--channels=1", "--bps=16", "--sample-rate=16000",
            ] + testCase.arguments + [rawURL.path, "-o", outputURL.path])

            let reader = try fixture.reader(at: outputURL, committedFrames: Int64(testCase.samples.count))
            try reader.validateAudio()
            try reader.validateAudio(against: source)
            #expect(try reader.readSamples(frameRange: 0..<Int64(testCase.samples.count)) == expected)
            let referenceRanges: [Range<Int64>] = [
                4_093..<4_102,
                8_189..<8_198,
                2_337..<2_401,
            ]
            for range in referenceRanges {
                #expect(try reader.readSamples(frameRange: range) == Array(expected[Int(range.lowerBound)..<Int(range.upperBound)]))
            }
            if testCase.laxLargeBlock {
                let range: Range<Int64> = 65_532..<65_540
                #expect(try reader.readSamples(frameRange: range) == Array(expected[Int(range.lowerBound)..<Int(range.upperBound)]))
            }
        }
    }

    @Test func flacTimelineRejectsPayloadMutationWithFrameCRC() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        bytes[49] ^= 1
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))

        #expect(throws: FLACTimelineReaderError.frameCRC(offset: 42)) {
            try reader.validateAudio()
        }
    }

    @Test func flacTimelineRejectsHeaderCRCMutation() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        bytes[47] ^= 1
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))

        #expect(throws: FLACTimelineReaderError.headerCRC(offset: 42)) {
            try reader.validateAudio()
        }
    }

    @Test func flacTimelineRejectsBadSyncAtFrameOffset() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        bytes[43] = 0xf6
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))

        #expect(throws: FLACTimelineReaderError.badSync(offset: 42)) {
            try reader.validateAudio()
        }
    }

    @Test func flacTimelineAcceptsFixedBlocksWithUnequalStreamInfoBounds() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        bytes[8] = 0
        bytes[9] = 17
        bytes[10] = 0x10
        bytes[11] = 0
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))

        #expect(reader.info.committedFrames == 4_113)
        try reader.validateAudio()
        #expect(try reader.readSamples(frameRange: 0..<4_113) == quantizedTimelineSamples(recording.samples))
    }

    @Test func flacTimelineRejectsMalformedIntermediateBlockSizeInValidationAndIndex() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let malformed = try malformedFixedBlockStream(in: fixture)
        let url = fixture.file("malformed-intermediate.flac")
        try SessionFileAccess.writeAtomically(Data(malformed.bytes), to: url, relativeTo: fixture.root)
        let expectedError = FLACTimelineReaderError.decodeFailed(
            frame: 4_096,
            reason: "FLACブロックサイズがSTREAMINFOの固定ブロックサイズと一致しません。"
        )
        let validationReader = try fixture.reader(at: url, committedFrames: malformed.frameCount)
        #expect(throws: expectedError) {
            try validationReader.validateAudio()
        }
        let indexReader = try fixture.reader(at: url, committedFrames: malformed.frameCount)
        #expect(throws: expectedError) {
            try indexReader.readSamples(frameRange: 0..<1)
        }
    }

    @Test func flacTimelineRejectsVariableBlockStrategyAfterValidHeaderCRC() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        bytes[43] = 0xf9
        bytes[47] = FLACChecksum.crc8(Array(bytes[42..<47]))
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))

        #expect(throws: FLACTimelineReaderError.unsupportedVariableBlockSize) {
            try reader.validateAudio()
        }
    }

    @Test func flacTimelineRejectsOneByteTruncatedFooterAtExactOffset() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        let truncated = Array(recording.bytes.dropLast())
        try SessionFileAccess.writeAtomically(Data(truncated), to: recording.url, relativeTo: fixture.root)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))

        #expect(throws: FLACTimelineReaderError.truncated(offset: UInt64(recording.bytes.count - 1))) {
            try reader.validateAudio()
        }
    }

    @Test func flacTimelinePreservesExactTruncationOffsetsInMetadata() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        #expect(Array(recording.bytes.prefix(4)) == Array("fLaC".utf8))
        let url = fixture.file("truncated-metadata.flac")

        for prefixLength in [0, 3, 7, 20] {
            try SessionFileAccess.writeAtomically(
                Data(recording.bytes.prefix(prefixLength)),
                to: url,
                relativeTo: fixture.root
            )
            #expect(throws: FLACTimelineReaderError.truncated(offset: UInt64(prefixLength))) {
                _ = try fixture.reader(at: url, committedFrames: Int64(recording.samples.count))
            }
        }
    }

    @Test func flacTimelineDetectsMissingFramesAfterFirstCompleteFrame() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        let firstFrameLength = readUInt24(recording.bytes, at: 12)
        let firstFrameEnd = 42 + firstFrameLength
        #expect(recording.bytes[firstFrameEnd] == 0xff)
        #expect(recording.bytes[firstFrameEnd + 1] == 0xf8)
        try SessionFileAccess.writeAtomically(
            Data(recording.bytes.prefix(firstFrameEnd)),
            to: recording.url,
            relativeTo: fixture.root
        )
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))

        #expect(throws: FLACTimelineReaderError.decodedFrameCountMismatch(expected: 4_113, decoded: 4_096)) {
            try reader.validateAudio()
        }
    }

    @Test func flacTimelineRejectsStreamInfoFrameCountMutationOnOpen() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        bytes[25] ^= 1
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)

        #expect(throws: FLACTimelineReaderError.lengthMismatch(expected: 4_113, actual: 4_112)) {
            _ = try fixture.reader(at: recording.url, committedFrames: 4_113)
        }
    }

    @Test func flacTimelineAcceptsOpenAndRangeReadBeforeRejectingMD5Mutation() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        bytes[26] ^= 1
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))

        #expect(try reader.readSamples(frameRange: 0..<4) == [0.25, 0.25, 0.25, 0.25])
        #expect(throws: FLACTimelineReaderError.md5Mismatch) {
            try reader.validateAudio()
        }
    }

    @Test func flacTimelineRejectsTrailingGarbageAtItsOffset() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        bytes.append(0x5a)
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))

        #expect(throws: FLACTimelineReaderError.trailingGarbage(offset: UInt64(recording.bytes.count))) {
            try reader.validateAudio()
        }
    }

    @Test func flacTimelineAcceptsEmptyNativeFLACAndRejectsTrailingData() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        var emptyBytes = Array("fLaC".utf8) + [0x80, 0, 0, 34]
        emptyBytes.append(contentsOf: [0x10, 0, 0x10, 0])
        emptyBytes.append(contentsOf: repeatElement(0, count: 6))
        emptyBytes.append(contentsOf: repeatElement(0, count: 8))
        let formatAndZeroFrames = (UInt64(16_000) << 44) | (UInt64(15) << 36)
        writeUInt64(formatAndZeroFrames, to: &emptyBytes, at: 18)
        var emptyDigest = FLACMD5()
        emptyBytes.append(contentsOf: emptyDigest.finalize())
        #expect(emptyBytes.count == 42)

        let emptyURL = fixture.file("empty.flac")
        try SessionFileAccess.writeAtomically(Data(emptyBytes), to: emptyURL, relativeTo: fixture.root)
        do {
            let emptyReader = try fixture.reader(at: emptyURL, committedFrames: 0)
            #expect(emptyReader.info.committedFrames == 0)
            try emptyReader.validateAudio()
        }

        var withTrailingByte = emptyBytes
        withTrailingByte.append(0x5a)
        try SessionFileAccess.writeAtomically(Data(withTrailingByte), to: emptyURL, relativeTo: fixture.root)
        let trailingReader = try fixture.reader(at: emptyURL, committedFrames: 0)
        #expect(throws: FLACTimelineReaderError.trailingGarbage(offset: 42)) {
            try trailingReader.validateAudio()
        }
    }

    @Test func flacTimelineRejectsNoncanonicalSampleRateInStreamInfo() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        writeUInt64(readUInt64(bytes, at: 18) ^ (UInt64(1) << 44), to: &bytes, at: 18)
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)

        #expect(throws: FLACTimelineReaderError.notCanonicalFLAC16) {
            _ = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))
        }
    }

    @Test func flacTimelineRejectsNoncanonicalChannelCountInStreamInfo() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        writeUInt64(readUInt64(bytes, at: 18) ^ (UInt64(1) << 41), to: &bytes, at: 18)
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)

        #expect(throws: FLACTimelineReaderError.notCanonicalFLAC16) {
            _ = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))
        }
    }

    @Test func flacTimelineRejectsNoncanonicalBitDepthInStreamInfo() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        writeUInt64(readUInt64(bytes, at: 18) ^ (UInt64(1) << 36), to: &bytes, at: 18)
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)

        #expect(throws: FLACTimelineReaderError.notCanonicalFLAC16) {
            _ = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))
        }
    }

    @Test func flacTimelineRejectsNonStreamInfoAsFirstMetadataBlock() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        bytes[4] = 0x81
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)

        #expect(throws: FLACTimelineReaderError.invalidStreamInfo) {
            _ = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))
        }
    }

    @Test func flacTimelineRejectsMalformedStreamInfoBlockLength() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        bytes[7] = 33
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)

        #expect(throws: FLACTimelineReaderError.invalidStreamInfo) {
            _ = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))
        }
    }

    @Test func flacTimelineRejectsStreamInfoMinimumBlockSmallerThanSixteen() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        var bytes = recording.bytes
        bytes[8] = 0
        bytes[9] = 15
        try SessionFileAccess.writeAtomically(Data(bytes), to: recording.url, relativeTo: fixture.root)

        #expect(throws: FLACTimelineReaderError.invalidStreamInfo) {
            _ = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))
        }
    }

    @Test func flacTimelineAgainstSourceRejectsSameReader() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))

        #expect(throws: FLACTimelineReaderError.decodeFailed(
            frame: 0,
            reason: "比較元に同じ FLAC 読み取り元は指定できません"
        )) {
            try reader.validateAudio(against: reader)
        }
    }

    @Test func flacTimelineAgainstSourceReportsAbsoluteSampleMismatch() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))
        var wrongSamples = recording.samples
        wrongSamples[4_100] = -0.5
        let source = try DeterministicTimelineAudio(samples: wrongSamples)

        #expect(throws: FLACTimelineReaderError.sampleMismatch(frame: 4_100)) {
            try reader.validateAudio(against: source)
        }
    }

    @Test func flacTimelineAgainstSourceRejectsShortBlockReads() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))
        let source = try DeterministicTimelineAudio(samples: recording.samples, returnsShortRead: true)

        #expect(throws: FLACTimelineReaderError.decodeFailed(
            frame: 0,
            reason: "比較元の読み取り数が一致しません（期待値: 4096、実際: 4095）。"
        )) {
            try reader.validateAudio(against: source)
        }
    }

    @Test func flacTimelineAgainstSourceRejectsNonfiniteSampleAtAbsoluteFrame() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))
        var sourceSamples = recording.samples
        sourceSamples[4_100] = .infinity
        let source = try DeterministicTimelineAudio(samples: sourceSamples)

        #expect(throws: RecordingFLACError.nonFiniteSample(frame: 4_100)) {
            try reader.validateAudio(against: source)
        }
    }

    @Test func flacTimelineAgainstSourceRejectsDifferentFrameCount() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))
        let source = try DeterministicTimelineAudio(
            samples: recording.samples,
            committedFrames: Int64(recording.samples.count - 1)
        )

        #expect(throws: FLACTimelineReaderError.lengthMismatch(expected: 4_113, actual: 4_112)) {
            try reader.validateAudio(against: source)
        }
    }

    @Test func flacTimelineKeepsOpenReaderPinnedAcrossRenameAndPathReplacement() throws {
        let fixture = try PortableFLACTimelineFixture()
        defer { fixture.cleanup() }
        let recording = try canonicalConstantFLAC(in: fixture)
        let reader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))
        let renamedURL = fixture.file("renamed-original.flac")
        try SessionFileAccess.rename(recording.url, to: renamedURL, relativeTo: fixture.root)
        var replacement = recording.bytes
        replacement[49] ^= 1
        try SessionFileAccess.writeAtomically(Data(replacement), to: recording.url, relativeTo: fixture.root)

        try reader.validateAudio()
        #expect(try reader.readSamples(frameRange: 0..<4_113) == quantizedTimelineSamples(recording.samples))
        let replacementReader = try fixture.reader(at: recording.url, committedFrames: Int64(recording.samples.count))
        #expect(throws: FLACTimelineReaderError.frameCRC(offset: 42)) {
            try replacementReader.validateAudio()
        }
    }
}
