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
func processingMetadataEncodesThePublishedStageContract() throws {
    let metadata = ProcessingMetadata(
        finalizationAttempt: FinalizationAttempt(attemptID: "final", state: .complete, failureReason: nil),
        activeRuns: ActiveRuns(
            segmentation: "seg", asr: "asr", diarization: "diar",
            clauseBoundary: "boundary", contentPriority: "priority"
        ),
        pendingClauseBoundarySegments: [],
        pendingContentPriorityClauses: []
    )
    let data = try JSONEncoder().encode(metadata)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["schema_version"] as? Int == 3)
    #expect(Set(object.keys) == Set([
        "schema_version", "finalization_attempt", "active_runs",
        "pending_clause_boundary_segments", "pending_content_priority_clauses"
    ]))
    let runs = try #require(object["active_runs"] as? [String: String])
    #expect(runs == [
        "segmentation": "seg", "asr": "asr", "diarization": "diar",
        "clause_boundary": "boundary", "content_priority": "priority"
    ])
    #expect(try JSONDecoder().decode(ProcessingMetadata.self, from: data) == metadata)
}

@Test(arguments: ["pending_clause_boundary_segments", "pending_content_priority_clauses"])
func missingClauseMetadataArraysAreRejectedBeforeReadingOrAppending(key: String) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var object: [String: Any] = [
        "schema_version": EventLogSchema.version,
        "finalization_attempt": NSNull(), "active_runs": NSNull(),
        "pending_clause_boundary_segments": [], "pending_content_priority_clauses": []
    ]
    object.removeValue(forKey: key)
    let store = ProcessingMetadataStore(sessionURL: root)
    let original = try JSONSerialization.data(withJSONObject: object)
    try original.write(to: store.url)
    #expect(throws: ProcessingMetadataStoreError.self) { _ = try store.load() }
    #expect(throws: ProcessingMetadataStoreError.self) { _ = try SessionWriter(sessionURL: root) }
    #expect(try Data(contentsOf: store.url) == original)
}

@Test(arguments: [1, 2, 4, nil] as [Int?])
func unsupportedMetadataSchemaCannotBeReadAppendedOrReplaced(version: Int?) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var object: [String: Any] = [
        "finalization_attempt": NSNull(), "active_runs": NSNull(),
        "pending_clause_boundary_segments": [], "pending_content_priority_clauses": []
    ]
    object["schema_version"] = version
    let store = ProcessingMetadataStore(sessionURL: root)
    let original = try JSONSerialization.data(withJSONObject: object)
    try original.write(to: store.url)
    #expect(throws: ProcessingMetadataStoreError.unsupportedSchemaVersion) { _ = try store.load() }
    #expect(throws: ProcessingMetadataStoreError.unsupportedSchemaVersion) {
        _ = try SessionWriter(sessionURL: root)
    }
    for policy in [UnreadableMetadataPolicy.reject, .replace] {
        #expect(throws: ProcessingMetadataStoreError.unsupportedSchemaVersion) {
            try store.beginFinalization(attemptID: "new", policy: policy)
        }
    }
    #expect(try Data(contentsOf: store.url) == original)
}

@Test(arguments: ["duplicate", "wrongASR", "wrongBoundary", "orphanPriority"])
func metadataRejectsInvalidAtomicSnapshotAndLeavesPublishedBytesIntact(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = try SegmentTextReference(segmentationRunID: "seg", segmentID: "s", asrRunID: "asr", asrEventSeq: 2)
    let store = ProcessingMetadataStore(sessionURL: root)
    let active = ActiveRuns(segmentation: "seg", asr: "asr")
    try store.save(ProcessingMetadata(
        finalizationAttempt: FinalizationAttempt(attemptID: "a", state: .complete, failureReason: nil),
        activeRuns: active, pendingClauseBoundarySegments: [source], pendingContentPriorityClauses: []
    ))
    let original = try Data(contentsOf: store.url)
    var invalid = try #require(try store.load())
    switch kind {
    case "duplicate": invalid.pendingClauseBoundarySegments = [source, source]
    case "wrongASR":
        invalid.pendingClauseBoundarySegments = [
            try SegmentTextReference(segmentationRunID: "seg", segmentID: "s", asrRunID: "other", asrEventSeq: 2)
        ]
    case "wrongBoundary":
        invalid.activeRuns = active.withDecisionRuns(clauseBoundary: "boundary", contentPriority: "priority")
        invalid.pendingContentPriorityClauses = [try ClauseReference(boundaryRunID: "other", clauseID: "c2_0")]
    default:
        invalid.activeRuns = active.withDecisionRuns(clauseBoundary: nil, contentPriority: "priority")
    }
    #expect(throws: ProcessingMetadataStoreError.self) { try store.save(invalid) }
    #expect(try Data(contentsOf: store.url) == original)
}

@Test
func staleDecisionPublicationCannotOverwriteNewLocalRunsOrPendingSources() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let old = ActiveRuns(segmentation: "oldSeg", asr: "oldASR")
    let current = ActiveRuns(segmentation: "newSeg", asr: "newASR")
    let source = try SegmentTextReference(segmentationRunID: "newSeg", segmentID: "s", asrRunID: "newASR", asrEventSeq: 8)
    let store = ProcessingMetadataStore(sessionURL: root)
    try store.save(ProcessingMetadata(
        finalizationAttempt: FinalizationAttempt(attemptID: "new", state: .complete, failureReason: nil),
        activeRuns: current, pendingClauseBoundarySegments: [source], pendingContentPriorityClauses: []
    ))
    let original = try Data(contentsOf: store.url)
    #expect(throws: ProcessingMetadataStoreError.publishedRunsChanged) {
        try store.publishDecisionSnapshot(basedOn: old, clauseBoundaryRunID: "staleBoundary", contentPriorityRunID: "stalePriority",
                                     pendingClauseBoundarySegments: [], pendingContentPriorityClauses: [])
    }
    #expect(try Data(contentsOf: store.url) == original)
}
