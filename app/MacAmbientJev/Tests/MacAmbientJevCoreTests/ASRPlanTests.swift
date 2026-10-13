import Foundation
import Testing
@testable import MacAmbientJevCore

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func samplePlan(secondEnd: Int64 = 40_000) -> ASRPlan {
    ASRPlan(
        segments: [
            SegmentReference(segmentationRunID: "seg", segmentID: "seg_000001", startFrame: 100, endFrame: 20_000),
            SegmentReference(segmentationRunID: "seg", segmentID: "seg_000002", startFrame: 20_000, endFrame: secondEnd),
            SegmentReference(segmentationRunID: "seg", segmentID: "seg_000003", startFrame: 50_000, endFrame: 50_319),
        ],
        speakerSpans: [
            SpeakerSpan(speakerID: "SPEAKER_00", startFrame: 0, endFrame: 25_000, confidence: 0.9),
            SpeakerSpan(speakerID: "SPEAKER_01", startFrame: 24_000, endFrame: 60_000, confidence: nil),
        ],
        sampleRate: 16_000,
        bitDepth: 16,
        language: "ja"
    )
}

private func writeTexts(_ lines: [String], to directory: URL) throws -> URL {
    let url = directory.appending(path: "texts.jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    return url
}

@Test
func asrPlanRoundTripsThroughPlanJSONWithSnakeCaseKeys() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let plan = samplePlan()

    try plan.write(directory: directory)

    #expect(try ASRPlan.load(directory: directory) == plan)
    let object = try #require(try JSONSerialization.jsonObject(
        with: Data(contentsOf: directory.appending(path: "plan.json"))
    ) as? [String: Any])
    #expect(object["sample_rate"] as? Int == 16_000)
    #expect(object["bit_depth"] as? Int == 16)
    let requests = try #require(object["requests"] as? [[String: Any]])
    #expect(requests.map { $0["id"] as? String } == ["seg_000001", "seg_000002"])
    #expect(requests[1]["start_sample"] as? Int == 20_000)
    #expect(requests[1]["end_sample"] as? Int == 40_000)
    #expect(requests[1]["language"] as? String == "ja")
    let speakers = try #require(requests[1]["speakers"] as? [[String: Any]])
    #expect(speakers.map { $0["speaker_id"] as? String } == ["SPEAKER_00", "SPEAKER_01"])
    #expect(speakers.map { $0["start_sample"] as? Int } == [20_000, 24_000])
    #expect(speakers.map { $0["end_sample"] as? Int } == [25_000, 40_000])
}

@Test
func asrPlanOmitsRequestsShorterThanTheASRMinimum() {
    #expect(samplePlan().requests.map(\.id) == ["seg_000001", "seg_000002"])
}

@Test
func asrPlanMismatchNamesTheFirstDifferingRequest() throws {
    let stored = samplePlan()

    #expect(throws: Never.self) { try stored.requireEqual(to: samplePlan()) }
    do {
        try stored.requireEqual(to: samplePlan(secondEnd: 39_999))
        Issue.record("a changed sample range must be rejected")
    } catch let error as ASRPlanError {
        #expect(error == .planMismatch("2 番目が違います（plan.json: seg_000002 20000..<40000、再計算: seg_000002 20000..<39999）"))
        #expect(error.errorDescription?.contains("plan.json") == true)
    }
}

@Test
func asrPlanMismatchReportsADifferentRequestCount() throws {
    let stored = samplePlan()
    let fewer = ASRPlan(
        segments: [SegmentReference(segmentationRunID: "seg", segmentID: "seg_000001", startFrame: 100, endFrame: 20_000)],
        speakerSpans: [], sampleRate: 16_000, bitDepth: 16, language: "ja"
    )

    #expect(throws: ASRPlanError.planMismatch("リクエスト数が違います（plan.json: 2、再計算: 1）")) {
        try stored.requireEqual(to: fewer)
    }
}

@Test
func asrTextsMustCoverExactlyThePlanIDs() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let plan = samplePlan()

    let complete = try ASRTexts(contentsOf: writeTexts([
        #"{"id": "seg_000001", "text": "一つ目"}"#, #"{"id": "seg_000002", "text": ""}"#,
    ], to: directory))
    try complete.requireIDs(of: plan)
    #expect(complete.textByID == ["seg_000001": "一つ目", "seg_000002": ""])

    let missing = try ASRTexts(contentsOf: writeTexts([#"{"id": "seg_000001", "text": "a"}"#], to: directory))
    #expect(throws: ASRPlanError.missingTextIDs(["seg_000002"])) { try missing.requireIDs(of: plan) }

    let extra = try ASRTexts(contentsOf: writeTexts([
        #"{"id": "seg_000001", "text": "a"}"#, #"{"id": "seg_000002", "text": "b"}"#, #"{"id": "seg_000009", "text": "c"}"#,
    ], to: directory))
    #expect(throws: ASRPlanError.extraTextIDs(["seg_000009"])) { try extra.requireIDs(of: plan) }
}

@Test
func asrTextsRejectDuplicateIDsAndMalformedLines() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let duplicate = try writeTexts([#"{"id": "a", "text": "x"}"#, #"{"id": "a", "text": "y"}"#], to: directory)
    #expect(throws: ASRPlanError.duplicateTextID("a")) { try ASRTexts(contentsOf: duplicate) }

    let malformed = try writeTexts([#"{"id": "a", "text": "x"}"#, #"{"id": "b"}"#], to: directory)
    #expect(throws: ASRPlanError.invalidTextLine(line: 2)) { try ASRTexts(contentsOf: malformed) }

    let blank = try writeTexts([#"{"id": "a", "text": "x"}"#, ""], to: directory)
    #expect(throws: ASRPlanError.invalidTextLine(line: 2)) { try ASRTexts(contentsOf: blank) }
}
