import Foundation
import MacAmbientJevCore

public struct LiveASRProgress: Sendable, Equatable {
    public let materializedSegments: [MaterializedTranscriptSegment]
    public let completedCount: Int
    public let failedCount: Int
    public let pendingCount: Int

    public init(
        materializedSegments: [MaterializedTranscriptSegment],
        completedCount: Int,
        failedCount: Int,
        pendingCount: Int
    ) {
        self.materializedSegments = materializedSegments
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.pendingCount = pendingCount
    }
}

/// One registered live segment and what its ASR produced so far.
public struct LiveASRSegmentStatus: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case pending
        /// The text may be empty: an empty result ends the text stream for boundary requests.
        case recognized(SegmentTextReference, String)
        case failed
    }

    public let segmentID: String
    public let startFrame: Int64
    public let outcome: Outcome

    public init(segmentID: String, startFrame: Int64, outcome: Outcome) {
        self.segmentID = segmentID
        self.startFrame = startFrame
        self.outcome = outcome
    }
}

public struct LiveASRSnapshot: Sendable, Equatable {
    public let events: [TranscriptEvent]
    public let activeRuns: ActiveRuns
    public let progress: LiveASRProgress
    /// Every registered segment in time order.
    public let segments: [LiveASRSegmentStatus]

    public init(events: [TranscriptEvent], activeRuns: ActiveRuns, progress: LiveASRProgress, segments: [LiveASRSegmentStatus]) {
        self.events = events
        self.activeRuns = activeRuns
        self.progress = progress
        self.segments = segments
    }
}

public struct LiveASRCompletion: Sendable, Equatable {
    public let events: [TranscriptEvent]
    public let materializedSegments: [MaterializedTranscriptSegment]
    public let completedCount: Int
    public let failedCount: Int
    public let pendingCount: Int

    public var succeeded: Bool {
        failedCount == 0 && pendingCount == 0
    }

    public init(
        events: [TranscriptEvent],
        materializedSegments: [MaterializedTranscriptSegment],
        completedCount: Int,
        failedCount: Int,
        pendingCount: Int
    ) {
        self.events = events
        self.materializedSegments = materializedSegments
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.pendingCount = pendingCount
    }
}

public enum LiveASRSessionError: LocalizedError {
    case foreignClauseEvent
    case segmentationNotSealed
    case segmentationSegmentCountMismatch(registered: Int, expected: Int)
    case segmentBeyondCheckpoint(segmentID: String, endFrame: Int64, committedFrames: Int64)

    public var errorDescription: String? {
        switch self {
        case .segmentBeyondCheckpoint(let segmentID, let endFrame, let committedFrames):
            "区間 \(segmentID) の終端（\(endFrame) frame）が、渡された音声の確定範囲（\(committedFrames) frame）を超えています"
        case .foreignClauseEvent: "ライブ文字起こしと別の判定を表示しようとしました"
        case .segmentationNotSealed: "VAD の入力が確定していないため、区間検出を完了できません"
        case .segmentationSegmentCountMismatch(let registered, let expected):
            "保存した発話区間（\(registered)）が VAD の区間数（\(expected)）と一致しません"
        }
    }
}

