import Foundation
import MacAmbientJevCAFFixtures
import Testing
@testable import MacAmbientJevCore

private enum ExportReaderFailure: Error, Equatable, Sendable {
    case requestedBlockFailed
}

private enum ExportReaderBehavior: Sendable {
    case normal
    case short(startFrame: Int64, by: Int)
    case long(startFrame: Int64, by: Int)
    case failure(startFrame: Int64, error: ExportReaderFailure)
}

private final class ExportTestReader: TimelineAudioReading, @unchecked Sendable {
    let info: TimelineAudioInfo
    private let samples: [Float]
    private let behavior: ExportReaderBehavior
    private let lock = NSLock()
    private var storedRanges: [Range<Int64>] = []

    init(
        info: TimelineAudioInfo,
        samples: [Float] = [],
        behavior: ExportReaderBehavior = .normal
    ) {
        self.info = info
        self.samples = samples
        self.behavior = behavior
    }

    var requestedRanges: [Range<Int64>] {
        lock.lock()
        defer { lock.unlock() }
        return storedRanges
    }

    func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        lock.lock()
        storedRanges.append(frameRange)
        lock.unlock()

        switch behavior {
        case .normal:
            return samples[Int(frameRange.lowerBound)..<Int(frameRange.upperBound)].map { $0 }
        case .short(let startFrame, let by) where frameRange.lowerBound == startFrame:
            return Array(samples[Int(frameRange.lowerBound)..<Int(frameRange.upperBound)].dropLast(by))
        case .long(let startFrame, let by) where frameRange.lowerBound == startFrame:
            let requested = samples[Int(frameRange.lowerBound)..<Int(frameRange.upperBound)]
            return Array(requested) + [Float](repeating: 0.25, count: by)
        case .failure(let startFrame, let error) where frameRange.lowerBound == startFrame:
            throw error
        default:
            return samples[Int(frameRange.lowerBound)..<Int(frameRange.upperBound)].map { $0 }
        }
    }

    func validateAudio() throws {}
}

private struct ProcessingCAFExporterFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ProcessingCAFExporter-\(UUID().uuidString)")
        try SessionFileAccess.createDirectory(root, relativeTo: root)
    }

    func cleanup() {
        do {
            try SessionFileAccess.removeIfPresent(root, relativeTo: root.deletingLastPathComponent())
        } catch {
            Issue.record("Could not clean exporter test session: \(error)")
        }
    }
}

private func withCAFReader<Result>(
    at url: URL,
    sessionURL: URL,
    perform: (CanonicalCAFReader) throws -> Result
) throws -> Result {
    let reader = try CanonicalCAFReader(url: url, sessionURL: sessionURL)
    return try perform(reader)
}

private func directoryNames(_ url: URL, relativeTo root: URL) throws -> [String] {
    try SessionFileAccess.contentsOfDirectory(url, relativeTo: root)
        .map(\.lastPathComponent)
        .sorted()
}

private func expectExportFailure(
    _ expected: ProcessingTimelineAudioExporterError,
    messageFragments: [String],
    reader: any TimelineAudioReading,
    destination: URL,
    sessionURL: URL
) throws {
    do {
        try ProcessingTimelineAudioExporter(framesPerBuffer: 3)
            .export(reader: reader, to: destination, sessionURL: sessionURL)
        Issue.record("Expected exporter failure \(expected)")
    } catch let error as ProcessingTimelineAudioExporterError {
        #expect(error == expected)
        for fragment in messageFragments {
            #expect(error.errorDescription?.contains(fragment) == true)
        }
    } catch {
        Issue.record("Unexpected exporter failure: \(error)")
    }
}

@Test func processingCAFExporterPreservesFloatBitsAcrossBuffersAndSubranges() throws {
    let fixture = try ProcessingCAFExporterFixture()
    defer { fixture.cleanup() }

    let samples: [Float] = [
        -0.0, 0.0, Float.leastNonzeroMagnitude, -Float.leastNonzeroMagnitude,
        Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude,
        1.5, -2.75, Float(bitPattern: 0x0000_0002), Float(bitPattern: 0x8000_0001),
        0.125, -0.25, 42.0
    ]
    let source = ExportTestReader(
        info: try TimelineAudioInfo(committedFrames: Int64(samples.count), gapEvents: []),
        samples: samples
    )
    let output = fixture.root.appending(path: "roundtrip.caf")
    try ProcessingTimelineAudioExporter(framesPerBuffer: 3)
        .export(reader: source, to: output, sessionURL: fixture.root)

    try withCAFReader(at: output, sessionURL: fixture.root) { cafReader in
        let end = Int64(samples.count)
        let ranges: [Range<Int64>] = [0..<end, 0..<1, 2..<5, 5..<5, 9..<12, end - 1..<end, end..<end]
        for range in ranges {
            let actual = try cafReader.readSamples(frames: range)
            let expected = samples[Int(range.lowerBound)..<Int(range.upperBound)]
            #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern))
        }
    }
    #expect(source.requestedRanges == [0..<3, 3..<6, 6..<9, 9..<12, 12..<13])
}

