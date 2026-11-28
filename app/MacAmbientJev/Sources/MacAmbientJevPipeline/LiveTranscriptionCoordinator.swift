import Foundation
import MacAmbientJevCore

public protocol LiveTranscriptionExecuting: Sendable {
    /// Creates the generation and returns its segmentation run ID.
    func startLiveTranscription(
        sessionID: UUID,
        sampleRate: Double,
        onGenerationOpened: @escaping NativeSessionProcessor.GenerationOpenedHandler
    ) async throws -> String

    func registerLiveSegments(
        sessionID: UUID,
        segments: [SegmentReference]
    ) async throws -> LiveASRProgress

    /// Durably seals the segmentation input at its final length, before the VAD's EOF flush.
    func sealLiveSegmentation(sessionID: UUID, frameCount: Int64) async throws

    /// Records that every segment the VAD emitted is saved.
    func completeLiveSegmentation(sessionID: UUID, frameCount: Int64, segmentCount: Int) async throws

    func processLiveSegments(
        sessionID: UUID,
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck,
        onStatus: NativeSessionProcessor.StatusHandler?,
        onUpdate: NativeSessionProcessor.UpdateHandler?
    ) async throws -> LiveASRProgress

    func cancelLiveTranscription(sessionID: UUID) async
}

extension NativeSessionProcessor: LiveTranscriptionExecuting {}

public enum LiveASRDrainOutcome: Sendable, Equatable {
    case drained
    /// The live worker waits for cooling and keeps its unfinished segments.
    case suspendedForCooling
}

public enum LiveTranscriptionEvent: Sendable, Equatable {
    case started(UUID)
    case startFailed(UUID, String)
    case registrationFailed(UUID, String)
    case recognitionFailed(UUID, String)
    case thermal(UUID, String)
    case vadProgress(UUID, LiveVADProgress)
    case vadSegmentsEnqueued(UUID, Int)
    case vadFailed(UUID, String)
    /// Live recognition is off because the models are not ready; finalization covers the session.
    case waitingForModels(UUID)
}

@MainActor
public protocol LiveTranscriptionEffects: AnyObject {
    var recordingSessionID: UUID? { get }
    func isCurrentRecording(_ sessionID: UUID) -> Bool
    func committedLiveCheckpoint() async throws -> AudioCheckpoint
    func awaitIdleRelease() async
    var modelPhase: ModelPreparationStatus.Phase { get }
    /// Returns when the running model preparation has finished.
    func awaitModelPreparation() async
    func liveStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler
    func liveUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler
    func liveGenerationDidOpen(sessionID: UUID, generationID: UUID)
    func liveDidChange(_ event: LiveTranscriptionEvent)
}

@MainActor
public final class LiveTranscriptionCoordinator {
    private let state: LiveTranscriptionState
    private weak var effects: (any LiveTranscriptionEffects)?
    private let processor: any LiveTranscriptionExecuting
    private let thermalMonitor: any ThermalMonitoring
    private let sleep: @MainActor (Duration) async throws -> Void
    private let resourceMonitor: (any InferenceResourceMonitoring)?
    private var resourceObservation: (any InferenceResourceObservation)? = nil
    private var resourceSuspensions: Set<UUID> = []
    private var vadSession: (sessionID: UUID, session: any LiveVADProcessing)?
    private var vadTask: Task<Void, Never>?
    private var vadTaskID: UUID?
    private var vadStopRequested = false
    private var vadSleepTask: Task<Void, Error>?
    private var asrTasks: [UUID: Task<Void, Never>] = [:]
    private var asrTaskIDs: [UUID: UUID] = [:]
    private var retiredASRTasks: [UUID: Task<Void, Never>] = [:]
    private var retiredASRTaskSessionIDs: [UUID: UUID] = [:]
    /// Sessions whose live worker waits for cooling; a finalization must not wait for them.
    private var thermalSuspensions: Set<UUID> = []
    /// Sessions whose segment gate stopped a batch, so the worker waits for cooling and continues.
    private var gatedSessions: Set<UUID> = []
    private var drainWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init(
        state: LiveTranscriptionState,
        effects: any LiveTranscriptionEffects,
        processor: any LiveTranscriptionExecuting,
        thermalMonitor: any ThermalMonitoring,
        resourceMonitor: (any InferenceResourceMonitoring)?,
        sleep: @escaping @MainActor (Duration) async throws -> Void
    ) {
        self.state = state
        self.effects = effects
        self.processor = processor
        self.thermalMonitor = thermalMonitor
        self.resourceMonitor = resourceMonitor
        self.sleep = sleep
        self.resourceObservation = resourceMonitor?.observeChanges { [weak self] in
            guard let self, let sessionID = self.effects?.recordingSessionID else { return }
            _ = self.suspendForResources(sessionID: sessionID)
        }
    }

