import Foundation
import MacAmbientJevCore

@MainActor
public final class LiveTranscriptionState {
    public var vadSegmentCount = 0
    public var vadFailureText: String?
    public var contentPriorityStatus: [UUID: String] = [:]

    private var queues: [UUID: [[SegmentReference]]] = [:]
    private var latestCheckpoints: [UUID: AudioCheckpoint] = [:]
    private var failures: [UUID: String] = [:]

    public init() {}

    public func begin(sessionID: UUID) {
        queues[sessionID] = []
        failures.removeValue(forKey: sessionID)
    }

    public func failure(sessionID: UUID) -> String? {
        failures[sessionID]
    }

    public func recordFailure(sessionID: UUID, message: String, discardQueued: Bool) {
        failures[sessionID] = message
        if discardQueued {
            queues[sessionID] = []
        }
    }

    public func enqueue(
        sessionID: UUID,
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint
    ) {
        precondition(!segments.isEmpty, "登録する発話区間が空です")
        precondition(failures[sessionID] == nil, "失敗済みのセッションには発話区間を登録できません")
        latestCheckpoints[sessionID] = checkpoint
        queues[sessionID, default: []].append(segments)
    }

    /// Drops the queued batches without recording a failure. Their segments stay registered, so
    /// finalization recognizes them.
    public func discardQueued(sessionID: UUID) {
        queues[sessionID] = []
    }

    public func hasQueued(sessionID: UUID) -> Bool {
        queues[sessionID]?.isEmpty == false
    }

    func queuedSegments(sessionID: UUID) -> [SegmentReference] {
        queues[sessionID, default: []].flatMap { $0 }
    }

    func queuedBatchCount(sessionID: UUID) -> Int {
        queues[sessionID]?.count ?? 0
    }

    func latestCheckpoint(sessionID: UUID) -> AudioCheckpoint? {
        latestCheckpoints[sessionID]
    }

    public func pendingSegmentCount(sessionID: UUID) -> Int {
        queues[sessionID, default: []].reduce(into: 0) { count, batch in
            count += batch.count
        }
    }

    public func dequeue(sessionID: UUID) -> (segments: [SegmentReference], checkpoint: AudioCheckpoint)? {
        guard failures[sessionID] == nil,
              var queue = queues[sessionID],
              !queue.isEmpty
        else {
            return nil
        }
        guard let checkpoint = latestCheckpoints[sessionID] else {
            preconditionFailure("ASR キューに対応する音声チェックポイントがありません")
        }
        let segments = queue.removeFirst()
        queues[sessionID] = queue
        return (segments, checkpoint)
    }

    public var isQueueEmpty: Bool {
        queues.values.allSatisfy(\.isEmpty)
    }

    public func cleanup(sessionID: UUID) {
        queues.removeValue(forKey: sessionID)
        latestCheckpoints.removeValue(forKey: sessionID)
        failures.removeValue(forKey: sessionID)
        contentPriorityStatus.removeValue(forKey: sessionID)
    }

    public func resetVAD() {
        vadFailureText = nil
        vadSegmentCount = 0
    }
}