@Test func processingCAFExporterWritesExactCanonicalHeaderAndLittleEndianPayload() throws {
    let fixture = try ProcessingCAFExporterFixture()
    defer { fixture.cleanup() }

    let samples: [Float] = [1.0, -2.5, 0.125]
    let source = ExportTestReader(
        info: try TimelineAudioInfo(committedFrames: 3, gapEvents: []),
        samples: samples
    )
    let outputURL = fixture.root.appending(path: "layout.caf")
    try ProcessingTimelineAudioExporter(framesPerBuffer: 3)
        .export(reader: source, to: outputURL, sessionURL: fixture.root)
    let output = try SessionFileAccess.read(outputURL, relativeTo: fixture.root)

    let expectedHeader: [UInt8] = [
        0x63, 0x61, 0x66, 0x66, 0x00, 0x01, 0x00, 0x00,
        0x64, 0x65, 0x73, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20,
        0x40, 0xcf, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x6c, 0x70, 0x63, 0x6d, 0x00, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x20,
        0x64, 0x61, 0x74, 0x61, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
        0x00, 0x00, 0x00, 0x00
    ]
    let expectedPayload: [UInt8] = [
        0x00, 0x00, 0x80, 0x3f,
        0x00, 0x00, 0x20, 0xc0,
        0x00, 0x00, 0x00, 0x3e
    ]
    #expect(expectedHeader.count == 68)
    #expect(Array(output.prefix(68)) == expectedHeader)
    #expect(Array(output.suffix(expectedPayload.count)) == expectedPayload)
    #expect(output.count == 68 + 4 * samples.count)
    #expect(Array(output[56..<64]) == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10])
    #expect(Array(output[64..<68]) == [0x00, 0x00, 0x00, 0x00])
    #expect(try directoryNames(fixture.root, relativeTo: fixture.root) == ["layout.caf"])
}

@Test func processingCAFExporterWritesAHeaderOnlyEmptyCAFWithoutReading() throws {
    let fixture = try ProcessingCAFExporterFixture()
    defer { fixture.cleanup() }

    let source = ExportTestReader(info: try TimelineAudioInfo(committedFrames: 0, gapEvents: []))
    let outputURL = fixture.root.appending(path: "empty.caf")
    try ProcessingTimelineAudioExporter(framesPerBuffer: 3)
        .export(reader: source, to: outputURL, sessionURL: fixture.root)
    let output = try SessionFileAccess.read(outputURL, relativeTo: fixture.root)

    #expect(output.count == 68)
    #expect(source.requestedRanges.isEmpty)
    try withCAFReader(at: outputURL, sessionURL: fixture.root) { reader in
        #expect(reader.sampleCount == 0)
        let emptySamples = try reader.readSamples(frames: 0..<0)
        #expect(emptySamples.isEmpty)
    }
}