    public var isASRIdle: Bool {
        asrTasks.isEmpty && retiredASRTasks.isEmpty && state.isQueueEmpty
    }

    public var processingWorkerSessionIDs: Set<UUID> {
        Set(asrTasks.keys)
            .union(retiredASRTaskSessionIDs.values)
            .union(vadSession.map { [$0.sessionID] } ?? [])
    }

    public func hasWork(sessionID: UUID) -> Bool {
        asrTasks[sessionID] != nil
            || retiredASRTaskSessionIDs.values.contains(sessionID)
            || state.hasQueued(sessionID: sessionID)
            || vadSession?.sessionID == sessionID
    }

    public func isDraining(sessionID: UUID) -> Bool {
        asrTasks[sessionID] != nil
    }

    /// The generation is created first; the VAD session takes its segmentation run ID from it.
    public func startVAD(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        makeSession: (String) async throws -> any LiveVADProcessing
    ) async throws {
        guard !suspendForResources(sessionID: sessionID) else { return }
        let effects = requiredEffects
        state.vadFailureText = nil
        state.vadSegmentCount = 0
        effects.liveDidChange(.started(sessionID))

        let segmentationRunID: String
        do {
            segmentationRunID = try await processor.startLiveTranscription(
                sessionID: sessionID,
                sampleRate: checkpoint.sampleRate,
                onGenerationOpened: { generationID in
                    effects.liveGenerationDidOpen(sessionID: sessionID, generationID: generationID)
                }
            )
        } catch {
            // Without a generation there is no live VAD; stop reprocesses the whole recording.
            state.recordFailure(sessionID: sessionID, message: error.localizedDescription, discardQueued: false)
            effects.liveDidChange(.startFailed(sessionID, error.localizedDescription))
            return
        }
        let session: any LiveVADProcessing
        do {
            session = try await makeSession(segmentationRunID)
        } catch {
            cleanup(sessionID: sessionID)
            await processor.cancelLiveTranscription(sessionID: sessionID)
            throw error
        }

        guard effects.isCurrentRecording(sessionID) else {
            cleanup(sessionID: sessionID)
            await processor.cancelLiveTranscription(sessionID: sessionID)
            return
        }

        await stopVADPolling()
        guard effects.isCurrentRecording(sessionID) else {
            cleanup(sessionID: sessionID)
            await processor.cancelLiveTranscription(sessionID: sessionID)
            return
        }
        guard !resourceSuspensions.contains(sessionID) else { return }

        // Installed only now: a later recording may own the slot by the time a slow factory returns.
        vadSession = (sessionID, session)
        vadStopRequested = false
        let taskID = UUID()
        vadTaskID = taskID
        vadTask = Task { [weak self] in
            await self?.runVADLoop(sessionID: sessionID)
        }
    }

    public func stopVADPolling() async {
        vadStopRequested = true
        vadSleepTask?.cancel()
        guard let task = vadTask, let taskID = vadTaskID else { return }
        _ = await task.value
        if vadTaskID == taskID {
            vadTask = nil
            vadTaskID = nil
        }
    }

