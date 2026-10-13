import AVFoundation
import Foundation
import MacAmbientJevAppleSupport
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private struct FixedVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "fixed-vad", model: nil, version: "test", configuration: [:])
    let ranges: [Range<Int64>]

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        ranges.enumerated().map { index, range in
            SegmentReference(
                segmentationRunID: runID, segmentID: String(format: "seg_%06d", index + 1),
                startFrame: range.lowerBound, endFrame: range.upperBound
            )
        }
    }
}

private struct FixedDiarizer: DiarizationEngine {
    let provenance = RunProvenance(engine: "fixed-diarizer", model: nil, version: "test", configuration: [:])
    let spans: [SpeakerSpan]

    func prepare() async throws {}
    func unload() async {}
    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] { spans }
}

private struct Fixture {
    let root: URL
    let paths: AppPaths
    let sessionID: UUID
    let sessionURL: URL
}

private func makeFixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let writer = try DurableAudioWriter(
        directory: sessionURL.appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "processing", directoryHint: .isDirectory),
        chunkDurationSeconds: 1, sessionURL: sessionURL
    )
    try await writer.append(samples: (0..<32_000).map { sin(Float($0) * 0.02) * 0.5 })
    return Fixture(root: root, paths: paths, sessionID: sessionID, sessionURL: sessionURL)
}

private let speakers = [
    SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 8_000, confidence: 0.9),
    SpeakerSpan(speakerID: "S2", startFrame: 8_000, endFrame: 16_000, confidence: 0.9),
]

private func process(
    _ fixture: Fixture, asr: any ASREngine, ranges: [Range<Int64>] = [0..<16_000, 20_000..<32_000]
) async -> SessionProcessingResult {
    await NativeSessionProcessor(
        paths: fixture.paths,
        engines: SessionProcessingEngines(
            asr: asr, diarization: FixedDiarizer(spans: speakers), finalTranscriptVAD: FixedVAD(ranges: ranges)
        ),
        contentPriority: .disabled
    ).processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { false }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
}

private func publishedTexts(_ sessionURL: URL) throws -> [String] {
    guard let metadata = try ProcessingMetadataStore(sessionURL: sessionURL).load(),
          let runs = metadata.activeRuns else { return [] }
    let lines = try SessionRecovery.recoverJSONL(Data(contentsOf: sessionURL.appending(path: "events.jsonl"))).lines
    return try TranscriptMaterializer(sampleRate: 16_000)
        .materialize(events: EventLogTranscriptReader().events(lines: lines, activeRuns: runs), activeRuns: runs)
        .map(\.text)
}

@Test
func exportWritesPlanAndExactClipsThenReplayPublishesTheGivenTexts() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let planDirectory = fixture.root.appending(path: "plan", directoryHint: .isDirectory)
    let exporter = ASRPlanExportEngine(directory: planDirectory)

    let exportResult = await process(fixture, asr: exporter)

    #expect(await exporter.hasExported)
    #expect(exportResult.disposition == .failed)
    #expect(try publishedTexts(fixture.sessionURL) == [])
    let plan = try ASRPlan.load(directory: planDirectory)
    #expect(plan.sampleRate == 16_000)
    #expect(plan.bitDepth == 16)
    #expect(plan.requests.map(\.id) == ["seg_000001_turn_0001", "seg_000001_turn_0002", "seg_000002"])
    #expect(plan.requests.map(\.startSample) == [0, 8_000, 20_000])
    #expect(plan.requests.map(\.endSample) == [8_000, 16_000, 32_000])
    #expect(plan.requests.map { $0.speakers.map(\.speakerID) } == [["S1"], ["S2"], []])
    #expect(plan.requests.allSatisfy { $0.language == "ja" })
    for request in plan.requests {
        let file = try AVAudioFile(forReading: planDirectory.appending(path: request.clipRelativePath))
        #expect(file.length == request.endSample - request.startSample)
        #expect(file.fileFormat.sampleRate == 16_000)
    }

    let texts = fixture.root.appending(path: "texts.jsonl")
    try Data("""
    {"id": "seg_000001_turn_0001", "text": "前半"}
    {"id": "seg_000001_turn_0002", "text": "後半"}
    {"id": "seg_000002", "text": "最後"}

    """.utf8).write(to: texts)
    let replay = try ASRPlanReplayEngine(planDirectory: planDirectory, textsURL: texts)

    let replayResult = await process(fixture, asr: replay)

    #expect(replayResult.disposition == .completed)
    #expect(try publishedTexts(fixture.sessionURL) == ["前半", "後半", "最後"])
}

@Test
func replayRejectsARecomputedPlanThatDiffersFromPlanJSONWithoutPublishing() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let planDirectory = fixture.root.appending(path: "plan", directoryHint: .isDirectory)
    _ = await process(fixture, asr: ASRPlanExportEngine(directory: planDirectory))
    let texts = fixture.root.appending(path: "texts.jsonl")
    try Data("""
    {"id": "seg_000001_turn_0001", "text": "a"}
    {"id": "seg_000001_turn_0002", "text": "b"}
    {"id": "seg_000002", "text": "c"}

    """.utf8).write(to: texts)
    let replay = try ASRPlanReplayEngine(planDirectory: planDirectory, textsURL: texts)

    let result = await process(fixture, asr: replay, ranges: [0..<16_000, 20_000..<31_000])

    #expect(result.disposition == .failed)
    #expect(result.message?.contains("plan.json と一致しません") == true)
    #expect(result.message?.contains("seg_000002 20000..<32000、再計算: seg_000002 20000..<31000") == true)
    #expect(try publishedTexts(fixture.sessionURL) == [])
}

@Test
func replayRejectsMissingAndExtraTextIDsBeforeProcessing() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let planDirectory = fixture.root.appending(path: "plan", directoryHint: .isDirectory)
    _ = await process(fixture, asr: ASRPlanExportEngine(directory: planDirectory))
    let texts = fixture.root.appending(path: "texts.jsonl")

    try Data(#"{"id": "seg_000001_turn_0001", "text": "a"}"#.utf8).write(to: texts)
    #expect(throws: ASRPlanError.missingTextIDs(["seg_000001_turn_0002", "seg_000002"])) {
        try ASRPlanReplayEngine(planDirectory: planDirectory, textsURL: texts)
    }

    try Data("""
    {"id": "seg_000001_turn_0001", "text": "a"}
    {"id": "seg_000001_turn_0002", "text": "b"}
    {"id": "seg_000002", "text": "c"}
    {"id": "seg_000099", "text": "d"}
    """.utf8).write(to: texts)
    #expect(throws: ASRPlanError.extraTextIDs(["seg_000099"])) {
        try ASRPlanReplayEngine(planDirectory: planDirectory, textsURL: texts)
    }
}

@Test
func exportRefusesANonEmptyDirectory() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let planDirectory = fixture.root.appending(path: "plan", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: planDirectory, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: planDirectory.appending(path: "stale"))
    let exporter = ASRPlanExportEngine(directory: planDirectory)

    let result = await process(fixture, asr: exporter)

    #expect(await exporter.hasExported == false)
    #expect(result.message?.contains("空ではありません") == true)
}