@Test(arguments: [1, 1_000, 48_000])
func processingCAFExporterMatchesTheCommittedMacFixtureAtEveryBufferSize(_ framesPerBuffer: Int) throws {
    let fixture = try ProcessingCAFExporterFixture()
    defer { fixture.cleanup() }

    let sourceCAF = try CanonicalCAFFixture.cafURL()
    let copiedCAF = fixture.root.appending(path: "canonical-input.caf")
    try SessionFileAccess.copy(
        sourceCAF,
        relativeTo: sourceCAF.deletingLastPathComponent(),
        to: copiedCAF,
        relativeTo: fixture.root
    )
    let expectedSamples = try CanonicalCAFFixture.expectedSamples()
    let expectedSampleBytes = try Data(contentsOf: CanonicalCAFFixture.expectedSamplesURL())
    let source = ExportTestReader(
        info: try TimelineAudioInfo(committedFrames: Int64(expectedSamples.count), gapEvents: []),
        samples: expectedSamples
    )
    let outputURL = fixture.root.appending(path: "exported.caf")
    try ProcessingTimelineAudioExporter(framesPerBuffer: Int64(framesPerBuffer))
        .export(reader: source, to: outputURL, sessionURL: fixture.root)

    let sourceBytes = try SessionFileAccess.read(copiedCAF, relativeTo: fixture.root)
    let outputBytes = try SessionFileAccess.read(outputURL, relativeTo: fixture.root)
    #expect(expectedSamples.count == CanonicalCAFFixture.frameCount)
    #expect(sourceBytes.count == 23_296)
    #expect(outputBytes.count == 19_268)
    #expect(expectedSampleBytes.count == 19_200)
    #expect(Array(outputBytes.dropFirst(68)) == Array(expectedSampleBytes))

    try withCAFReader(at: copiedCAF, sessionURL: fixture.root) { committedReader in
        try withCAFReader(at: outputURL, sessionURL: fixture.root) { exportedReader in
            #expect(committedReader.sampleCount == Int64(expectedSamples.count))
            #expect(exportedReader.sampleCount == Int64(expectedSamples.count))
            let fullRange = 0..<Int64(expectedSamples.count)
            let committedBits = try committedReader.readSamples(frames: fullRange).map(\.bitPattern)
            let exportedBits = try exportedReader.readSamples(frames: fullRange).map(\.bitPattern)
            #expect(committedBits == expectedSamples.map(\.bitPattern))
            #expect(exportedBits == committedBits)
        }
    }
}

@Test func processingCAFExporterRejectsAShortReadOnALaterBlockAndPreservesDestination() throws {
    let fixture = try ProcessingCAFExporterFixture()
    defer { fixture.cleanup() }

    let outputURL = fixture.root.appending(path: "existing.caf")
    let sentinel = Data([0x53, 0x45, 0x4e, 0x54, 0x49, 0x4e, 0x45, 0x4c])
    try SessionFileAccess.writeAtomically(sentinel, to: outputURL, relativeTo: fixture.root)
    let source = ExportTestReader(
        info: try TimelineAudioInfo(committedFrames: 7, gapEvents: []),
        samples: [0, 1, 2, 3, 4, 5, 6],
        behavior: .short(startFrame: 3, by: 1)
    )

    try expectExportFailure(
        .sourceLengthMismatch(startFrame: 3, expected: 3, actual: 2),
        messageFragments: ["開始フレーム: 3", "期待: 3", "実際: 2"],
        reader: source,
        destination: outputURL,
        sessionURL: fixture.root
    )
    #expect(try SessionFileAccess.read(outputURL, relativeTo: fixture.root) == sentinel)
    #expect(try directoryNames(fixture.root, relativeTo: fixture.root) == ["existing.caf"])
}

@Test func processingCAFExporterRejectsALongReadOnALaterBlockAndPreservesDestination() throws {
    let fixture = try ProcessingCAFExporterFixture()
    defer { fixture.cleanup() }

    let outputURL = fixture.root.appending(path: "existing.caf")
    let sentinel = Data([0x53, 0x45, 0x4e, 0x54, 0x49, 0x4e, 0x45, 0x4c])
    try SessionFileAccess.writeAtomically(sentinel, to: outputURL, relativeTo: fixture.root)
    let source = ExportTestReader(
        info: try TimelineAudioInfo(committedFrames: 7, gapEvents: []),
        samples: [0, 1, 2, 3, 4, 5, 6],
        behavior: .long(startFrame: 3, by: 1)
    )

    try expectExportFailure(
        .sourceLengthMismatch(startFrame: 3, expected: 3, actual: 4),
        messageFragments: ["開始フレーム: 3", "期待: 3", "実際: 4"],
        reader: source,
        destination: outputURL,
        sessionURL: fixture.root
    )
    #expect(try SessionFileAccess.read(outputURL, relativeTo: fixture.root) == sentinel)
    #expect(try directoryNames(fixture.root, relativeTo: fixture.root) == ["existing.caf"])
}

