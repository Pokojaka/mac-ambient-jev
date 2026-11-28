import Foundation
import Testing
import Synchronization
import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private final class RecoveryTestLog: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ value: String) {
        storage.withLock { $0.append(value) }
    }

    var values: [String] {
        storage.withLock { $0 }
    }
}

private final class RecoveryTestObservation: ThermalStateObservation {}

private struct RecoveryTestThermalMonitor: ThermalMonitoring {
    var isCritical: Bool { false }
    var liveASRDecision: LiveASRThermalDecision { .processNow }

    @MainActor
    func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any ThermalStateObservation {
        RecoveryTestObservation()
    }
}

@MainActor
private final class RecoveryCoordinatorEffects: SessionProcessingEffects, SessionRecoveryEffects {
    private(set) var processingQueue: ProcessingQueueSnapshot!
    let pausesProcessing: Bool
    var recordingSessionID: UUID?
    let recoveryStatusSnapshot: SessionRecoveryStatusSnapshot
    private(set) var recoveryEvents: [SessionRecoveryEvent] = []
    private(set) var processingEvents: [SessionProcessingEvent] = []
    private(set) var exportedSessionIDs: [UUID] = []
    private var idleReleased = false
    private var idleContinuation: CheckedContinuation<Void, Never>?

    init(
        pausesProcessing: Bool,
        recordingSessionID: UUID?,
        recoveryStatusSnapshot: SessionRecoveryStatusSnapshot
    ) {
        self.pausesProcessing = pausesProcessing
        self.recordingSessionID = recordingSessionID
        self.recoveryStatusSnapshot = recoveryStatusSnapshot
    }

    func releaseIdle() {
        idleReleased = true
        let continuation = idleContinuation
        idleContinuation = nil
        continuation?.resume()
    }

    var modelsReady: Bool { true }
    func prepareModels() {}

    func awaitIdleRelease() async {
        guard !idleReleased else { return }
        await withCheckedContinuation { continuation in
            idleContinuation = continuation
        }
    }

    func processingStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler {
        { _ in }
    }

    func processingUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        { _, _ in }
    }

    func processingGenerationDidOpen(sessionID: UUID, generationID: UUID) {}
    func hasLiveProcessingWorker(sessionID: UUID) -> Bool { false }

    func waitForLiveASRDrain(sessionID: UUID) async -> LiveASRDrainOutcome { .drained }

    func liveASRFailure(sessionID: UUID) -> String? { nil }

    func cleanupLiveASRState(sessionID: UUID) {}

    func refreshSavedSessions() {}

    func autoExportIfEnabled(sessionID: UUID) async {
        exportedSessionIDs.append(sessionID)
    }

    func processingQueueDidChange(_ snapshot: ProcessingQueueSnapshot) {
        processingQueue = snapshot
    }

    func processingDidChange(_ event: SessionProcessingEvent) {
        processingEvents.append(event)
    }

    func recoveryDidChange(_ event: SessionRecoveryEvent) {
        recoveryEvents.append(event)
    }
}

private actor RecoveryTestExecutor: SessionProcessingExecuting {
    private let finalizationIDs: Set<UUID>
    private let retryIDs: Set<UUID>
    private var recordedCalls: [String] = []

    init(finalizationIDs: Set<UUID>, retryIDs: Set<UUID>) {
        self.finalizationIDs = finalizationIDs
        self.retryIDs = retryIDs
    }

    func processSession(
        sessionID: UUID,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck,
        onPhase: @escaping NativeSessionProcessor.PhaseHandler,
        metadataPolicy: SessionFinalizationPolicy,
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler,
        onGenerationOpened: @escaping NativeSessionProcessor.GenerationOpenedHandler
    ) async -> SessionProcessingResult {
        guard finalizationIDs.contains(sessionID) else {
            preconditionFailure("unexpected finalization for \(sessionID)")
        }
        recordedCalls.append("finalize:\(sessionID.uuidString)")
        return .completed(metrics: nil, noSpeech: false, replacementGeneration: .notOpened)
    }

    func retryContentPrioritySession(
        sessionID: UUID,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference],
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult {
        guard retryIDs.contains(sessionID) else {
            preconditionFailure("unexpected decision retry for \(sessionID)")
        }
        recordedCalls.append("retry:\(sessionID.uuidString)")
        return .completed(metrics: nil, noSpeech: false, replacementGeneration: .notOpened)
    }

    func cancelLiveTranscription(sessionID: UUID) async {
        preconditionFailure("recovery tests do not cancel live transcription")
    }

    func hasUnresolvedASRFailure(sessionID: UUID) async throws -> Bool { false }

    func calls() -> [String] { recordedCalls }
}

