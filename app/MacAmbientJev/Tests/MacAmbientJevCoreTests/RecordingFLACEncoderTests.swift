import Foundation
import Testing
@testable import MacAmbientJevCore

private let flacExecutable: URL? = {
    #if os(Windows)
    let executableName = "flac.exe"
    let pathSeparator: Character = ";"
    #else
    let executableName = "flac"
    let pathSeparator: Character = ":"
    #endif
    guard let searchPath = ProcessInfo.processInfo.environment["PATH"] else { return nil }
    for directory in searchPath.split(separator: pathSeparator, omittingEmptySubsequences: false) {
        let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appending(path: executableName)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
}()

private struct FLACProcessFailure: LocalizedError {
    let arguments: [String]
    let status: Int32
    let output: String

    var errorDescription: String? {
        "flac \(arguments.joined(separator: " ")) が終了コード \(status) で失敗しました: \(output)"
    }
}

private func runFLAC(_ executable: URL, arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw FLACProcessFailure(arguments: arguments, status: process.terminationStatus, output: message)
    }
}

private func deterministicNoise(count: Int) -> [Float] {
    var state: UInt32 = 0x6d2b_79f5
    return (0..<count).map { _ in
        state = state &* 1_664_525 &+ 1_013_904_223
        let sample = Int32(state >> 16) - 32_768
        return Float(sample) / 32_768
    }
}

private final class SyntheticTimelineAudio: TimelineAudioReading, @unchecked Sendable {
    let info: TimelineAudioInfo
    private let samples: [Float]
    private let shortRead: Bool
    private let lock = NSLock()
    private var recordedRequests: [Range<Int64>] = []

    init(samples: [Float], committedFrames: Int64? = nil, shortRead: Bool = false) throws {
        self.samples = samples
        self.shortRead = shortRead
        self.info = try TimelineAudioInfo(
            committedFrames: committedFrames ?? Int64(samples.count), gapEvents: []
        )
    }

    var requests: [Range<Int64>] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        lock.lock()
        recordedRequests.append(frameRange)
        lock.unlock()
        var result = Array(samples[Int(frameRange.lowerBound)..<Int(frameRange.upperBound)])
        if shortRead && !result.isEmpty { result.removeLast() }
        return result
    }

    func validateAudio() throws {}
}

private struct RecordingFLACFixture {
    let root: URL
    let output: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "RecordingFLAC-\(UUID().uuidString)")
        output = root.appending(path: "recording.flac")
        try SessionFileAccess.createDirectory(root, relativeTo: root)
    }

    func cleanup() { try? SessionFileAccess.removeIfPresent(root, relativeTo: root.deletingLastPathComponent()) }
}

@Test func quantizationClipsEndpointsAndRoundsTiesAwayFromZero() {
    #expect(RecordingFLAC.quantize16(-1) == Int16.min)
    #expect(RecordingFLAC.quantize16(1) == Int16.max)
    #expect(RecordingFLAC.quantize16(-4) == Int16.min)
    #expect(RecordingFLAC.quantize16(4) == Int16.max)
    #expect(RecordingFLAC.quantize16(1.0 / 65_536) == 1)
    #expect(RecordingFLAC.quantize16(-1.0 / 65_536) == -1)
    #expect(RecordingFLAC.quantize16(.nan) == nil)
    #expect(RecordingFLAC.quantize16(.infinity) == nil)
    #expect(RecordingFLAC.quantize16(-.infinity) == nil)
}

