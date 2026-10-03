import Foundation

public struct ContentPriorityEventPayload: Codable, Sendable, Equatable {
    public enum Decision: Codable, Sendable, Equatable {
        /// Jev classified the segment in this run.
        case classified(confidence: Double, model: String?, inputTokens: Int?)
        /// The segment stays primary until a later run classifies it.
        case retryPending
        /// This run did not resend the segment and keeps the priority that
        /// run `sourceRunID` assigned.
        case carriedOver(sourceRunID: String)
    }

    public let priority: ContentPriority
    public let decision: Decision

    public var needsRetry: Bool {
        decision == .retryPending
    }

    private enum CodingKeys: String, CodingKey {
        case priority
        case needsRetry
        case decision
    }

    public init(priority: ContentPriority, decision: Decision) {
        precondition(decision != .retryPending || priority == .primary)
        self.priority = priority
        self.decision = decision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let priority = try container.decode(ContentPriority.self, forKey: .priority)
        let decision = try container.decode(Decision.self, forKey: .decision)
        let needsRetry = try container.decode(Bool.self, forKey: .needsRetry)
        guard needsRetry == (decision == .retryPending),
              decision != .retryPending || priority == .primary else {
            throw DecodingError.dataCorruptedError(
                forKey: .needsRetry,
                in: container,
                debugDescription: "needs_retry does not match the decision"
            )
        }
        self.priority = priority
        self.decision = decision
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(priority, forKey: .priority)
        try container.encode(needsRetry, forKey: .needsRetry)
        try container.encode(decision, forKey: .decision)
    }
}

public enum JevEnrichmentError: LocalizedError, Sendable, Equatable {
    /// A retry run must carry over every segment it does not resend, but the
    /// active content priority run holds no priority for this segment.
    case noPriorityToCarryOver(segmentID: String)

    public var errorDescription: String? {
        switch self {
        case .noPriorityToCarryOver(let segmentID):
            "区間 \(segmentID) の以前の意味分類が見つからないため、再試行結果を保存できません"
        }
    }
}

public struct JevEnrichmentBatchResult: Sendable, Equatable {
    public let retryPendingSegmentIDs: [String]
    public let stopReason: JevBatchStopReason?
    public let events: [TranscriptEvent]
    public let materializedSegments: [MaterializedTranscriptSegment]

    public init(
        retryPendingSegmentIDs: [String],
        stopReason: JevBatchStopReason?,
        events: [TranscriptEvent],
        materializedSegments: [MaterializedTranscriptSegment]
    ) {
        self.retryPendingSegmentIDs = retryPendingSegmentIDs
        self.stopReason = stopReason
        self.events = events
        self.materializedSegments = materializedSegments
    }
}

/// Which segments a content-priority run sends to Jev.
public enum JevEnrichmentScope: Sendable, Equatable {
    /// Every segment with recognized text.
    case all
    /// Only these segments; every other segment carries over its active priority.
    case retry(Set<String>)
}

public actor JevEnrichmentCoordinator {
    private let sessionID: UUID
    private let runID: String
    private let writer: SessionWriter
    private let decisions: JevDecisionCoordinator
    private let materializer: TranscriptMaterializer

    public init(
        sessionID: UUID,
        runID: String,
        writer: SessionWriter,
        decisions: JevDecisionCoordinator,
        materializer: TranscriptMaterializer
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.writer = writer
        self.decisions = decisions
        self.materializer = materializer
    }

    public func process(
        existingEvents: [TranscriptEvent],
        activeRuns: ActiveRuns,
        scope: JevEnrichmentScope
    ) async throws -> JevEnrichmentBatchResult {
        let baseSegments = materializer.materialize(
            events: existingEvents,
            activeRuns: activeRuns
        ).filter(\.hasRecognizedText)
        let carriedOverPriorities = try carriedOverPriorities(
            segments: baseSegments,
            activeRuns: activeRuns,
            scope: scope
        )

        var events = existingEvents
        var retryPendingSegmentIDs: [String] = []
        var stopReason: JevBatchStopReason?

        for segment in baseSegments {
            let payload: ContentPriorityEventPayload
            if let carriedOver = carriedOverPriorities[segment.segmentID] {
                payload = carriedOver
            } else if stopReason != nil {
                await decisions.deferClassification(
                    segmentID: segment.segmentID,
                    sessionID: sessionID
                )
                payload = ContentPriorityEventPayload(
                    priority: .primary,
                    decision: .retryPending
                )
            } else {
                switch await decisions.classify(
                    text: segment.text,
                    segmentID: segment.segmentID,
                    sessionID: sessionID
                ) {
                case .classified(let decision, let visiblePriority):
                    payload = ContentPriorityEventPayload(
                        priority: visiblePriority,
                        decision: .classified(
                            confidence: decision.confidence,
                            model: decision.model,
                            inputTokens: decision.inputTokens
                        )
                    )
                case .failed(let batchStopReason):
                    stopReason = batchStopReason
                    payload = ContentPriorityEventPayload(
                        priority: .primary,
                        decision: .retryPending
                    )
                }
            }

            if payload.needsRetry {
                retryPendingSegmentIDs.append(segment.segmentID)
            }

            let envelope = try await writer.append(EventDraft(
                eventType: "content_priority.assigned",
                sessionID: sessionID,
                processingRunID: runID,
                segmentID: segment.segmentID,
                payload: payload
            ))
            events.append(.contentPriority(
                seq: envelope.eventSeq,
                runID: runID,
                segmentID: segment.segmentID,
                priority: payload.priority
            ))

            if payload.needsRetry {
                _ = try await writer.append(EventDraft(
                    eventType: "content_priority.pending_retry",
                    sessionID: sessionID,
                    processingRunID: runID,
                    segmentID: segment.segmentID,
                    payload: EmptyPayload()
                ))
            }
        }

        _ = try await writer.append(EventDraft(
            eventType: "processing.run.completed",
            sessionID: sessionID,
            processingRunID: runID,
            payload: ProcessingRunCompletedPayload(
                stage: .contentPriority,
                succeeded: true,
                completedCount: baseSegments.count,
                failedCount: retryPendingSegmentIDs.count
            )
        ))

        var selectedRuns = activeRuns
        selectedRuns.markCompleted(
            stage: .contentPriority,
            runID: runID,
            succeeded: true
        )
        try selectedRuns.select(
            stage: .contentPriority,
            runID: runID
        )

        return JevEnrichmentBatchResult(
            retryPendingSegmentIDs: retryPendingSegmentIDs,
            stopReason: stopReason,
            events: events,
            materializedSegments: materializer.materialize(
                events: events,
                activeRuns: selectedRuns
            )
        )
    }

    /// Payloads for the segments a retry run does not resend. Checked before
    /// any request so that a retry never leaves a partial run behind.
    private func carriedOverPriorities(
        segments: [MaterializedTranscriptSegment],
        activeRuns: ActiveRuns,
        scope: JevEnrichmentScope
    ) throws -> [String: ContentPriorityEventPayload] {
        guard case .retry(let retryOnlySegmentIDs) = scope else { return [:] }

        var payloads: [String: ContentPriorityEventPayload] = [:]
        for segment in segments where !retryOnlySegmentIDs.contains(segment.segmentID) {
            guard let sourceRunID = activeRuns.contentPriority,
                  let priority = segment.contentPriority else {
                throw JevEnrichmentError.noPriorityToCarryOver(
                    segmentID: segment.segmentID
                )
            }
            payloads[segment.segmentID] = ContentPriorityEventPayload(
                priority: priority,
                decision: .carriedOver(sourceRunID: sourceRunID)
            )
        }
        return payloads
    }
}