private enum RecoveryScanTestError: LocalizedError {
    case unavailable

    var errorDescription: String? { "scanner unavailable" }
}

private func recoveryCandidate(
    _ sessionID: UUID,
    generationID: UUID? = nil,
    action: RecoverableProcessingAction
) -> RecoverableSession {
    let manifest = SessionManifest(
        sessionID: sessionID,
        createdAt: Date(timeIntervalSince1970: 0),
        source: .imported(originalFilename: "fixture.wav")
    )
    return RecoverableSession(
        manifest: manifest,
        sessionURL: URL(fileURLWithPath: "/recovery/\(sessionID.uuidString)"),
        generationID: generationID,
        action: action
    )
}

private func maintenanceCandidate(_ sessionID: UUID) -> SessionMaintenanceCandidate {
    SessionMaintenanceCandidate(
        sessionID: sessionID,
        sessionURL: URL(fileURLWithPath: "/maintenance/\(sessionID.uuidString)"),
        maintenance: .removeTransients
    )
}

@MainActor
private func makeRecoveryCoordinator(
    effects: RecoveryCoordinatorEffects,
    executor: RecoveryTestExecutor
) -> SessionProcessingCoordinator {
    SessionProcessingCoordinator(
        effects: effects,
        processor: executor,
        thermalMonitor: RecoveryTestThermalMonitor(),
        resourceHolds: nil
    )
}

private struct RetrySnapshot: Equatable {
    let sessionID: UUID
    let boundarySegments: [SegmentTextReference]
    let clauses: [ClauseReference]
}

private func retrySnapshot(_ request: PendingProcessing) -> RetrySnapshot? {
    guard case .retryContentPriority(_, let sessionID, let boundarySegments, let clauses) = request else {
        return nil
    }
    return RetrySnapshot(sessionID: sessionID, boundarySegments: boundarySegments, clauses: clauses)
}

private func expectRetry(
    _ request: PendingProcessing,
    sessionID: UUID,
    boundarySegments: [SegmentTextReference],
    clauses: [ClauseReference]
) {
    #expect(retrySnapshot(request) == RetrySnapshot(
        sessionID: sessionID,
        boundarySegments: boundarySegments,
        clauses: clauses
    ))
}