@Test(arguments: [Float.nan, Float.infinity, -Float.infinity])
func processingCAFExporterRejectsNonFiniteSamplesOnALaterBlockAndPreservesDestination(_ invalidSample: Float) throws {
    let fixture = try ProcessingCAFExporterFixture()
    defer { fixture.cleanup() }

    let outputURL = fixture.root.appending(path: "existing.caf")
    let sentinel = Data([0x53, 0x45, 0x4e, 0x54, 0x49, 0x4e, 0x45, 0x4c])
    try SessionFileAccess.writeAtomically(sentinel, to: outputURL, relativeTo: fixture.root)
    let source = ExportTestReader(
        info: try TimelineAudioInfo(committedFrames: 6, gapEvents: []),
        samples: [0, 1, 2, 3, invalidSample, 5]
    )

    try expectExportFailure(
        .nonFiniteSample(frame: 4),
        messageFragments: ["フレーム: 4"],
        reader: source,
        destination: outputURL,
        sessionURL: fixture.root
    )
    #expect(try SessionFileAccess.read(outputURL, relativeTo: fixture.root) == sentinel)
    #expect(try directoryNames(fixture.root, relativeTo: fixture.root) == ["existing.caf"])
}

@Test func processingCAFExporterPropagatesAReaderErrorAndPreservesDestination() throws {
    let fixture = try ProcessingCAFExporterFixture()
    defer { fixture.cleanup() }

    let outputURL = fixture.root.appending(path: "existing.caf")
    let sentinel = Data([0x53, 0x45, 0x4e, 0x54, 0x49, 0x4e, 0x45, 0x4c])
    try SessionFileAccess.writeAtomically(sentinel, to: outputURL, relativeTo: fixture.root)
    let source = ExportTestReader(
        info: try TimelineAudioInfo(committedFrames: 7, gapEvents: []),
        samples: [0, 1, 2, 3, 4, 5, 6],
        behavior: .failure(startFrame: 3, error: .requestedBlockFailed)
    )

    do {
        try ProcessingTimelineAudioExporter(framesPerBuffer: 3)
            .export(reader: source, to: outputURL, sessionURL: fixture.root)
        Issue.record("Expected the reader error to propagate")
    } catch let error as ExportReaderFailure {
        #expect(error == .requestedBlockFailed)
    } catch {
        Issue.record("Unexpected exporter failure: \(error)")
    }
    #expect(try SessionFileAccess.read(outputURL, relativeTo: fixture.root) == sentinel)
    #expect(try directoryNames(fixture.root, relativeTo: fixture.root) == ["existing.caf"])
}

@Test func processingCAFExporterRejectsTooManyFramesBeforeCreatingDestinationParent() throws {
    let fixture = try ProcessingCAFExporterFixture()
    defer { fixture.cleanup() }

    let source = ExportTestReader(
        info: try TimelineAudioInfo(committedFrames: Int64.max, gapEvents: [])
    )
    let outputURL = fixture.root.appending(path: "not-created").appending(path: "output.caf")
    #expect(throws: ProcessingTimelineAudioExporterError.tooManyFrames) {
        try ProcessingTimelineAudioExporter(framesPerBuffer: 3)
            .export(reader: source, to: outputURL, sessionURL: fixture.root)
    }
    #expect(source.requestedRanges.isEmpty)
    #expect(try directoryNames(fixture.root, relativeTo: fixture.root).isEmpty)
}

@Test func processingCAFExporterAtomicallyReplacesAnExistingDestination() throws {
    let fixture = try ProcessingCAFExporterFixture()
    defer { fixture.cleanup() }

    let outputURL = fixture.root.appending(path: "published.caf")
    try SessionFileAccess.writeAtomically(Data([0x6f, 0x6c, 0x64]), to: outputURL, relativeTo: fixture.root)
    let samples: [Float] = [-0.0, 1.25]
    let source = ExportTestReader(
        info: try TimelineAudioInfo(committedFrames: Int64(samples.count), gapEvents: []),
        samples: samples
    )
    try ProcessingTimelineAudioExporter(framesPerBuffer: 1)
        .export(reader: source, to: outputURL, sessionURL: fixture.root)

    #expect(try directoryNames(fixture.root, relativeTo: fixture.root) == ["published.caf"])
    try withCAFReader(at: outputURL, sessionURL: fixture.root) { reader in
        #expect(reader.sampleCount == 2)
        let actualSamples = try reader.readSamples(frames: 0..<2)
        #expect(actualSamples.map(\.bitPattern) == samples.map(\.bitPattern))
    }
}

