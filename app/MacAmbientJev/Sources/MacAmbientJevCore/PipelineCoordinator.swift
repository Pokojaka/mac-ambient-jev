import Foundation

public struct ASRCompletedEventPayload: Codable, Sendable, Equatable {
    public let text: String
    public let detectedLanguage: String?
    public let engine: String
    public let model: String

    public init(
        text: String,
        detectedLanguage: String?,
        engine: String,
        model: String
    ) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.engine = engine
        self.model = model
    }
}

public struct ASRFailedEventPayload: Codable, Sendable, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct ProcessingRunCompletedPayload: Codable, Sendable, Equatable {
    public let stage: ProcessingStage
    public let succeeded: Bool
    public let completedCount: Int
    public let failedCount: Int

    public init(
        stage: ProcessingStage,
        succeeded: Bool,
        completedCount: Int,
        failedCount: Int
    ) {
        self.stage = stage
        self.succeeded = succeeded
        self.completedCount = completedCount
        self.failedCount = failedCount
    }
}

public struct PipelineBatchResult: Sendable, Equatable {
    public let events: [TranscriptEvent]
    public let materializedSegments: [MaterializedTranscriptSegment]
    public let completedCount: Int
    public let failedCount: Int

    public init(
        events: [TranscriptEvent],
        materializedSegments: [MaterializedTranscriptSegment],
        completedCount: Int,
        failedCount: Int
    ) {
        self.events = events
        self.materializedSegments = materializedSegments
        self.completedCount = completedCount
        self.failedCount = failedCount
    }
}

