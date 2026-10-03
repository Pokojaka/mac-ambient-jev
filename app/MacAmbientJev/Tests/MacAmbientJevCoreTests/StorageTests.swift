import Foundation
import Testing
@testable import MacAmbientJevCore

@Test func unknownScopeAndMissingPriorityRemainRepresentable() {
    let scope: AcousticScope = .unknown
    let priority: ContentPriority? = nil
    #expect(scope == .unknown)
    #expect(priority == nil)
}

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
    let valid1 = #"{"event_seq":1,"event_type":"segment.created"}"# + "\n"
    let valid2 = #"{"event_seq":2,"event_type":"asr.pending"}"# + "\n"
    let broken = #"{"event_seq":3,"event_type":"asr.com"#
    let recovered = try SessionRecovery.recoverJSONL(Data((valid1 + valid2 + broken).utf8))
    #expect(recovered.lines.count == 2)
    #expect(recovered.lastEventSequence == 2)
}

@Test func corruptMiddleLineIsNotSilentlyDropped() throws {
    let input = "{\"event_seq\":1}\nnot-json\n{\"event_seq\":3}\n"
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
func processingMetadataStorePersistsActiveRunsAtomically() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let active = ActiveRuns(
        segmentation: "seg_run_03",
        asr: "asr_run_07"
    )
    let metadata = ProcessingMetadata(
        finalizationAttempt: nil,
        activeRuns: active,
        pendingContentPrioritySegmentIDs: []
    )

    let store = ProcessingMetadataStore(sessionURL: root)
    try store.save(metadata)
    let restored = try store.load()

    #expect(restored?.activeRuns?.segmentation == "seg_run_03")
    #expect(restored?.activeRuns?.asr == "asr_run_07")
}