@Test func writesNativeSingleStreamInfoWithExactFramesMD5AndFrameSizes() throws {
    let fixture = try RecordingFLACFixture()
    defer { fixture.cleanup() }
    let sourceSamples: [Float] = [-1, -0.5, 0, 0.5, 1]
    let reader = try SyntheticTimelineAudio(samples: sourceSamples)

    try RecordingFLAC.write(reader: reader, to: fixture.output, sessionURL: fixture.root)

    let bytes = Array(try SessionFileAccess.read(fixture.output, relativeTo: fixture.root))
    #expect(Array(bytes[0..<4]) == Array("fLaC".utf8))
    #expect(Array(bytes[4..<8]) == [0x80, 0, 0, 34])
    #expect(bytes.count > 42)
    #expect(bytes[42] == 0xff)
    #expect(bytes[43] == 0xf8)
    #expect(bytes[44] == 0x65)
    #expect(bytes[45] == 0x08)

    let streamInfo = Array(bytes[8..<42])
    #expect(readUInt16(streamInfo, at: 0) == 4_096)
    #expect(readUInt16(streamInfo, at: 2) == 4_096)
    let encodedFrameSize = bytes.count - 42
    #expect(readUInt24(streamInfo, at: 4) == encodedFrameSize)
    #expect(readUInt24(streamInfo, at: 7) == encodedFrameSize)
    let formatAndTotal = readUInt64(streamInfo, at: 10)
    #expect((formatAndTotal >> 44) & 0x0f_ffff == 16_000)
    #expect((formatAndTotal >> 41) & 0x07 == 0)
    #expect((formatAndTotal >> 36) & 0x1f == 15)
    #expect(formatAndTotal & ((UInt64(1) << 36) - 1) == UInt64(sourceSamples.count))

    var expectedMD5 = FLACMD5()
    expectedMD5.update(samples: sourceSamples.map { RecordingFLAC.quantize16($0)! })
    #expect(Array(streamInfo[18..<34]) == expectedMD5.finalize())

    let frame = Array(bytes[42...])
    #expect(FLACChecksum.crc8(Array(frame[0..<6])) == frame[6])
    let expectedCRC = FLACChecksum.crc16(Array(frame.dropLast(2)))
    #expect(frame[frame.count - 2] == UInt8(truncatingIfNeeded: expectedCRC >> 8))
    #expect(frame[frame.count - 1] == UInt8(truncatingIfNeeded: expectedCRC))
    #expect(reader.requests == [0..<Int64(sourceSamples.count)])
}

@Test func silenceRoundTripsExactlyAndUsesCompactSubframes() throws {
    let fixture = try RecordingFLACFixture()
    defer { fixture.cleanup() }

    for count in [1, 2, 4_096] {
        let output = fixture.root.appending(path: "silence-\(count).flac")
        let samples = [Float](repeating: 0, count: count)
        let source = try SyntheticTimelineAudio(samples: samples)
        try RecordingFLAC.write(reader: source, to: output, sessionURL: fixture.root)

        let reader = try FLACTimelineReader(url: output, info: source.info, sessionURL: fixture.root)
        try reader.validateAudio()
        try reader.validateAudio(against: source)
        #expect(reader.info.committedFrames == Int64(count))
        #expect(try reader.readSamples(frameRange: 0..<Int64(count)) == samples)

        let bytes = Array(try SessionFileAccess.read(output, relativeTo: fixture.root))
        let subframe = try firstEncoderFrameSubframe(in: output, sessionURL: fixture.root)
        let encodedSubframeBytes = bytes.count - subframe.offset - 2
        #expect(encodedSubframeBytes <= 1 + 2 * count)
        if count > 1 {
            #expect(encodedSubframeBytes < 1 + 2 * count)
        }
        if count == 4_096 {
            #expect(subframe.type == 0)
        }
    }
}

@Test(.enabled(if: flacExecutable != nil, "PATH に flac が見つからないためスキップします"))
func flacCLIValidatesFramesAndRoundTripsPCM() throws {
    guard let executable = flacExecutable else {
        throw FLACProcessFailure(arguments: [], status: -1, output: "有効化されたテストで PATH に flac が見つかりません")
    }
    let fixture = try RecordingFLACFixture()
    defer { fixture.cleanup() }

    let sine = (0..<4_097).map { index in
        Float(0.75 * sin(2.0 * .pi * 440.0 * Double(index) / 16_000.0))
    }
    let orderOneRamp = (0..<5).map { Float(10_000 + $0) / 32_768 }
    let multiBlockTail = deterministicNoise(count: 3 * 4_096 + 17)
    var cases: [(name: String, samples: [Float])] = [
        ("sine", sine),
        ("noise", deterministicNoise(count: 4_097)),
        ("order1-ramp", orderOneRamp),
        ("multi-block-tail", multiBlockTail),
        ("silence", [Float](repeating: 0, count: 4_096)),
    ]
    for count in [1, 4_095, 4_096, 4_097] {
        let samples: [Float] = (0..<count).map { index in index.isMultiple(of: 2) ? -1.5 : 1.5 }
        cases.append(("clipped-\(count)", samples))
    }

    for testCase in cases {
        let flacURL = fixture.root.appending(path: "\(testCase.name).flac")
        let reader = try SyntheticTimelineAudio(samples: testCase.samples)
        try RecordingFLAC.write(reader: reader, to: flacURL, sessionURL: fixture.root)
        try runFLAC(executable, arguments: ["-t", flacURL.path])

        if testCase.name == "order1-ramp" {
            let bytes = Array(try SessionFileAccess.read(flacURL, relativeTo: fixture.root))
            let firstSubframeHeader = bytes[42 + 7]
            #expect((firstSubframeHeader >> 1) & 0x3f == 9)
        }

        guard ["sine", "noise", "order1-ramp", "multi-block-tail"].contains(testCase.name) else {
            continue
        }
        let rawURL = fixture.root.appending(path: "\(testCase.name).pcm")
        try runFLAC(executable, arguments: [
            "-d", "--force-raw-format", "--endian=little", "--sign=signed",
            "--output-name=\(rawURL.path)", flacURL.path,
        ])
        let expectedRaw = testCase.samples.flatMap { sample -> [UInt8] in
            let value = UInt16(bitPattern: RecordingFLAC.quantize16(sample)!)
            return [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
        }
        #expect(try SessionFileAccess.read(rawURL, relativeTo: fixture.root) == Data(expectedRaw))
    }
}

@Test func sourceReadsAreBoundedToFullBlocksAndOneExactFinalBlock() throws {
    let fixture = try RecordingFLACFixture()
    defer { fixture.cleanup() }
    let reader = try SyntheticTimelineAudio(samples: [Float](repeating: 0, count: 8_193))

    try RecordingFLAC.write(reader: reader, to: fixture.output, sessionURL: fixture.root)

    #expect(reader.requests == [0..<4_096, 4_096..<8_192, 8_192..<8_193])
    #expect(reader.requests.allSatisfy { $0.count <= 4_096 })
}

@Test func shortSourceReadFailsWithLengthMismatch() throws {
    let fixture = try RecordingFLACFixture()
    defer { fixture.cleanup() }
    let reader = try SyntheticTimelineAudio(samples: [0.25, 0.5, 0.75, 1], shortRead: true)

    #expect(throws: RecordingFLACError.sourceLengthMismatch(expected: 4, actual: 3)) {
        try RecordingFLAC.write(reader: reader, to: fixture.output, sessionURL: fixture.root)
    }
    #expect(reader.requests == [0..<4])
}

