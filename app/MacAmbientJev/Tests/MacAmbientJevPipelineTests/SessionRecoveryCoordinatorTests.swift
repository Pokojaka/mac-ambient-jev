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
    var processingQueue = SessionProcessingQueue()
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

    func prepareASRModel() {}

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

    func waitForLiveASRDrain(sessionID: UUID) async {
        preconditionFailure("recovery tests do not finish live transcription")
    }

    func liveASRFailure(sessionID: UUID) -> String? {
        preconditionFailure("recovery tests do not inspect live ASR failures")
    }

    func cleanupLiveASRState(sessionID: UUID) {
        preconditionFailure("recovery tests do not clean up live ASR state")
    }

    func refreshSavedSessions() {}

    func autoExportIfEnabled(sessionID: UUID) async {
        exportedSessionIDs.append(sessionID)
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
        metadataPolicy: UnreadableMetadataPolicy,
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult {
        guard finalizationIDs.contains(sessionID) else {
            preconditionFailure("unexpected finalization for \(sessionID)")
        }
        recordedCalls.append("finalize:\(sessionID.uuidString)")
        return .completed(metrics: nil, noSpeech: false)
    }

    func finishLiveTranscription(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        finalSegments: [SegmentReference],
        pacingMode: ASRPacingMode,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck,
        onPhase: @escaping NativeSessionProcessor.PhaseHandler,
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult {
        preconditionFailure("recovery tests do not finish live transcription")
    }

    func retryContentPrioritySession(
        sessionID: UUID,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference],
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async {
        guard retryIDs.contains(sessionID) else {
            preconditionFailure("unexpected decision retry for \(sessionID)")
        }
        recordedCalls.append("retry:\(sessionID.uuidString)")
    }

    func cancelLiveTranscription(sessionID: UUID) async {
        preconditionFailure("recovery tests do not cancel live transcription")
    }

    func calls() -> [String] { recordedCalls }
}

private enum RecoveryScanTestError: LocalizedError {
    case unavailable

    var errorDescription: String? { "scanner unavailable" }
}

private func recoveryCandidate(
    _ sessionID: UUID,
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
        thermalMonitor: RecoveryTestThermalMonitor()
    )
}

private struct RetrySnapshot: Equatable {
    let sessionID: UUID
    let boundarySegments: [SegmentTextReference]
    let clauses: [ClauseReference]
}

private func retrySnapshot(_ request: PendingProcessing) -> RetrySnapshot? {
    guard case .retryContentPriority(let sessionID, let boundarySegments, let clauses) = request else {
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
    let alreadyPendingID = UUID()
    let publishedRetryID = UUID()
    let previous = SessionRecoveryStatusSnapshot(processing: "ongoing", transcript: "prior transcript")
    let effects = RecoveryCoordinatorEffects(
        pausesProcessing: false,
        recordingSessionID: recordingID,
        recoveryStatusSnapshot: previous
    )
    effects.processingQueue.enqueue(.retryContentPriority(
        sessionID: alreadyPendingID,
        boundarySegments: [],
        clauses: []
    ))
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
        recoveryCandidate(alreadyPendingID, action: .finalize),
        recoveryCandidate(publishedRetryID, action: .retryContentPriority(boundarySegments: segments, clauses: clauses))
    ]
    let scanFailure = SessionRecoveryFailure(
        sessionURL: URL(fileURLWithPath: "/recovery/broken"),
        message: "manifest unavailable"
    )
    let executor = RecoveryTestExecutor(
        finalizationIDs: [finalizeID],
        retryIDs: [alreadyPendingID, decisionID]
    )
    let coordinator = makeRecoveryCoordinator(effects: effects, executor: executor)
    let maintenanceLog = RecoveryTestLog()

    await coordinator.recoverPendingSessions(
        effects: effects,
        scan: {
            SessionRecoveryScan(
                candidates: candidates,
                maintenance: [maintenanceCandidate(recordingID), maintenanceCandidate(maintenanceFailureID)],
                failures: [scanFailure]
            )
        },
        maintain: { items, willMaintain in
            let wasMaintaining = await MainActor.run { effects.processingQueue.isMaintainingStorage }
            maintenanceLog.append("maintaining:\(wasMaintaining)")
            maintenanceLog.append("items:\(items.map(\.sessionID).map(\.uuidString).joined(separator: ","))")
            await willMaintain(items.count)
            return [maintenanceFailureID: "maintenance failed"]
        }
    )

    #expect(maintenanceLog.values == ["maintaining:true", "items:\(maintenanceFailureID.uuidString)"])
    #expect(effects.recoveryEvents == [
        .maintenanceStarted(1),
        .maintenanceFinished(count: 1, previous: previous),
        .recovering(2),
        .reportedFailures(
            scanFailures: [scanFailure],
            maintenanceFailures: [maintenanceFailureID: "maintenance failed"],
            hasRecoveries: true
        )
    ])
    #expect(effects.processingQueue.pending.map(\.sessionID) == [alreadyPendingID, finalizeID, decisionID])
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
@Test
func failedRecoveryScanClearsMaintenanceAndDrainsPendingWork() async {
    let pendingID = UUID()
    let effects = RecoveryCoordinatorEffects(
        pausesProcessing: false,
        recordingSessionID: nil,
        recoveryStatusSnapshot: SessionRecoveryStatusSnapshot(processing: nil, transcript: "idle")
    )
    effects.processingQueue.enqueue(.retryContentPriority(sessionID: pendingID, boundarySegments: [], clauses: []))
    let executor = RecoveryTestExecutor(finalizationIDs: [], retryIDs: [pendingID])
    let coordinator = makeRecoveryCoordinator(effects: effects, executor: executor)

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
                effects.processingQueue.enqueue(.retryContentPriority(
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
    effects.processingQueue.enqueue(.finalize(sessionID: recoveryID, metadataPolicy: .reject))
    let executor = RecoveryTestExecutor(finalizationIDs: [], retryIDs: [])
    let coordinator = makeRecoveryCoordinator(effects: effects, executor: executor)

    await coordinator.retryDeferredDecisions(
        effects: effects,
        scan: { SessionRecoveryScan(candidates: candidates, maintenance: [], failures: []) }
    )

    #expect(effects.processingQueue.pending.count == 4)
    #expect(effects.processingQueue.pending.map(\.sessionID) == [recoveryID, recoveryID, publishedID, publishedID])
    if effects.processingQueue.pending.count == 4 {
        expectRetry(effects.processingQueue.pending[1], sessionID: recoveryID, boundarySegments: recoverySegments, clauses: recoveryClauses)
        expectRetry(effects.processingQueue.pending[2], sessionID: publishedID, boundarySegments: publishedSegments, clauses: publishedClauses)
        expectRetry(effects.processingQueue.pending[3], sessionID: publishedID, boundarySegments: repeatedSegments, clauses: repeatedClauses)
    }
    #expect(effects.recoveryEvents.isEmpty)
    #expect(!coordinator.isDraining)

    let sharedRecoveryRequests = SessionProcessingCoordinator.recoveryRequests(
        candidates: candidates,
        recordingSessionID: nil,
        maintenanceFailures: [:],
        pending: []
    )
    #expect(sharedRecoveryRequests.count == 2)
    if sharedRecoveryRequests.count == 2, effects.processingQueue.pending.count == 4 {
        if case .finalize(let sessionID, let metadataPolicy) = sharedRecoveryRequests[0] {
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
        #expect(retrySnapshot(effects.processingQueue.pending[1]) == retrySnapshot(sharedRecoveryRequests[1]))
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
