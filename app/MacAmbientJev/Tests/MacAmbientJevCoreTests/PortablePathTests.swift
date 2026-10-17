import Foundation
import Testing
@testable import MacAmbientJevCore

@Test(arguments: [
    (#"a<b>c\d|e?f*g"h.wav"#, "a-b-c-d-e-f-g-h"),
    ("lecture. .wav", "lecture--"),
    ("CON.wav", "-CON"),
    ("com1.part.wav", "-com1.part"),
    ("LPT².wav", "-LPT²"),
    ("control\u{1F}name.wav", "control-name"),
])
func sessionFolderNamesSanitizeWindowsUnsafeStems(input: String, expected: String) throws {
    let name = try SessionFolderName.make(
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), sessionID: UUID(),
        source: .imported(originalFilename: input), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    #expect(try SessionFolderName.parse(name).stem == expected)
}

@Test(arguments: [#"x\y"#, "x?y", "x*y", "x|y", "x<y", "x>y", "x\"y", "x\u{1F}y", "tail.", "tail ", "CON", "nul.part", "COM1", "LPT9"])
func sessionFolderNamesRejectWindowsUnsafeStoredStems(stem: String) {
    #expect(throws: SessionFolderNameError.self) {
        _ = try SessionFolderName.parse("2023-11-14_22-13-20_\(stem)_0123abcd")
    }
}

@Test(arguments: [#"..\outside.f32le"#, #"folder\chunk.f32le"#, "chunk:stream", "chunk\0file", "CON", "chunk.", "chunk "])
func audioCheckpointRejectsWindowsPathEscapes(filename: String) {
    let checkpoint = AudioCheckpoint(
        committedFrames: 1, sampleRate: 16_000, channelCount: 1, sampleFormat: .float32LE,
        chunkFiles: [filename], chunkFrameCounts: [1], gapEvents: []
    )
    #expect(!checkpoint.hasPlainUniqueChunkFiles)
}

@Test func manifestReadsAbsoluteReferencePath() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let reference = root.appending(path: "reference.txt")
    try "参照文".write(to: reference, atomically: true, encoding: .utf8)
    let nativePath = reference.withUnsafeFileSystemRepresentation { String(cString: $0!) }
    let manifest = ASRSessionManifest(id: "absolute", audio: "unused.wav", reference: .file(nativePath))
    #expect(try manifest.referenceText(manifestURL: root.appending(path: "nested/manifest.json")) == "参照文")
}

@Test func eventWritersSerializeConcurrentAppends() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try SessionWriter(sessionURL: root)
    let second = try SessionWriter(sessionURL: root)
    let sessionID = UUID()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for writer in [first, second] {
            group.addTask {
                for _ in 0..<20 {
                    try await writer.append(EventDraft(eventType: "test", sessionID: sessionID, payload: "data"))
                }
            }
        }
        try await group.waitForAll()
    }
    let recovered = try SessionRecovery.recoverJSONL(SessionWriter.readDurableLog(eventsURL: root.appending(path: "events.jsonl")))
    #expect(recovered.lines.count == 40)
    #expect(recovered.lastEventSequence == 40)
}
