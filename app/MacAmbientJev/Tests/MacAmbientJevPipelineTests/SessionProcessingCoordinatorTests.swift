import Foundation
import Testing
import Synchronization
@testable import MacAmbientJevPipeline
@testable import MacAmbientJevCore

private final class CoordinatorTestEventLog: Sendable {
    private let storage: Mutex<[String]>

    init() {
        storage = Mutex([])
    }

    func append(_ event: String) {
        storage.withLock { $0.append(event) }
    }

    var events: [String] {
        storage.withLock { $0 }
    }
}

private final class CoordinatorTestThermalMonitor: ThermalMonitoring, Sendable {
    private let pressureStorage: Mutex<ThermalPressure>
    private let changeObservers = TestThermalChangeObservers()

    init(pressure: ThermalPressure) {
        pressureStorage = Mutex(pressure)
    }

    var pressure: ThermalPressure {
        pressureStorage.withLock { $0 }
    }

    @MainActor
    func setPressure(_ pressure: ThermalPressure) {
        let didChange = pressureStorage.withLock { current in
            guard current != pressure else { return false }
            current = pressure
            return true
        }
        if didChange {
            changeObservers.notify()
        }
    }

    @MainActor
    func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any ThermalStateObservation {
        changeObservers.observeChanges(onChange)
    }

    var isCritical: Bool { pressure == .critical }
    var liveASRDecision: LiveASRThermalDecision {
        LiveASRThermalPolicy.decision(pressure: pressure)
    }
}

private struct CoordinatorQueueSnapshot {
    let pendingSessionIDs: [UUID]
    let thermallyHeldSessionIDs: [UUID]
    let currentSessionID: UUID?
    let claimedSessionIDs: Set<UUID>

    init(queue: SessionProcessingQueue) {
        pendingSessionIDs = queue.pending.map(\.sessionID)
        thermallyHeldSessionIDs = queue.thermallyHeld.map(\.sessionID)
        currentSessionID = queue.currentSessionID
        claimedSessionIDs = queue.claimedSessionIDs
    }
}

@MainActor
private final class CoordinatorEffectsFake: SessionProcessingEffects {
    var processingQueue = SessionProcessingQueue() {
        didSet {
            queueSnapshots.append(CoordinatorQueueSnapshot(queue: processingQueue))
        }
    }
    var pausesProcessing: Bool
    private let liveFailure: String?
    private let eventLog: CoordinatorTestEventLog
    var onLiveASRDrainWait: (() -> Void)?

    private(set) var queueSnapshots: [CoordinatorQueueSnapshot] = []
    private(set) var eventOrder: [String] = []
    private(set) var prepareASRModelCount = 0
    private(set) var idleReleaseCount = 0
    private(set) var liveASRDrainWaitCount = 0
    private(set) var liveASRCleanupCount = 0
    private(set) var refreshSavedSessionsCount = 0
    private(set) var exportCount = 0
    private(set) var exportedSessionIDs: [UUID] = []
    private(set) var currentSessionIDsDuringExport: [UUID?] = []
    var onEvent: (@MainActor (SessionProcessingEvent) -> Void)?

    init(
        pausesProcessing: Bool,
        liveFailure: String?,
        eventLog: CoordinatorTestEventLog
    ) {
        self.pausesProcessing = pausesProcessing
        self.liveFailure = liveFailure
        self.eventLog = eventLog
    }

    func prepareASRModel() {
        prepareASRModelCount += 1
    }

    func awaitIdleRelease() async {
        idleReleaseCount += 1
    }

    func processingStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler {
        { _ in }
    }

    func processingUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        { _, _ in }
    }

    func waitForLiveASRDrain(sessionID: UUID) async {
        liveASRDrainWaitCount += 1
        eventLog.append("waitForLiveASRDrain:\(sessionID.uuidString)")
        onLiveASRDrainWait?()
    }

    func liveASRFailure(sessionID: UUID) -> String? {
        liveFailure
    }

    func cleanupLiveASRState(sessionID: UUID) {
        liveASRCleanupCount += 1
        eventLog.append("cleanupLiveASRState:\(sessionID.uuidString)")
    }

    func refreshSavedSessions() {
        refreshSavedSessionsCount += 1
    }

    func autoExportIfEnabled(sessionID: UUID) async {
        exportCount += 1
        exportedSessionIDs.append(sessionID)
        currentSessionIDsDuringExport.append(processingQueue.currentSessionID)
        eventLog.append("export:\(sessionID.uuidString)")
    }

    func processingDidChange(_ event: SessionProcessingEvent) {
        let description: String
        switch event {
        case .backlogged:
            description = "backlogged"
        case .held(let request):
            description = "held:\(request.sessionID.uuidString)"
        case .began(let request):
            description = "began:\(request.sessionID.uuidString)"
        case .liveFailed(let message):
            description = "liveFailed:\(message)"
        case .finished(let request, let result):
            description = "finished:\(request.sessionID.uuidString):\(result?.disposition.rawValue ?? "none")"
        case .next:
            description = "next"
        case .willFinishDrain:
            description = "willFinishDrain"
        case .drained:
            description = "drained"
        }
        eventOrder.append(description)
        eventLog.append(description)
        onEvent?(event)
    }
}

