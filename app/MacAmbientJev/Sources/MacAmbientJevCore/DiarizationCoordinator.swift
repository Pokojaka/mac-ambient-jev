import Foundation

public struct DiarizationBatchResult: Sendable, Equatable {
    public let speakerSpans: [SpeakerSpan]
    public let events: [TranscriptEvent]
    public let materializedSegments: [MaterializedTranscriptSegment]

    public init(
        speakerSpans: [SpeakerSpan],
        events: [TranscriptEvent],
        materializedSegments: [MaterializedTranscriptSegment]
    ) {
        self.speakerSpans = speakerSpans
        self.events = events
        self.materializedSegments = materializedSegments
    }
}

public actor DiarizationCoordinator {
    private let sessionID: UUID
    private let runID: String
    private let writer: SessionWriter
    private let engine: any DiarizationEngine
    private let materializer: TranscriptMaterializer

    public init(
        sessionID: UUID,
        runID: String,
        writer: SessionWriter,
        engine: any DiarizationEngine,
        materializer: TranscriptMaterializer
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.writer = writer
        self.engine = engine
        self.materializer = materializer
    }

    public func process(
        fileURL: URL,
        canonicalSampleRate: Double,
        existingEvents: [TranscriptEvent],
        activeRuns: ActiveRuns
    ) async throws -> DiarizationBatchResult {
        try await engine.prepare()
        let spans = try await engine.diarize(
            fileURL: fileURL,
            canonicalSampleRate: canonicalSampleRate
        )

        var events = existingEvents
        for span in spans {
            let envelope = try await writer.append(EventDraft(
                eventType: "speaker.span",
                sessionID: sessionID,
                processingRunID: runID,
                sourceStartFrame: span.startFrame,
                sourceEndFrame: span.endFrame,
                payload: span
            ))
            events.append(.speakerSpan(
                seq: envelope.eventSeq,
                runID: runID,
                speakerID: span.speakerID,
                startFrame: span.startFrame,
                endFrame: span.endFrame,
                confidence: span.confidence
            ))
        }

        _ = try await writer.append(EventDraft(
            eventType: "processing.run.completed",
            sessionID: sessionID,
            processingRunID: runID,
            payload: ProcessingRunCompletedPayload(
                stage: .diarization,
                succeeded: true,
                completedCount: spans.count,
                failedCount: 0
            )
        ))

        let materialized = materializer.materialize(
            events: events,
            activeRuns: activeRuns
        )

        return DiarizationBatchResult(
            speakerSpans: spans,
            events: events,
            materializedSegments: materialized
        )
    }
}