@Test func emptyAndTooLongRecordingsFailBeforeCreatingOutput() throws {
    let fixture = try RecordingFLACFixture()
    defer { fixture.cleanup() }
    let empty = try SyntheticTimelineAudio(samples: [])

    #expect(throws: RecordingFLACError.emptyRecording) {
        try RecordingFLAC.write(reader: empty, to: fixture.output, sessionURL: fixture.root)
    }
    #expect(try SessionFileAccess.isDirectoryIfPresent(fixture.output, relativeTo: fixture.root) == nil)

    let tooLong = try SyntheticTimelineAudio(samples: [], committedFrames: Int64(1) << 36)
    #expect(throws: RecordingFLACError.tooManyFrames) {
        try RecordingFLAC.write(reader: tooLong, to: fixture.output, sessionURL: fixture.root)
    }
    #expect(try SessionFileAccess.isDirectoryIfPresent(fixture.output, relativeTo: fixture.root) == nil)
    #expect(tooLong.requests.isEmpty)
}

@Test func nonFiniteSampleReportsAbsoluteFrame() throws {
    let fixture = try RecordingFLACFixture()
    defer { fixture.cleanup() }
    let samples = [Float](repeating: 0, count: 4_096) + [0.75, .nan]
    let reader = try SyntheticTimelineAudio(samples: samples)

    #expect(throws: RecordingFLACError.nonFiniteSample(frame: 4_097)) {
        try RecordingFLAC.write(reader: reader, to: fixture.output, sessionURL: fixture.root)
    }
}

private func firstEncoderFrameSubframe(in url: URL, sessionURL: URL) throws -> (offset: Int, type: Int) {
    let handle = try SessionFileAccess.openHandle(url, relativeTo: sessionURL)
    defer { try? handle.close() }
    let reader = FLACBitReader(handle: handle)
    try reader.seek(to: 42)

    _ = try reader.read(16)
    let blockSizeCode = Int(try reader.read(4))
    let sampleRateCode = Int(try reader.read(4))
    _ = try reader.read(8)
    _ = try reader.read(8)
    if blockSizeCode == 6 {
        _ = try reader.read(8)
    } else if blockSizeCode == 7 {
        _ = try reader.read(16)
    }
    if sampleRateCode == 12 {
        _ = try reader.read(8)
    } else if sampleRateCode == 13 || sampleRateCode == 14 {
        _ = try reader.read(16)
    }
    _ = try reader.read(8)

    let offset = Int(reader.offset)
    _ = try reader.read(1)
    let type = Int(try reader.read(6))
    return (offset, type)
}

private func readUInt16(_ bytes: [UInt8], at offset: Int) -> Int {
    Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
}

private func readUInt24(_ bytes: [UInt8], at offset: Int) -> Int {
    Int(bytes[offset]) << 16 | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
}

private func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(bytes[offset + $1]) }
}