private actor ScriptedSessionProcessingExecutor: SessionProcessingExecuting {
    private var scriptedResults: [SessionProcessingResult]
    private var recordedOperations: [String] = []
    private var recordedShouldPauseValues: [Bool] = []
    private let eventLog: CoordinatorTestEventLog
    var retryWaitsForCancellation = false
    private(set) var retryCancellationObserved = false

    init(scriptedResults: [SessionProcessingResult], eventLog: CoordinatorTestEventLog) {
        self.scriptedResults = scriptedResults
        self.eventLog = eventLog
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
        record("processSession:\(sessionID.uuidString)")
        let paused = await shouldPause()
        recordedShouldPauseValues.append(paused)
        return nextResult()
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
        record("finishLiveTranscription:\(sessionID.uuidString)")
        let paused = await shouldPause()
        recordedShouldPauseValues.append(paused)
        return nextResult()
    }

    func retryContentPrioritySession(
        sessionID: UUID,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference],
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async {
        record("retryContentPriority:\(sessionID.uuidString)")
        if retryWaitsForCancellation {
            // Only cancellation ends the wait; the test's `.timeLimit` guards against a hang.
            do {
                while true { try await Task.sleep(nanoseconds: 60_000_000_000) }
            } catch is CancellationError {
                // The coordinator cancellation is the behavior under test.
            } catch {
                preconditionFailure("予期しない retry 待機エラー: \(error)")
            }
        }
        retryCancellationObserved = Task.isCancelled
    }

    func makeRetryWaitForCancellation() {
        retryWaitsForCancellation = true
    }

    func cancelLiveTranscription(sessionID: UUID) async {
        record("cancelLiveTranscription:\(sessionID.uuidString)")
    }

    func operations() -> [String] { recordedOperations }
    func shouldPauseValues() -> [Bool] { recordedShouldPauseValues }

    private func record(_ operation: String) {
        recordedOperations.append(operation)
        eventLog.append(operation)
    }

    private func nextResult() -> SessionProcessingResult {
        guard !scriptedResults.isEmpty else {
            preconditionFailure("処理結果のスクリプトが尽きました")
        }
        return scriptedResults.removeFirst()
    }
}

private func makeCoordinatorTestPauseResult() -> SessionProcessingResult {
    SessionProcessingResult(
        disposition: .paused,
        metrics: nil,
        message: "熱負荷により処理を中断しました",
        noSpeech: false,
        retainedTranscript: .nothing
    )
}

private func makeCoordinatorTestCompletedResult() -> SessionProcessingResult {
    .completed(metrics: nil, noSpeech: false)
}

private func makeCoordinatorTestFailedResult() -> SessionProcessingResult {
    .failed(message: "確定処理に失敗しました", metrics: nil, retained: nil)
}

