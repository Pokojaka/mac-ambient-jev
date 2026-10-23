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

    public var errorDescription: String? {
        "ライブ文字起こしと別の判定を表示しようとしました"
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
    private let processingDirectory: URL
    private let writer: any SessionEventAppending
    private let asr: any ASREngine
    private let materializer: IncrementalTranscriptMaterializer

    private let clauseBoundaryRunID: String?
    private let contentPriorityRunID: String?
    private var transcriptEvents: [TranscriptEvent] = []
    private var segmentStatuses: [LiveASRSegmentStatus] = []
    private var segmentStatusIndex: [String: Int] = [:]
    private var registeredSegmentIDs: Set<String> = []
    private var registeringSegmentIDs: Set<String> = []
    private var finishedSegmentIDs: Set<String> = []
    private var completedCount = 0
    private var failedCount = 0
    private var prepared = false
    private var runStarted = false
    private var startingRun = false
    private var runStartWaiters: [CheckedContinuation<Void, any Error>] = []
    private var finalized = false
    private var completedFinish: LiveASRCompletion?
    private var finishing = false
    private var finishWaiters: [CheckedContinuation<LiveASRCompletion, any Error>] = []
    private var activeWorkCount = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaitObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init(
        sessionID: UUID,
        sessionURL: URL,
        segmentationRunID: String,
        asrRunID: String,
        processingDirectory: URL,
        writer: any SessionEventAppending,
        asr: any ASREngine,
        sampleRate: Double,
        clauseBoundaryRunID: String?,
        contentPriorityRunID: String?
    ) {
        self.sessionID = sessionID
        self.sessionURL = sessionURL
        self.segmentationRunID = segmentationRunID
        self.asrRunID = asrRunID
        self.clauseBoundaryRunID = clauseBoundaryRunID
        self.contentPriorityRunID = contentPriorityRunID
        self.processingDirectory = processingDirectory
        self.writer = writer
        self.asr = asr
        self.materializer = IncrementalTranscriptMaterializer(
            sampleRate: sampleRate, segmentationRunID: segmentationRunID,
            asrRunID: asrRunID, clauseBoundaryRunID: clauseBoundaryRunID
        )
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
        where !registeredSegmentIDs.contains(segment.segmentID)
            && !registeringSegmentIDs.contains(segment.segmentID) {
            try Task.checkCancellation()
            guard !finalized else { break }
            registeringSegmentIDs.insert(segment.segmentID)
            defer { registeringSegmentIDs.remove(segment.segmentID) }
            try Task.checkCancellation()
            let created = try await writer.append(EventDraft(
                eventType: "segment.created",
                sessionID: sessionID,
                segmentationRunID: segmentationRunID,
                segmentID: segment.segmentID,
                sourceStartFrame: segment.startFrame,
                sourceEndFrame: segment.endFrame,
                payload: EmptyPayload()
            ))
            let event = TranscriptEvent.segmentCreated(
                seq: created.eventSeq,
                segmentationRunID: segmentationRunID,
                segmentID: segment.segmentID,
                startFrame: segment.startFrame,
                endFrame: segment.endFrame
            )
            try materializer.appendSourceEvent(event)
            transcriptEvents.append(event)
            registeredSegmentIDs.insert(segment.segmentID)
            setStatus(LiveASRSegmentStatus(segmentID: segment.segmentID, startFrame: segment.startFrame, outcome: .pending))
        }
    }

    @discardableResult
    public func process(
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint,
        onSegmentFinished: (@Sendable (LiveASRSegmentStatus, LiveASRSnapshot) async -> Void)? = nil
    ) async throws -> LiveASRProgress {
        try Task.checkCancellation()
        guard !finalized else {
            return currentProgress()
        }
        beginWork()
        defer { endWork() }

        try await registerPendingSegments(segments)
        try Task.checkCancellation()
        guard !finalized else {
            return currentProgress()
        }

        let pendingSegments = segments.filter { segment in
            registeredSegmentIDs.contains(segment.segmentID)
                && !finishedSegmentIDs.contains(segment.segmentID)
        }
        guard !pendingSegments.isEmpty else {
            return currentProgress()
        }

        try await ensureRunStarted()

        if !prepared {
            try await asr.prepare()
            try Task.checkCancellation()
            prepared = true
        }

        let loader = ASRAudioLoader(
            reader: try ProcessingTimelineReader(
                directory: processingDirectory,
                checkpoint: checkpoint,
                sessionURL: sessionURL
            )
        )

        for segment in pendingSegments {
            try Task.checkCancellation()
            guard !finalized else { break }

            let input: ASRAudioInput
            do {
                input = try loader.load(segment: segment)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                let failed = try await appendFailure(segment: segment, kind: .audioUnreadable, error: error)
                await onSegmentFinished?(failed, snapshot())
                continue
            }

            let result: ASRResult
            do {
                result = try await asr.transcribe(input)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                let failed = try await appendFailure(segment: segment, kind: .transcriptionFailed, error: error)
                await onSegmentFinished?(failed, snapshot())
                continue
            }

            try Task.checkCancellation()
            let completed = try await writer.append(EventDraft(
                eventType: "asr.completed",
                sessionID: sessionID,
                processingRunID: asrRunID,
                segmentationRunID: segmentationRunID,
                segmentID: segment.segmentID,
                sourceStartFrame: segment.startFrame,
                sourceEndFrame: segment.endFrame,
                payload: ASRCompletedEventPayload(
                    text: result.text,
                    detectedLanguage: result.detectedLanguage,
                    provenance: asr.provenance
                )
            ))
            let event = TranscriptEvent.asrCompleted(
                seq: completed.eventSeq,
                runID: asrRunID,
                segmentationRunID: segmentationRunID,
                segmentID: segment.segmentID,
                text: result.text,
                detectedLanguage: result.detectedLanguage
            )
            try materializer.appendSourceEvent(event)
            transcriptEvents.append(event)
            completedCount += 1
            finishedSegmentIDs.insert(segment.segmentID)
            guard let source = try event.asrSource() else {
                preconditionFailure("an asr.completed event always has a text reference")
            }
            let status = LiveASRSegmentStatus(
                segmentID: segment.segmentID, startFrame: segment.startFrame,
                outcome: .recognized(source, result.text)
            )
            setStatus(status)
            await onSegmentFinished?(status, snapshot())
        }

        return currentProgress()
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
            _ = try await writer.append(EventDraft(
                eventType: "processing.run.completed",
                sessionID: sessionID,
                processingRunID: asrRunID,
                payload: ProcessingRunCompletedPayload(
                    stage: .asr,
                    succeeded: failedCount == 0 && pendingCount == 0,
                    completedCount: completedCount,
                    failedCount: failedCount
                )
            ))

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

    /// A segment counts as finished only once its failure is durable; an unwritable log stops the live run.
    private func appendFailure(
        segment: SegmentReference,
        kind: ASRFailureKind,
        error: any Error
    ) async throws -> LiveASRSegmentStatus {
        try Task.checkCancellation()
        _ = try await writer.append(EventDraft(
            eventType: "asr.failed",
            sessionID: sessionID,
            processingRunID: asrRunID,
            segmentationRunID: segmentationRunID,
            segmentID: segment.segmentID,
            sourceStartFrame: segment.startFrame,
            sourceEndFrame: segment.endFrame,
            payload: ASRFailedEventPayload(
                kind: kind,
                message: error.localizedDescription
            )
        ))
        failedCount += 1
        finishedSegmentIDs.insert(segment.segmentID)
        let status = LiveASRSegmentStatus(segmentID: segment.segmentID, startFrame: segment.startFrame, outcome: .failed)
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

    // Finished IDs are a subset of durably registered IDs, including failed ASR.
    private var currentPendingCount: Int {
        registeredSegmentIDs.count - finishedSegmentIDs.count
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
