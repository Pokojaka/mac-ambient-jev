import Foundation
import Testing
@testable import MacAmbientJevCore

private func finalizationMetadata(
    activeRuns: ActiveRuns? = nil,
    attempt: FinalizationAttempt? = nil
) -> ProcessingMetadata {
    ProcessingMetadata(
        timelineVersion: 1,
        vadVersion: "vad",
        vadConfigHash: "hash",
        asrEngine: "qwen",
        asrModel: "model",
        asrVersion: "version",
        diarizationVersion: "diarization",
        sceneAnalyzerVersion: 1,
        jevSchemaVersion: 1,
        policyVersion: 1,
        materializerSchemaVersion: 1,
        activeRuns: activeRuns,
        finalizationAttempt: attempt
    )
}

private func writeFinalizationSession(
    id: UUID,
    at root: URL,
    metadata: ProcessingMetadata
) throws -> URL {
    let sessionURL = root.appending(path: id.uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
    let manifest = SessionManifest(
        sessionID: id,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        sourceKind: .live
    )
    let manifestEncoder = JSONEncoder()
    manifestEncoder.keyEncodingStrategy = .convertToSnakeCase
    manifestEncoder.dateEncodingStrategy = .iso8601
    try manifestEncoder.encode(manifest).write(
        to: sessionURL.appending(path: "session.json"),
        options: .atomic
    )
    try ProcessingMetadataStore(sessionURL: sessionURL).save(metadata)

    let processingURL = sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: processingURL, withIntermediateDirectories: true)
    try JSONEncoder().encode(AudioCheckpoint(
        committedFrames: 100,
        sampleRate: 100,
        channelCount: 1,
        chunkFiles: ["chunk-000000.f32le"]
    )).write(
        to: processingURL.appending(path: DurableAudioWriter.checkpointFilename),
        options: .atomic
    )
    try Data(count: 100 * MemoryLayout<Float>.size)
        .write(to: processingURL.appending(path: "chunk-000000.f32le"))
    return sessionURL
}

@Test
func oldProcessingMetadataDecodesWithoutFinalizationAttempt() throws {
    let oldMetadataJSON = #"{"timeline_version":1,"vad_version":"vad","vad_config_hash":"hash","asr_engine":"qwen","asr_model":"model","asr_version":"version","diarization_version":"diarization","scene_analyzer_version":1,"jev_schema_version":1,"policy_version":1,"materializer_schema_version":1,"active_runs":{"asr":"asr_old"}}"#
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let metadata = try decoder.decode(ProcessingMetadata.self, from: Data(oldMetadataJSON.utf8))

    #expect(metadata.activeRuns?.asr == "asr_old")
    #expect(metadata.finalizationAttempt == nil)
}

@Test
func finalizationLifecyclePreservesActiveRunsUntilAtomicCompletion() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = ProcessingMetadataStore(sessionURL: root)
    let oldRuns = ActiveRuns(segmentation: "seg_old", asr: "asr_old", scope: "scope_old")
    try store.save(finalizationMetadata(activeRuns: oldRuns))

    try store.beginFinalization(attemptID: "attempt_1")
    let runningValue = try store.load()
    let running = try #require(runningValue)
    #expect(running.activeRuns == oldRuns)
    #expect(running.finalizationAttempt == FinalizationAttempt(attemptID: "attempt_1", state: .running))
    #expect(running.withActiveRuns(ActiveRuns(asr: "asr_other")).finalizationAttempt == running.finalizationAttempt)

    try store.failFinalization(attemptID: "attempt_1", reason: "diarization failed")
    let failedValue = try store.load()
    let failed = try #require(failedValue)
    #expect(failed.activeRuns == oldRuns)
    #expect(failed.finalizationAttempt == FinalizationAttempt(
        attemptID: "attempt_1", state: .failed, failureReason: "diarization failed"
    ))

    let newRuns = ActiveRuns(segmentation: "seg_new", asr: "asr_new", diarization: "diar_new", scope: "scope_new")
    try store.beginFinalization(attemptID: "attempt_2")
    try store.completeFinalization(attemptID: "attempt_2", activeRuns: newRuns)
    let completeValue = try store.load()
    let complete = try #require(completeValue)
    #expect(complete.activeRuns == newRuns)
    #expect(complete.finalizationAttempt == FinalizationAttempt(attemptID: "attempt_2", state: .complete))
}