private func makeRecoveryCandidate(
    sessionID: UUID,
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

@MainActor
@Test
func criticalHoldResumesInFIFOOrder() async {
    let thermalMonitor = CoordinatorTestThermalMonitor(pressure: .critical)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult(), makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: thermalMonitor
    )
    let firstSessionID = UUID()
    let secondSessionID = UUID()
    let retrySessionID = UUID()

    var queue = effects.processingQueue
    let firstSessionClaimed = queue.claimReprocessing(firstSessionID)
    #expect(firstSessionClaimed)
    let secondSessionClaimed = queue.claimReprocessing(secondSessionID)
    #expect(secondSessionClaimed)
    effects.processingQueue = queue
    coordinator.enqueue(.finalize(sessionID: firstSessionID, metadataPolicy: .reject))
    coordinator.enqueue(.finalize(sessionID: secondSessionID, metadataPolicy: .reject))
    coordinator.enqueue(.retryContentPriority(sessionID: retrySessionID, boundarySegments: [], clauses: []))

    await coordinator.waitUntilIdle()

    #expect(effects.processingQueue.thermallyHeld.map(\.sessionID) == [firstSessionID, secondSessionID])
    #expect(effects.processingQueue.claimedSessionIDs == Set([firstSessionID, secondSessionID]))
    #expect(await processor.operations() == ["retryContentPriority:\(retrySessionID.uuidString)"])
    #expect(effects.exportCount == 0)
    #expect(effects.queueSnapshots.contains {
        $0.thermallyHeldSessionIDs == [firstSessionID, secondSessionID]
            && $0.claimedSessionIDs == Set([firstSessionID, secondSessionID])
    })
    #expect(effects.queueSnapshots.contains {
        $0.pendingSessionIDs.contains(firstSessionID)
            && $0.claimedSessionIDs == Set([firstSessionID, secondSessionID])
    })

    thermalMonitor.setPressure(.fair)
    coordinator.resumeThermallyHeldProcessing()
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == [
        "retryContentPriority:\(retrySessionID.uuidString)",
        "processSession:\(firstSessionID.uuidString)",
        "processSession:\(secondSessionID.uuidString)"
    ])
    #expect(await processor.shouldPauseValues() == [false, false])
    #expect(effects.processingQueue.claimedSessionIDs.isEmpty)
    #expect(effects.processingQueue.thermallyHeld.isEmpty)
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(!coordinator.isDraining)
    #expect(effects.exportedSessionIDs == [firstSessionID, secondSessionID])
}

@MainActor
@Test
func pauseRetainsClaimAndCompletionReleasesIt() async throws {
    let thermalMonitor = CoordinatorTestThermalMonitor(pressure: .fair)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestPauseResult(), makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: thermalMonitor
    )
    let sessionID = UUID()

    var queue = effects.processingQueue
    let sessionClaimed = queue.claimReprocessing(sessionID)
    #expect(sessionClaimed)
    effects.processingQueue = queue
    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(effects.processingQueue.thermallyHeld.map(\.sessionID) == [sessionID])
    #expect(effects.processingQueue.claimedSessionIDs == [sessionID])

    coordinator.resumeThermallyHeldProcessing()
    await coordinator.waitUntilIdle()

    #expect(effects.processingQueue.claimedSessionIDs.isEmpty)
    #expect(effects.exportCount == 1)
    #expect(effects.exportedSessionIDs == [sessionID])
    #expect(effects.currentSessionIDsDuringExport == [sessionID])
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(await processor.operations() == [
        "processSession:\(sessionID.uuidString)",
        "processSession:\(sessionID.uuidString)"
    ])

    let heldIndex = try #require(effects.eventOrder.firstIndex(of: "held:\(sessionID.uuidString)"))
    let finishedIndex = try #require(effects.eventOrder.firstIndex(of: "finished:\(sessionID.uuidString):paused"))
    #expect(heldIndex < finishedIndex)
}

@MainActor
@Test
func failedFinalizationReleasesClaimWithoutExport() async {
    let thermalMonitor = CoordinatorTestThermalMonitor(pressure: .fair)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestFailedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: thermalMonitor
    )
    let sessionID = UUID()

    var queue = effects.processingQueue
    let sessionClaimed = queue.claimReprocessing(sessionID)
    #expect(sessionClaimed)
    effects.processingQueue = queue
    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(effects.processingQueue.claimedSessionIDs.isEmpty)
    #expect(effects.exportCount == 0)
    #expect(effects.exportedSessionIDs.isEmpty)
}

