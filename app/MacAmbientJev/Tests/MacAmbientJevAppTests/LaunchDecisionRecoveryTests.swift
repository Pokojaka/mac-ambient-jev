import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCore
import MacAmbientJevPipeline
import MacAmbientJevRuntime

/// A completed recording whose published local transcript has one segment pending boundary decision.
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
    let runs = ActiveRuns(segmentation: "seg", asr: "asr", diarization: "diar")
    let writer = try SessionWriter(sessionURL: sessionURL)
    let provenance = RunProvenance(engine: "launch-recovery-test", model: nil, version: "1", configuration: [:])
    let stages: [(ProcessingStage, String, Int)] = [(.segmentation, "seg", 1), (.asr, "asr", 1), (.diarization, "diar", 0)]
    for (stage, runID, _) in stages {
        _ = try await writer.append(EventDraft(
            eventType: "processing.run.started", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunStartedPayload(stage: stage, provenance: provenance)
        ))
    }
    _ = try await writer.append(EventDraft(
        eventType: "segment.created", sessionID: sessionID, segmentationRunID: "seg", segmentID: "s01",
        sourceStartFrame: 0, sourceEndFrame: 16_000, payload: EmptyPayload()
    ))
    let recognized = try await writer.append(EventDraft(
        eventType: "asr.completed", sessionID: sessionID, processingRunID: "asr", segmentationRunID: "seg",
        segmentID: "s01", sourceStartFrame: 0, sourceEndFrame: 16_000,
        payload: ASRCompletedEventPayload(text: "本文です", detectedLanguage: "ja", provenance: provenance)
    ))
    for (stage, runID, completed) in stages {
        _ = try await writer.append(EventDraft(
            eventType: "processing.run.completed", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunCompletedPayload(stage: stage, succeeded: true, completedCount: completed, failedCount: 0)
        ))
    }
    let source = try SegmentTextReference(
        segmentationRunID: "seg", segmentID: "s01", asrRunID: "asr", asrEventSeq: recognized.eventSeq
    )
    try ProcessingMetadataStore(sessionURL: sessionURL).save(ProcessingMetadata(
        finalizationAttempt: FinalizationAttempt(attemptID: "finalize_saved", state: .complete, failureReason: nil),
        activeRuns: runs,
        pendingClauseBoundarySegments: [source],
        pendingContentPriorityClauses: []
    ))
    return (sessionID, layout, source)
}

@MainActor
private func pausedState(paths: AppPaths, defaults: UserDefaults) -> AppState {
    AppState(
        paths: paths, captureEngine: FakeAppCaptureEngine(), microphoneAccess: { false },
        pausesProcessing: true, userDefaults: defaults, engines: .production(paths: paths),
        makeLiveVADSession: idleLiveVADFactory(),
        thermalMonitor: TestThermalMonitor(.nominal)
    )
}

@MainActor
private func queuedRetry(_ state: AppState) -> (sessionID: UUID, boundarySegments: [SegmentTextReference], clauses: [ClauseReference])? {
    guard state.processingQueue.pending.count == 1,
          case .retryContentPriority(let sessionID, let boundarySegments, let clauses) = state.processingQueue.pending[0] else {
        return nil
    }
    return (sessionID, boundarySegments, clauses)
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

    await launched.recoverPendingSessions()

    #expect(launched.processingQueue.pending.isEmpty)
    #expect(launched.processingStatusText == nil)

    await launched.retryDeferredDecisions()

    let retry = try #require(queuedRetry(launched))
    #expect(retry.sessionID == saved.sessionID)
    #expect(retry.boundarySegments == [saved.source])
    #expect(retry.clauses == [])
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

    await launched.recoverPendingSessions()

    let retry = try #require(queuedRetry(launched))
    #expect(retry.sessionID == saved.sessionID)
    #expect(retry.boundarySegments == [saved.source])
    #expect(retry.clauses == [])
    #expect(launched.processingStatusText == "未完了の文字起こしを復旧しています（1件）")
}
