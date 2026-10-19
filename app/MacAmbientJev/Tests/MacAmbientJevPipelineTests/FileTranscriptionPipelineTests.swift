import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private struct FileSegmentSpec: Sendable {
    let id: String
    let startFrame: Int64
    let endFrame: Int64
}

private actor FileVADCallRecorder {
    private var runIDs: [String] = []

    func record(runID: String) { runIDs.append(runID) }
    func recordedRunIDs() -> [String] { runIDs }
}

private struct FakeFileVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "fake-file-vad", model: nil, version: "test", configuration: [:])
    let segments: [FileSegmentSpec]
    let recorder: FileVADCallRecorder
    let usesUnexpectedRunID: Bool

    init(
        segments: [FileSegmentSpec],
        recorder: FileVADCallRecorder,
        usesUnexpectedRunID: Bool
    ) {
        self.segments = segments
        self.recorder = recorder
        self.usesUnexpectedRunID = usesUnexpectedRunID
    }

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        await recorder.record(runID: runID)
        let referenceRunID = usesUnexpectedRunID ? "unexpected-run" : runID
        return segments.map {
            SegmentReference(
                segmentationRunID: referenceRunID,
                segmentID: $0.id,
                startFrame: $0.startFrame,
                endFrame: $0.endFrame
            )
        }
    }
}

private enum FakeFileASRError: Error {
    case expected
}

private actor FakeFileASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-file-asr", model: nil, version: "test", configuration: [:])

    struct Snapshot: Sendable {
        let prepareCalls: Int
        let inputs: [ASRAudioInput]
    }

    private let texts: [String]
    private let failAtIndex: Int?
    private var prepareCalls = 0
    private var inputs: [ASRAudioInput] = []

    init(texts: [String], failAtIndex: Int?) {
        self.texts = texts
        self.failAtIndex = failAtIndex
    }

    func prepare() async throws {
        prepareCalls += 1
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        let index = inputs.count
        inputs.append(input)
        if failAtIndex == index {
            throw FakeFileASRError.expected
        }
        return ASRResult(text: texts[index], detectedLanguage: "ja")
    }

    func unload() async {}

    func snapshot() -> Snapshot {
        Snapshot(prepareCalls: prepareCalls, inputs: inputs)
    }
}

private enum FakeTimelineAudioError: Error {
    case invalidRange
}

private struct InMemoryTimelineAudio: TimelineAudioReading {
    let info: TimelineAudioInfo
    let samples: [Float]

    init(samples: [Float]) throws {
        self.samples = samples
        self.info = try TimelineAudioInfo(committedFrames: Int64(samples.count), gapEvents: [])
    }

    func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        guard frameRange.lowerBound >= 0,
              frameRange.lowerBound <= frameRange.upperBound,
              frameRange.upperBound <= Int64(samples.count) else {
            throw FakeTimelineAudioError.invalidRange
        }
        return Array(samples[Int(frameRange.lowerBound)..<Int(frameRange.upperBound)])
    }

    func validateAudio() throws {
        guard info.committedFrames == Int64(samples.count), samples.allSatisfy(\.isFinite) else {
            throw FakeTimelineAudioError.invalidRange
        }
    }
}