@MainActor
@Test
func recoveryMaintainsAndFiltersBeforeEnqueuingRecoveries() async throws {
    let recordingID = UUID()
    let finalizeID = UUID()
    let decisionID = UUID()
    let maintenanceFailureID = UUID()
    let maintenanceInterruptedID = UUID()
    let alreadyPendingID = UUID()
    let publishedRetryID = UUID()
    let previous = SessionRecoveryStatusSnapshot(processing: "ongoing", transcript: "prior transcript")
    let effects = RecoveryCoordinatorEffects(
        pausesProcessing: false,
        recordingSessionID: recordingID,
        recoveryStatusSnapshot: previous
    )
    let segments = [try SegmentTextReference(
        segmentationRunID: "seg",
        segmentID: "s01",
        asrRunID: "asr",
        asrEventSeq: 1
    )]
    let clauses = [try ClauseReference(boundaryRunID: "boundary", clauseID: "clause_0001")]
    let candidates = [
        recoveryCandidate(finalizeID, action: .finalize),
        recoveryCandidate(recordingID, action: .finalize),
        recoveryCandidate(decisionID, action: .recoverDecisionRun(boundarySegments: segments, clauses: clauses)),
        recoveryCandidate(maintenanceFailureID, action: .finalize),
        recoveryCandidate(maintenanceInterruptedID, action: .finalize),
        recoveryCandidate(alreadyPendingID, action: .finalize),
        recoveryCandidate(publishedRetryID, action: .retryContentPriority(boundarySegments: segments, clauses: clauses))
    ]
    let scanFailure = SessionRecoveryFailure(
        sessionURL: URL(fileURLWithPath: "/recovery/broken"),
        message: "manifest unavailable"
    )
    let maintenanceIssues: [UUID: SessionMaintenanceIssue] = [
        maintenanceFailureID: .failed("maintenance failed"),
        maintenanceInterruptedID: .interruptedByShutdown("maintenance interrupted")
    ]
    let executor = RecoveryTestExecutor(
        finalizationIDs: [finalizeID],
        retryIDs: [alreadyPendingID, decisionID]
    )
    let coordinator = makeRecoveryCoordinator(effects: effects, executor: executor)
    coordinator.enqueue(.retryContentPriority(sessionID: alreadyPendingID, boundarySegments: [], clauses: []))
    let maintenanceLog = RecoveryTestLog()

    await coordinator.recoverPendingSessions(
        effects: effects,
        scan: {
            SessionRecoveryScan(
                candidates: candidates,
                maintenance: [
                    maintenanceCandidate(recordingID),
                    maintenanceCandidate(maintenanceFailureID),
                    maintenanceCandidate(maintenanceInterruptedID)
                ],
                failures: [scanFailure]
            )
        },
        maintain: { items, willMaintain in
            let wasMaintaining = await MainActor.run { effects.processingQueue.isMaintainingStorage }
            maintenanceLog.append("maintaining:\(wasMaintaining)")
            maintenanceLog.append("items:\(items.map(\.sessionID).map(\.uuidString).joined(separator: ","))")
            await willMaintain(items.count)
            return maintenanceIssues
        }
    )

    #expect(maintenanceLog.values == [
        "maintaining:true",
        "items:\(maintenanceFailureID.uuidString),\(maintenanceInterruptedID.uuidString)"
    ])
    #expect(effects.recoveryEvents == [
        .maintenanceStarted(2),
        .recovering(2),
        .maintenanceFinished(count: 2, previous: previous),
        .reportedFailures(
            scanFailures: [scanFailure],
            maintenanceFailures: maintenanceIssues,
            hasRecoveries: true
        )
    ])
    #expect(effects.processingQueue.pending.map(\.sessionID) == [alreadyPendingID, finalizeID, decisionID])
    #expect(!effects.processingQueue.pending.map(\.sessionID).contains(maintenanceFailureID))
    #expect(!effects.processingQueue.pending.map(\.sessionID).contains(maintenanceInterruptedID))
    #expect(!effects.processingQueue.isMaintainingStorage)

    effects.releaseIdle()
    await coordinator.waitUntilIdle()

    #expect(await executor.calls() == [
        "retry:\(alreadyPendingID.uuidString)",
        "finalize:\(finalizeID.uuidString)",
        "retry:\(decisionID.uuidString)"
    ])
    #expect(effects.processingQueue.pending.isEmpty)
    #expect(!effects.processingQueue.isMaintainingStorage)
}