    public func finishVAD(sessionID: UUID, checkpoint: AudioCheckpoint) async {
        guard !resourceSuspensions.contains(sessionID),
              let active = vadSession, active.sessionID == sessionID else { return }
        do {
            // Sealed before the EOF flush, completed only after every emitted segment is saved. A recorded
            // failure leaves the segmentation open, so stop reopens the sessions and surfaces the failure.
            try await processor.sealLiveSegmentation(sessionID: sessionID, frameCount: checkpoint.committedFrames)
            let progress = try await active.session.finish(checkpoint: checkpoint)
            state.vadSegmentCount = progress.totalSegmentCount
            await enqueue(
                sessionID: sessionID,
                segments: progress.emittedSegments,
                checkpoint: checkpoint
            )
            // A VAD that failed earlier does not certify the segmentation, even if its EOF flush worked.
            if state.failure(sessionID: sessionID) == nil, state.vadFailureText == nil {
                try await processor.completeLiveSegmentation(
                    sessionID: sessionID, frameCount: checkpoint.committedFrames,
                    segmentCount: progress.totalSegmentCount
                )
            }
        } catch {
            state.vadFailureText = error.localizedDescription
        }
        if vadSession?.sessionID == sessionID {
            vadSession = nil
        }
    }

    public func resetVAD() {
        vadStopRequested = true
        vadSleepTask?.cancel()
        vadSession = nil
        state.resetVAD()
    }

    public func finishRecording(
        sessionID: UUID,
        failureMessage: String?,
        processing: SessionProcessingCoordinator,
        effects: any RecordingFinishEffects
    ) async {
        processing.claimStopHandoff(sessionID: sessionID)
        var stopClaimHeld = true
        defer {
            if stopClaimHeld { processing.releaseStopHandoff(sessionID: sessionID) }
        }
        do {
            let result = try await effects.stopCapture()
            await stopVADPolling()
            effects.captureStopped(dropoutCount: result.dropoutCount)
            let checkpoint = result.checkpoint

            if let writerFailure = result.writerFailure {
                let message = Self.combinedFailureMessage(
                    writerFailure, result.systemAudioReleaseFailure
                ) ?? writerFailure
                resetVAD()
                cleanup(sessionID: sessionID)
                await processor.cancelLiveTranscription(sessionID: sessionID)
                effects.recordingDidFinish(.failed(message))
                processing.enqueue(
                    .finalize(sessionID: sessionID, metadataPolicy: .reject)
                )
                effects.refreshSavedSessions()
                return
            }

            let stopFailureMessage = Self.combinedFailureMessage(
                failureMessage, result.systemAudioReleaseFailure
            )
            await finishVAD(sessionID: sessionID, checkpoint: checkpoint)
            effects.recordingDidFinish(
                .saved(
                    result: result,
                    failureMessage: stopFailureMessage,
                    vadFailureText: state.vadFailureText,
                    vadSegmentCount: state.vadSegmentCount
                )
            )

            // Stop drains the live worker in place. Without complete live segmentation there is no worker to keep.
            if state.vadFailureText != nil || resourceSuspensions.contains(sessionID) {
                cleanup(sessionID: sessionID)
                await processor.cancelLiveTranscription(sessionID: sessionID)
            }
            processing.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))

