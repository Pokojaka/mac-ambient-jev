import Foundation
import MacAmbientJevCore

public enum ReplacementGeneration: Sendable, Equatable {
    case notOpened
    case opened(UUID)
}

private final class ReplacementGenerationBinding: @unchecked Sendable {
    private enum State {
        case notOpened
        case opening(UUID)
        case opened(UUID)
    }

    private let lock = NSLock()
    private var state = State.notOpened

    func generation() -> ReplacementGeneration {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .notOpened, .opening(_):
            return .notOpened
        case .opened(let id):
            return .opened(id)
        }
    }

    func beginOpening(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .notOpened = state else { return false }
        state = .opening(id)
        return true
    }

    func didAppend(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard case .opening(id) = state else {
            preconditionFailure("replacement generation must be reserved before its durable append")
        }
        state = .opened(id)
    }

    func didNotAppend(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard case .opening(id) = state else {
            preconditionFailure("only an unappended replacement reservation can be released")
        }
        state = .notOpened
    }
}

public struct SessionFinalizationPolicy: Sendable, Equatable {
    private enum State: Sendable {
        case reject
        case replacement(ReplacementGenerationBinding)
    }

    private let state: State

    private init(state: State) {
        self.state = state
    }

    public static let reject = SessionFinalizationPolicy(state: .reject)

    fileprivate static func admittedReplacement() -> SessionFinalizationPolicy {
        SessionFinalizationPolicy(state: .replacement(ReplacementGenerationBinding()))
    }

    public static func == (lhs: SessionFinalizationPolicy, rhs: SessionFinalizationPolicy) -> Bool {
        switch (lhs.state, rhs.state) {
        case (.reject, .reject): true
        case (.replacement(let left), .replacement(let right)):
            left.generation() == right.generation()
        default: false
        }
    }

    public var isReplacement: Bool {
        if case .replacement = state { true } else { false }
    }

    public var replacementGeneration: ReplacementGeneration {
        switch state {
        case .reject: .notOpened
        case .replacement(let binding): binding.generation()
        }
    }

    func reserveReplacementGeneration(_ id: UUID) throws {
        guard case .replacement(let binding) = state else {
            preconditionFailure("only an admitted replacement can reserve a generation")
        }
        guard binding.beginOpening(id) else {
            throw SessionProcessingQueueError.replacementMustEnterThroughAdmission
        }
    }

    func replacementGenerationDidAppend(_ id: UUID) {
        guard case .replacement(let binding) = state else {
            preconditionFailure("only an admitted replacement can bind a generation")
        }
        binding.didAppend(id)
    }

    func replacementGenerationDidNotAppend(_ id: UUID) {
        guard case .replacement(let binding) = state else {
            preconditionFailure("only an admitted replacement can release a generation reservation")
        }
        binding.didNotAppend(id)
    }
}

public enum SessionProcessingQueueError: Error, LocalizedError, Equatable {
    case replacementMustEnterThroughAdmission
    case terminalRequestAlreadyCompleted

    public var errorDescription: String? {
        switch self {
        case .replacementMustEnterThroughAdmission:
            "再処理要求は admission を通してのみキューに追加できます"
        case .terminalRequestAlreadyCompleted:
            "完了済み処理要求はキューに再追加できません"
        }
    }
}

public enum PendingProcessing: Sendable {
    case finalize(
        requestID: UUID = UUID(), sessionID: UUID, metadataPolicy: SessionFinalizationPolicy
    )
    case retryContentPriority(
        requestID: UUID = UUID(),
        sessionID: UUID,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference]
    )

    public var requestID: UUID {
        switch self {
        case .finalize(let requestID, _, _),
             .retryContentPriority(let requestID, _, _, _):
            requestID
        }
    }

    public var sessionID: UUID {
        switch self {
        case .finalize(_, let sessionID, _),
             .retryContentPriority(_, let sessionID, _, _):
            sessionID
        }
    }

    public var finalizesTranscript: Bool {
        switch self {
        case .finalize:
            true
        case .retryContentPriority:
            false
        }
    }

    var isReplacement: Bool {
        guard case .finalize(_, _, let policy) = self else { return false }
        return policy.isReplacement
    }

}

