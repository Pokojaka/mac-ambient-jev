import Foundation
import MacAmbientJevCore

public enum PendingProcessing: Sendable {
    case finishLive(sessionID: UUID, checkpoint: AudioCheckpoint)
    case finalize(sessionID: UUID, metadataPolicy: UnreadableMetadataPolicy)
    case retryContentPriority(
        sessionID: UUID,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference]
    )

    public var sessionID: UUID {
        switch self {
        case .finishLive(let sessionID, _),
             .finalize(let sessionID, _),
             .retryContentPriority(let sessionID, _, _):
            sessionID
        }
    }

    public var finalizesTranscript: Bool {
        switch self {
        case .finishLive, .finalize:
            true
        case .retryContentPriority:
            false
        }
    }
}

public struct SessionProcessingQueue: Sendable {
    public private(set) var pending: [PendingProcessing] = []
    public private(set) var thermallyHeld: [PendingProcessing] = []
    public private(set) var currentSessionID: UUID?
    public private(set) var isMaintainingStorage = false
    private var finalizationGate = SavedSessionReprocessGate()

    public init() {}

    public var claimedSessionIDs: Set<UUID> { finalizationGate.sessionIDs }

    public var sessionIDs: Set<UUID> {
        finalizationGate.sessionIDs
            .union(pending.map(\.sessionID))
            .union(thermallyHeld.map(\.sessionID))
            .union(currentSessionID.map { [$0] } ?? [])
    }

    public func containsForReprocessing(_ id: UUID) -> Bool {
        finalizationGate.sessionIDs.contains(id)
            || currentSessionID == id
            || pending.contains { $0.sessionID == id }
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

    public mutating func holdForHeat(_ request: PendingProcessing) {
        thermallyHeld.append(request)
    }

    @discardableResult
    public mutating func resumeHeld(
        isCritical: Bool,
        pausesProcessing: Bool
    ) -> Bool {
        guard !isCritical, !thermallyHeld.isEmpty, !pausesProcessing else {
            return false
        }
        pending.insert(contentsOf: thermallyHeld, at: 0)
        thermallyHeld = []
        return true
    }

    public mutating func beginStorageMaintenance() {
        isMaintainingStorage = true
    }

    public mutating func endStorageMaintenance() {
        isMaintainingStorage = false
    }
}
