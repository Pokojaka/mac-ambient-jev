import Foundation
import Testing
@testable import MacAmbientJevCore

@Test func recoveryRejectsCorruptNewlineTerminatedFinalLine() throws {
    let input = Data(("{\"event_seq\":1}\nnot-json\n").utf8)
    #expect(throws: SessionRecoveryError.self) {
        _ = try SessionRecovery.recoverJSONL(input)
    }
}

@Test func writerTerminatesValidUnterminatedFinalLineBeforeAppending() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let eventsURL = root.appending(path: "events.jsonl")
    try Data("{\"event_seq\":1,\"event_type\":\"segment.created\"}".utf8).write(to: eventsURL)

    let writer = try SessionWriter(sessionURL: root)
    _ = try await writer.append(EventDraft(
        eventType: "asr.pending", sessionID: UUID(), payload: EmptyPayload()
    ))
    let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: eventsURL))
    #expect(recovered.lines.count == 2)
    #expect(recovered.lastEventSequence == 2)
}

@Test func writersOfTheSameLogDeriveConsecutiveSequences() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try SessionWriter(sessionURL: root)
    let second = try SessionWriter(sessionURL: root)
    let sessionID = UUID()
    let a = try await first.append(EventDraft(
        eventType: "segment.created", sessionID: sessionID, payload: EmptyPayload()
    ))
    let b = try await second.append(EventDraft(
        eventType: "asr.pending", sessionID: sessionID, payload: EmptyPayload()
    ))
    #expect(b.eventSeq == a.eventSeq + 1)
}

@Test func recoveryRejectsNegativeAndOverflowingEventSequences() throws {
    for value in ["-1", "18446744073709551615", "1e30", "1.5", "true"] {
        #expect(throws: SessionRecoveryError.invalidEventSequence(index: 0)) {
            _ = try SessionRecovery.recoverJSONL(Data("{\"event_seq\":\(value)}\n".utf8))
        }
    }
}

@Test func writerDropsTornFinalLineWithoutRewritingEarlierEvents() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let eventsURL = root.appending(path: "events.jsonl")
    let first = "{\"event_seq\":1,\"event_type\":\"segment.created\"}\n"
    try Data((first + "{\"event_seq\":2,\"eve").utf8).write(to: eventsURL)

    let appended = try await SessionWriter(sessionURL: root).append(EventDraft(
        eventType: "asr.pending", sessionID: UUID(), payload: EmptyPayload()
    ))
    let data = try Data(contentsOf: eventsURL)
    #expect(appended.eventSeq == 2)
    #expect(data.starts(with: Data(first.utf8)))
    let recovered = try SessionRecovery.recoverJSONL(data)
    #expect(recovered.lines.count == 2)
}
