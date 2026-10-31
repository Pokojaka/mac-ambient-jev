import Foundation
import MacAmbientJevCore

public protocol LiveTranscriptionExecuting: Sendable {
    func startLiveTranscription(
        sessionID: UUID,
        segmentationRunID: String,
        sampleRate: Double
    ) async throws -> String

    func registerLiveSegments(
        sessionID: UUID,
        segments: [SegmentReference]
    ) async throws -> LiveASRProgress

    func processLiveSegments(
        sessionID: UUID,
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint,
        onStatus: NativeSessionProcessor.StatusHandler?,
        onUpdate: NativeSessionProcessor.UpdateHandler?
    ) async throws -> LiveASRProgress

    func cancelLiveTranscription(sessionID: UUID) async
}

extension NativeSessionProcessor: LiveTranscriptionExecuting {}

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
    func liveDidChange(_ event: LiveTranscriptionEvent)
}

@MainActor
public final class LiveTranscriptionCoordinator {
    private let state: LiveTranscriptionState
    private weak var effects: (any LiveTranscriptionEffects)?
    private let processor: any LiveTranscriptionExecuting
    private let thermalMonitor: any ThermalMonitoring
    private let sleep: @MainActor (Duration) async throws -> Void
    private var vadSession: (sessionID: UUID, session: any LiveVADProcessing)?
    private var vadTask: Task<Void, Never>?
    private var vadTaskID: UUID?
    private var vadStopRequested = false
    private var vadSleepTask: Task<Void, Error>?
    private var asrTasks: [UUID: Task<Void, Never>] = [:]
    private var asrTaskIDs: [UUID: UUID] = [:]
    private var retiredASRTasks: [UUID: Task<Void, Never>] = [:]
    private var retiredASRTaskSessionIDs: [UUID: UUID] = [:]

    public init(
        state: LiveTranscriptionState,
        effects: any LiveTranscriptionEffects,
        processor: any LiveTranscriptionExecuting,
        thermalMonitor: any ThermalMonitoring,
        sleep: @escaping @MainActor (Duration) async throws -> Void
    ) {
        self.state = state
        self.effects = effects
        self.processor = processor
        self.thermalMonitor = thermalMonitor
        self.sleep = sleep
    }

    public var isASRIdle: Bool {
        asrTasks.isEmpty && retiredASRTasks.isEmpty && state.isQueueEmpty
    }

    public func isDraining(sessionID: UUID) -> Bool {
        asrTasks[sessionID] != nil
    }

    public func startVAD(
        sessionID: UUID,
        session: any LiveVADProcessing,
        checkpoint: AudioCheckpoint
    ) async {
        let effects = requiredEffects
        state.vadFailureText = nil
        state.vadSegmentCount = 0
        vadSession = (sessionID, session)
        effects.liveDidChange(.started(sessionID))

        do {
            _ = try await processor.startLiveTranscription(
                sessionID: sessionID,
                segmentationRunID: session.segmentationRunID,
                sampleRate: checkpoint.sampleRate
            )
        } catch {
            state.recordFailure(
                sessionID: sessionID,
                message: error.localizedDescription,
                discardQueued: false
            )
            effects.liveDidChange(.startFailed(sessionID, error.localizedDescription))
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
        guard let active = vadSession, active.sessionID == sessionID else { return }
        do {
            let progress = try await active.session.finish(checkpoint: checkpoint)
            state.vadSegmentCount = progress.totalSegmentCount
            await enqueue(
                sessionID: sessionID,
                segments: progress.emittedSegments,
                checkpoint: checkpoint
            )
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

            if state.vadFailureText == nil {
                processing.enqueue(
                    .finishLive(sessionID: sessionID, checkpoint: checkpoint)
                )
            } else {
                cleanup(sessionID: sessionID)
                await processor.cancelLiveTranscription(sessionID: sessionID)
                processing.enqueue(
                    .finalize(sessionID: sessionID, metadataPolicy: .reject)
                )
            }

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

    public func waitForDrain(sessionID: UUID) async {
        while let task = asrTasks[sessionID] {
            _ = await task.value
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
                try await waitForThermalHeadroom(sessionID: sessionID)
            } catch {
                break
            }

            guard !Task.isCancelled, asrTaskIDs[sessionID] == taskID else { return }
            guard let batch = state.dequeue(sessionID: sessionID) else { break }
            do {
                _ = try await processor.processLiveSegments(
                    sessionID: sessionID,
                    segments: batch.segments,
                    checkpoint: batch.checkpoint,
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

    /// Thermal pressure only throttles live transcription during recording; the queue retains its oldest segments.
    private func waitForThermalHeadroom(sessionID: UUID) async throws {
        let effects = requiredEffects
        while effects.isCurrentRecording(sessionID) {
            switch thermalMonitor.liveASRDecision {
            case .processNow:
                return
            case .wait(let delay):
                let pendingCount = state.pendingSegmentCount(sessionID: sessionID)
                effects.liveDidChange(
                    .thermal(sessionID, "発熱を抑えるため文字起こしを調整中（未処理 \(pendingCount)区間）")
                )
                try await sleep(delay)
                return
            case .suspendUntilCooled:
                effects.liveDidChange(
                    .thermal(sessionID, UserFacingStatus.liveTranscriptionThermalSuspended.text)
                )
                try await sleep(
                    .milliseconds(LiveTranscriptionCadence.thermalRecheckIntervalMilliseconds)
                )
            }
        }
    }
}