@MainActor
@Test(arguments: [false, true])
func launchExportsOnlySessionsWhoseStorageMaintenanceCompleted(pausesProcessing: Bool) async {
    let compacted = UUID(), compactionFailed = UUID(), transientsOnly = UUID()
    // A paused engine (for example Windows setup not ready) still exports: export needs no models.
    let effects = RecoveryCoordinatorEffects(
        pausesProcessing: pausesProcessing,
        recordingSessionID: nil,
        recoveryStatusSnapshot: SessionRecoveryStatusSnapshot(processing: nil, transcript: "idle")
    )
    let coordinator = makeRecoveryCoordinator(
        effects: effects, executor: RecoveryTestExecutor(finalizationIDs: [], retryIDs: [])
    )
    func candidate(_ id: UUID, _ maintenance: SessionStorageMaintenance) -> SessionMaintenanceCandidate {
        SessionMaintenanceCandidate(
            sessionID: id, sessionURL: URL(fileURLWithPath: "/maintenance/\(id.uuidString)"), maintenance: maintenance
        )
    }

    await coordinator.recoverPendingSessions(
        effects: effects,
        scan: {
            SessionRecoveryScan(
                candidates: [],
                maintenance: [
                    candidate(compacted, .compactRecording),
                    candidate(compactionFailed, .compactRecording),
                    candidate(transientsOnly, .removeTransients)
                ],
                failures: []
            )
        },
        maintain: { _, _ in [compactionFailed: .failed("compaction failed")] }
    )

    #expect(effects.exportedSessionIDs == [compacted])
}

@MainActor
@Test
func failedRecoveryScanClearsMaintenanceAndDrainsPendingWork() async throws {
    let pendingID = UUID()
    let effects = RecoveryCoordinatorEffects(
        pausesProcessing: false,
        recordingSessionID: nil,
        recoveryStatusSnapshot: SessionRecoveryStatusSnapshot(processing: nil, transcript: "idle")
    )
    let executor = RecoveryTestExecutor(finalizationIDs: [], retryIDs: [pendingID])
    let coordinator = makeRecoveryCoordinator(effects: effects, executor: executor)
    coordinator.enqueue(.retryContentPriority(sessionID: pendingID, boundarySegments: [], clauses: []))

    await coordinator.recoverPendingSessions(
        effects: effects,
        scan: { throw RecoveryScanTestError.unavailable },
        maintain: { _, _ in [:] }
    )

    #expect(effects.recoveryEvents == [.failed("scanner unavailable")])
    #expect(!effects.processingQueue.isMaintainingStorage)
    #expect(effects.processingQueue.pending.map(\.sessionID) == [pendingID])
    #expect(coordinator.isDraining)

    effects.releaseIdle()
    await coordinator.waitUntilIdle()

    #expect(await executor.calls() == ["retry:\(pendingID.uuidString)"])
    #expect(effects.processingQueue.pending.isEmpty)
}

@MainActor
@Test
func emptyRecoveryHasNoMaintenanceStatusOrDrain() async {
    let effects = RecoveryCoordinatorEffects(
        pausesProcessing: false,
        recordingSessionID: nil,
        recoveryStatusSnapshot: SessionRecoveryStatusSnapshot(processing: nil, transcript: "idle")
    )
    let executor = RecoveryTestExecutor(finalizationIDs: [], retryIDs: [])
    let coordinator = makeRecoveryCoordinator(effects: effects, executor: executor)

    await coordinator.recoverPendingSessions(
        effects: effects,
        scan: { SessionRecoveryScan(candidates: [], maintenance: [], failures: []) },
        maintain: { _, _ in [:] }
    )

    #expect(effects.recoveryEvents.isEmpty)
    #expect(!effects.processingQueue.isMaintainingStorage)
    #expect(effects.processingQueue.pending.isEmpty)
    #expect(!coordinator.isDraining)
    #expect(await executor.calls().isEmpty)
}

