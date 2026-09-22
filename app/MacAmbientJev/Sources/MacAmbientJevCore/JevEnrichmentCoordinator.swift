import Foundation

public struct ContentPriorityEventPayload: Codable, Sendable, Equatable {
    public let priority: ContentPriority
    public let confidence: Double?
    public let model: String?
    public let inputTokens: Int?
    public let needsRetry: Bool

    public init(
        priority: ContentPriority,
        confidence: Double?,
        model: String?,
        inputTokens: Int?,
        needsRetry: Bool
    ) {
        self.priority = priority
        self.confidence = confidence
        self.model = model
        self.inputTokens = inputTokens
        self.needsRetry = needsRetry
    }
}

public struct JevEnrichmentBatchResult: Sendable, Equatable {
    public let retryPendingSegmentIDs: [String]
    public let events: [TranscriptEvent]
    public let materializedSegments: [MaterializedTranscriptSegment]

    public init(
        retryPendingSegmentIDs: [String],
        events: [TranscriptEvent],
        materializedSegments: [MaterializedTranscriptSegment]
    ) {
        self.retryPendingSegmentIDs = retryPendingSegmentIDs
        self.events = events
        self.materializedSegments = materializedSegments
    }
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
        activeRuns: ActiveRuns
    ) async throws -> JevEnrichmentBatchResult {
        let baseSegments = materializer.materialize(
            events: existingEvents,
            activeRuns: activeRuns
        )

        var events = existingEvents
        var retryPendingSegmentIDs: [String] = []

        for segment in baseSegments {
            let result = await decisions.classify(text: segment.text)

            let payload = ContentPriorityEventPayload(
                priority: result.visiblePriority,
                confidence: result.decision?.confidence,
                model: result.decision?.model,
                inputTokens: result.decision?.inputTokens,
                needsRetry: result.needsRetry
            )

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
                priority: result.visiblePriority
            ))

            if result.needsRetry {
                retryPendingSegmentIDs.append(segment.segmentID)
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
            events: events,
            materializedSegments: materializer.materialize(
                events: events,
                activeRuns: selectedRuns
            )
        )
    }
}