            if failureMessage != nil { effects.refreshSavedSessions() }
            resetVAD()
        } catch {
            await stopVADPolling()
            resetVAD()
            cleanup(sessionID: sessionID)
            await processor.cancelLiveTranscription(sessionID: sessionID)
            effects.recordingDidFinish(
                .failed(Self.combinedFailureMessage(failureMessage, error.localizedDescription))
            )
            if failureMessage != nil { effects.refreshSavedSessions() }
            processing.releaseStopHandoff(sessionID: sessionID)
            stopClaimHeld = false
            effects.releaseIdleResourcesIfIdle()
        }
    }

    public func enqueue(
        sessionID: UUID,
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint
    ) async {
        guard !segments.isEmpty,
              state.failure(sessionID: sessionID) == nil else {
            return
        }

        do {
            _ = try await processor.registerLiveSegments(
                sessionID: sessionID,
                segments: segments
            )
        } catch {
            state.recordFailure(
                sessionID: sessionID,
                message: error.localizedDescription,
                discardQueued: false
            )
            requiredEffects.liveDidChange(.registrationFailed(sessionID, error.localizedDescription))
            return
        }

        // Do not restore the queue when an ASR failure discards it during registration.
        guard state.failure(sessionID: sessionID) == nil else { return }

        // Batches are not kept for later: they wait only while the models verify and load.
        switch requiredEffects.modelPhase {
        case .ready, .loading:
            break
        case .idle, .downloading, .failed:
            requiredEffects.liveDidChange(.waitingForModels(sessionID))
            return
        }

        state.enqueue(
            sessionID: sessionID,
            segments: segments,
            checkpoint: checkpoint
        )
        startDrainIfIdle(sessionID: sessionID)
    }

    public func startDrainIfIdle(sessionID: UUID) {
        guard asrTasks[sessionID] == nil else { return }
        let taskID = UUID()
        asrTaskIDs[sessionID] = taskID
        asrTasks[sessionID] = Task { [weak self] in
            await self?.drain(sessionID: sessionID, taskID: taskID)
        }
    }

    /// Returns when the live worker has drained, or when it waits for cooling: a finalization parks then
    /// and keeps the worker, so the queue never blocks behind heat.
    @discardableResult
    public func waitForDrain(sessionID: UUID) async -> LiveASRDrainOutcome {
        while let task = asrTasks[sessionID] {
            if thermalSuspensions.contains(sessionID), thermalMonitor.liveASRDecision == .suspendUntilCooled {
                return .suspendedForCooling
            }
            // Woken by the task's end or by a suspension, whichever comes first.
            await withCheckedContinuation { waiter in
                drainWaiters[sessionID, default: []].append(waiter)
                Task { @MainActor [weak self] in
                    await task.value
                    self?.wakeDrainWaiters(sessionID: sessionID)
                }
            }
        }
        return .drained
    }

    private func wakeDrainWaiters(sessionID: UUID) {
        for waiter in drainWaiters.removeValue(forKey: sessionID) ?? [] { waiter.resume() }
    }

    private func setThermalSuspended(_ suspended: Bool, sessionID: UUID) {
        if suspended {
            if thermalSuspensions.insert(sessionID).inserted { wakeDrainWaiters(sessionID: sessionID) }
        } else {
            thermalSuspensions.remove(sessionID)
        }
    }

    public func cancelAndWait(sessionIDs: Set<UUID>) async {
        let activeTasks = asrTasks.map { (sessionID: $0.key, task: $0.value) }
        let retiredTasks = retiredASRTasks.map { (taskID: $0.key, task: $0.value) }
        let retiredSessionIDs = Set(retiredTasks.compactMap {
            retiredASRTaskSessionIDs[$0.taskID]
        })
        let allSessionIDs = sessionIDs
            .union(activeTasks.map { $0.sessionID })
            .union(retiredSessionIDs)

        for (_, task) in activeTasks {
            task.cancel()
        }
        for (_, task) in retiredTasks {
            task.cancel()
        }
        for sessionID in allSessionIDs {
            await processor.cancelLiveTranscription(sessionID: sessionID)
        }
        for (_, task) in activeTasks {
            await task.value
        }
        for (_, task) in retiredTasks {
            await task.value
        }
        for sessionID in allSessionIDs {
            cleanup(sessionID: sessionID)
        }
    }

    public func cleanup(sessionID: UUID) {
        if let task = asrTasks[sessionID], let taskID = asrTaskIDs[sessionID] {
            task.cancel()
            retiredASRTasks[taskID] = task
            retiredASRTaskSessionIDs[taskID] = sessionID
        }
        asrTasks.removeValue(forKey: sessionID)
        asrTaskIDs.removeValue(forKey: sessionID)
        resourceSuspensions.remove(sessionID)
        thermalSuspensions.remove(sessionID)
        gatedSessions.remove(sessionID)
        state.cleanup(sessionID: sessionID)
    }

    private static func combinedFailureMessage(
        _ primary: String?, _ additional: String?
    ) -> String? {
        let messages = [primary, additional].compactMap { $0 }.filter { !$0.isEmpty }
        guard !messages.isEmpty else { return nil }
        return messages.reduce(into: [String]()) { unique, message in
            if !unique.contains(message) { unique.append(message) }
        }.joined(separator: "。")
    }

    private var requiredEffects: any LiveTranscriptionEffects {
        guard let effects else {
            preconditionFailure("ライブ文字起こしの効果提供元が解放されています")
        }
        return effects
    }

    private func suspendForResources(sessionID: UUID) -> Bool {
        if resourceSuspensions.contains(sessionID) { return true }
        guard let reason = resourceMonitor?.signal.holdReason else { return false }
        resourceSuspensions.insert(sessionID)
        state.recordFailure(
            sessionID: sessionID, message: reason.liveExplanation, discardQueued: true
        )
        vadStopRequested = true
        vadSleepTask?.cancel()
        requiredEffects.liveDidChange(.recognitionFailed(sessionID, reason.liveExplanation))
        return true
    }

    private func runVADLoop(sessionID: UUID) async {
        while !vadStopRequested,
              let pollingEffects = effects,
              pollingEffects.isCurrentRecording(sessionID) {
            guard await sleepForVADPoll() else { return }

            guard !vadStopRequested,
                  let effects,
                  effects.recordingSessionID == sessionID,
                  let active = vadSession,
                  active.sessionID == sessionID else {
                return
            }

            do {
                let checkpoint = try await effects.committedLiveCheckpoint()
                guard !suspendForResources(sessionID: sessionID) else { return }
                let progress = try await active.session.processAvailable(checkpoint: checkpoint)
                state.vadSegmentCount = progress.totalSegmentCount
                effects.liveDidChange(.vadProgress(sessionID, progress))
                if !progress.emittedSegments.isEmpty {
                    await enqueue(
                        sessionID: sessionID,
                        segments: progress.emittedSegments,
                        checkpoint: checkpoint
                    )
                    effects.liveDidChange(.vadSegmentsEnqueued(sessionID, progress.totalSegmentCount))
                }
            } catch {
                state.vadFailureText = error.localizedDescription
                effects.liveDidChange(.vadFailed(sessionID, error.localizedDescription))
                return
            }
        }
    }

    private func sleepForVADPoll() async -> Bool {
        guard !vadStopRequested else { return false }
        let sleep = self.sleep
        let task = Task<Void, Error> {
            try await sleep(
                .milliseconds(LiveTranscriptionCadence.checkpointPollIntervalMilliseconds)
            )
        }
        vadSleepTask = task
        do {
            try await task.value
            vadSleepTask = nil
            return !vadStopRequested
        } catch {
            vadSleepTask = nil
            return false
        }
    }

    private func drain(sessionID: UUID, taskID: UUID) async {
        defer {
            retiredASRTasks[taskID] = nil
            retiredASRTaskSessionIDs[taskID] = nil
            if asrTaskIDs[sessionID] == taskID {
                asrTasks[sessionID] = nil
                asrTaskIDs[sessionID] = nil
                thermalSuspensions.remove(sessionID)
                gatedSessions.remove(sessionID)
            }
        }
        let effects = requiredEffects
        await effects.awaitIdleRelease()
        guard !Task.isCancelled, asrTaskIDs[sessionID] == taskID else { return }

        while state.failure(sessionID: sessionID) == nil && state.hasQueued(sessionID: sessionID) {
            if effects.modelPhase == .loading {
                await effects.awaitModelPreparation()
            }
            guard !Task.isCancelled, asrTaskIDs[sessionID] == taskID else { return }
            guard effects.modelPhase == .ready else {
                state.discardQueued(sessionID: sessionID)
                effects.liveDidChange(.waitingForModels(sessionID))
                break
            }
            do {
                try await waitUntilCooled(sessionID: sessionID)
            } catch {
                break
            }
            guard state.failure(sessionID: sessionID) == nil else { break }

            guard !suspendForResources(sessionID: sessionID) else { break }
            guard !Task.isCancelled, asrTaskIDs[sessionID] == taskID else { return }
            guard let batch = state.dequeue(sessionID: sessionID) else { break }
            while true {
                do {
                    _ = try await processor.processLiveSegments(
                        sessionID: sessionID,
                        segments: batch.segments,
                        checkpoint: batch.checkpoint,
                        shouldPause: { [self] point in try await gateBeforeSegment(sessionID: sessionID, at: point) },
                        onStatus: effects.liveStatusHandler(sessionID: sessionID),
                        onUpdate: effects.liveUpdateHandler(sessionID: sessionID)
                    )
                } catch {
                    guard !Task.isCancelled, asrTaskIDs[sessionID] == taskID else { return }
                    state.recordFailure(
                        sessionID: sessionID,
                        message: error.localizedDescription,
                        discardQueued: true
                    )
                    effects.liveDidChange(.recognitionFailed(sessionID, error.localizedDescription))
                    break
                }
                // The gate stopped the batch at heat: after cooling the same batch continues its unfinished
                // segments with its own checkpoint. A failure recorded while cooling ends the worker.
                guard gatedSessions.remove(sessionID) != nil else { break }
                do { try await waitUntilCooled(sessionID: sessionID) } catch { break }
                guard state.failure(sessionID: sessionID) == nil else { break }
            }
        }

        guard asrTaskIDs[sessionID] == taskID else { return }
        asrTasks[sessionID] = nil
        asrTaskIDs[sessionID] = nil

        if !Task.isCancelled,
           state.failure(sessionID: sessionID) == nil,
           state.hasQueued(sessionID: sessionID) {
            startDrainIfIdle(sessionID: sessionID)
        }
    }

    /// Thermal pressure throttles the live worker before and after stop alike; the queue retains its oldest segments.
    private func waitUntilCooled(sessionID: UUID) async throws {
        let effects = requiredEffects
        while state.failure(sessionID: sessionID) == nil,
              thermalMonitor.liveASRDecision == .suspendUntilCooled {
            setThermalSuspended(true, sessionID: sessionID)
            effects.liveDidChange(
                .thermal(sessionID, UserFacingStatus.liveTranscriptionThermalSuspended.text)
            )
            try await sleep(.milliseconds(LiveTranscriptionCadence.thermalRecheckIntervalMilliseconds))
        }
        setThermalSuspended(false, sessionID: sessionID)
    }

    /// The live side of the shared per-segment gate: serious paces, critical stops the batch.
    private func gateBeforeSegment(sessionID: UUID, at point: InferenceGatePoint) async throws -> InferenceHoldReason? {
        if point == .dispatch, case .wait = thermalMonitor.liveASRDecision {
            let pendingCount = state.pendingSegmentCount(sessionID: sessionID)
            requiredEffects.liveDidChange(
                .thermal(sessionID, "発熱を抑えるため文字起こしを調整中（未処理 \(pendingCount)区間）")
            )
        }
        let reason = try await thermalMonitor.inferenceGate(at: point, sleep: sleep)
        if reason != nil {
            gatedSessions.insert(sessionID)
            setThermalSuspended(true, sessionID: sessionID)
        }
        return reason
    }
}