/// Why a request waits in `held`. An inference hold ends with its condition; a pause ends only by explicit resume.
public enum ProcessingHoldReason: Sendable, Equatable {
    case inference(InferenceHoldReason)
    case paused
}

public enum ProcessingRequestHold: Sendable, Equatable {
    case inference(InferenceHoldReason)
    case paused
    case models
    case pending

    public var resumesInProcess: Bool {
        switch self {
        case .inference, .models, .pending: true
        case .paused: false
        }
    }
}

public enum ProcessingRequestKind: Sendable, Equatable {
    case finalization
    case replacement
    case decisionRetry
}

/// A read-only projection of queued work for clients outside the processing coordinator.
public struct ProcessingQueueItemSummary: Sendable, Equatable {
    public let requestID: UUID
    public let sessionID: UUID
    public let kind: ProcessingRequestKind
    public let holdReason: ProcessingRequestHold?

    public init(requestID: UUID, sessionID: UUID, kind: ProcessingRequestKind, holdReason: ProcessingRequestHold?) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.kind = kind
        self.holdReason = holdReason
    }
}

public struct ProcessingQueueSnapshot: Sendable, Equatable {
    public static let empty = ProcessingQueueSnapshot(
        summaries: [], pending: [], held: [], modelHeld: [], currentSessionID: nil,
        isMaintainingStorage: false, recoveryClaimedSessionIDs: [], claimedSessionIDs: [],
        sessionIDs: [], liveProjectionSessionIDs: []
    )

    public let summaries: [ProcessingQueueItemSummary]
    public let pending: [ProcessingQueueItemSummary]
    public let held: [ProcessingQueueItemSummary]
    public let modelHeld: [ProcessingQueueItemSummary]
    public let currentSessionID: UUID?
    public let isMaintainingStorage: Bool
    public let recoveryClaimedSessionIDs: Set<UUID>
    public let claimedSessionIDs: Set<UUID>
    public let sessionIDs: Set<UUID>
    public let liveProjectionSessionIDs: Set<UUID>

    public func containsProcessing(_ id: UUID) -> Bool {
        sessionIDs.contains(id)
    }

    public func containsQueuedWork(_ id: UUID) -> Bool {
        claimedSessionIDs.contains(id) || liveProjectionSessionIDs.contains(id)
    }
}

struct SessionProcessingQueue: Sendable {
    private(set) var pending: [PendingProcessing] = []
    private(set) var held: [(request: PendingProcessing, reason: ProcessingHoldReason)] = []
    /// Finalizing work that waits for the models to be fetched, verified and loaded.
    private(set) var modelHeld: [PendingProcessing] = []
    private(set) var currentSessionID: UUID?
    private(set) var isMaintainingStorage = false
    private(set) var recoveryClaimedSessionIDs: Set<UUID> = []
    private var currentRequest: PendingProcessing?
    private var resourceCleanupHolds: [UUID: InferenceHoldReason] = [:]
    private var terminalRequestIDs: Set<UUID> = []
    private var finalizationGate = SavedSessionReprocessGate()

    init() {}

    func summary(for request: PendingProcessing, holdReason: ProcessingRequestHold?) -> ProcessingQueueItemSummary {
        let kind: ProcessingRequestKind = if request.isReplacement {
            .replacement
        } else if request.finalizesTranscript {
            .finalization
        } else {
            .decisionRetry
        }
        return ProcessingQueueItemSummary(
            requestID: request.requestID, sessionID: request.sessionID, kind: kind, holdReason: holdReason
        )
    }

    private func holdSummary(_ reason: ProcessingHoldReason) -> ProcessingRequestHold {
        switch reason {
        case .inference(let reason): .inference(reason)
        case .paused: .paused
        }
    }

