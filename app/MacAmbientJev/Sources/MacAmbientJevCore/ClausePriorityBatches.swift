import Foundation

public enum DecisionAvailability: Sendable {
    case available(DecisionCoordinator)
    case pending(ClausePendingReason, String)
}

/// Serial live/final/retry batching of at most 40 clauses per request.
public struct ClausePriorityBatches: Sendable {
    private let targets: [(reference: ClauseReference, text: String)]
    private var offset = 0

    public init(targets: [(reference: ClauseReference, text: String)]) throws {
        guard Set(targets.lazy.map(\.reference)).count == targets.count,
              targets.allSatisfy({ !ClauseTextComposer.isBlank($0.text) }) else {
            throw ClauseRecordError.invalidPriorityEvent
        }
        self.targets = targets
    }

    public var hasRemaining: Bool { offset < targets.count }

    /// Availability is read for each batch; it may change live.
    public mutating func next(
        isolation: isolated (any Actor)? = #isolation,
        availability: () async -> DecisionAvailability
    ) async throws -> ContentPriorityAssignedPayload {
        guard hasRemaining else { throw ClauseRecordError.invalidPriorityEvent }
        try Task.checkCancellation()
        let end = min(offset + PriorityBatchPolicy.maximumTargets, targets.count)
        let batch = targets[offset..<end]
        let current = await availability()
        try Task.checkCancellation()
        let payload: ContentPriorityAssignedPayload
        switch current {
        case .available(let decisions):
            payload = try await ClausePriorityBatch.classify(
                references: batch.map(\.reference), texts: batch.map(\.text), decisions: decisions
            )
        case .pending(let reason, let message):
            payload = try ClausePriorityBatch.pending(
                references: batch.map(\.reference), reason: reason, message: message
            )
        }
        try Task.checkCancellation()
        offset = end
        return payload
    }
}

/// Builds the assignments of one priority batch of at most 40 clauses.
public enum ClausePriorityBatch {
    /// Request-local keys `u0001`… in clause order; no source identifier is sent.
    public static func targets(texts: [String]) -> [PriorityTextTarget] {
        texts.enumerated().map { PriorityTextTarget(key: String(format: "u%04d", $0.offset + 1), text: $0.element) }
    }

    public static func classify(
        references: [ClauseReference],
        texts: [String],
        decisions: DecisionCoordinator
    ) async throws -> ContentPriorityAssignedPayload {
        guard !references.isEmpty, references.count == texts.count,
              references.count <= PriorityBatchPolicy.maximumTargets,
              Set(references).count == references.count,
              texts.allSatisfy({ !ClauseTextComposer.isBlank($0) }) else {
            throw ClauseRecordError.invalidPriorityEvent
        }
        let targets = targets(texts: texts)
        switch await decisions.classifyPriorities(targets) {
        case .answered(let response, let record):
            var assignments: [ClausePriorityAssignment] = []
            for (reference, target) in zip(references, targets) {
                guard let decision = response.decisions[target.key] else { throw DecisionResponseError.missingAnswer }
                assignments.append(try ClausePriorityAssignment(
                    reference: reference,
                    priority: ContentPriorityPolicy.visiblePriority(for: decision),
                    needsRetry: false,
                    decision: .classified(requestID: record.requestID, answerKey: target.key, response: decision)
                ))
            }
            return try ContentPriorityAssignedPayload(assignments: assignments, request: record)
        case .failed(let message):
            return try pending(references: references, reason: .requestFailed, message: message)
        case .cancelled:
            throw CancellationError()
        }
    }

    public static func pending(
        references: [ClauseReference], reason: ClausePendingReason, message: String
    ) throws -> ContentPriorityAssignedPayload {
        try ContentPriorityAssignedPayload(assignments: references.map {
            try ClausePriorityAssignment(
                reference: $0, priority: nil, needsRetry: true,
                decision: .retryPending(reason: reason, message: message)
            )
        }, request: nil)
    }
}