@MainActor
@Test
func pausedFinishLiveResumesAsStoredFinalization() async throws {
    let thermalMonitor = CoordinatorTestThermalMonitor(pressure: .fair)
    let eventLog = CoordinatorTestEventLog()
    let failureMessage = "ライブ文字起こしに失敗しました"
    let effects = CoordinatorEffectsFake(
        pausesProcessing: false,
        liveFailure: failureMessage,
        eventLog: eventLog
    )
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestPauseResult(), makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: thermalMonitor
    )
    let sessionID = UUID()
    let checkpoint = AudioCheckpoint(
        committedFrames: 0,
        sampleRate: 16_000,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: [],
        chunkFrameCounts: [],
        gapEvents: []
    )

    coordinator.enqueue(.finishLive(sessionID: sessionID, checkpoint: checkpoint))
    await coordinator.waitUntilIdle()

    #expect(effects.liveASRDrainWaitCount == 1)
    #expect(effects.liveASRCleanupCount == 1)
    #expect(effects.processingQueue.thermallyHeld.map(\.sessionID) == [sessionID])
    if let heldRequest = effects.processingQueue.thermallyHeld.first {
        if case .finalize(let heldSessionID, let metadataPolicy) = heldRequest {
            #expect(heldSessionID == sessionID)
            #expect(metadataPolicy == .reject)
        } else {
            #expect(Bool(false), "一時停止したライブ処理は確定処理として保持されます")
        }
    } else {
        #expect(Bool(false), "一時停止したライブ処理がキューに保持されていません")
    }

    let eventsBeforeResume = eventLog.events
    let waitIndex = try #require(eventsBeforeResume.firstIndex(of: "waitForLiveASRDrain:\(sessionID.uuidString)"))
    let cancellationIndex = try #require(eventsBeforeResume.firstIndex(of: "cancelLiveTranscription:\(sessionID.uuidString)"))
    let finishIndex = try #require(eventsBeforeResume.firstIndex(of: "finishLiveTranscription:\(sessionID.uuidString)"))
    #expect(waitIndex < cancellationIndex)
    #expect(waitIndex < finishIndex)

    coordinator.resumeThermallyHeldProcessing()
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == [
        "cancelLiveTranscription:\(sessionID.uuidString)",
        "finishLiveTranscription:\(sessionID.uuidString)",
        "processSession:\(sessionID.uuidString)"
    ])
    #expect(effects.liveASRDrainWaitCount == 1)
    #expect(effects.liveASRCleanupCount == 1)
    #expect(effects.exportedSessionIDs == [sessionID])
}

@MainActor
@Test
func pauseDuringLiveDrainSkipsFinishAndHoldsStoredFinalization() async {
    let thermalMonitor = CoordinatorTestThermalMonitor(pressure: .fair)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    effects.onLiveASRDrainWait = { effects.pausesProcessing = true }
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: thermalMonitor
    )
    let sessionID = UUID()
    let checkpoint = AudioCheckpoint(
        committedFrames: 0,
        sampleRate: 16_000,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: [],
        chunkFrameCounts: [],
        gapEvents: []
    )

    coordinator.enqueue(.finishLive(sessionID: sessionID, checkpoint: checkpoint))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == ["cancelLiveTranscription:\(sessionID.uuidString)"])
    #expect(effects.liveASRCleanupCount == 1)
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(effects.processingQueue.thermallyHeld.count == 1)
    if let heldRequest = effects.processingQueue.thermallyHeld.first {
        if case .finalize(let heldSessionID, let metadataPolicy) = heldRequest {
            #expect(heldSessionID == sessionID)
            #expect(metadataPolicy == .reject)
        } else {
            #expect(Bool(false), "一時停止したライブ処理は確定処理として保持されます")
        }
    }
    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):paused"))
    #expect(effects.eventOrder.suffix(2) == ["willFinishDrain", "drained"])
}

@MainActor
@Test(.timeLimit(.minutes(10)))
func cancelledRetryIsHeldAndFollowingRequestIsNotDequeued() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(scriptedResults: [], eventLog: eventLog)
    await processor.makeRetryWaitForCancellation()
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair)
    )
    let firstSessionID = UUID()
    let nextSessionID = UUID()
    coordinator.enqueue(.retryContentPriority(sessionID: firstSessionID, boundarySegments: [], clauses: []))
    coordinator.enqueue(.retryContentPriority(sessionID: nextSessionID, boundarySegments: [], clauses: []))

    let retryStarted = "retryContentPriority:\(firstSessionID.uuidString)"
    while !eventLog.events.contains(retryStarted) {
        await Task.yield()
    }
    coordinator.requestPause()
    await coordinator.waitUntilIdle()

    #expect(await processor.retryCancellationObserved)
    #expect(await processor.operations() == [retryStarted])
    #expect(effects.processingQueue.thermallyHeld.map(\.sessionID) == [firstSessionID])
    #expect(effects.processingQueue.pending.map(\.sessionID) == [nextSessionID])
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(effects.eventOrder.contains("finished:\(firstSessionID.uuidString):paused"))
    #expect(effects.exportCount == 0)
}

@MainActor
@Test
func pausedRetryIsHeldWithoutCallingExecutor() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(scriptedResults: [], eventLog: eventLog)
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair)
    )
    let sessionID = UUID()
    effects.onEvent = { event in
        if case .began = event {
            effects.pausesProcessing = true
        }
    }

    coordinator.enqueue(.retryContentPriority(sessionID: sessionID, boundarySegments: [], clauses: []))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations().isEmpty)
    #expect(effects.processingQueue.thermallyHeld.map(\.sessionID) == [sessionID])
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):paused"))
}