    /// Queue contents without exposing mutable requests or their generation-binding policy.
    var summaries: [ProcessingQueueItemSummary] {
        var result: [ProcessingQueueItemSummary] = []
        if let currentRequest { result.append(summary(for: currentRequest, holdReason: nil)) }
        result += pending.map { request in
            summary(for: request, holdReason: resourceCleanupHolds[request.requestID].map(ProcessingRequestHold.inference) ?? .pending)
        }
        result += held.map { entry in
            summary(for: entry.request, holdReason: holdSummary(entry.reason))
        }
        result += modelHeld.map { summary(for: $0, holdReason: .models) }
        return result
    }

    var pendingSummaries: [ProcessingQueueItemSummary] {
        pending.map { request in
            summary(for: request, holdReason: resourceCleanupHolds[request.requestID].map(ProcessingRequestHold.inference) ?? .pending)
        }
    }

    var heldSummaries: [ProcessingQueueItemSummary] {
        held.map { entry in summary(for: entry.request, holdReason: holdSummary(entry.reason)) }
    }

    var modelHeldSummaries: [ProcessingQueueItemSummary] {
        modelHeld.map { summary(for: $0, holdReason: .models) }
    }

    var claimedSessionIDs: Set<UUID> { finalizationGate.sessionIDs }

    var sessionIDs: Set<UUID> {
        finalizationGate.sessionIDs
            .union(recoveryClaimedSessionIDs)
            .union(liveProjectionSessionIDs)
    }

    var liveProjectionSessionIDs: Set<UUID> {
        Set(pending.map(\.sessionID))
            .union(held.map { $0.request.sessionID })
            .union(modelHeld.map(\.sessionID))
            .union(currentSessionID.map { [$0] } ?? [])
    }

    var snapshot: ProcessingQueueSnapshot {
        ProcessingQueueSnapshot(
            summaries: summaries,
            pending: pendingSummaries,
            held: heldSummaries,
            modelHeld: modelHeldSummaries,
            currentSessionID: currentSessionID,
            isMaintainingStorage: isMaintainingStorage,
            recoveryClaimedSessionIDs: recoveryClaimedSessionIDs,
            claimedSessionIDs: claimedSessionIDs,
            sessionIDs: sessionIDs,
            liveProjectionSessionIDs: liveProjectionSessionIDs
        )
    }

    func containsProcessing(_ id: UUID) -> Bool {
        containsQueuedWork(id) || recoveryClaimedSessionIDs.contains(id)
    }

    func containsQueuedWork(_ id: UUID) -> Bool {
        finalizationGate.sessionIDs.contains(id)
            || currentSessionID == id
            || pending.contains { $0.sessionID == id }
            || held.contains { $0.request.sessionID == id }
            || modelHeld.contains { $0.sessionID == id }
    }

    func completionHold(for requestID: UUID) -> ProcessingRequestHold? {
        if let entry = held.first(where: { $0.request.requestID == requestID }) {
            return holdSummary(entry.reason)
        }
        if modelHeld.contains(where: { $0.requestID == requestID }) { return .models }
        if pending.contains(where: { $0.requestID == requestID }) {
            return resourceCleanupHolds[requestID].map(ProcessingRequestHold.inference) ?? .pending
        }
        return nil
    }

    @discardableResult
    mutating func claimReprocessing(_ id: UUID) -> Bool {
        finalizationGate.claim(id)
    }

    /// The only constructor for replacement work; admission and insertion share this queue mutation.
    @discardableResult
    mutating func enqueueAdmittedReplacement(sessionID: UUID) -> UUID? {
        guard !containsProcessing(sessionID), finalizationGate.claim(sessionID) else { return nil }
        let requestID = UUID()
        pending.append(.finalize(
            requestID: requestID, sessionID: sessionID, metadataPolicy: .admittedReplacement()
        ))
        return requestID
    }

    mutating func releaseReprocessing(_ id: UUID) {
        finalizationGate.release(id)
    }

    mutating func claimRecovery(_ ids: Set<UUID>) {
        recoveryClaimedSessionIDs.formUnion(ids)
    }

    mutating func releaseRecovery(_ ids: Set<UUID>) {
        recoveryClaimedSessionIDs.subtract(ids)
    }

