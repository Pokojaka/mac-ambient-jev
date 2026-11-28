import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCore
import MacAmbientJevPipeline
import MacAmbientJevRuntime

/// A completed recording whose local transcript has one segment pending boundary decision.
private func pendingDecisionRecording(paths: AppPaths) async throws -> (sessionID: UUID, layout: SessionLayout, source: SegmentTextReference) {
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let layout = SessionLayout(sessionURL: sessionURL)
    let audio = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: sessionURL)
    try await audio.append(samples: Array(repeating: 0.125, count: 16_000))
    _ = try await audio.finish()
    let writer = try SessionWriter(sessionURL: sessionURL)
    let provenance = RunProvenance(engine: "launch-recovery-test", model: nil, version: "1", configuration: [:])
    let generation = PipelineGeneration(
        id: UUID(), runs: ActiveRuns(segmentation: "seg", asr: "asr"), sampleRate: 16_000,
        segmentationProvenance: provenance, asrProvenance: provenance
    )
    _ = try await writer.append(generation.startEvent(sessionID: sessionID))
    for (stage, runID) in [(ProcessingStage.segmentation, "seg"), (.asr, "asr")] {
        _ = try await writer.append(EventDraft(
            eventType: "processing.run.started", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunStartedPayload(stage: stage, provenance: provenance)
        ))
    }
    _ = try await writer.append(EventDraft.segmentCreated(
        sessionID: sessionID,
        segment: SegmentReference(segmentationRunID: "seg", segmentID: "s01", speechRanges: [0..<16_000])
    ))
    _ = try await writer.append(EventDraft(
        eventType: "segmentation.input.sealed", sessionID: sessionID, segmentationRunID: "seg",
        payload: SegmentationInputSealedPayload(frameCount: 16_000)
    ))
    _ = try await writer.append(EventDraft(
        eventType: "segmentation.completed", sessionID: sessionID, segmentationRunID: "seg",
        payload: SegmentationCompletedPayload(consumedFrames: 16_000, segmentCount: 1)
    ))
    _ = try await writer.append(EventDraft(
        eventType: "processing.run.completed", sessionID: sessionID, processingRunID: "seg",
        payload: ProcessingRunCompletedPayload(stage: .segmentation, succeeded: true, completedCount: 1, failedCount: 0)
    ))
    let recognized = try await writer.append(EventDraft(
        eventType: "asr.completed", sessionID: sessionID, processingRunID: "asr", segmentationRunID: "seg",
        segmentID: "s01", sourceStartFrame: 0, sourceEndFrame: 16_000,
        payload: ASRCompletedEventPayload(text: "本文です", detectedLanguage: "ja", provenance: provenance)
    ))
    _ = try await writer.append(EventDraft(
        eventType: "processing.run.completed", sessionID: sessionID, processingRunID: "asr",
        payload: ProcessingRunCompletedPayload(stage: .asr, succeeded: true, completedCount: 1, failedCount: 0)
    ))
    let source = try SegmentTextReference(
        segmentationRunID: "seg", segmentID: "s01", asrRunID: "asr", asrEventSeq: recognized.eventSeq
    )
    try ProcessingMetadataStore(sessionURL: sessionURL).save(
        ProcessingMetadata(generationID: generation.id, state: .complete, failureReason: nil)
    )
    return (sessionID, layout, source)
}

@MainActor
private func pausedState(paths: AppPaths, defaults: UserDefaults) -> AppState {
    AppState(
        paths: paths, captureEngine: FakeAppCaptureEngine(), microphoneAccess: { false },
        pausesProcessing: true, userDefaults: defaults, engines: productionEngines(paths: paths),
        modelProvisioning: ReadyModelProvisioning(),
        makeLiveVADSession: idleLiveVADFactory(),
        thermalMonitor: TestThermalMonitor(.nominal),
        liveTranscriptionSleep: { try await Task.sleep(for: $0) }
    )
}

@MainActor
private func queuedRetry(_ state: AppState) -> ProcessingQueueItemSummary? {
    let retries = state.processingQueue.summaries.filter { $0.kind == .decisionRetry }
    guard retries.count == 1 else { return nil }
    return retries[0]
}

@MainActor
@Test("launch recovery leaves published decision pendings to the user's retry")
func launchRecoveryLeavesPublishedDecisionPendingsToTheUser() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let saved = try await pendingDecisionRecording(paths: paths)
    let launched = pausedState(paths: paths, defaults: defaults)

    await launched.processingCoordinator.recoverPendingSessions(
        effects: launched,
        scan: {
            try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
        },
        maintain: { items, willMaintain in
            await SessionStorageMaintainer.maintain(items, willMaintain: willMaintain)
        }
    )

    #expect(launched.processingQueue.summaries.isEmpty)
    #expect(launched.processingStatusText == nil)

    await launched.processingCoordinator.retryDeferredDecisions(
        effects: launched,
        scan: {
            try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
        }
    )

    let retry = try #require(queuedRetry(launched))
    #expect(retry.sessionID == saved.sessionID)
    #expect(retry.kind == .decisionRetry)
}

@MainActor
@Test("launch recovery finishes an unpublished decision run with the published pending targets")
func launchRecoveryFinishesAnUnpublishedDecisionRun() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let saved = try await pendingDecisionRecording(paths: paths)
    _ = try await SessionWriter(sessionURL: saved.layout.sessionURL).append(EventDraft(
        eventType: "processing.run.started", sessionID: saved.sessionID, processingRunID: "boundary_interrupted",
        payload: ProcessingRunStartedPayload(stage: .clauseBoundary, provenance: RunProvenance(
            engine: "launch-recovery-test", model: nil, version: "1", configuration: ["mode": "retry"]
        ))
    ))
    let launched = pausedState(paths: paths, defaults: defaults)

    await launched.processingCoordinator.recoverPendingSessions(
        effects: launched,
        scan: {
            try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
        },
        maintain: { items, willMaintain in
            await SessionStorageMaintainer.maintain(items, willMaintain: willMaintain)
        }
    )

    let retry = try #require(queuedRetry(launched))
    #expect(retry.sessionID == saved.sessionID)
    #expect(retry.kind == .decisionRetry)
    #expect(launched.processingStatusText == "未完了の文字起こしを復旧しています（1件）")
}
