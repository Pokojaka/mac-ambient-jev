import Foundation
import MacAmbientJevCore

public enum LiveContentPriorityError: LocalizedError {
    case unknownSource
    case segmentOrderChanged

    public var errorDescription: String? {
        switch self {
        case .unknownSource: "ライブ文字起こしにない区間を判定に渡そうとしました"
        case .segmentOrderChanged: "ライブ文字起こしの区間順序が判定済みの区間と一致しません"
        }
    }
}

/// Runs live boundary and priority decision stages independently of ASR and recording drain.
/// Each segment's boundary request waits until the next segment's ASR is saved; rows stay
/// visible as normal text meanwhile. Only durable results reach the screen.
public actor LiveContentPrioritySession {
    public typealias StatusHandler = @Sendable (String) async -> Void
    public typealias UpdateHandler = @Sendable (LiveASRSnapshot) async -> Void

    public nonisolated let boundaryRunID: String
    public nonisolated let priorityRunID: String

    private struct Step {
        enum Successor {
            /// The following segment has no ASR result, so the boundary cannot be requested.
            case gap
            /// nil ends the text stream.
            case head(NextSegmentHead?)
        }
        let source: SegmentTextReference
        let text: String
        let successor: Successor
    }

    private let sessionID: UUID
    private let writer: SessionWriter
    private let liveASR: LiveASRSession
    private let makeDecisions: NativeSessionProcessor.DecisionCoordinatorFactory
    private let usageCounter: DecisionUsageCounter

    private var segments: [LiveASRSegmentStatus] = []
    private var handledCount = 0
    private var inputFinished = false
    private var assembly: ClauseBoundaryAssembly
    private var composer = ClauseTextComposer()
    private var sourceTexts: [SegmentTextReference: String] = [:]
    private var startedRuns: Set<ProcessingStage> = []
    private var boundaryProvenance: RunProvenance?
    private var priorityProvenance: RunProvenance?
    private var completedRuns = false
    private var boundaryCounts = (assessed: 0, pending: 0)
    private var priorityCounts = (classified: 0, pending: 0)
    private var recordedPendingTargets: Set<DecisionPendingTarget> = []
    private var onStatus: StatusHandler?
    private var onUpdate: UpdateHandler?
    private var worker: Task<Void, Never>?
    private var stopped = false
    private var halted = false

    public init(
        sessionID: UUID,
        boundaryRunID: String,
        priorityRunID: String,
        writer: SessionWriter,
        liveASR: LiveASRSession,
        makeDecisions: @escaping NativeSessionProcessor.DecisionCoordinatorFactory,
        usageCounter: DecisionUsageCounter
    ) {
        self.sessionID = sessionID
        self.boundaryRunID = boundaryRunID
        self.priorityRunID = priorityRunID
        self.writer = writer
        self.liveASR = liveASR
        self.makeDecisions = makeDecisions
        self.usageCounter = usageCounter
        self.assembly = ClauseBoundaryAssembly(boundaryRunID: boundaryRunID)
    }

    /// Notes a newly saved ASR segment and returns without waiting for decision results.
    public func enqueue(
        source: SegmentTextReference,
        snapshot: LiveASRSnapshot,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async throws {
        guard !stopped else { return }
        guard snapshot.segments.contains(where: {
            if case .recognized(let recognized, _) = $0.outcome { recognized == source } else { false }
        }) else { throw LiveContentPriorityError.unknownSource }
        self.onStatus = onStatus
        self.onUpdate = onUpdate
        try update(snapshot.segments)
        startWorker()
    }

    /// Notes a segment that ended without text to queue (a failed ASR), so a segment
    /// waiting for this successor is marked boundary-pending rather than bridged.
    public func observe(snapshot: LiveASRSnapshot) async throws {
        guard !stopped else { return }
        try update(snapshot.segments)
        startWorker()
    }

    /// The text stream ended: the last segment is judged with no successor and the tail
    /// already assessed is closed. This only releases the wait for a next segment.
    public func finishInput(snapshot: LiveASRSnapshot) async throws {
        guard !stopped else { return }
        try update(snapshot.segments)
        inputFinished = true
        startWorker()
    }

    /// Cancels the queue immediately, even if a decision engine ignores cancellation. Results already
    /// saved stay durable; a response that arrives later is neither saved nor shown.
    public func stop() async {
        stopped = true
        worker?.cancel()
        worker = nil
        onStatus = nil
        onUpdate = nil
    }

    /// Pending targets this session recorded in the usage counter.
    public func pendingTargets() -> Set<DecisionPendingTarget> {
        recordedPendingTargets
    }

    private func update(_ statuses: [LiveASRSegmentStatus]) throws {
        guard statuses.count >= segments.count,
              zip(statuses, segments).allSatisfy({ current, previous in
                  guard current.segmentID == previous.segmentID, current.startFrame == previous.startFrame else { return false }
                  switch previous.outcome {
                  case .pending:
                      return true
                  case .failed:
                      return current.outcome == .failed
                  case .recognized(let source, let text):
                      guard case .recognized(let currentSource, let currentText) = current.outcome else { return false }
                      return source == currentSource && text.utf8.elementsEqual(currentText.utf8)
                  }
              }) else {
            throw LiveContentPriorityError.segmentOrderChanged
        }
        segments = statuses
        for status in statuses {
            if case .recognized(let source, let text) = status.outcome { sourceTexts[source] = text }
        }
    }

    private func startWorker() {
        guard worker == nil, onUpdate != nil, !halted, !stopped, !completedRuns else { return }
        worker = Task { await drain() }
    }

    private func drain() async {
        defer { worker = nil }
        do {
            while true {
                try ensureActive()
                if let step = try nextStep() {
                    try await handle(step)
                    handledCount += 1
                } else if inputFinished, handledCount == segments.count, !completedRuns {
                    try await completeRuns()
                } else {
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            halted = true
            guard !stopped && !Task.isCancelled else { return }
            await onStatus?("発話文の判定を保存できませんでした: \(error.localizedDescription)")
        }
    }

    /// The next segment whose successor is known, skipping segments without text.
    private func nextStep() throws -> Step? {
        while handledCount < segments.count {
            let segment = segments[handledCount]
            switch segment.outcome {
            case .pending:
                guard inputFinished else { return nil }
                handledCount += 1
            case .failed:
                handledCount += 1
            case .recognized(let source, let text):
                guard ASRRecognitionOutcome(text: text) == .recognized else {
                    _ = try assembly.endTextStream()
                    handledCount += 1
                    continue
                }
                let successorIndex = handledCount + 1
                guard successorIndex < segments.count else {
                    return inputFinished ? Step(source: source, text: text, successor: .head(nil)) : nil
                }
                switch segments[successorIndex].outcome {
                case .pending:
                    return inputFinished ? Step(source: source, text: text, successor: .gap) : nil
                case .failed:
                    return Step(source: source, text: text, successor: .gap)
                case .recognized(let nextSource, let nextText):
                    guard ASRRecognitionOutcome(text: nextText) == .recognized else {
                        return Step(source: source, text: text, successor: .head(nil))
                    }
                    return Step(source: source, text: text, successor: .head(try NextSegmentHead(
                        source: nextSource, text: String(nextText.prefix(ClauseBoundaryPolicy.nextHeadCharacterLimit))
                    )))
                }
            }
        }
        return nil
    }

    /// The decision coordinator for one request; a failed tagger load leaves the request pending.
    private func availableDecisions(stage: ProcessingStage) -> DecisionAvailability {
        do {
            let decisions = try makeDecisions()
            let provenance: RunProvenance
            switch stage {
            case .clauseBoundary:
                provenance = decisions.boundaryProvenance(mode: "live")
            case .contentPriority:
                provenance = decisions.priorityProvenance(mode: "live")
            default:
                preconditionFailure("Live decisions require a boundary or priority stage")
            }
            storeProvenance(provenance, for: stage)
            return .available(decisions)
        } catch {
            storeProvenance(DecisionRunProvenance.unavailable(mode: "live"), for: stage)
            let message = "判定エンジンを初期化できませんでした: \(error.localizedDescription)"
            return .pending(.initializationFailed, message)
        }
    }

    private func storeProvenance(_ provenance: RunProvenance, for stage: ProcessingStage) {
        switch stage {
        case .clauseBoundary:
            boundaryProvenance = provenance
        case .contentPriority:
            priorityProvenance = provenance
        default:
            preconditionFailure("Live decisions require a boundary or priority stage")
        }
    }

    private func handle(_ step: Step) async throws {
        let state: ClauseBoundaryState
        switch step.successor {
        case .gap:
            state = .pending(reason: .asrGap, message: DecisionPendingMessage.asrGap)
        case .head(let next):
            switch availableDecisions(stage: .clauseBoundary) {
            case .pending(let reason, let message):
                state = .pending(reason: reason, message: message)
            case .available(let decisions):
                await report(UserFacingStatus.classifyingContent.text)
                state = try await ClauseBoundaryStep.assess(
                    source: step.source, text: step.text, next: next, decisions: decisions
                )
            }
        }
        try ensureActive()

        var events: [TranscriptEvent] = []
        switch state {
        case .assessed(let assessment):
            events.append(try await append(ClauseEventType.boundaryAssessed, stage: .clauseBoundary, payload: assessment,
                                           kind: .clauseBoundaryAssessed(assessment)))
            boundaryCounts.assessed += 1
        case .pending(let reason, let message):
            let payload = ClauseBoundaryPendingPayload(source: step.source, reason: reason, message: message)
            events.append(try await append(ClauseEventType.boundaryPending, stage: .clauseBoundary, payload: payload,
                                           kind: .clauseBoundaryPending(payload)))
            boundaryCounts.pending += 1
            try await recordPending([.boundary(step.source)])
            if reason != .asrGap { await reportPending(message: message) }
        }
        if handledCount > 0 {
            switch segments[handledCount - 1].outcome {
            case .failed, .pending:
                _ = try assembly.beginAfterASRGap()
            case .recognized:
                break
            }
        }
        let delta = try assembly.consume(ClauseAssemblyInput(source: step.source, text: step.text, state: state))
        try await close(delta.closed, preceding: events)
    }

    private func completeRuns() async throws {
        let finished = try assembly.finish().closed
        try await close(finished, preceding: [])
        for stage in [ProcessingStage.clauseBoundary, .contentPriority] where startedRuns.contains(stage) {
            let counts = stage == .clauseBoundary
                ? (completed: boundaryCounts.assessed, failed: boundaryCounts.pending)
                : (completed: priorityCounts.classified, failed: priorityCounts.pending)
            try ensureActive()
            _ = try await writer.append(EventDraft(
                eventType: "processing.run.completed", sessionID: sessionID,
                processingRunID: stage == .clauseBoundary ? boundaryRunID : priorityRunID,
                payload: ProcessingRunCompletedPayload(
                    stage: stage, succeeded: true, completedCount: counts.completed, failedCount: counts.failed
                )
            ))
        }
        completedRuns = true
    }

    /// Saves newly closed clauses, shows them, then classifies the non-blank ones in batches of 40.
    private func close(
        _ units: [ClauseUnit],
        preceding: [TranscriptEvent]
    ) async throws {
        var events = preceding
        var targets: [(reference: ClauseReference, text: String)] = []
        do {
            for unit in units {
                events.append(try await append(ClauseEventType.clauseClosed, stage: .clauseBoundary, payload: unit,
                                               kind: .clauseClosed(unit)))
                let text = try composer.text(of: unit.parts) { source in
                    guard let text = self.sourceTexts[source] else { throw LiveContentPriorityError.unknownSource }
                    return text
                }
                if !ClauseTextComposer.isBlank(text) { targets.append((unit.reference, text)) }
            }
        } catch {
            // A later save failure must not hide the independent results already durable.
            try await show(events)
            throw error
        }
        try await show(events)

        var batches = try ClausePriorityBatches(targets: targets)
        while batches.hasRemaining {
            try ensureActive()
            let payload = try await batches.next { self.availableDecisions(stage: .contentPriority) }
            try ensureActive()
            let event = try await append(ClauseEventType.priorityAssigned, stage: .contentPriority, payload: payload,
                                         kind: .contentPriorityAssigned(payload))
            let pending = payload.assignments.filter(\.needsRetry).map(\.reference)
            priorityCounts.classified += payload.assignments.count - pending.count
            priorityCounts.pending += pending.count
            try await show([event])
            if !pending.isEmpty {
                try await recordPending(Set(pending.map(DecisionPendingTarget.priority)))
                if let assignment = payload.assignments.first(where: \.needsRetry),
                   case .retryPending(_, let message) = assignment.decision {
                    await reportPending(message: message)
                }
            }
        }
    }

    private func show(_ events: [TranscriptEvent]) async throws {
        guard !events.isEmpty else { return }
        try ensureActive()
        let snapshot = try await liveASR.applyClauseEvents(events)
        try ensureActive()
        await onUpdate?(snapshot)
    }

    private func append<Payload: Codable & Sendable>(
        _ eventType: String,
        stage: ProcessingStage,
        payload: Payload,
        kind: TranscriptEventKind
    ) async throws -> TranscriptEvent {
        let runID = stage == .clauseBoundary ? boundaryRunID : priorityRunID
        if !startedRuns.contains(stage) {
            let provenance: RunProvenance
            switch stage {
            case .clauseBoundary:
                provenance = boundaryProvenance
                    ?? DecisionRunProvenance.unavailable(mode: "live")
            case .contentPriority:
                provenance = priorityProvenance
                    ?? DecisionRunProvenance.unavailable(mode: "live")
            default:
                preconditionFailure("Live decisions require a boundary or priority stage")
            }
            try ensureActive()
            _ = try await writer.append(EventDraft(
                eventType: "processing.run.started", sessionID: sessionID, processingRunID: runID,
                payload: ProcessingRunStartedPayload(stage: stage, provenance: provenance)
            ))
            startedRuns.insert(stage)
        }
        try ensureActive()
        let envelope = try await writer.append(EventDraft(
            eventType: eventType, sessionID: sessionID, processingRunID: runID, payload: payload
        ))
        return TranscriptEvent.clause(seq: envelope.eventSeq, runID: runID, kind: kind)
    }

    private func recordPending(_ targets: Set<DecisionPendingTarget>) async throws {
        try ensureActive()
        recordedPendingTargets.formUnion(targets)
        await usageCounter.recordDeferred(sessionID: sessionID, targets: targets)
    }

    private func ensureActive() throws {
        guard !stopped, !Task.isCancelled else { throw CancellationError() }
    }

    private func reportPending(message: String) async {
        await report("\(UserFacingStatus.decisionDeferred.text)。\(message)")
    }

    private func report(_ text: String) async {
        guard !stopped && !Task.isCancelled else { return }
        await onStatus?(text)
    }
}