/// Incremental ASR run used while recording.
///
/// Detection and transcription are intentionally separate. register first
/// persists segment.created, making the backlog recoverable before model
/// inference starts. process is idempotent for both registration
/// and transcription.
public actor LiveASRSession {
    public nonisolated let segmentationRunID: String
    public nonisolated let asrRunID: String

    private let sessionID: UUID
    private let sessionURL: URL
    private let generationID: UUID
    private let processingDirectory: URL
    private let writer: any SessionEventAppending
    private let asr: any ASREngine
    private let materializer: IncrementalTranscriptMaterializer

    private let clauseBoundaryRunID: String?
    private let contentPriorityRunID: String?
    private var transcriptEvents: [TranscriptEvent] = []
    private var segmentStatuses: [LiveASRSegmentStatus] = []
    private var segmentStatusIndex: [String: Int] = [:]
    private var registeredSegments: [String: SegmentReference] = [:]
    private var registeringSegmentIDs: Set<String> = []
    private var pendingSince: [String: Date] = [:]
    private var finishedSegmentIDs: Set<String> = []
    private var completedCount = 0
    private var failedCount = 0
    private var prepared = false
    private var runStarted = false
    private var segmentationSealed = false
    private var segmentationCompleted = false
    private var attemptFailed = false
    private var processing = false
    private var startingRun = false
    private var runStartWaiters: [CheckedContinuation<Void, any Error>] = []
    private var finalized = false
    private var completedFinish: LiveASRCompletion?
    private var finishing = false
    private var finishWaiters: [CheckedContinuation<LiveASRCompletion, any Error>] = []
    private var activeWorkCount = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaitObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private init(
        sessionID: UUID,
        sessionURL: URL,
        processingDirectory: URL,
        writer: any SessionEventAppending,
        asr: any ASREngine,
        recovery: ProcessingLogState
    ) {
        let runs = recovery.generation.runs
        self.sessionID = sessionID
        self.sessionURL = sessionURL
        self.generationID = recovery.generation.id
        self.segmentationRunID = recovery.segmentationRunID
        self.asrRunID = recovery.asrRunID
        self.clauseBoundaryRunID = runs.clauseBoundary
        self.contentPriorityRunID = runs.contentPriority
        self.processingDirectory = processingDirectory
        self.writer = writer
        self.asr = asr
        self.materializer = IncrementalTranscriptMaterializer(
            sampleRate: recovery.generation.sampleRate,
            segmentationRunID: recovery.segmentationRunID,
            asrRunID: recovery.asrRunID,
            clauseBoundaryRunID: runs.clauseBoundary
        )
    }

    public static func open(
        sessionID: UUID,
        sessionURL: URL,
        writer: any SessionEventAppending,
        asr: any ASREngine
    ) async throws -> LiveASRSession {
        let layout = SessionLayout(sessionURL: sessionURL)
        guard let recovery = try ProcessingLogState(eventsURL: layout.eventsURL, sessionID: sessionID) else {
            throw ProcessingLogStateError.missingGeneration
        }
        guard recovery.generation.asrProvenance == asr.provenance else {
            throw ProcessingLogStateError.incompatibleSettings
        }
        let session = LiveASRSession(
            sessionID: sessionID,
            sessionURL: sessionURL,
            processingDirectory: layout.processingDirectory,
            writer: writer,
            asr: asr,
            recovery: recovery
        )
        try await session.hydrate(recovery)
        return session
    }

    private func hydrate(_ recovery: ProcessingLogState) throws {
        registeredSegments = Dictionary(uniqueKeysWithValues: recovery.segments.map { ($0.segmentID, $0) })
        pendingSince = recovery.pendingSince
        for segment in recovery.segments {
            setStatus(LiveASRSegmentStatus(segmentID: segment.segmentID, startFrame: segment.startFrame, outcome: .pending))
        }
        runStarted = recovery.runStarts[.asr] != nil
        segmentationSealed = recovery.sealedFrames != nil
        segmentationCompleted = recovery.segmentationCompleted

        for event in recovery.events {
            switch event.kind {
            case .segmentCreated:
                try materializer.appendSourceEvent(event)
                transcriptEvents.append(event)
            case .asrCompleted:
                guard let segmentID = event.segmentID,
                      let segment = registeredSegments[segmentID] else {
                    throw TranscriptMaterializationError.missingClauseSource
                }
                _ = try applyPersistedSegment(segment, event: event)
            default:
                throw TranscriptMaterializationError.missingClauseSource
            }
        }

        if recovery.runCompletions[.asr] != nil {
            finalized = true
            completedFinish = currentCompletion()
        }
    }

    /// Seals the segmentation input at its exact final length. Must precede the VAD's EOF flush.
    public func sealSegmentationInput(frameCount: Int64) async throws {
        guard !segmentationSealed else { return }
        try await writer.append(EventDraft(
            eventType: "segmentation.input.sealed", sessionID: sessionID, segmentationRunID: segmentationRunID,
            payload: SegmentationInputSealedPayload(frameCount: frameCount)
        ))
        segmentationSealed = true
    }

    /// Closes the segmentation once every segment the VAD emitted is saved.
    public func completeSegmentation(frameCount: Int64, segmentCount: Int) async throws {
        guard !segmentationCompleted else { return }
        guard segmentationSealed else { throw LiveASRSessionError.segmentationNotSealed }
        guard registeredSegments.count == segmentCount else {
            throw LiveASRSessionError.segmentationSegmentCountMismatch(
                registered: registeredSegments.count, expected: segmentCount
            )
        }
        try await writer.append(EventDraft(
            eventType: "segmentation.completed", sessionID: sessionID, segmentationRunID: segmentationRunID,
            payload: SegmentationCompletedPayload(consumedFrames: frameCount, segmentCount: segmentCount)
        ))
        segmentationCompleted = true
        try await writer.append(EventDraft(
            eventType: "processing.run.completed", sessionID: sessionID, processingRunID: segmentationRunID,
            payload: ProcessingRunCompletedPayload(
                stage: .segmentation, succeeded: true, completedCount: segmentCount, failedCount: 0
            )
        ))
    }

    /// Durably registers newly detected speech before it enters the ASR queue.
    @discardableResult
    public func register(
        segments: [SegmentReference]
    ) async throws -> LiveASRProgress {
        try Task.checkCancellation()
        guard !finalized else {
            return currentProgress()
        }
        beginWork()
        defer { endWork() }

        try await registerPendingSegments(segments)
        return currentProgress()
    }

    private func registerPendingSegments(_ segments: [SegmentReference]) async throws {
        try Task.checkCancellation()

        for segment in segments
        where registeredSegments[segment.segmentID] == nil
            && !registeringSegmentIDs.contains(segment.segmentID) {
            try Task.checkCancellation()
            guard !finalized else { break }
            registeringSegmentIDs.insert(segment.segmentID)
            defer { registeringSegmentIDs.remove(segment.segmentID) }
            try Task.checkCancellation()
            let created = try await writer.append(.segmentCreated(sessionID: sessionID, segment: segment))
            let event = TranscriptEvent.segmentCreated(
                seq: created.eventSeq,
                segmentationRunID: segmentationRunID,
                segmentID: segment.segmentID,
                startFrame: segment.startFrame,
                endFrame: segment.endFrame
            )
            try materializer.appendSourceEvent(event)
            transcriptEvents.append(event)
            registeredSegments[segment.segmentID] = segment
            pendingSince[segment.segmentID] = created.createdAt
            setStatus(LiveASRSegmentStatus(segmentID: segment.segmentID, startFrame: segment.startFrame, outcome: .pending))
        }
    }

    /// Recognizes the unfinished segments that the batch's checkpoint covers, read through that checkpoint.
    /// Every supplied segment must lie within the checkpoint; one beyond it is an error, before registration.
    /// Segments registered separately, beyond this batch's audio, wait for their own batches.
    @discardableResult
    public func process(
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint,
        onSegmentFinished: (@Sendable (LiveASRSegmentStatus, LiveASRSnapshot) async -> Void)? = nil,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck
    ) async throws -> LiveASRProgress {
        if let outside = segments.first(where: { $0.endFrame > checkpoint.committedFrames }) {
            throw LiveASRSessionError.segmentBeyondCheckpoint(
                segmentID: outside.segmentID, endFrame: outside.endFrame, committedFrames: checkpoint.committedFrames
            )
        }
        try Task.checkCancellation()
        guard !finalized else { return currentProgress() }
        let reader = try ProcessingTimelineReader(
            directory: processingDirectory,
            checkpoint: checkpoint,
            sessionURL: sessionURL
        )
        return try await process(
            segments: segments, scope: .coveredBy(committedFrames: checkpoint.committedFrames), reader: reader,
            onSegmentFinished: onSegmentFinished, shouldPause: shouldPause
        )
    }

    /// Recognizes every registered unfinished segment through `reader`.
    @discardableResult
    public func process(
        segments: [SegmentReference] = [],
        reader: any TimelineAudioReading,
        onSegmentFinished: (@Sendable (LiveASRSegmentStatus, LiveASRSnapshot) async -> Void)? = nil,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck
    ) async throws -> LiveASRProgress {
        try await process(
            segments: segments, scope: .registered, reader: reader,
            onSegmentFinished: onSegmentFinished, shouldPause: shouldPause
        )
    }

    private func process(
        segments: [SegmentReference],
        scope: RunScope,
        reader: any TimelineAudioReading,
        onSegmentFinished: (@Sendable (LiveASRSegmentStatus, LiveASRSnapshot) async -> Void)?,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck
    ) async throws -> LiveASRProgress {
        do {
            _ = try await run(
                segments: segments,
                scope: scope,
                reader: reader,
                pacingMode: .normal,
                sleep: { try await Task.sleep(for: $0) },
                shouldPause: shouldPause,
                onSegmentFinished: onSegmentFinished
            )
        } catch is ASRRunCancellation {
            throw CancellationError()
        }
        return currentProgress()
    }

    func drain(
        reader: any TimelineAudioReading,
        pacingMode: ASRPacingMode,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck,
        onSegmentFinished: (@Sendable (LiveASRSegmentStatus, LiveASRSnapshot) async -> Void)?
    ) async throws -> ASRRunResult? {
        try await run(
            segments: [],
            scope: .registered,
            reader: reader,
            pacingMode: pacingMode,
            sleep: sleep,
            shouldPause: shouldPause,
            onSegmentFinished: onSegmentFinished
        )
    }

    /// Which unfinished segments a run recognizes: a live batch only those its checkpoint's audio covers,
    /// a drain every registered one.
    private enum RunScope {
        case registered
        case coveredBy(committedFrames: Int64)
    }

    private func run(
        segments: [SegmentReference],
        scope: RunScope,
        reader: any TimelineAudioReading,
        pacingMode: ASRPacingMode,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck,
        onSegmentFinished: (@Sendable (LiveASRSegmentStatus, LiveASRSnapshot) async -> Void)?
    ) async throws -> ASRRunResult? {
        try Task.checkCancellation()
        guard !finalized else { return nil }
        beginWork()
        defer { endWork() }

        try await registerPendingSegments(segments)
        try Task.checkCancellation()
        guard !finalized, !attemptFailed, !processing else { return nil }

        let pendingSegments = segmentStatuses.compactMap { status -> SegmentReference? in
            guard !finishedSegmentIDs.contains(status.segmentID) else { return nil }
            guard let segment = registeredSegments[status.segmentID] else { return nil }
            if case .coveredBy(let committedFrames) = scope, segment.endFrame > committedFrames { return nil }
            return segment
        }
        guard !pendingSegments.isEmpty else { return nil }

        processing = true
        defer { processing = false }

        try await ensureRunStarted()
        try Task.checkCancellation()
        guard !finalized, !attemptFailed else { return nil }

        let coordinator = PipelineCoordinator(
            sessionID: sessionID,
            segmentationRunID: segmentationRunID,
            asrRunID: asrRunID,
            writer: writer,
            asr: asr,
            loader: ASRAudioLoader(reader: reader),
            pacingMode: pacingMode,
            sleep: sleep,
            shouldPause: shouldPause
        )
        let result = try await coordinator.execute(
            segments: pendingSegments,
            pendingSince: pendingSince,
            existingEvents: [],
            prepareModel: !prepared,
            stopOnPersistenceFailure: true,
            shouldContinue: { await self.canExecuteSegment() },
            onSegmentPersisted: { segment, event in
                let status = try await self.applyPersistedSegment(segment, event: event)
                let currentSnapshot = await self.snapshot()
                await onSegmentFinished?(status, currentSnapshot)
            }
        )
        if !attemptFailed { prepared = true }
        return result
    }

    public func snapshot() -> LiveASRSnapshot {
        LiveASRSnapshot(
            events: transcriptEvents,
            activeRuns: currentActiveRuns(),
            progress: currentProgress(),
            segments: segmentStatuses
        )
    }

    /// Merges durable clause-decision events of this session's live runs without discarding ASR
    /// rows recognized while clause classification was in progress.
    @discardableResult
    public func applyClauseEvents(_ events: [TranscriptEvent]) throws -> LiveASRSnapshot {
        for event in events {
            switch event.kind {
            case .clauseBoundaryAssessed, .clauseBoundaryPending, .clauseClosed:
                guard let clauseBoundaryRunID, event.processingRunID == clauseBoundaryRunID else {
                    throw LiveASRSessionError.foreignClauseEvent
                }
            case .contentPriorityAssigned:
                guard let contentPriorityRunID, event.processingRunID == contentPriorityRunID else {
                    throw LiveASRSessionError.foreignClauseEvent
                }
            default:
                throw LiveASRSessionError.foreignClauseEvent
            }
        }
        try materializer.applyClauseEvents(events)
        transcriptEvents.append(contentsOf: events)
        return snapshot()
    }

    var finishWaiterCount: Int {
        idleWaiters.count + finishWaiters.count
    }

    func waitForFinishWaiters(_ count: Int) async {
        precondition(count > 0, "finish waiter count must be positive")
        guard finishWaiterCount < count else { return }
        await withCheckedContinuation { continuation in
            finishWaitObservers.append((count: count, continuation: continuation))
        }
    }

    private func resumeSatisfiedFinishWaitObservers() {
        let satisfied = finishWaitObservers.filter { $0.count <= finishWaiterCount }
        finishWaitObservers.removeAll { $0.count <= finishWaiterCount }
        satisfied.forEach { $0.continuation.resume() }
    }

    public func finish() async throws -> LiveASRCompletion {
        if let completedFinish {
            return completedFinish
        }
        if finishing {
            return try await withCheckedThrowingContinuation { continuation in
                finishWaiters.append(continuation)
                resumeSatisfiedFinishWaitObservers()
            }
        }
        finishing = true
        finalized = true

        do {
            if activeWorkCount > 0 {
                await withCheckedContinuation { continuation in
                    idleWaiters.append(continuation)
                    resumeSatisfiedFinishWaitObservers()
                }
            }

            try await ensureRunStarted()
            let pendingCount = currentPendingCount
            let succeeded = failedCount == 0 && pendingCount == 0
            if succeeded {
                let layout = SessionLayout(sessionURL: sessionURL)
                guard let state = try ProcessingLogState(eventsURL: layout.eventsURL, sessionID: sessionID),
                      state.generation.id == generationID,
                      state.segmentationCompleted,
                      state.segments.count == completedCount else {
                    throw ProcessingLogStateError.incompleteRecognition
                }
                _ = try await writer.append(EventDraft(
                    eventType: "processing.run.completed",
                    sessionID: sessionID,
                    processingRunID: asrRunID,
                    payload: ProcessingRunCompletedPayload(
                        stage: .asr,
                        succeeded: true,
                        completedCount: completedCount,
                        failedCount: 0
                    )
                ))
            }

            let completion = currentCompletion()
            completedFinish = completion
            finishing = false
            let waiters = finishWaiters
            finishWaiters = []
            waiters.forEach { $0.resume(returning: completion) }
            return completion
        } catch {
            finishing = false
            let waiters = finishWaiters
            finishWaiters = []
            waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func ensureRunStarted() async throws {
        guard !runStarted else { return }
        if startingRun {
            try await withCheckedThrowingContinuation { runStartWaiters.append($0) }
            return
        }
        startingRun = true
        do {
            _ = try await writer.append(EventDraft(
                eventType: "processing.run.started", sessionID: sessionID, processingRunID: asrRunID,
                payload: ProcessingRunStartedPayload(stage: .asr, provenance: asr.provenance)
            ))
            runStarted = true
            startingRun = false
            let waiters = runStartWaiters
            runStartWaiters = []
            waiters.forEach { $0.resume() }
        } catch {
            startingRun = false
            let waiters = runStartWaiters
            runStartWaiters = []
            waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    /// True when this session's view of the saved segments and recognized lines is the log's own.
    /// An append that failed after its line reached the disk leaves the two apart.
    func agrees(with state: ProcessingLogState) -> Bool {
        let recognized = state.events.reduce(0) { count, event in
            if case .asrCompleted = event.kind { count + 1 } else { count }
        }
        return !attemptFailed && registeredSegments.count == state.segments.count && completedCount == recognized
    }

    private func canExecuteSegment() -> Bool {
        !finalized && !attemptFailed
    }

    private func applyPersistedSegment(
        _ segment: SegmentReference,
        event: TranscriptEvent?
    ) throws -> LiveASRSegmentStatus {
        let status: LiveASRSegmentStatus
        if let event {
            try materializer.appendSourceEvent(event)
            transcriptEvents.append(event)
            completedCount += 1
            finishedSegmentIDs.insert(segment.segmentID)
            guard case .asrCompleted(let result) = event.kind,
                  let source = try event.asrSource() else {
                preconditionFailure("an asr.completed event always has a text reference")
            }
            status = LiveASRSegmentStatus(
                segmentID: segment.segmentID,
                startFrame: segment.startFrame,
                outcome: .recognized(source, result.text)
            )
        } else {
            failedCount += 1
            attemptFailed = true
            status = LiveASRSegmentStatus(
                segmentID: segment.segmentID,
                startFrame: segment.startFrame,
                outcome: .failed
            )
        }
        setStatus(status)
        return status
    }

    private func beginWork() {
        activeWorkCount += 1
    }

    private func endWork() {
        activeWorkCount -= 1
        guard activeWorkCount == 0 else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func currentActiveRuns() -> ActiveRuns {
        ActiveRuns(
            segmentation: segmentationRunID,
            asr: asrRunID,
            clauseBoundary: clauseBoundaryRunID,
            contentPriority: contentPriorityRunID
        )
    }

    private func setStatus(_ status: LiveASRSegmentStatus) {
        if let index = segmentStatusIndex[status.segmentID] {
            segmentStatuses[index] = status
            return
        }
        // Detection emits segments in time order, so a new segment is normally appended.
        let index = (segmentStatuses.last.map { $0.startFrame <= status.startFrame } ?? true)
            ? segmentStatuses.count
            : segmentStatuses.firstIndex { $0.startFrame > status.startFrame } ?? segmentStatuses.count
        segmentStatuses.insert(status, at: index)
        for position in index..<segmentStatuses.count {
            segmentStatusIndex[segmentStatuses[position].segmentID] = position
        }
    }

    // Successfully completed IDs are a subset of durably registered IDs.
    private var currentPendingCount: Int {
        registeredSegments.count - finishedSegmentIDs.count
    }


    private func currentProgress() -> LiveASRProgress {
        LiveASRProgress(
            materializedSegments: materializer.materializedSegments,
            completedCount: completedCount,
            failedCount: failedCount,
            pendingCount: currentPendingCount
        )
    }

    private func currentCompletion() -> LiveASRCompletion {
        let progress = currentProgress()
        return LiveASRCompletion(
            events: transcriptEvents,
            materializedSegments: progress.materializedSegments,
            completedCount: completedCount,
            failedCount: failedCount,
            pendingCount: progress.pendingCount
        )
    }
}