public actor PipelineCoordinator {
    public typealias UpdateHandler = @Sendable (
        _ segments: [MaterializedTranscriptSegment],
        _ processingState: ProcessingState
    ) async -> Void

    private let sessionID: UUID
    private let segmentationRunID: String
    private let asrRunID: String
    private let writer: SessionWriter
    private let asr: any ASREngine
    private let loader: ASRAudioLoader
    private let materializer: TranscriptMaterializer
    private let state: SessionProcessingState

    public init(
        sessionID: UUID,
        segmentationRunID: String,
        asrRunID: String,
        writer: SessionWriter,
        asr: any ASREngine,
        loader: ASRAudioLoader,
        materializer: TranscriptMaterializer,
        state: SessionProcessingState
    ) {
        self.sessionID = sessionID
        self.segmentationRunID = segmentationRunID
        self.asrRunID = asrRunID
        self.writer = writer
        self.asr = asr
        self.loader = loader
        self.materializer = materializer
        self.state = state
    }

    public func process(
        segments: [SegmentReference],
        onUpdate: UpdateHandler? = nil
    ) async -> PipelineBatchResult {
        await run(
            segments: segments,
            existingEvents: [],
            registerPending: true,
            onUpdate: onUpdate
        )
    }

    public func resumePendingASR(
        segments: [SegmentReference],
        existingEvents: [TranscriptEvent],
        onUpdate: UpdateHandler? = nil
    ) async -> PipelineBatchResult {
        await run(
            segments: segments,
            existingEvents: existingEvents,
            registerPending: false,
            onUpdate: onUpdate
        )
    }

    private func run(
        segments: [SegmentReference],
        existingEvents: [TranscriptEvent],
        registerPending: Bool,
        onUpdate: UpdateHandler?
    ) async -> PipelineBatchResult {
        await state.setProcessing(.running)

        var transcriptEvents = existingEvents
        var completedCount = existingEvents.reduce(into: 0) { count, event in
            guard event.processingRunID == asrRunID else { return }
            if case .asrCompleted = event.kind {
                count += 1
            }
        }
        var failedCount = 0

        if registerPending {
            do {
                for segment in segments {
                    let created = try await writer.append(EventDraft(
                        eventType: "segment.created",
                        sessionID: sessionID,
                        segmentationRunID: segmentationRunID,
                        segmentID: segment.segmentID,
                        sourceStartFrame: segment.startFrame,
                        sourceEndFrame: segment.endFrame,
                        payload: EmptyPayload()
                    ))
                    transcriptEvents.append(.segmentCreated(
                        seq: created.eventSeq,
                        segmentationRunID: segmentationRunID,
                        segmentID: segment.segmentID,
                        startFrame: segment.startFrame,
                        endFrame: segment.endFrame
                    ))

                    _ = try await writer.append(EventDraft(
                        eventType: "asr.pending",
                        sessionID: sessionID,
                        processingRunID: asrRunID,
                        segmentationRunID: segmentationRunID,
                        segmentID: segment.segmentID,
                        sourceStartFrame: segment.startFrame,
                        sourceEndFrame: segment.endFrame,
                        payload: EmptyPayload()
                    ))
                }
            } catch {
                let message =
                    "イベントログへ未処理区間を保存できませんでした: \(error.localizedDescription)"
                let stateValue = ProcessingState.partialFailure(message)
                await state.setProcessing(stateValue)

                let materialized = materializer.materialize(
                    events: transcriptEvents,
                    activeRuns: ActiveRuns(
                        segmentation: segmentationRunID,
                        asr: asrRunID
                    )
                )
                if let onUpdate {
                    await onUpdate(materialized, stateValue)
                }
                return PipelineBatchResult(
                    events: transcriptEvents,
                    materializedSegments: materialized,
                    completedCount: completedCount,
                    failedCount: segments.count
                )
            }
        }

        do {
            try await asr.prepare()
        } catch {
            let message = error.localizedDescription

            for segment in segments {
                _ = try? await writer.append(EventDraft(
                    eventType: "asr.failed",
                    sessionID: sessionID,
                    processingRunID: asrRunID,
                    segmentationRunID: segmentationRunID,
                    segmentID: segment.segmentID,
                    sourceStartFrame: segment.startFrame,
                    sourceEndFrame: segment.endFrame,
                    payload: ASRFailedEventPayload(message: message)
                ))
            }

            failedCount = segments.count
            let stateValue = ProcessingState.partialFailure(
                "音声認識モデルを準備できませんでした: \(message)"
            )
            await state.setProcessing(stateValue)

            let materialized = materializer.materialize(
                events: transcriptEvents,
                activeRuns: ActiveRuns(
                    segmentation: segmentationRunID,
                    asr: asrRunID
                )
            )
            if let onUpdate {
                await onUpdate(materialized, stateValue)
            }
            return PipelineBatchResult(
                events: transcriptEvents,
                materializedSegments: materialized,
                completedCount: completedCount,
                failedCount: failedCount
            )
        }

        let activeRuns = ActiveRuns(
            segmentation: segmentationRunID,
            asr: asrRunID
        )

        for segment in segments {
            do {
                let input = try loader.load(segment: segment)
                let result = try await asr.transcribe(input)

                let completed = try await writer.append(EventDraft(
                    eventType: "asr.completed",
                    sessionID: sessionID,
                    processingRunID: asrRunID,
                    segmentationRunID: segmentationRunID,
                    segmentID: segment.segmentID,
                    sourceStartFrame: segment.startFrame,
                    sourceEndFrame: segment.endFrame,
                    payload: ASRCompletedEventPayload(
                        text: result.text,
                        detectedLanguage: result.detectedLanguage,
                        engine: "qwen3-asr",
                        model: ModelStore.qwen3ASRModelID
                    )
                ))

                transcriptEvents.append(.asrCompleted(
                    seq: completed.eventSeq,
                    runID: asrRunID,
                    segmentationRunID: segmentationRunID,
                    segmentID: segment.segmentID,
                    text: result.text,
                    detectedLanguage: result.detectedLanguage
                ))
                completedCount += 1

                if let onUpdate {
                    let materialized = materializer.materialize(
                        events: transcriptEvents,
                        activeRuns: activeRuns
                    )
                    await onUpdate(materialized, .running)
                }
            } catch {
                failedCount += 1
                _ = try? await writer.append(EventDraft(
                    eventType: "asr.failed",
                    sessionID: sessionID,
                    processingRunID: asrRunID,
                    segmentationRunID: segmentationRunID,
                    segmentID: segment.segmentID,
                    sourceStartFrame: segment.startFrame,
                    sourceEndFrame: segment.endFrame,
                    payload: ASRFailedEventPayload(
                        message: error.localizedDescription
                    )
                ))
            }
        }

        let succeeded = failedCount == 0
        _ = try? await writer.append(EventDraft(
            eventType: "processing.run.completed",
            sessionID: sessionID,
            processingRunID: asrRunID,
            payload: ProcessingRunCompletedPayload(
                stage: .asr,
                succeeded: succeeded,
                completedCount: completedCount,
                failedCount: failedCount
            )
        ))

        let materialized = materializer.materialize(
            events: transcriptEvents,
            activeRuns: activeRuns
        )
        let finalState: ProcessingState = succeeded
            ? .complete
            : .partialFailure("一部の発話を文字起こしできませんでした")

        await state.setProcessing(finalState)
        if let onUpdate {
            await onUpdate(materialized, finalState)
        }

        return PipelineBatchResult(
            events: transcriptEvents,
            materializedSegments: materialized,
            completedCount: completedCount,
            failedCount: failedCount
        )
    }
}
