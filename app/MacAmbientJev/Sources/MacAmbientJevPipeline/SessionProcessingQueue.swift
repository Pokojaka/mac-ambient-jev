import Foundation
import MacAmbientJevCore

public enum PendingProcessing: Sendable {
    case finalize(sessionID: UUID, metadataPolicy: UnreadableMetadataPolicy)
    case retryContentPriority(
        sessionID: UUID,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference]
    )

    public var sessionID: UUID {
        switch self {
        case .finalize(let sessionID, _),
             .retryContentPriority(let sessionID, _, _):
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
}

/// Why a request waits in `held`. An inference hold ends with its condition; a pause (a cancellation or the
/// app pausing processing) ends only by an explicit resume.
public enum ProcessingHoldReason: Sendable, Equatable {
    case inference(InferenceHoldReason)
    case paused
}

public struct SessionProcessingQueue: Sendable {
    public private(set) var pending: [PendingProcessing] = []
    public private(set) var held: [(request: PendingProcessing, reason: ProcessingHoldReason)] = []
    /// Finalizing work that waits for the models to be fetched, verified and loaded.
    public private(set) var modelHeld: [PendingProcessing] = []
    public private(set) var currentSessionID: UUID?
    public private(set) var isMaintainingStorage = false
    private var finalizationGate = SavedSessionReprocessGate()

    public init() {}

    public var claimedSessionIDs: Set<UUID> { finalizationGate.sessionIDs }

    public var sessionIDs: Set<UUID> {
        finalizationGate.sessionIDs
            .union(pending.map(\.sessionID))
            .union(held.map { $0.request.sessionID })
            .union(modelHeld.map(\.sessionID))
            .union(currentSessionID.map { [$0] } ?? [])
    }

    public func containsForReprocessing(_ id: UUID) -> Bool {
        finalizationGate.sessionIDs.contains(id)
            || currentSessionID == id
            || pending.contains { $0.sessionID == id }
            || held.contains { $0.request.sessionID == id }
    }

    @discardableResult
    public mutating func claimReprocessing(_ id: UUID) -> Bool {
        guard !containsForReprocessing(id) else { return false }
        return finalizationGate.claim(id)
    }

    public mutating func releaseReprocessing(_ id: UUID) {
        finalizationGate.release(id)
    }

    public mutating func enqueue(_ request: PendingProcessing) {
        pending.append(request)
    }

    public mutating func dequeue() -> PendingProcessing? {
        precondition(currentSessionID == nil, "処理中のセッションがある間はキューから取り出せません")
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    public mutating func begin(_ request: PendingProcessing) {
        precondition(currentSessionID == nil, "処理中のセッションがある間は別のセッションを開始できません")
        currentSessionID = request.sessionID
    }

    public mutating func completeCurrent() {
        precondition(currentSessionID != nil, "処理中のセッションがないため完了できません")
        currentSessionID = nil
    }

    public mutating func hold(_ request: PendingProcessing, reason: ProcessingHoldReason) {
        held.append((request: request, reason: reason))
    }

    public mutating func holdForModels(_ request: PendingProcessing) {
        modelHeld.append(request)
    }

    /// Moves the model-held work to the front of `pending` in its original order.
    @discardableResult
    public mutating func resumeModelHeld(modelsReady: Bool, pausesProcessing: Bool) -> Bool {
        guard modelsReady, !modelHeld.isEmpty, !pausesProcessing else {
            return false
        }
        pending.insert(contentsOf: modelHeld, at: 0)
        modelHeld = []
        return true
    }

    /// Moves the held work whose hold has ended to the front of `pending`, in its original order.
    /// Inference holds end when no inference hold is active; pauses end only when `releasesPauses`.
    @discardableResult
    public mutating func resumeHeld(
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
    public mutating func wakeHeldFinalization(sessionID: UUID) -> Bool {
        guard let index = held.firstIndex(where: {
            $0.reason == .inference(.thermal) && $0.request.finalizesTranscript && $0.request.sessionID == sessionID
        }) else { return false }
        pending.insert(held.remove(at: index).request, at: 0)
        return true
    }

    public mutating func beginStorageMaintenance() {
        isMaintainingStorage = true
    }

    public mutating func endStorageMaintenance() {
        isMaintainingStorage = false
    }
}
