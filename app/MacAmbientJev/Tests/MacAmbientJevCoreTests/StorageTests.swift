import Foundation
import Testing
@testable import MacAmbientJevCore


@Test func sessionWriterAssignsMonotonicEventSequence() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try SessionWriter(sessionURL: root)
    let sessionID = UUID()

    let first = try await writer.append(EventDraft(
        eventType: "segment.created", sessionID: sessionID, payload: EmptyPayload()
    ))
    let second = try await writer.append(EventDraft(
        eventType: "asr.pending", sessionID: sessionID, payload: EmptyPayload()
    ))

    #expect(first.eventSeq == 1)
    #expect(second.eventSeq == 2)
}

@Test func recoveryDropsOnlyIncompleteFinalJSONLine() throws {
    let valid1 = #"{"event_seq":1,"event_type":"segment.created","schema_version":3}"# + "\n"
    let valid2 = #"{"event_seq":2,"event_type":"asr.pending","schema_version":3}"# + "\n"
    let broken = #"{"event_seq":3,"event_type":"asr.com"#
    let recovered = try SessionRecovery.recoverJSONL(Data((valid1 + valid2 + broken).utf8))
    #expect(recovered.lines.count == 2)
    #expect(recovered.lastEventSequence == 2)
}

@Test func corruptMiddleLineIsNotSilentlyDropped() throws {
    let input = "{\"event_seq\":1,\"schema_version\":3}\nnot-json\n{\"event_seq\":3,\"schema_version\":3}\n"
    #expect(throws: SessionRecoveryError.self) {
        _ = try SessionRecovery.recoverJSONL(Data(input.utf8))
    }
}

@Test func failedRunCannotReplaceActiveASRRun() throws {
    var runs = ActiveRuns(asr: "asr_run_01")
    runs.markCompleted(stage: .asr, runID: "asr_run_02", succeeded: false)
    #expect(throws: ActiveRunsError.self) {
        try runs.select(stage: .asr, runID: "asr_run_02")
    }
    #expect(runs.asr == "asr_run_01")
}

@Test func successfulRunCanBeSelected() throws {
    var runs = ActiveRuns(asr: "asr_run_01")
    runs.markCompleted(stage: .asr, runID: "asr_run_02", succeeded: true)
    try runs.select(stage: .asr, runID: "asr_run_02")
    #expect(runs.asr == "asr_run_02")
}

@Test func activeRunsCodingPersistsOnlySelectedPointers() throws {
    var runs = ActiveRuns(asr: "asr_run_01")
    runs.markCompleted(stage: .asr, runID: "asr_run_02", succeeded: true)

    let data = try JSONEncoder().encode(runs)
    var restored = try JSONDecoder().decode(ActiveRuns.self, from: data)

    #expect(restored.asr == "asr_run_01")
    #expect(throws: ActiveRunsError.self) {
        try restored.select(stage: .asr, runID: "asr_run_02")
    }
}


@Test
func processingMetadataEncodesTheGenerationAndItsState() throws {
    let metadata = ProcessingMetadata(generationID: UUID(), state: .failed, failureReason: "reason")
    let data = try JSONEncoder().encode(metadata)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["schema_version"] as? Int == EventLogSchema.version)
    #expect(Set(object.keys) == Set(["schema_version", "generation_id", "state", "failure_reason"]))
    #expect(object["state"] as? String == "failed")
    #expect(try JSONDecoder().decode(ProcessingMetadata.self, from: data) == metadata)
}

@Test(arguments: ["generation_id", "state"])
func missingMetadataFieldsAreRejected(key: String) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var object: [String: Any] = [
        "schema_version": EventLogSchema.version,
        "generation_id": UUID().uuidString, "state": "running"
    ]
    object.removeValue(forKey: key)
    let url = SessionLayout(sessionURL: root).processingMetadataURL
    let original = try JSONSerialization.data(withJSONObject: object)
    try original.write(to: url)
    #expect(throws: ProcessingMetadataStoreError.self) { _ = try ProcessingMetadataStore(sessionURL: root).load() }
    #expect(try Data(contentsOf: url) == original)
}

@Test(arguments: [1, 2, 3, nil] as [Int?])
func unsupportedMetadataSchemaCannotBeRead(version: Int?) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var object: [String: Any] = ["generation_id": UUID().uuidString, "state": "running"]
    object["schema_version"] = version
    let url = SessionLayout(sessionURL: root).processingMetadataURL
    let original = try JSONSerialization.data(withJSONObject: object)
    try original.write(to: url)
    #expect(throws: ProcessingMetadataStoreError.unsupportedSchemaVersion) {
        _ = try ProcessingMetadataStore(sessionURL: root).load()
    }
    #expect(try Data(contentsOf: url) == original)
}
