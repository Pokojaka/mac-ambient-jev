import Foundation
import MacAmbientJevCAFFixtures
import MacAmbientJevCore
import Testing

@testable import MacAmbientJevDiarizationMeasurement

private struct FakeEngine: DiarizationEngine {
    let spans: [SpeakerSpan]

    var provenance: RunProvenance {
        RunProvenance(engine: "fake", model: nil, version: "1", configuration: ["k": "v"])
    }

    func prepare() async throws {}
    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] { spans }
    func unload() async {}
}

private func workDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationMeasurementTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory.resolvingSymlinksInPath()
}

private func stagedAudio(in directory: URL) throws -> URL {
    let audio = directory.appendingPathComponent("audio.caf")
    try FileManager.default.copyItem(at: CanonicalCAFFixture.cafURL(), to: audio)
    return audio
}

private func arguments(audio: URL, models: URL, output: URL, threads: String? = "2") -> [String] {
    var result = ["--audio", audio.path, "--model-directory", models.path, "--output", output.path]
    if let threads { result += ["--threads", threads] }
    return result
}

private func parse(_ values: [String], requiresThreads: Bool = true) throws -> DiarizationMeasurementArguments {
    try DiarizationMeasurementArguments.parse(values, modelOption: "--model-directory", requiresThreads: requiresThreads)
}

private func parseError(_ values: [String], requiresThreads: Bool = true) -> String? {
    do {
        _ = try parse(values, requiresThreads: requiresThreads)
        return nil
    } catch {
        return error.localizedDescription
    }
}

@Test func parsesAllOptionsOnce() throws {
    let directory = try workDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try stagedAudio(in: directory)
    let output = directory.appendingPathComponent("run.json")
    let parsed = try parse(arguments(audio: audio, models: directory, output: output))
    #expect(parsed.audioURL == audio)
    #expect(parsed.modelDirectory == directory)
    #expect(parsed.threads == 2)
    #expect(parsed.outputURL == output)

    let oracle = try parse(arguments(audio: audio, models: directory, output: output, threads: nil), requiresThreads: false)
    #expect(oracle.threads == nil)
}

@Test func rejectsInvalidArguments() throws {
    let directory = try workDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try stagedAudio(in: directory)
    let output = directory.appendingPathComponent("run.json")
    let valid = arguments(audio: audio, models: directory, output: output)

    #expect(parseError([])?.contains("--audio") == true)
    #expect(parseError(Array(valid.dropLast(2)))?.contains("--threads") == true)
    #expect(parseError(valid + ["--audio", audio.path])?.contains("重複") == true)
    #expect(parseError(valid + ["--working-memory-mib", "512"])?.contains("不明") == true)
    #expect(parseError(valid + ["extra"])?.contains("extra") == true)
    #expect(parseError(arguments(audio: audio, models: directory, output: output, threads: "0"))?.contains("--threads") == true)
    #expect(parseError(arguments(audio: audio, models: directory, output: output, threads: "two"))?.contains("--threads") == true)
    #expect(parseError(["--audio", "--model-directory", directory.path, "--output", output.path, "--threads", "2"])?.contains("--audio") == true)
    #expect(parseError(arguments(audio: directory.appendingPathComponent("missing.caf"), models: directory, output: output)) != nil)
    #expect(parseError(arguments(audio: audio, models: directory.appendingPathComponent("missing"), output: output)) != nil)
    #expect(parseError(arguments(audio: audio, models: audio, output: output)) != nil)
    #expect(parseError(arguments(audio: audio, models: directory, output: directory.appendingPathComponent("no/run.json"))) != nil)
    #expect(parseError(arguments(audio: audio, models: directory, output: audio))?.contains("同じ") == true)
    #expect(parseError(arguments(audio: audio, models: directory, output: directory.appendingPathComponent("audio.caf")))?.contains("同じ") == true)

    try Data("{}".utf8).write(to: output)
    #expect(parseError(valid)?.contains("既に存在") == true)
}

@Test func measuresRawSpansWithAudioIdentity() async throws {
    let directory = try workDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try stagedAudio(in: directory)
    let spans = [
        SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 1_000, confidence: 0.5),
        SpeakerSpan(speakerID: "S2", startFrame: 800, endFrame: 4_800, confidence: nil),
        SpeakerSpan(speakerID: "S1", startFrame: 2_000, endFrame: 3_000, confidence: 1)
    ]
    let run = try await DiarizationMeasurementRun.measure(engine: FakeEngine(spans: spans), audioURL: audio)
    #expect(run.audio.sampleCount == Int64(CanonicalCAFFixture.frameCount))
    #expect(run.audio.sha256 == (try FileSHA256.hexDigest(ofFileAt: audio)))
    #expect(run.rawSpeakerCount == 2)
    #expect(run.rawSpans.count == 3)
    #expect(run.wallTimeSeconds >= 0)
    #expect(run.peakRSSBytes > 0)

    let output = directory.appendingPathComponent("run.json")
    try run.writeNew(to: output)
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
    #expect(Set(object.keys) == [
        "schema_version", "audio", "provenance", "raw_spans", "raw_speaker_count",
        "prepare_seconds", "wall_time_seconds", "peak_rss_bytes"
    ])
    let audioObject = try #require(object["audio"] as? [String: Any])
    #expect(audioObject["sample_count"] as? Int == CanonicalCAFFixture.frameCount)
    let rawSpans = try #require(object["raw_spans"] as? [[String: Any]])
    #expect(rawSpans[0]["speaker_id"] as? String == "S1")
    #expect(rawSpans[1]["start_frame"] as? Int == 800)
}

@Test func writeNewNeverReplaces() async throws {
    let directory = try workDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try stagedAudio(in: directory)
    let run = try await DiarizationMeasurementRun.measure(engine: FakeEngine(spans: []), audioURL: audio)
    let output = directory.appendingPathComponent("run.json")
    try Data("keep".utf8).write(to: output)
    #expect(throws: DiarizationMeasurementError.self) { try run.writeNew(to: output) }
    #expect(try Data(contentsOf: output) == Data("keep".utf8))
}

@Test func rejectsInvalidSpansAndAudio() async throws {
    let directory = try workDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try stagedAudio(in: directory)
    let beyondEnd = [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 4_801, confidence: nil)]
    let empty = [SpeakerSpan(speakerID: "S1", startFrame: 5, endFrame: 5, confidence: nil)]
    let blank = [SpeakerSpan(speakerID: "", startFrame: 0, endFrame: 5, confidence: nil)]
    for spans in [beyondEnd, empty, blank] {
        await #expect(throws: DiarizationMeasurementError.self) {
            _ = try await DiarizationMeasurementRun.measure(engine: FakeEngine(spans: spans), audioURL: audio)
        }
    }

    let notCAF = directory.appendingPathComponent("not.caf")
    try Data("RIFF".utf8).write(to: notCAF)
    await #expect(throws: (any Error).self) {
        _ = try await DiarizationMeasurementRun.measure(engine: FakeEngine(spans: []), audioURL: notCAF)
    }
}