@Test func processingCAFExporterDoesNotPublishOutputForATruncatedProcessingChunk() throws {
    let fixture = try ProcessingCAFExporterFixture()
    defer { fixture.cleanup() }

    let processingDirectory = fixture.root.appending(path: "processing")
    try SessionFileAccess.createDirectory(processingDirectory, relativeTo: fixture.root)
    let chunkName = "chunk-000000.f32le"
    let truncatedSamples: [Float] = [0.25, -0.5, 0.75]
    var chunkData = Data()
    for sample in truncatedSamples {
        var encoded = sample.bitPattern.littleEndian
        withUnsafeBytes(of: &encoded) { chunkData.append(contentsOf: $0) }
    }
    try SessionFileAccess.writeAtomically(
        chunkData,
        to: processingDirectory.appending(path: chunkName),
        relativeTo: fixture.root
    )
    let checkpoint = AudioCheckpoint(
        committedFrames: 4,
        sampleRate: CanonicalAudio.sampleRate,
        channelCount: CanonicalAudio.channelCount,
        sampleFormat: CanonicalAudio.sampleFormat,
        chunkFiles: [chunkName],
        chunkFrameCounts: [4],
        gapEvents: []
    )
    let source = try ProcessingTimelineReader(
        directory: processingDirectory,
        checkpoint: checkpoint,
        sessionURL: fixture.root
    )
    let outputURL = fixture.root.appending(path: "must-not-publish.caf")

    #expect(throws: ProcessingTimelineReaderError.corruptChunk(chunkName)) {
        try ProcessingTimelineAudioExporter(framesPerBuffer: 3)
            .export(reader: source, to: outputURL, sessionURL: fixture.root)
    }
    #expect(try SessionFileAccess.readIfPresent(outputURL, relativeTo: fixture.root) == nil)
    #expect(try directoryNames(fixture.root, relativeTo: fixture.root) == ["processing"])
    #expect(try directoryNames(processingDirectory, relativeTo: fixture.root) == [chunkName])
}

@Test func processingCAFExporterRejectsDestinationOutsideSessionAndPreservesSentinel() throws {
    let fixture = try ProcessingCAFExporterFixture()
    defer { fixture.cleanup() }

    let outsideRoot = fixture.root.deletingLastPathComponent()
        .appending(path: "ProcessingCAFExporterOutside-\(UUID().uuidString)")
    try SessionFileAccess.createDirectory(outsideRoot, relativeTo: outsideRoot)
    defer {
        do {
            try SessionFileAccess.removeIfPresent(outsideRoot, relativeTo: outsideRoot.deletingLastPathComponent())
        } catch {
            Issue.record("Could not clean outside exporter fixture: \(error)")
        }
    }
    let outsideDestination = outsideRoot.appending(path: "sentinel.caf")
    let sentinel = Data([0x4f, 0x55, 0x54, 0x53, 0x49, 0x44, 0x45])
    try SessionFileAccess.writeAtomically(sentinel, to: outsideDestination, relativeTo: outsideRoot)
    let source = ExportTestReader(
        info: try TimelineAudioInfo(committedFrames: 1, gapEvents: []),
        samples: [0.5]
    )

    #expect(throws: CocoaError.self) {
        try ProcessingTimelineAudioExporter(framesPerBuffer: 1)
            .export(reader: source, to: outsideDestination, sessionURL: fixture.root)
    }
    #expect(try SessionFileAccess.read(outsideDestination, relativeTo: outsideRoot) == sentinel)
    #expect(try directoryNames(outsideRoot, relativeTo: outsideRoot) == ["sentinel.caf"])
    #expect(try directoryNames(fixture.root, relativeTo: fixture.root).isEmpty)
}

@Test func processingCAFExporterRemovesTemporaryFileWhenFailureHasNoDestination() throws {
    let fixture = try ProcessingCAFExporterFixture()
    defer { fixture.cleanup() }

    let outputURL = fixture.root.appending(path: "absent.caf")
    let source = ExportTestReader(
        info: try TimelineAudioInfo(committedFrames: 4, gapEvents: []),
        samples: [1, 2, .infinity, 4]
    )

    try expectExportFailure(
        .nonFiniteSample(frame: 2),
        messageFragments: ["フレーム: 2"],
        reader: source,
        destination: outputURL,
        sessionURL: fixture.root
    )
    #expect(try SessionFileAccess.readIfPresent(outputURL, relativeTo: fixture.root) == nil)
    #expect(try directoryNames(fixture.root, relativeTo: fixture.root).isEmpty)
}
