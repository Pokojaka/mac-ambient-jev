import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func manifestResolvesReferenceFileRelativeToManifest() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root.appending(path: "refs"), withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try "公開鍵暗号\n".write(to: root.appending(path: "refs/sample.txt"), atomically: true, encoding: .utf8)
    let manifestURL = root.appending(path: "manifest.json")
    try Data(#"{"id":"r1","audio":"audio.wav","reference":{"file":"refs/sample.txt"}}"#.utf8)
        .write(to: manifestURL)

    let manifest = try JSONDecoder().decode(ASRSessionManifest.self, from: Data(contentsOf: manifestURL))

    #expect(manifest.reference == .file("refs/sample.txt"))
    #expect(try manifest.referenceText(manifestURL: manifestURL) == "公開鍵暗号\n")
}

@Test
func manifestReadsInlineReferenceText() throws {
    let manifest = try JSONDecoder().decode(
        ASRSessionManifest.self,
        from: Data(#"{"id":"r1","audio":"audio.wav","reference":{"text":"本文"}}"#.utf8)
    )

    #expect(try manifest.referenceText(manifestURL: URL(fileURLWithPath: "/nonexistent/manifest.json")) == "本文")
}

@Test(arguments: [
    #"{"id":"r1","audio":"audio.wav","reference":{"text":"a","file":"b.txt"}}"#,
    #"{"id":"r1","audio":"audio.wav","reference":{}}"#,
    #"{"id":"r1","audio":"audio.wav"}"#
])
func manifestRejectsReferenceWithoutExactlyOneSource(json: String) {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ASRSessionManifest.self, from: Data(json.utf8))
    }
}

@Test
func evaluationScoresJoinedSegmentTextAgainstReference() throws {
    let segments = try JSONDecoder().decode([ASRSessionSegment].self, from: Data("""
    [
      {"segment_id": "seg_000001", "start_ms": 0, "end_ms": 1000, "text": "ABC", "speakers": []},
      {"segment_id": "seg_000002", "start_ms": 1000, "end_ms": 2000, "text": "公開鍵", "speakers": []}
    ]
    """.utf8))

    let report = ASRSessionEvaluator.evaluate(id: "r1", reference: "ＡＢＣ、公開鍵。", segments: segments)

    #expect(report.id == "r1")
    #expect(report.asrEvaluation.raw.rate > 0)
    #expect(report.asrEvaluation.normalized.rate == 0)
}