@MainActor
@Test
func recoveryRejectsAChangedGenerationPlanBeforeEnqueue() async {
    let sessionID = UUID(), scannedGeneration = UUID(), currentGeneration = UUID()
    let effects = RecoveryCoordinatorEffects(
        pausesProcessing: false,
        recordingSessionID: nil,
        recoveryStatusSnapshot: SessionRecoveryStatusSnapshot(processing: nil, transcript: "idle")
    )
    let executor = RecoveryTestExecutor(finalizationIDs: [sessionID], retryIDs: [])
    let coordinator = makeRecoveryCoordinator(effects: effects, executor: executor)
    var scans = 0

    await coordinator.recoverPendingSessions(
        effects: effects,
        scan: {
            scans += 1
            return SessionRecoveryScan(
                candidates: [recoveryCandidate(
                    sessionID, generationID: scans == 1 ? scannedGeneration : currentGeneration, action: .finalize
                )],
                maintenance: [], failures: []
            )
        },
        maintain: { _, _ in [:] }
    )

    #expect(scans == 2)
    #expect(effects.processingQueue.pending.isEmpty)
    #expect(effects.processingQueue.recoveryClaimedSessionIDs.isEmpty)
    #expect(!effects.processingQueue.isMaintainingStorage)
    #expect(effects.recoveryEvents.isEmpty)
    #expect(!coordinator.isDraining)
    #expect(await executor.calls().isEmpty)
}

@MainActor
@Test
func recoveryUsesRecordingAndPendingValuesUpdatedDuringMaintenance() async {
    let oldRecordingID = UUID()
    let updatedRecordingID = UUID()
    let duplicateID = UUID()
    let normalID = UUID()
    let effects = RecoveryCoordinatorEffects(
        pausesProcessing: false,
        recordingSessionID: oldRecordingID,
        recoveryStatusSnapshot: SessionRecoveryStatusSnapshot(processing: nil, transcript: "idle")
    )
    let executor = RecoveryTestExecutor(
        finalizationIDs: [oldRecordingID, normalID],
        retryIDs: [duplicateID]
    )
    let coordinator = makeRecoveryCoordinator(effects: effects, executor: executor)

    await coordinator.recoverPendingSessions(
        effects: effects,
        scan: {
            SessionRecoveryScan(
                candidates: [
                    recoveryCandidate(oldRecordingID, action: .finalize),
                    recoveryCandidate(updatedRecordingID, action: .finalize),
                    recoveryCandidate(duplicateID, action: .finalize),
                    recoveryCandidate(normalID, action: .finalize)
                ],
                maintenance: [maintenanceCandidate(UUID())],
                failures: []
            )
        },
        maintain: { items, willMaintain in
            await MainActor.run {
                effects.recordingSessionID = updatedRecordingID
                coordinator.enqueue(.retryContentPriority(
                    sessionID: duplicateID,
                    boundarySegments: [],
                    clauses: []
                ))
            }
            await willMaintain(items.count)
            return [:]
        }
    )

    #expect(effects.recoveryEvents.contains(.recovering(2)))
    #expect(effects.processingQueue.pending.map(\.sessionID) == [duplicateID, oldRecordingID, normalID])

    effects.releaseIdle()
    await coordinator.waitUntilIdle()

    #expect(await executor.calls() == [
        "retry:\(duplicateID.uuidString)",
        "finalize:\(oldRecordingID.uuidString)",
        "finalize:\(normalID.uuidString)"
    ])
}