private func makeFileSessionURL() throws -> URL {
    let sessionURL = FileManager.default.temporaryDirectory
        .appending(path: "file-transcription-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
    return sessionURL
}

private func makeFilePipeline(
    samples: [Float],
    segments: [FileSegmentSpec],
    asr: FakeFileASR,
    vadRecorder: FileVADCallRecorder,
    usesUnexpectedRunID: Bool
) throws -> FileTranscriptionPipeline {
    FileTranscriptionPipeline(
        audio: try InMemoryTimelineAudio(samples: samples),
        asr: asr,
        vadSegmenter: FakeFileVAD(
            segments: segments,
            recorder: vadRecorder,
            usesUnexpectedRunID: usesUnexpectedRunID
        )
    )
}

@Test
func fileTranscriptionPreservesVADOrderAndLoadsOnlyBoundedSamples() async throws {
    let sessionURL = try makeFileSessionURL()
    defer { try? FileManager.default.removeItem(at: sessionURL) }
    let samples = (0..<640).map { Float($0) / 640 }
    let vadRecorder = FileVADCallRecorder()
    let asr = FakeFileASR(texts: ["先の区間", "後の区間"], failAtIndex: nil)
    let pipeline = try makeFilePipeline(
        samples: samples,
        segments: [
            FileSegmentSpec(id: "first", startFrame: 0, endFrame: 320),
            FileSegmentSpec(id: "second", startFrame: 320, endFrame: 640)
        ],
        asr: asr,
        vadRecorder: vadRecorder,
        usesUnexpectedRunID: false
    )

    let result = try await pipeline.process(sessionID: UUID(), sessionURL: sessionURL)

    #expect(result.segments.map(\.reference.segmentID) == ["first", "second"])
    #expect(result.segments.map(\.text) == ["先の区間", "後の区間"])
    #expect(result.segments.map(\.reference.startFrame) == [0, 320])
    #expect(result.segments.map(\.reference.endFrame) == [320, 640])
    let snapshot = await asr.snapshot()
    #expect(snapshot.prepareCalls == 1)
    #expect(snapshot.inputs.map(\.samples) == [Array(samples[0..<320]), Array(samples[320..<640])])
    #expect(snapshot.inputs.allSatisfy { $0.sampleRate == Int(CanonicalAudio.sampleRate) })
    #expect(result.metrics.initialPendingCount == 2)
    #expect(result.metrics.processedAudioSeconds == 0.04)
    #expect(result.segmentationSeconds >= 0)
    #expect(result.asrWallSeconds >= 0)
    let recordedRunIDs = await vadRecorder.recordedRunIDs()
    #expect(recordedRunIDs.count == 1)
    #expect(recordedRunIDs.first?.hasPrefix("seg_file_") == true)
}

@Test
func fileTranscriptionWithNoSpeechDoesNotPrepareOrCallASR() async throws {
    let sessionURL = try makeFileSessionURL()
    defer { try? FileManager.default.removeItem(at: sessionURL) }
    let vadRecorder = FileVADCallRecorder()
    let asr = FakeFileASR(texts: [], failAtIndex: nil)
    let pipeline = try makeFilePipeline(
        samples: Array(repeating: 0.1, count: 640),
        segments: [],
        asr: asr,
        vadRecorder: vadRecorder,
        usesUnexpectedRunID: false
    )

    let result = try await pipeline.process(sessionID: UUID(), sessionURL: sessionURL)

    #expect(result.segments.isEmpty)
    #expect(result.metrics == .zero)
    let snapshot = await asr.snapshot()
    #expect(snapshot.prepareCalls == 0)
    #expect(snapshot.inputs.isEmpty)
}

@Test
func invalidVADReferencesFailBeforeASR() async throws {
    let invalidSegments: [[FileSegmentSpec]] = [
        [FileSegmentSpec(id: "empty", startFrame: 0, endFrame: 0)],
        [FileSegmentSpec(id: "negative", startFrame: -1, endFrame: 10)],
        [FileSegmentSpec(id: "past-end", startFrame: 0, endFrame: 641)],
        [
            FileSegmentSpec(id: "duplicate", startFrame: 0, endFrame: 100),
            FileSegmentSpec(id: "duplicate", startFrame: 100, endFrame: 200)
        ],
        [
            FileSegmentSpec(id: "later", startFrame: 320, endFrame: 640),
            FileSegmentSpec(id: "earlier", startFrame: 0, endFrame: 320)
        ],
        [
            FileSegmentSpec(id: "first", startFrame: 0, endFrame: 400),
            FileSegmentSpec(id: "overlap", startFrame: 300, endFrame: 640)
        ]
    ]

    for segments in invalidSegments {
        let sessionURL = try makeFileSessionURL()
        defer { try? FileManager.default.removeItem(at: sessionURL) }
        let vadRecorder = FileVADCallRecorder()
        let asr = FakeFileASR(texts: [], failAtIndex: nil)
        let pipeline = try makeFilePipeline(
            samples: Array(repeating: 0.1, count: 640),
            segments: segments,
            asr: asr,
            vadRecorder: vadRecorder,
            usesUnexpectedRunID: false
        )

        await #expect(throws: FileTranscriptionPipelineError.self) {
            try await pipeline.process(sessionID: UUID(), sessionURL: sessionURL)
        }
        let snapshot = await asr.snapshot()
        #expect(snapshot.prepareCalls == 0)
        #expect(snapshot.inputs.isEmpty)
    }
}

@Test
func mismatchedVADRunIDFailsBeforeASR() async throws {
    let sessionURL = try makeFileSessionURL()
    defer { try? FileManager.default.removeItem(at: sessionURL) }
    let vadRecorder = FileVADCallRecorder()
    let asr = FakeFileASR(texts: [], failAtIndex: nil)
    let pipeline = try makeFilePipeline(
        samples: Array(repeating: 0.1, count: 640),
        segments: [FileSegmentSpec(id: "segment", startFrame: 0, endFrame: 320)],
        asr: asr,
        vadRecorder: vadRecorder,
        usesUnexpectedRunID: true
    )

    await #expect(throws: FileTranscriptionPipelineError.self) {
        try await pipeline.process(sessionID: UUID(), sessionURL: sessionURL)
    }
    let snapshot = await asr.snapshot()
    #expect(snapshot.prepareCalls == 0)
    #expect(snapshot.inputs.isEmpty)
}

@Test
func ASREngineFailureThrowsInsteadOfReturningPartialFileTranscript() async throws {
    let sessionURL = try makeFileSessionURL()
    defer { try? FileManager.default.removeItem(at: sessionURL) }
    let vadRecorder = FileVADCallRecorder()
    let asr = FakeFileASR(texts: ["先の区間", "失敗する区間"], failAtIndex: 1)
    let pipeline = try makeFilePipeline(
        samples: Array(repeating: 0.1, count: 640),
        segments: [
            FileSegmentSpec(id: "first", startFrame: 0, endFrame: 320),
            FileSegmentSpec(id: "second", startFrame: 320, endFrame: 640)
        ],
        asr: asr,
        vadRecorder: vadRecorder,
        usesUnexpectedRunID: false
    )

    var failure: ASRRunFailure?
    do {
        _ = try await pipeline.process(sessionID: UUID(), sessionURL: sessionURL)
    } catch let error as ASRRunFailure {
        failure = error
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(failure?.failedSegmentCount == 1)
    let snapshot = await asr.snapshot()
    #expect(snapshot.prepareCalls == 1)
    #expect(snapshot.inputs.count == 2)
}
