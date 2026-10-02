import Foundation

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
    public let disposition: BatchDisposition
    public let metrics: ASRBatchMetrics

    public init(
        events: [TranscriptEvent],
        materializedSegments: [MaterializedTranscriptSegment],
        completedCount: Int,
        failedCount: Int,
        disposition: BatchDisposition = .completed,
        metrics: ASRBatchMetrics = .zero
    ) {
        self.events = events
        self.materializedSegments = materializedSegments
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.disposition = disposition
        self.metrics = metrics
    }
}

public enum BatchDisposition: String, Codable, Sendable, Equatable {
    case completed
    case failed
    case paused
}

public enum RunPhase: String, Codable, Sendable {
    case preparing
    case asr
    case postprocessing
    case complete
}

public struct ASRBatchMetrics: Codable, Sendable, Equatable {
    public var modelLoadSeconds: Double = 0
    public var asrCallSeconds: Double = 0
    public var processedAudioSeconds: Double = 0
    public var pacingWaitSeconds: Double = 0
    public var pacingWaitCount: Int = 0
    public var initialPendingCount: Int = 0
    public var maximumPendingCount: Int = 0
    public var oldestPendingAgeSeconds: Double = 0

    public static let zero = ASRBatchMetrics()
    public init() {}

    public var asrRTF: Double? {
        processedAudioSeconds > 0 ? asrCallSeconds / processedAudioSeconds : nil
    }
}

public enum ASRPacingMode: Sendable, Equatable {
    case normal
    case lowHeat
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
    private let pacingMode: ASRPacingMode
    private let sleep: @Sendable (Duration) async throws -> Void
    private let shouldPause: @Sendable () async -> Bool
    private let pendingSince: [String: Date]
    private let onPhase: @Sendable (RunPhase) async -> Void

    public init(
        sessionID: UUID,
        segmentationRunID: String,
        asrRunID: String,
        writer: SessionWriter,
        asr: any ASREngine,
        loader: ASRAudioLoader,
        materializer: TranscriptMaterializer,
        state: SessionProcessingState,
        pacingMode: ASRPacingMode = .normal,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        shouldPause: @escaping @Sendable () async -> Bool = { false },
        pendingSince: [String: Date] = [:],
        onPhase: @escaping @Sendable (RunPhase) async -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.segmentationRunID = segmentationRunID
        self.asrRunID = asrRunID
        self.writer = writer
        self.asr = asr
        self.loader = loader
        self.materializer = materializer
        self.state = state
        self.pacingMode = pacingMode
        self.sleep = sleep
        self.shouldPause = shouldPause
        self.pendingSince = pendingSince
        self.onPhase = onPhase
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
        var metrics = ASRBatchMetrics()
        metrics.initialPendingCount = segments.count
        metrics.maximumPendingCount = segments.count
        let batchStarted = Date()
        let clock = ContinuousClock()

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
                    failedCount: segments.count,
                    disposition: .failed,
                    metrics: metrics
                )
            }
        }

        do {
            if !segments.isEmpty {
                let start = clock.now
                try await asr.prepare()
                metrics.modelLoadSeconds = seconds(start.duration(to: clock.now))
            }
            await onPhase(.asr)
        } catch {
            let message = error.localizedDescription

            for segment in segments {
                await appendFailure(segment: segment, kind: .engineUnavailable, error: error)
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
                failedCount: failedCount,
                disposition: .failed,
                metrics: metrics
            )
        }

        let activeRuns = ActiveRuns(
            segmentation: segmentationRunID,
            asr: asrRunID
        )

        var paused = false
        for (index, segment) in segments.enumerated() {
            if await shouldPause() {
                paused = true
                break
            }
            let pending = segments[index...]
            if let oldest = pending.map({ pendingSince[$0.segmentID] ?? batchStarted }).min() {
                metrics.oldestPendingAgeSeconds = max(
                    metrics.oldestPendingAgeSeconds,
                    Date().timeIntervalSince(oldest)
                )
            }
            let input: ASRAudioInput
            do {
                input = try loader.load(segment: segment)
            } catch {
                failedCount += 1
                await appendFailure(segment: segment, kind: .audioUnreadable, error: error)
                continue
            }

            let start = clock.now
            let result: ASRResult
            do {
                result = try await asr.transcribe(input)
            } catch {
                if !input.isShorterThanMinimumASRDuration {
                    metrics.asrCallSeconds += seconds(start.duration(to: clock.now))
                }
                failedCount += 1
                await appendFailure(segment: segment, kind: .transcriptionFailed, error: error)
                continue
            }
            if !input.isShorterThanMinimumASRDuration, input.sampleRate > 0 {
                metrics.asrCallSeconds += seconds(start.duration(to: clock.now))
                metrics.processedAudioSeconds += Double(input.samples.count) / Double(input.sampleRate)
            }

            var didComplete = false
            do {
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
                didComplete = true

                if let onUpdate {
                    let materialized = materializer.materialize(
                        events: transcriptEvents,
                        activeRuns: activeRuns
                    )
                    await onUpdate(materialized, .running)
                }
            } catch {
                failedCount += 1
            }

            if pacingMode == .lowHeat,
               index < segments.count - 1,
               didComplete {
                do {
                    let start = clock.now
                    try await sleep(.seconds(2))
                    metrics.pacingWaitSeconds += seconds(start.duration(to: clock.now))
                    metrics.pacingWaitCount += 1
                } catch {
                    paused = true
                    break
                }
            }
        }

        var succeeded = failedCount == 0 && !paused
        if !paused {
            do {
                _ = try await writer.append(EventDraft(
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
            } catch {
                succeeded = false
                failedCount += 1
            }
        }

        let materialized = materializer.materialize(
            events: transcriptEvents,
            activeRuns: activeRuns
        )
        let finalState: ProcessingState = paused
            ? .backlogged
            : (succeeded ? .complete : .partialFailure("一部の発話を文字起こしできませんでした"))

        await state.setProcessing(finalState)
        if let onUpdate {
            await onUpdate(materialized, finalState)
        }

        return PipelineBatchResult(
            events: transcriptEvents,
            materializedSegments: materialized,
            completedCount: completedCount,
            failedCount: failedCount,
            disposition: paused ? .paused : (succeeded ? .completed : .failed),
            metrics: metrics
        )
    }

    private func appendFailure(
        segment: SegmentReference,
        kind: ASRFailureKind,
        error: any Error
    ) async {
        _ = try? await writer.append(EventDraft(
            eventType: "asr.failed",
            sessionID: sessionID,
            processingRunID: asrRunID,
            segmentationRunID: segmentationRunID,
            segmentID: segment.segmentID,
            sourceStartFrame: segment.startFrame,
            sourceEndFrame: segment.endFrame,
            payload: ASRFailedEventPayload(
                kind: kind,
                message: error.localizedDescription
            )
        ))
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}