@MainActor
@Test
func manualRetryPreservesBothDecisionActionsAndDoesNotFilterAttempts() async throws {
    let recoveryID = UUID()
    let publishedID = UUID()
    let finalizeID = UUID()
    let recoverySegments = [try SegmentTextReference(
        segmentationRunID: "seg", segmentID: "s01", asrRunID: "asr", asrEventSeq: 7
    )]
    let publishedSegments = [try SegmentTextReference(
        segmentationRunID: "seg", segmentID: "s02", asrRunID: "asr", asrEventSeq: 8
    )]
    let repeatedSegments = [try SegmentTextReference(
        segmentationRunID: "seg", segmentID: "s03", asrRunID: "asr", asrEventSeq: 9
    )]
    let recoveryClauses = [try ClauseReference(boundaryRunID: "boundary", clauseID: "clause_0001")]
    let publishedClauses = [try ClauseReference(boundaryRunID: "boundary", clauseID: "clause_0002")]
    let repeatedClauses = [try ClauseReference(boundaryRunID: "boundary", clauseID: "clause_0003")]
    let candidates = [
        recoveryCandidate(finalizeID, action: .finalize),
        recoveryCandidate(recoveryID, action: .recoverDecisionRun(
            boundarySegments: recoverySegments, clauses: recoveryClauses
        )),
        recoveryCandidate(publishedID, action: .retryContentPriority(
            boundarySegments: publishedSegments, clauses: publishedClauses
        )),
        recoveryCandidate(publishedID, action: .retryContentPriority(
            boundarySegments: repeatedSegments, clauses: repeatedClauses
        ))
    ]
    let effects = RecoveryCoordinatorEffects(
        pausesProcessing: true,
        recordingSessionID: recoveryID,
        recoveryStatusSnapshot: SessionRecoveryStatusSnapshot(processing: nil, transcript: "idle")
    )
    let executor = RecoveryTestExecutor(finalizationIDs: [], retryIDs: [])
    let coordinator = makeRecoveryCoordinator(effects: effects, executor: executor)
    coordinator.enqueue(.finalize(sessionID: recoveryID, metadataPolicy: .reject))

    await coordinator.retryDeferredDecisions(
        effects: effects,
        scan: { SessionRecoveryScan(candidates: candidates, maintenance: [], failures: []) }
    )

    #expect(effects.processingQueue.pending.count == 4)
    #expect(effects.processingQueue.pending.map(\.sessionID) == [recoveryID, recoveryID, publishedID, publishedID])
    if effects.processingQueue.pending.count == 4 {
        #expect(effects.processingQueue.pending[1].kind == .decisionRetry)
        #expect(effects.processingQueue.pending[2].kind == .decisionRetry)
        #expect(effects.processingQueue.pending[3].kind == .decisionRetry)
    }
    #expect(effects.recoveryEvents.isEmpty)
    #expect(!coordinator.isDraining)

    let sharedRecoveryRequests = SessionProcessingCoordinator.recoveryRequests(
        candidates: candidates,
        recordingSessionID: nil,
        maintenanceFailures: [:],
        occupiedSessionIDs: []
    )
    #expect(sharedRecoveryRequests.count == 2)
    if sharedRecoveryRequests.count == 2, effects.processingQueue.pending.count == 4 {
        if case .finalize(_, let sessionID, let metadataPolicy) = sharedRecoveryRequests[0] {
            #expect(sessionID == finalizeID)
            #expect(metadataPolicy == .reject)
        } else {
            #expect(Bool(false), "The first recovery request finalizes the candidate")
        }
        expectRetry(
            sharedRecoveryRequests[1],
            sessionID: recoveryID,
            boundarySegments: recoverySegments,
            clauses: recoveryClauses
        )
        #expect(effects.processingQueue.pending[1].sessionID == sharedRecoveryRequests[1].sessionID)
        #expect(effects.processingQueue.pending[1].kind == .decisionRetry)
    }
}

@MainActor
@Test
func manualRetryReportsEmptyAndThrowingScansExactly() async {
    let effects = RecoveryCoordinatorEffects(
        pausesProcessing: true,
        recordingSessionID: nil,
        recoveryStatusSnapshot: SessionRecoveryStatusSnapshot(processing: nil, transcript: "idle")
    )
    let executor = RecoveryTestExecutor(finalizationIDs: [], retryIDs: [])
    let coordinator = makeRecoveryCoordinator(effects: effects, executor: executor)

    await coordinator.retryDeferredDecisions(
        effects: effects,
        scan: { SessionRecoveryScan(candidates: [], maintenance: [], failures: []) }
    )
    await coordinator.retryDeferredDecisions(
        effects: effects,
        scan: { throw RecoveryScanTestError.unavailable }
    )

    #expect(effects.recoveryEvents == [.retryEmpty, .retryFailed("scanner unavailable")])
    #expect(effects.processingQueue.pending.isEmpty)
    #expect(!coordinator.isDraining)
}
