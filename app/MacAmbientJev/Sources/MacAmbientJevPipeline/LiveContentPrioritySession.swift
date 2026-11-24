import Foundation
import MacAmbientJevCore

public enum LiveContentPriorityError: LocalizedError {
    case unknownSource
    case segmentOrderChanged
    case unfinishedASR
    case invalidRecovery

    public var errorDescription: String? {
        switch self {
        case .unknownSource: "ライブ文字起こしにない区間を判定に渡そうとしました"
        case .segmentOrderChanged: "ライブ文字起こしの区間順序が判定済みの区間と一致しません"
        case .unfinishedASR: "未完了の音声認識区間があります"
        case .invalidRecovery: "保存済みの判定状態とライブ文字起こしが一致しません"
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
        let source: SegmentTextReference
        let text: String
        let successor: NextSegmentHead?
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
    private var completedRuns: Set<ProcessingStage> = []
    private var boundaryProvenance: RunProvenance?
    private var priorityProvenance: RunProvenance?
    private var boundaryCounts = (assessed: 0, pending: 0)
    private var priorityCounts = (classified: 0, pending: 0)
    private var recordedPendingTargets: Set<DecisionPendingTarget> = []
    private var unsavedClauses: [ClauseUnit] = []
    private var unassignedClauses: [ClauseUnit] = []
    private var onStatus: StatusHandler?
    private var onUpdate: UpdateHandler?
    private(set) var worker: Task<Void, Never>?
    private var stopped = false
    private var writesInFlight = 0
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var workerError: Error?

    private init(
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

    public static func open(
        sessionID: UUID,
        writer: SessionWriter,
        liveASR: LiveASRSession,
        makeDecisions: @escaping NativeSessionProcessor.DecisionCoordinatorFactory,
        usageCounter: DecisionUsageCounter,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async throws -> LiveContentPrioritySession {
        let eventsURL = await writer.eventsURL
        let recovery = try DecisionSessionRecovery(eventsURL: eventsURL, sessionID: sessionID)
        let session = LiveContentPrioritySession(
            sessionID: sessionID,
            boundaryRunID: recovery.boundaryRunID,
            priorityRunID: recovery.priorityRunID,
            writer: writer,
            liveASR: liveASR,
            makeDecisions: makeDecisions,
            usageCounter: usageCounter
        )
        try await session.hydrate(recovery, onStatus: onStatus, onUpdate: onUpdate)
        return session
    }

    private func hydrate(
        _ recovery: DecisionSessionRecovery, onStatus: @escaping StatusHandler, onUpdate: @escaping UpdateHandler
    ) async throws {
        try update(await liveASR.snapshot().segments)
        var recoveredSourceIndex = 0
        recoveryScan: while handledCount < segments.count {
            switch segments[handledCount].outcome {
            case .pending, .failed:
                break recoveryScan
            case .recognized(let source, let text):
                guard ASRRecognitionOutcome(text: text) == .recognized else {
                    handledCount += 1
                    continue recoveryScan
                }
                guard recoveredSourceIndex < recovery.handledSources.count else {
                    break recoveryScan
                }
                guard recovery.handledSources[recoveredSourceIndex] == source else {
                    throw LiveContentPriorityError.invalidRecovery
                }
                recoveredSourceIndex += 1
                handledCount += 1
            }
        }
        guard recoveredSourceIndex == recovery.handledSources.count,
              !recovery.completedRuns.contains(.clauseBoundary) || handledCount == segments.count else {
            throw LiveContentPriorityError.invalidRecovery
        }

        assembly = recovery.assembly
        composer = recovery.composer
        startedRuns = recovery.startedRuns
        completedRuns = recovery.completedRuns
        boundaryCounts = recovery.boundaryCounts
        priorityCounts = recovery.priorityCounts
        recordedPendingTargets = recovery.pendingTargets
        unsavedClauses = recovery.unsavedClauses
        unassignedClauses = recovery.unassignedClauses
        _ = try await liveASR.applyClauseEvents(recovery.events)
        if !recordedPendingTargets.isEmpty {
            await usageCounter.recordDeferred(sessionID: sessionID, targets: recordedPendingTargets)
        }
        self.onStatus = onStatus
        self.onUpdate = onUpdate
        startWorker()
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

    /// Redirects status and row updates, e.g. from recording to the stop that drains this session.
    public func rebind(onStatus: @escaping StatusHandler, onUpdate: @escaping UpdateHandler) {
        guard !stopped else { return }
        self.onStatus = onStatus
        self.onUpdate = onUpdate
    }

    /// Notes ASR progress so the queue can continue when a waiting successor becomes available.
    public func observe(snapshot: LiveASRSnapshot) async throws {
        guard !stopped else { return }
        try update(snapshot.segments)
        startWorker()
    }

    /// The caller confirms segmentation and ASR are complete, releasing the final successor wait.
    public func finishInput(snapshot: LiveASRSnapshot) async throws {
        guard !stopped else { return }
        guard snapshot.segments.allSatisfy({
            if case .recognized = $0.outcome { true } else { false }
        }) else { throw LiveContentPriorityError.unfinishedASR }
        try update(snapshot.segments)
        inputFinished = true
        startWorker()
    }

    func waitForDrain() async throws {
        if let currentWorker = worker {
            await withTaskCancellationHandler {
                await currentWorker.value
            } onCancel: {
                currentWorker.cancel()
            }
        }
        try Task.checkCancellation()
        if let workerError { throw workerError }
    }

    /// Cancels the queue immediately, even if a decision engine ignores cancellation. Results already
    /// saved stay durable; a response that arrives later is neither saved nor shown. Returns once the
    /// writes already started have finished, so the run can be reopened without duplicate events.
    public func stop() async {
        stopped = true
        worker?.cancel()
        worker = nil
        onStatus = nil
        onUpdate = nil
        if writesInFlight > 0 {
            await withCheckedContinuation { quiescenceWaiters.append($0) }
        }
    }

    /// Pending targets this session recorded in the usage counter.
    public func pendingTargets() -> Set<DecisionPendingTarget> {
        recordedPendingTargets
    }

    private func update(_ statuses: [LiveASRSegmentStatus]) throws {
        guard ((!inputFinished && !completedRuns.contains(.clauseBoundary)) || statuses.count == segments.count),
              statuses.count >= segments.count,
              zip(statuses, segments).allSatisfy({ current, previous in
                  guard current.segmentID == previous.segmentID, current.startFrame == previous.startFrame else { return false }
                  switch previous.outcome {
                  case .pending, .failed:
                      return true
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
        guard worker == nil, onUpdate != nil, workerError == nil, !stopped else { return }
        worker = Task { await drain() }
    }

    private func drain() async {
        defer { worker = nil }
        do {
            while true {
                try ensureActive()
                if !unsavedClauses.isEmpty || !unassignedClauses.isEmpty {
                    let unsaved = unsavedClauses
                    let unassigned = unassignedClauses
                    unsavedClauses = []
                    unassignedClauses = []
                    try await close(unsaved, preceding: [], alreadyClosed: unassigned)
                    continue
                }
                if let step = try nextStep() {
                    try await handle(step)
                    handledCount += 1
                } else if inputFinished, handledCount == segments.count {
                    try await completeRuns()
                    return
                } else {
                    return
                }
            }
        } catch {
            guard !(error is CancellationError && (stopped || Task.isCancelled)) else { return }
            workerError = error
            guard !stopped && !Task.isCancelled else { return }
            await onStatus?("発話文の判定を保存できませんでした: \(error.localizedDescription)")
        }
    }

    /// Consumes successful text in order and waits at every unfinished ASR status.
    private func nextStep() throws -> Step? {
        while handledCount < segments.count {
            let segment = segments[handledCount]
            switch segment.outcome {
            case .pending, .failed:
                return nil
            case .recognized(let source, let text):
                guard ASRRecognitionOutcome(text: text) == .recognized else {
                    _ = try assembly.endTextStream()
                    handledCount += 1
                    continue
                }
                let successorIndex = handledCount + 1
                guard successorIndex < segments.count else {
                    return inputFinished ? Step(source: source, text: text, successor: nil) : nil
                }
                switch segments[successorIndex].outcome {
                case .pending, .failed:
                    return nil
                case .recognized(let nextSource, let nextText):
                    guard ASRRecognitionOutcome(text: nextText) == .recognized else {
                        return Step(source: source, text: text, successor: nil)
                    }
                    return Step(source: source, text: text, successor: try NextSegmentHead(
                        source: nextSource, text: String(nextText.prefix(ClauseBoundaryPolicy.nextHeadCharacterLimit))
                    ))
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
                provenance = decisions.boundaryProvenance()
            case .contentPriority:
                provenance = decisions.priorityProvenance()
            default:
                preconditionFailure("Live decisions require a boundary or priority stage")
            }
            storeProvenance(provenance, for: stage)
            return .available(decisions)
        } catch {
            storeProvenance(DecisionRunProvenance.unavailable(), for: stage)
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
        switch availableDecisions(stage: .clauseBoundary) {
        case .pending(let reason, let message):
            state = .pending(reason: reason, message: message)
        case .available(let decisions):
            await report(UserFacingStatus.classifyingContent.text)
            state = try await ClauseBoundaryStep.assess(
                source: step.source, text: step.text, next: step.successor, decisions: decisions
            )
        }
        try ensureActive()

        var events: [TranscriptEvent] = []
        switch state {
        case .assessed(let assessment):
            let event = try await append(ClauseEventType.boundaryAssessed, stage: .clauseBoundary, payload: assessment,
                                         kind: .clauseBoundaryAssessed(assessment))
            events.append(event)
            composer.setFillerRanges(assessment.fillerRanges, for: assessment.source)
            boundaryCounts.assessed += 1
        case .pending(let reason, let message):
            let payload = ClauseBoundaryPendingPayload(source: step.source, reason: reason, message: message)
            events.append(try await append(ClauseEventType.boundaryPending, stage: .clauseBoundary, payload: payload,
                                           kind: .clauseBoundaryPending(payload)))
            boundaryCounts.pending += 1
            try await recordPending([.boundary(step.source)])
            await reportPending(message: message)
        }
        let delta = try assembly.consume(ClauseAssemblyInput(source: step.source, text: step.text, state: state))
        try await close(delta.closed, preceding: events, alreadyClosed: [])
    }

    private func completeRuns() async throws {
        let finished = try assembly.finish().closed
        try await close(finished, preceding: [], alreadyClosed: [])
        for stage in [ProcessingStage.clauseBoundary, .contentPriority]
        where startedRuns.contains(stage) && !completedRuns.contains(stage) {
            let counts = stage == .clauseBoundary
                ? (completed: boundaryCounts.assessed, failed: boundaryCounts.pending)
                : (completed: priorityCounts.classified, failed: priorityCounts.pending)
            _ = try await save(EventDraft(
                eventType: "processing.run.completed", sessionID: sessionID,
                processingRunID: stage == .clauseBoundary ? boundaryRunID : priorityRunID,
                payload: ProcessingRunCompletedPayload(
                    stage: stage, succeeded: true, completedCount: counts.completed, failedCount: counts.failed
                )
            ))
            completedRuns.insert(stage)
        }
    }

    /// Saves new clauses, shows only new events, then classifies unassigned text in batches of 40.
    private func close(
        _ units: [ClauseUnit],
        preceding: [TranscriptEvent],
        alreadyClosed: [ClauseUnit]
    ) async throws {
        var events = preceding
        var targets: [(reference: ClauseReference, text: String)] = []
        do {
            for unit in units {
                events.append(try await append(ClauseEventType.clauseClosed, stage: .clauseBoundary, payload: unit,
                                               kind: .clauseClosed(unit)))
            }
            for unit in alreadyClosed + units {
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
        guard !completedRuns.contains(stage) else { throw LiveContentPriorityError.invalidRecovery }
        let runID = stage == .clauseBoundary ? boundaryRunID : priorityRunID
        if !startedRuns.contains(stage) {
            let provenance: RunProvenance
            switch stage {
            case .clauseBoundary:
                provenance = boundaryProvenance
                    ?? DecisionRunProvenance.unavailable()
            case .contentPriority:
                provenance = priorityProvenance
                    ?? DecisionRunProvenance.unavailable()
            default:
                preconditionFailure("Live decisions require a boundary or priority stage")
            }
            _ = try await save(EventDraft(
                eventType: "processing.run.started", sessionID: sessionID, processingRunID: runID,
                payload: ProcessingRunStartedPayload(stage: stage, provenance: provenance)
            ))
            startedRuns.insert(stage)
        }
        let envelope = try await save(EventDraft(
            eventType: eventType, sessionID: sessionID, processingRunID: runID, payload: payload
        ))
        return TranscriptEvent.clause(seq: envelope.eventSeq, runID: runID, kind: kind)
    }

    /// Every log write goes through here so that `stop` can wait for the ones already started.
    private func save<Payload: Codable & Sendable>(_ draft: EventDraft<Payload>) async throws -> EventEnvelope<Payload> {
        try ensureActive()
        writesInFlight += 1
        defer {
            writesInFlight -= 1
            if writesInFlight == 0 {
                let waiters = quiescenceWaiters
                quiescenceWaiters = []
                waiters.forEach { $0.resume() }
            }
        }
        return try await writer.append(draft)
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
