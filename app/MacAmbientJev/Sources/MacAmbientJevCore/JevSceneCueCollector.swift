import Foundation

public struct SemanticSceneCueEventPayload: Codable, Sendable, Equatable {
    public let cue: SemanticSceneCue
    public let confidence: Double?
    public let model: String?
    public let inputTokens: Int?
    public let needsRetry: Bool

    public init(
        cue: SemanticSceneCue,
        confidence: Double?,
        model: String?,
        inputTokens: Int?,
        needsRetry: Bool
    ) {
        self.cue = cue
        self.confidence = confidence
        self.model = model
        self.inputTokens = inputTokens
        self.needsRetry = needsRetry
    }
}

public struct JevSceneCueCollection: Sendable, Equatable {
    public let cues: [TimedSemanticSceneCue]
    public let retryPendingSegmentIDs: [String]

    public init(
        cues: [TimedSemanticSceneCue],
        retryPendingSegmentIDs: [String]
    ) {
        self.cues = cues
        self.retryPendingSegmentIDs = retryPendingSegmentIDs
    }
}

public actor JevSceneCueCollector {
    private let sessionID: UUID
    private let runID: String
    private let writer: SessionWriter
    private let decisions: JevDecisionCoordinator
    private let sampleRate: Double

    public init(
        sessionID: UUID,
        runID: String,
        writer: SessionWriter,
        decisions: JevDecisionCoordinator,
        sampleRate: Double
    ) {
        precondition(sampleRate > 0)
        self.sessionID = sessionID
        self.runID = runID
        self.writer = writer
        self.decisions = decisions
        self.sampleRate = sampleRate
    }

    public func collect(
        segments: [MaterializedTranscriptSegment]
    ) async throws -> JevSceneCueCollection {
        var previousTexts: [String] = []
        var cues: [TimedSemanticSceneCue] = []
        var retryPendingSegmentIDs: [String] = []

        for segment in segments.sorted(by: {
            $0.startMilliseconds < $1.startMilliseconds
        }) where JevTranscriptEligibility.isEligible(segment.text) {
            let result = await decisions.classifySceneCue(
                currentText: segment.text,
                previousTexts: previousTexts,
                currentScene: segment.scene
            )

            let payload = SemanticSceneCueEventPayload(
                cue: result.cue,
                confidence: result.decision?.confidence,
                model: result.decision?.model,
                inputTokens: result.decision?.inputTokens,
                needsRetry: result.needsRetry
            )
            _ = try await writer.append(EventDraft(
                eventType: "scene_cue.assigned",
                sessionID: sessionID,
                processingRunID: runID,
                segmentID: segment.segmentID,
                payload: payload
            ))

            if result.needsRetry {
                retryPendingSegmentIDs.append(segment.segmentID)
                _ = try await writer.append(EventDraft(
                    eventType: "scene_cue.pending_retry",
                    sessionID: sessionID,
                    processingRunID: runID,
                    segmentID: segment.segmentID,
                    payload: EmptyPayload()
                ))
            } else if result.cue != .none {
                let frame = Int64(
                    (
                        Double(segment.startMilliseconds)
                        * sampleRate
                        / 1_000.0
                    ).rounded()
                )
                cues.append(
                    TimedSemanticSceneCue(
                        frame: frame,
                        cue: result.cue
                    )
                )
            }

            previousTexts.append(segment.text)
            if previousTexts.count > 3 {
                previousTexts.removeFirst(
                    previousTexts.count - 3
                )
            }
        }

        return JevSceneCueCollection(
            cues: cues,
            retryPendingSegmentIDs: retryPendingSegmentIDs
        )
    }
}