    mutating func enqueue(_ request: PendingProcessing) throws {
        guard !request.isReplacement else {
            throw SessionProcessingQueueError.replacementMustEnterThroughAdmission
        }
        guard !terminalRequestIDs.contains(request.requestID) else {
            throw SessionProcessingQueueError.terminalRequestAlreadyCompleted
        }
        enqueueOrdinary(request)
    }

    mutating func enqueueOrdinary(_ request: PendingProcessing) {
        precondition(!request.isReplacement, "replacement requests must enter through reprocess admission")
        precondition(
            !terminalRequestIDs.contains(request.requestID),
            "terminal processing request \(request.requestID) was queued again"
        )
        pending.append(request)
    }

    mutating func dequeue() -> PendingProcessing? {
        precondition(currentSessionID == nil, "処理中のセッションがある間はキューから取り出せません")
        guard let request = pending.first else { return nil }
        precondition(
            !terminalRequestIDs.contains(request.requestID),
            "terminal processing request \(request.requestID) was queued again"
        )
        return pending.removeFirst()
    }

    mutating func begin(_ request: PendingProcessing) {
        precondition(currentSessionID == nil, "処理中のセッションがある間は別のセッションを開始できません")
        currentSessionID = request.sessionID
        currentRequest = request
    }

    mutating func completeCurrent(terminal: Bool = false) {
        precondition(currentSessionID != nil, "処理中のセッションがないため完了できません")
        if terminal, let currentRequest,
           !terminalRequestIDs.insert(currentRequest.requestID).inserted {
            preconditionFailure("terminal processing request \(currentRequest.requestID) completed more than once")
        }
        currentSessionID = nil
        currentRequest = nil
    }

    mutating func hold(_ request: PendingProcessing, reason: ProcessingHoldReason) {
        held.append((request: request, reason: reason))
        if case .inference(let reason) = reason, reason != .thermal {
            resourceCleanupHolds[request.requestID] = reason
        }
    }

    mutating func holdForModels(_ request: PendingProcessing) {
        modelHeld.append(request)
    }

    mutating func resourceCleanupDidFinish(requestID: UUID) {
        resourceCleanupHolds.removeValue(forKey: requestID)
    }

    /// Moves the model-held work to the front of `pending` in its original order.
    @discardableResult
    mutating func resumeModelHeld(modelsReady: Bool, pausesProcessing: Bool) -> Bool {
        guard modelsReady, !modelHeld.isEmpty, !pausesProcessing else {
            return false
        }
        pending.insert(contentsOf: modelHeld, at: 0)
        modelHeld = []
        return true
    }

    /// Moves the held work whose hold has ended to the front of `pending`, in its original order.
    @discardableResult
    mutating func resumeHeld(
        activeInferenceHold: InferenceHoldReason?,
        releasesPauses: Bool,
        pausesProcessing: Bool
    ) -> Bool {
        guard !pausesProcessing else { return false }
        var ended: [PendingProcessing] = []
        var remaining: [(request: PendingProcessing, reason: ProcessingHoldReason)] = []
        for entry in held {
            let hasEnded = switch entry.reason {
            case .inference: activeInferenceHold == nil
            case .paused: releasesPauses
            }
            if hasEnded { ended.append(entry.request) } else { remaining.append(entry) }
        }
        guard !ended.isEmpty else { return false }
        held = remaining
        pending.insert(contentsOf: ended, at: 0)
        return true
    }

    /// Moves a thermally held finalization back to the front of `pending`, so it is decided again now.
    @discardableResult
    mutating func wakeHeldFinalization(sessionID: UUID) -> Bool {
        guard let index = held.firstIndex(where: {
            $0.reason == .inference(.thermal) && $0.request.finalizesTranscript && $0.request.sessionID == sessionID
        }) else { return false }
        pending.insert(held.remove(at: index).request, at: 0)
        return true
    }

    mutating func beginStorageMaintenance() {
        isMaintainingStorage = true
    }

    mutating func endStorageMaintenance() {
        isMaintainingStorage = false
    }
}
