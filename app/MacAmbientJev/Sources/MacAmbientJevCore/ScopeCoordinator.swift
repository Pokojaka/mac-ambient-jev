import Foundation

public struct ProximityEvidenceSpan: Sendable, Equatable {
    public let startFrame: Int64
    public let endFrame: Int64
    public let evidence: ProximityEvidence

    public init(
        startFrame: Int64,
        endFrame: Int64,
        evidence: ProximityEvidence
    ) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.evidence = evidence
    }
}

public protocol ProximityEvidenceProvider: Sendable {
    func evidenceSpans(
        startFrame: Int64,
        endFrame: Int64,
        speakerSpans: [SpeakerSpan]
    ) async throws -> [ProximityEvidenceSpan]
}

public struct UnknownProximityEvidenceProvider: ProximityEvidenceProvider {
    public init() {}

    public func evidenceSpans(
        startFrame: Int64,
        endFrame: Int64,
        speakerSpans: [SpeakerSpan]
    ) async throws -> [ProximityEvidenceSpan] {
        guard endFrame > startFrame else { return [] }

        return [
            ProximityEvidenceSpan(
                startFrame: startFrame,
                endFrame: endFrame,
                evidence: .unknown
            )
        ]
    }
}

public struct ScopeBatchResult: Sendable, Equatable {
    public let scopeSpans: [ScopeSpan]
    public let events: [TranscriptEvent]
    public let materializedSegments: [MaterializedTranscriptSegment]

    public init(
        scopeSpans: [ScopeSpan],
        events: [TranscriptEvent],
        materializedSegments: [MaterializedTranscriptSegment]
    ) {
        self.scopeSpans = scopeSpans
        self.events = events
        self.materializedSegments = materializedSegments
    }
}

public actor ScopeCoordinator {
    private let sessionID: UUID
    private let runID: String
    private let writer: SessionWriter
    private let provider: any ProximityEvidenceProvider
    private let classifier: ScopeClassifier
    private let materializer: TranscriptMaterializer

    public init(
        sessionID: UUID,
        runID: String,
        writer: SessionWriter,
        provider: any ProximityEvidenceProvider,
        classifier: ScopeClassifier = ScopeClassifier(),
        materializer: TranscriptMaterializer
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.writer = writer
        self.provider = provider
        self.classifier = classifier
        self.materializer = materializer
    }

    public func process(
        existingEvents: [TranscriptEvent],
        speakerSpans: [SpeakerSpan],
        activeRuns: ActiveRuns
    ) async throws -> ScopeBatchResult {
        let ordered = existingEvents.sorted { $0.eventSeq < $1.eventSeq }
        let scenes = SceneTransitionTimeline(events: ordered, activeSceneRunID: activeRuns.scene)
        let segments = ordered.filter { event in
            guard case .segmentCreated = event.kind else {
                return false
            }
            return activeRuns.segmentation == nil
                || event.segmentationRunID == activeRuns.segmentation
        }

        var events = existingEvents
        var resultSpans: [ScopeSpan] = []

        for segment in segments {
            guard let startFrame = segment.sourceStartFrame,
                  let endFrame = segment.sourceEndFrame,
                  endFrame > startFrame else {
                continue
            }

            let evidenceSpans = try await provider.evidenceSpans(
                startFrame: startFrame,
                endFrame: endFrame,
                speakerSpans: speakerSpans
            )

            for evidenceSpan in evidenceSpans {
                let clippedStart = max(startFrame, evidenceSpan.startFrame)
                let clippedEnd = min(endFrame, evidenceSpan.endFrame)
                guard clippedEnd > clippedStart else { continue }

                var boundaries = Set<Int64>([
                    clippedStart,
                    clippedEnd
                ])
                for transitionFrame in scenes.frames(after: clippedStart, before: clippedEnd) {
                    boundaries.insert(transitionFrame)
                }
                let points = boundaries.sorted()
                guard points.count >= 2 else { continue }

                for index in 0..<(points.count - 1) {
                    let spanStart = points[index]
                    let spanEnd = points[index + 1]
                    guard spanEnd > spanStart else { continue }

                    let spanScene = scenes.scene(at: spanStart)
                    let classification = classifier.classify(
                        evidence: evidenceSpan.evidence,
                        scene: spanScene
                    )
                    let scopeSpan = ScopeSpan(
                        startFrame: spanStart,
                        endFrame: spanEnd,
                        scope: classification.scope,
                        confidence: classification.confidence
                    )

                    let envelope = try await writer.append(EventDraft(
                        eventType: "scope.span",
                        sessionID: sessionID,
                        processingRunID: runID,
                        segmentID: segment.segmentID,
                        sourceStartFrame: spanStart,
                        sourceEndFrame: spanEnd,
                        payload: scopeSpan
                    ))
                    events.append(.scopeSpan(
                        seq: envelope.eventSeq,
                        runID: runID,
                        startFrame: spanStart,
                        endFrame: spanEnd,
                        scope: classification.scope,
                        confidence: classification.confidence
                    ))
                    resultSpans.append(scopeSpan)
                }
            }
        }

        _ = try await writer.append(EventDraft(
            eventType: "processing.run.completed",
            sessionID: sessionID,
            processingRunID: runID,
            payload: ProcessingRunCompletedPayload(
                stage: .scope,
                succeeded: true,
                completedCount: resultSpans.count,
                failedCount: 0
            )
        ))

        var selectedRuns = activeRuns
        selectedRuns.markCompleted(
            stage: .scope,
            runID: runID,
            succeeded: true
        )
        try selectedRuns.select(stage: .scope, runID: runID)

        return ScopeBatchResult(
            scopeSpans: resultSpans,
            events: events,
            materializedSegments: materializer.materialize(
                events: events,
                activeRuns: selectedRuns
            )
        )
    }
}