@MainActor
@Test
func pauseOnFinishedNotificationSkipsAutoExport() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair)
    )
    let sessionID = UUID()
    effects.onEvent = { event in
        if case .finished = event {
            effects.pausesProcessing = true
        }
    }

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):completed"))
    #expect(effects.exportCount == 0)
    #expect(effects.exportedSessionIDs.isEmpty)
    #expect(effects.eventOrder.suffix(2) == ["willFinishDrain", "drained"])
}

@MainActor
@Test
func recoveryFilteringExcludesRecordingMaintenanceFailuresPendingAndPublishedRetries() throws {
    let finalizeID = UUID()
    let recordingID = UUID()
    let recoverDecisionID = UUID()
    let maintenanceFailureID = UUID()
    let interruptedMaintenanceID = UUID()
    let pendingID = UUID()
    let publishedRetryID = UUID()
    let boundarySegments = [try SegmentTextReference(
        segmentationRunID: "segmentation_run",
        segmentID: "segment_0001",
        asrRunID: "asr_run",
        asrEventSeq: 1
    )]
    let clauses = [try ClauseReference(boundaryRunID: "boundary_run", clauseID: "clause_0001")]
    let candidates = [
        makeRecoveryCandidate(sessionID: finalizeID, action: .finalize),
        makeRecoveryCandidate(sessionID: recordingID, action: .finalize),
        makeRecoveryCandidate(
            sessionID: recoverDecisionID,
            action: .recoverDecisionRun(boundarySegments: boundarySegments, clauses: clauses)
        ),
        makeRecoveryCandidate(sessionID: maintenanceFailureID, action: .finalize),
        makeRecoveryCandidate(sessionID: interruptedMaintenanceID, action: .finalize),
        makeRecoveryCandidate(sessionID: pendingID, action: .finalize),
        makeRecoveryCandidate(
            sessionID: publishedRetryID,
            action: .retryContentPriority(boundarySegments: boundarySegments, clauses: clauses)
        )
    ]
    let pending = [PendingProcessing.finalize(sessionID: pendingID, metadataPolicy: .reject)]

    let requests = SessionProcessingCoordinator.recoveryRequests(
        candidates: candidates,
        recordingSessionID: recordingID,
        maintenanceFailures: [
            maintenanceFailureID: .failed("保存領域の保守に失敗しました"),
            interruptedMaintenanceID: .interruptedByShutdown("終了時に保守が中断されました")
        ],
        pending: pending
    )

    #expect(requests.map(\.sessionID) == [finalizeID, recoverDecisionID])
    #expect(!requests.contains { $0.sessionID == maintenanceFailureID })
    #expect(!requests.contains { $0.sessionID == interruptedMaintenanceID })
    if case .finalize(let sessionID, let metadataPolicy) = requests[0] {
        #expect(sessionID == finalizeID)
        #expect(metadataPolicy == .reject)
    } else {
        #expect(Bool(false), "復旧候補は確定処理へ変換されます")
    }
    if case .retryContentPriority(let sessionID, let mappedBoundarySegments, let mappedClauses) = requests[1] {
        #expect(sessionID == recoverDecisionID)
        #expect(mappedBoundarySegments == boundarySegments)
        #expect(mappedClauses == clauses)
    } else {
        #expect(Bool(false), "未公開の判定 run は優先度再処理へ変換されます")
    }
}

@MainActor
@Test
func processingCompletionPublishesBeforeTaskReleaseThenAllowsIdleRelease() async {
    let thermalMonitor = CoordinatorTestThermalMonitor(pressure: .fair)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: thermalMonitor
    )
    var drainingObservations: [Bool] = []
    effects.onEvent = { event in
        switch event {
        case .willFinishDrain, .drained:
            drainingObservations.append(coordinator.isDraining)
        case .backlogged, .held, .began, .liveFailed, .finished, .next:
            break
        }
    }
    let sessionID = UUID()

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(drainingObservations == [true, false])
    #expect(effects.eventOrder.suffix(2) == ["willFinishDrain", "drained"])
}

@MainActor
@Test
func retainedFinalizeRequestRunsExactlyOneFinalization() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair)
    )
    let sessionID = UUID()

    coordinator.enqueue(SessionFinalizeRequest(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == ["processSession:\(sessionID.uuidString)"])
    #expect(effects.exportedSessionIDs == [sessionID])
}