@Test
func scannerQueuesInterruptedFinalizationAndDoesNotLoopFailedAttempt() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let oldRuns = ActiveRuns(segmentation: "seg_old", asr: "asr_old", scope: "scope_old")
    let sessionURL = try writeFinalizationSession(
        id: id,
        at: root,
        metadata: finalizationMetadata(
            activeRuns: oldRuns,
            attempt: FinalizationAttempt(attemptID: "attempt_1", state: .running)
        )
    )
    let scanner = SessionRecoveryScanner(sessionsRoot: root)

    let interruptedValue = try scanner.inspect(sessionID: id)
    let interrupted = try #require(interruptedValue)
    #expect(interrupted.action == .finalize)
    #expect(interrupted.source == .processingTimeline(AudioCheckpoint(
        committedFrames: 100,
        sampleRate: 100,
        channelCount: 1,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [100]
    )))

    try ProcessingMetadataStore(sessionURL: sessionURL).failFinalization(
        attemptID: "attempt_1",
        reason: "interrupted attempt failed"
    )
    #expect(try scanner.inspect(sessionID: id) == nil)
    #expect(try scanner.pendingSessions().isEmpty)

    try ProcessingMetadataStore(sessionURL: sessionURL).beginFinalization(
        attemptID: "attempt_2"
    )
    try ProcessingMetadataStore(sessionURL: sessionURL).completeFinalization(
        attemptID: "attempt_2",
        activeRuns: oldRuns
    )
    #expect(try scanner.inspect(sessionID: id) == nil)
    #expect(try scanner.pendingSessions().isEmpty)
}

@Test
func completedFinalizationStillRetriesPendingContentPrioritySegments() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let runs = ActiveRuns(
        segmentation: "seg_active",
        asr: "asr_active",
        diarization: "diar_active",
        scene: "scene_active",
        scope: "scope_active",
        contentPriority: "priority_active"
    )
    let sessionURL = try writeFinalizationSession(
        id: id,
        at: root,
        metadata: finalizationMetadata(
            activeRuns: runs,
            attempt: FinalizationAttempt(attemptID: "attempt_complete", state: .complete)
        )
    )
    let writer = try SessionWriter(sessionURL: sessionURL)
    _ = try await writer.append(EventDraft(
        eventType: "segment.created",
        sessionID: id,
        segmentationRunID: "seg_active",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.pending",
        sessionID: id,
        processingRunID: "asr_active",
        segmentationRunID: "seg_active",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.completed",
        sessionID: id,
        processingRunID: "asr_active",
        segmentationRunID: "seg_active",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: ASRCompletedEventPayload(
            text: "話者ターン確定済み",
            detectedLanguage: "ja",
            engine: "qwen3-asr",
            model: "fixture"
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "processing.run.completed",
        sessionID: id,
        processingRunID: "asr_active",
        payload: ProcessingRunCompletedPayload(
            stage: .asr,
            succeeded: true,
            completedCount: 1,
            failedCount: 0
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "content_priority.assigned",
        sessionID: id,
        processingRunID: "priority_active",
        segmentID: "seg_000001",
        payload: ContentPriorityEventPayload(
            priority: .primary,
            confidence: nil,
            model: nil,
            inputTokens: nil,
            needsRetry: true
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "content_priority.pending_retry",
        sessionID: id,
        processingRunID: "priority_active",
        segmentID: "seg_000001",
        payload: EmptyPayload()
    ))

    let candidateValue = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id)
    let candidate = try #require(candidateValue)
    #expect(candidate.action == .retryContentPriority(segmentIDs: ["seg_000001"]))
}
