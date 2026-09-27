import Foundation
import MacAmbientJevCore

enum NativeSessionProcessorError: LocalizedError {
    case invalidRecoveredRun
    case liveASRSessionNotStarted

    var errorDescription: String? {
        switch self {
        case .invalidRecoveredRun:
            "復旧対象の文字起こし run が完了状態ではありません"
        case .liveASRSessionNotStarted:
            "録音中の文字起こしセッションが開始されていません"
        }
    }
}

private struct SceneEnrichmentContext: Sendable {
    let runID: String
    let events: [TranscriptEvent]
    let materializedSegments: [MaterializedTranscriptSegment]
}

private struct JevEnrichmentOutcome: Sendable {
    let materializedSegments: [MaterializedTranscriptSegment]
    let pendingSegmentIDs: [String]
    let persistenceFailure: String?
}

public struct SessionProcessingResult: Sendable {
    public let disposition: BatchDisposition
    public let metrics: ASRBatchMetrics?
    public let message: String?

    public init(disposition: BatchDisposition, metrics: ASRBatchMetrics?, message: String? = nil) {
        self.disposition = disposition
        self.metrics = metrics
        self.message = message
    }
}

public actor NativeSessionProcessor {
    public typealias JevDecisionCoordinatorFactory = @Sendable () throws
        -> JevDecisionCoordinator?
    public typealias StatusHandler = @Sendable (_ text: String) async -> Void
    public typealias UpdateHandler = @Sendable (
        _ segments: [MaterializedTranscriptSegment],
        _ state: ProcessingState
    ) async -> Void

    private static let jevAPIKeyAccount = "jev-api-key"

    private let paths: AppPaths
    private let sessionsRoot: URL
    private let asr: any ASREngine
    private let diarization: any DiarizationEngine
    private let finalTranscriptVAD: any FinalTranscriptVADSegmenter
    private let allowExternalJev: Bool
    private let jevDecisionCoordinatorFactory: JevDecisionCoordinatorFactory?
    public let jevUsageCounter: JevUsageCounter
    private var liveASRSessions: [UUID: LiveASRSession] = [:]

    public init(
        paths: AppPaths,
        allowExternalJev: Bool = false,
        jevUsageCounter: JevUsageCounter = JevUsageCounter(),
        asr: (any ASREngine)? = nil,
        sessionsRoot: URL? = nil,
        diarizationEngine: (any DiarizationEngine)? = nil,
        finalTranscriptVAD: (any FinalTranscriptVADSegmenter)? = nil,
        jevDecisionCoordinatorFactory: JevDecisionCoordinatorFactory? = nil
    ) {
        self.paths = paths
        self.sessionsRoot = sessionsRoot ?? paths.sessionsRoot
        self.asr = asr ?? NativeQwen3ASREngine(
            modelStore: ModelStore(paths: paths)
        )
        self.diarization = diarizationEngine ?? FluidOfflineDiarizationEngine(paths: paths)
        self.finalTranscriptVAD = finalTranscriptVAD ?? FluidFinalTranscriptVADSegmenter()
        self.allowExternalJev = allowExternalJev
        self.jevDecisionCoordinatorFactory = jevDecisionCoordinatorFactory
        self.jevUsageCounter = jevUsageCounter
    }

    public func prepareASR(
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        try await asr.prepare(onProgress: onProgress)
    }

    @discardableResult
    public func startLiveTranscription(
        sessionID: UUID,
        segmentationRunID: String,
        sampleRate: Double
    ) throws -> String {
        try persistProcessingMetadata(sessionID: sessionID)

        let asrRunID = "asr_live_\(UUID().uuidString.lowercased())"
        liveASRSessions[sessionID] = LiveASRSession(
            sessionID: sessionID,
            segmentationRunID: segmentationRunID,
            asrRunID: asrRunID,
            processingDirectory: processingDirectory(for: sessionID),
            writer: try SessionWriter(sessionURL: sessionURL(for: sessionID)),
            asr: asr,
            sampleRate: sampleRate
        )
        return asrRunID
    }

    @discardableResult
    public func registerLiveSegments(
        sessionID: UUID,
        segments: [SegmentReference]
    ) async throws -> LiveASRProgress {
        guard let liveSession = liveASRSessions[sessionID] else {
            throw NativeSessionProcessorError.liveASRSessionNotStarted
        }
        return try await liveSession.register(segments: segments)
    }

    @discardableResult
    public func processLiveSegments(
        sessionID: UUID,
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint,
        onStatus: StatusHandler? = nil,
        onUpdate: UpdateHandler? = nil
    ) async throws -> LiveASRProgress {
        guard let liveSession = liveASRSessions[sessionID] else {
            throw NativeSessionProcessorError.liveASRSessionNotStarted
        }

        if let onStatus, !segments.isEmpty {
            await onStatus("録音中の発話を文字起こししています")
        }

        let progress = try await liveSession.process(
            segments: segments,
            checkpoint: checkpoint
        )

        if let onUpdate {
            await onUpdate(progress.materializedSegments, .running)
        }
        return progress
    }

    public func finishLiveTranscription(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        finalSegments: [SegmentReference] = [],
        onStatus: StatusHandler? = nil,
        onUpdate: UpdateHandler? = nil
    ) async -> LiveTranscriptionFinishResult {
        guard let liveSession = liveASRSessions[sessionID] else {
            return .fallbackRequired(
                NativeSessionProcessorError.liveASRSessionNotStarted.localizedDescription
            )
        }

        if !finalSegments.isEmpty {
            do {
                _ = try await processLiveSegments(
                    sessionID: sessionID,
                    segments: finalSegments,
                    checkpoint: checkpoint,
                    onStatus: onStatus,
                    onUpdate: onUpdate
                )
            } catch {
                // The saved timeline is the source of truth for final processing.
            }
        }

        let completion: LiveASRCompletion?
        do {
            completion = try await liveSession.finish()
        } catch {
            completion = nil
        }
        liveASRSessions[sessionID] = nil

        if let completion, let onUpdate {
            await onUpdate(completion.materializedSegments, .running)
        }
        let result = await processFinalTranscript(
            sessionID: sessionID,
            checkpoint: checkpoint,
            failureFallbackSegments: completion?.materializedSegments ?? [],
            onStatus: onStatus,
            onUpdate: onUpdate
        )
        switch result.disposition {
        case .completed:
            if let message = result.message, message == "noSpeech" { return .noSpeech }
            return .completed
        case .paused:
            return .postProcessingFailed(result.message ?? "確定処理を一時停止しました")
        case .failed:
            return .postProcessingFailed(result.message ?? "確定処理に失敗しました")
        }
    }

    /// Rebuilds every mandatory offline run from the saved processing timeline and
    /// exposes the resulting active-run set only after all stages have completed.
    @discardableResult
    public func processFinalTranscript(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        pacingMode: ASRPacingMode = .normal,
        shouldPause: @escaping @Sendable () async -> Bool = { false },
        onPhase: @escaping @Sendable (RunPhase) async -> Void = { _ in },
        failureFallbackSegments: [MaterializedTranscriptSegment] = [],
        onStatus: StatusHandler? = nil,
        onUpdate: UpdateHandler? = nil
    ) async -> SessionProcessingResult {
        let metadataStore = ProcessingMetadataStore(sessionURL: sessionURL(for: sessionID))
        let previousMetadata: ProcessingMetadata?
        do {
            previousMetadata = try metadataStore.load()
        } catch {
            let message = error.localizedDescription
            if let onStatus { await onStatus("確定処理を開始できませんでした: \(message)") }
            await onPhase(.complete)
            if let onUpdate {
                await onUpdate(failureFallbackSegments, .partialFailure(message))
            }
            return SessionProcessingResult(disposition: .failed, metrics: nil, message: message)
        }

        let attemptID = "finalize_\(UUID().uuidString.lowercased())"
        do {
            try metadataStore.beginFinalization(
                attemptID: attemptID,
                defaultMetadata: previousMetadata ?? makeProcessingMetadata(activeRuns: nil)
            )
            await onPhase(.preparing)
            let pipeline = FinalTranscriptPipeline(
                sessionID: sessionID,
                sessionURL: sessionURL(for: sessionID),
                processingDirectory: processingDirectory(for: sessionID),
                checkpoint: checkpoint,
                asr: asr,
                diarization: diarization,
                vadSegmenter: finalTranscriptVAD,
                proximityEvidenceProvider: TimelineProximityEvidenceProvider(
                    reader: ProcessingTimelineReader(
                        directory: processingDirectory(for: sessionID),
                        checkpoint: checkpoint
                    )
                )
            )
            let final = try await pipeline.process(
                onStatus: onStatus,
                pacingMode: pacingMode,
                shouldPause: shouldPause,
                onPhase: onPhase
            )
            try metadataStore.completeFinalization(
                attemptID: attemptID,
                activeRuns: final.activeRuns
            )

            if let onUpdate {
                await onUpdate(final.materializedSegments, .running)
            }

            var finalSegments = final.materializedSegments
            var deferredContentPriorityIDs: [String] = []
            var retryStatePersistenceFailure: String?
            if allowExternalJev {
                if final.materializedSegments.isEmpty {
                    do {
                        try persistPendingContentPriority(
                            sessionID: sessionID,
                            segmentIDs: []
                        )
                    } catch {
                        retryStatePersistenceFailure = error.localizedDescription
                    }
                } else {
                    do {
                        let events = try loadTranscriptEvents(
                            sessionID: sessionID,
                            activeRuns: final.activeRuns
                        )
                        let outcome = await runJevEnrichmentIfAvailable(
                            sessionID: sessionID,
                            checkpoint: checkpoint,
                            existingEvents: events,
                            activeRuns: final.activeRuns,
                            fallbackSegments: final.materializedSegments,
                            onStatus: onStatus
                        )
                        finalSegments = outcome.materializedSegments
                        deferredContentPriorityIDs = outcome.pendingSegmentIDs
                        retryStatePersistenceFailure = outcome.persistenceFailure
                    } catch {
                        deferredContentPriorityIDs = final.materializedSegments
                            .map(\.segmentID)
                        do {
                            try persistPendingContentPriority(
                                sessionID: sessionID,
                                segmentIDs: deferredContentPriorityIDs
                            )
                        } catch {
                            retryStatePersistenceFailure = error.localizedDescription
                        }
                        if let onStatus { await onStatus(UserFacingStatus.jevDeferred.text) }
                    }
                }
            }

            if let onUpdate {
                await onUpdate(finalSegments, .complete)
            }
            await onPhase(.complete)
            let noSpeech = final.completedCount == 0
            if noSpeech, let retryStatePersistenceFailure, let onStatus {
                await onStatus(
                    "意味分類の再試行状態を消去できませんでした: \(retryStatePersistenceFailure)"
                )
                await onStatus("発話区間は検出されませんでした")
            } else if noSpeech, let onStatus {
                await onStatus("発話区間は検出されませんでした")
            } else if let retryStatePersistenceFailure, let onStatus {
                await onStatus(
                    "意味分類の再試行状態を保存できませんでした: \(retryStatePersistenceFailure)"
                )
            } else if !deferredContentPriorityIDs.isEmpty, let onStatus {
                await onStatus(UserFacingStatus.jevDeferred.text)
            } else if let onStatus {
                await onStatus(noSpeech
                    ? "発話区間は検出されませんでした"
                    : "文字起こし、話者分離、場面判定、音響範囲整理が完了しました（\(final.completedCount)区間）")
            }
            return SessionProcessingResult(
                disposition: .completed,
                metrics: final.metrics,
                message: noSpeech ? "noSpeech" : nil
            )
        } catch {
            var message = error.localizedDescription
            do {
                try metadataStore.failFinalization(
                    attemptID: attemptID,
                    reason: message
                )
            } catch {
                message += "（処理状態も保存できませんでした: \(error.localizedDescription)）"
            }
            await onPhase(.complete)
            if let onStatus { await onStatus("確定処理に失敗しました: \(message)") }
            if let onUpdate {
                let preservedSegments: [MaterializedTranscriptSegment]
                if let activeRuns = previousMetadata?.activeRuns,
                   let previousSegments = try? loadMaterializedSegments(
                       sessionID: sessionID,
                       checkpoint: checkpoint,
                       activeRuns: activeRuns
                   ) {
                    preservedSegments = previousSegments
                } else {
                    preservedSegments = failureFallbackSegments
                }
                await onUpdate(preservedSegments, .partialFailure(message))
            }
            return SessionProcessingResult(
                disposition: .failed,
                metrics: nil,
                message: message
            )
        }
    }

    public func cancelLiveTranscription(sessionID: UUID) async {
        liveASRSessions[sessionID] = nil
    }

    public func retryContentPrioritySession(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        segmentIDs: [String],
        onStatus: StatusHandler? = nil,
        onUpdate: UpdateHandler? = nil
    ) async {
        do {
            guard !segmentIDs.isEmpty else {
                return
            }

            guard let decisions =
                    try makeJevDecisionCoordinatorIfAvailable()
            else {
                if let onStatus {
                    await onStatus(
                        UserFacingStatus.jevDeferred.text
                    )
                }
                return
            }

            let metadataStore = ProcessingMetadataStore(
                sessionURL: sessionURL(for: sessionID)
            )
            guard let metadata = try metadataStore.load(),
                  let activeRuns = metadata.activeRuns,
                  activeRuns.segmentation != nil,
                  activeRuns.asr != nil,
                  activeRuns.scope != nil else {
                throw NativeSessionProcessorError.invalidRecoveredRun
            }

            let eventsURL = sessionURL(for: sessionID)
                .appending(path: "events.jsonl")
            let recovered = try SessionRecovery.recoverJSONL(
                Data(contentsOf: eventsURL)
            )
            if recovered.droppedIncompleteTail {
                try recovered.normalizedData.write(
                    to: eventsURL,
                    options: .atomic
                )
            }

            let events = try EventLogTranscriptReader().events(
                lines: recovered.lines,
                activeRuns: activeRuns
            )
            let materializer = TranscriptMaterializer(
                sampleRate: checkpoint.sampleRate
            )
            let fallback = materializer.materialize(
                events: events,
                activeRuns: activeRuns
            ).filter { JevTranscriptEligibility.isEligible($0.text) }

            if let onStatus {
                await onStatus(
                    "保留中の意味分類を再試行しています（\(segmentIDs.count)区間）"
                )
            }
            if let onUpdate {
                await onUpdate(fallback, .running)
            }

            let runID =
                "priority_retry_\(UUID().uuidString.lowercased())"
            let coordinator = JevEnrichmentCoordinator(
                sessionID: sessionID,
                runID: runID,
                writer: try SessionWriter(
                    sessionURL: sessionURL(for: sessionID)
                ),
                decisions: decisions,
                materializer: materializer
            )
            let result = try await coordinator.process(
                existingEvents: events,
                activeRuns: activeRuns,
                retryOnlySegmentIDs: Set(segmentIDs)
            )

            try selectContentPriorityRun(
                sessionID: sessionID,
                runID: runID,
                pendingSegmentIDs: result.retryPendingSegmentIDs
            )

            if let onUpdate {
                await onUpdate(
                    result.materializedSegments,
                    .complete
                )
            }

            if let onStatus {
                if result.retryPendingSegmentIDs.isEmpty {
                    await onStatus("保留中の意味分類を更新しました")
                } else {
                    await onStatus(UserFacingStatus.jevDeferred.text)
                }
            }
        } catch {
            if let onStatus {
                await onStatus(
                    "意味分類を再試行できませんでした: \(error.localizedDescription)"
                )
            }
        }
    }

    public func makeLiveASRSession(
        sessionID: UUID,
        processingDirectory: URL,
        segmentationRunID: String,
        sampleRate: Double
    ) throws -> LiveASRSession {
        LiveASRSession(
            sessionID: sessionID,
            segmentationRunID: segmentationRunID,
            asrRunID: "asr_live_\(UUID().uuidString.lowercased())",
            processingDirectory: processingDirectory,
            writer: try SessionWriter(
                sessionURL: sessionURL(for: sessionID)
            ),
            asr: asr,
            sampleRate: sampleRate
        )
    }

    @discardableResult
    public func processImportedSession(
        sessionID: UUID,
        originalURL: URL,
        pacingMode: ASRPacingMode = .normal,
        shouldPause: @escaping @Sendable () async -> Bool = { false },
        onPhase: @escaping @Sendable (RunPhase) async -> Void = { _ in },
        onStatus: StatusHandler? = nil,
        onUpdate: UpdateHandler? = nil
    ) async -> SessionProcessingResult {
        let processingDirectory = processingDirectory(for: sessionID)
        do {
            if let onStatus {
                await onStatus(UserFacingStatus.convertingTimeline.text)
            }

            let checkpoint = try await AudioFileTimelineBuilder()
                .build(from: originalURL, into: processingDirectory)

            return await processFinalTranscript(
                sessionID: sessionID,
                checkpoint: checkpoint,
                pacingMode: pacingMode,
                shouldPause: shouldPause,
                onPhase: onPhase,
                onStatus: onStatus,
                onUpdate: onUpdate
            )
        } catch {
            await reportFailure(
                prefix: "音声ファイルを処理できませんでした",
                error: error,
                onStatus: onStatus,
                onUpdate: onUpdate
            )
            return SessionProcessingResult(disposition: .failed, metrics: nil, message: error.localizedDescription)
        }
    }

    public func processTimelineSession(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        onStatus: StatusHandler? = nil,
        onUpdate: UpdateHandler? = nil
    ) async {
        _ = await processFinalTranscript(
            sessionID: sessionID,
            checkpoint: checkpoint,
            onStatus: onStatus,
            onUpdate: onUpdate
        )
    }

    @discardableResult
    public func resumePendingASRSession(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        plan: ASRRecoveryPlan,
        pacingMode: ASRPacingMode = .normal,
        shouldPause: @escaping @Sendable () async -> Bool = { false },
        onPhase: @escaping @Sendable (RunPhase) async -> Void = { _ in },
        onStatus: StatusHandler? = nil,
        onUpdate: UpdateHandler? = nil
    ) async -> SessionProcessingResult {
        var metrics: ASRBatchMetrics?
        do {
            try persistProcessingMetadata(sessionID: sessionID)

            if let onStatus {
                await onStatus(
                    "未完了の文字起こしを再開しています（残り\(plan.pendingSegments.count)区間）"
                )
            }

            let reader = ProcessingTimelineReader(
                directory: processingDirectory(for: sessionID),
                checkpoint: checkpoint
            )
            let state = SessionProcessingState(captureState: .stopped)
            let coordinator = PipelineCoordinator(
                sessionID: sessionID,
                segmentationRunID: plan.segmentationRunID,
                asrRunID: plan.asrRunID,
                writer: try SessionWriter(
                    sessionURL: sessionURL(for: sessionID)
                ),
                asr: asr,
                loader: ASRAudioLoader(reader: reader),
                materializer: TranscriptMaterializer(
                    sampleRate: checkpoint.sampleRate
                ),
                state: state,
                pacingMode: pacingMode,
                shouldPause: shouldPause,
                pendingSince: try pendingDates(sessionID: sessionID, plan: plan),
                onPhase: onPhase
            )

            let result = await coordinator.resumePendingASR(
                segments: plan.pendingSegments,
                existingEvents: plan.transcriptEvents
            ) { materialized, processingState in
                if let onUpdate {
                    await onUpdate(materialized, processingState)
                }
            }
            metrics = result.metrics

            if result.disposition == .completed {
                await onPhase(.postprocessing)
                try selectSuccessfulRuns(
                    sessionID: sessionID,
                    segmentationRunID: plan.segmentationRunID,
                    asrRunID: plan.asrRunID
                )
                try await runOfflineDiarization(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    existingEvents: result.events,
                    segmentationRunID: plan.segmentationRunID,
                    asrRunID: plan.asrRunID,
                    onStatus: onStatus,
                    onUpdate: onUpdate
                )
                await onPhase(.complete)
            }

            if let onStatus {
                if result.disposition == .completed {
                    await onStatus(
                        "文字起こし、話者分離、場面判定、音響範囲整理を復旧しました（\(result.completedCount)区間）"
                    )
                } else if result.disposition == .paused {
                    await onStatus("熱状態のため文字起こしを一時停止しました")
                } else {
                    await onStatus(
                        "文字起こしの復旧中に\(result.failedCount)区間失敗しました"
                    )
                }
            }
            return SessionProcessingResult(disposition: result.disposition, metrics: metrics)
        } catch {
            await reportFailure(
                prefix: "文字起こしを復旧できませんでした",
                error: error,
                onStatus: onStatus,
                onUpdate: onUpdate
            )
            return SessionProcessingResult(disposition: .failed, metrics: metrics, message: error.localizedDescription)
        }
    }

    public func selectCompletedASRSession(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        plan: ASRRecoveryPlan,
        onStatus: StatusHandler? = nil,
        onUpdate: UpdateHandler? = nil
    ) async {
        do {
            guard plan.runSucceeded,
                  plan.pendingSegments.isEmpty,
                  !plan.hasFailures else {
                throw NativeSessionProcessorError.invalidRecoveredRun
            }

            try persistProcessingMetadata(sessionID: sessionID)
            try selectSuccessfulRuns(
                sessionID: sessionID,
                segmentationRunID: plan.segmentationRunID,
                asrRunID: plan.asrRunID
            )

            let materialized = TranscriptMaterializer(
                sampleRate: checkpoint.sampleRate
            ).materialize(
                events: plan.transcriptEvents,
                activeRuns: ActiveRuns(
                    segmentation: plan.segmentationRunID,
                    asr: plan.asrRunID
                )
            )

            if let onUpdate {
                await onUpdate(materialized, .running)
            }

            try await runOfflineDiarization(
                sessionID: sessionID,
                checkpoint: checkpoint,
                existingEvents: plan.transcriptEvents,
                segmentationRunID: plan.segmentationRunID,
                asrRunID: plan.asrRunID,
                onStatus: onStatus,
                onUpdate: onUpdate
            )

            if let onStatus {
                await onStatus(
                    "完了済みの文字起こし、話者分離、場面判定、音響範囲整理を復旧しました（\(materialized.count)区間）"
                )
            }
        } catch {
            await reportFailure(
                prefix: "完了済みの文字起こしを復旧できませんでした",
                error: error,
                onStatus: onStatus,
                onUpdate: onUpdate
            )
        }
    }

    private func processTimeline(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        processingDirectory: URL,
        pacingMode: ASRPacingMode = .normal,
        shouldPause: @escaping @Sendable () async -> Bool = { false },
        onPhase: @escaping @Sendable (RunPhase) async -> Void = { _ in },
        onStatus: StatusHandler?,
        onUpdate: UpdateHandler?
    ) async throws -> PipelineBatchResult {
        guard checkpoint.committedFrames > 0 else {
            try persistProcessingMetadata(sessionID: sessionID)
            try await finishWithoutSpeech(sessionID: sessionID)
            if let onStatus {
                await onStatus("処理できる音声がありません")
            }
            if let onUpdate {
                await onUpdate([], .complete)
            }
            await onPhase(.complete)
            return PipelineBatchResult(events: [], materializedSegments: [], completedCount: 0, failedCount: 0)
        }

        try persistProcessingMetadata(sessionID: sessionID)

        let segmentationRunID = "seg_\(UUID().uuidString.lowercased())"
        let asrRunID = "asr_\(UUID().uuidString.lowercased())"
        let reader = ProcessingTimelineReader(
            directory: processingDirectory,
            checkpoint: checkpoint
        )
        let state = SessionProcessingState(captureState: .stopped)

        if let onStatus {
            await onStatus(UserFacingStatus.detectingSpeech.text)
        }

        let vad = try await FluidVADSegmentationEngine.make(
            segmentationRunID: segmentationRunID,
            canonicalSampleRate: checkpoint.sampleRate
        )
        let segments = try await FluidVADTimelineProcessor(
            reader: reader,
            engine: vad
        ).segmentAll()

        guard !segments.isEmpty else {
            try await finishWithoutSpeech(sessionID: sessionID)
            await state.setProcessing(.complete)
            if let onStatus {
                await onStatus("発話区間は検出されませんでした")
            }
            if let onUpdate {
                await onUpdate([], .complete)
            }
            await onPhase(.complete)
            return PipelineBatchResult(events: [], materializedSegments: [], completedCount: 0, failedCount: 0)
        }

        if let onStatus {
            await onStatus(UserFacingStatus.preparingASR.text)
        }

        let coordinator = PipelineCoordinator(
            sessionID: sessionID,
            segmentationRunID: segmentationRunID,
            asrRunID: asrRunID,
            writer: try SessionWriter(sessionURL: sessionURL(for: sessionID)),
            asr: asr,
            loader: ASRAudioLoader(reader: reader),
            materializer: TranscriptMaterializer(
                sampleRate: checkpoint.sampleRate
            ),
            state: state,
            pacingMode: pacingMode,
            shouldPause: shouldPause,
            onPhase: onPhase
        )

        let result = await coordinator.process(
            segments: segments
        ) { materialized, processingState in
            if let onUpdate {
                await onUpdate(materialized, processingState)
            }
        }

        if result.disposition == .completed {
            await onPhase(.postprocessing)
            try selectSuccessfulRuns(
                sessionID: sessionID,
                segmentationRunID: segmentationRunID,
                asrRunID: asrRunID
            )

            try await runOfflineDiarization(
                sessionID: sessionID,
                checkpoint: checkpoint,
                existingEvents: result.events,
                segmentationRunID: segmentationRunID,
                asrRunID: asrRunID,
                onStatus: onStatus,
                onUpdate: onUpdate
            )
            await onPhase(.complete)
        }

        if let onStatus {
            if result.disposition == .completed {
                await onStatus(
                    "文字起こし、話者分離、場面判定、音響範囲整理が完了しました（\(result.completedCount)区間）"
                )
            } else if result.disposition == .paused {
                await onStatus("熱状態のため文字起こしを一時停止しました")
            } else {
                await onStatus(
                    "文字起こしが完了しました（成功 \(result.completedCount)区間、失敗 \(result.failedCount)区間）"
                )
            }
        }
        return result
    }

    private func finishWithoutSpeech(sessionID: UUID) async throws {
        let scopeRunID = "scope_empty_\(UUID().uuidString.lowercased())"
        _ = try await SessionWriter(sessionURL: sessionURL(for: sessionID)).append(EventDraft(
            eventType: "processing.run.completed",
            sessionID: sessionID,
            processingRunID: scopeRunID,
            payload: ProcessingRunCompletedPayload(
                stage: .scope,
                succeeded: true,
                completedCount: 0,
                failedCount: 0
            )
        ))
        try selectScopeRun(sessionID: sessionID, scopeRunID: scopeRunID)
    }

    public func runRecoveredDiarizationSession(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        plan: ASRRecoveryPlan,
        onStatus: StatusHandler? = nil,
        onUpdate: UpdateHandler? = nil
    ) async {
        do {
            try await runOfflineDiarization(
                sessionID: sessionID,
                checkpoint: checkpoint,
                existingEvents: plan.transcriptEvents,
                segmentationRunID: plan.segmentationRunID,
                asrRunID: plan.asrRunID,
                onStatus: onStatus,
                onUpdate: onUpdate
            )
        } catch {
            await reportFailure(
                prefix: "話者分離を復旧できませんでした",
                error: error,
                onStatus: onStatus,
                onUpdate: onUpdate
            )
        }
    }

    private func runOfflineDiarization(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        existingEvents: [TranscriptEvent],
        segmentationRunID: String,
        asrRunID: String,
        onStatus: StatusHandler?,
        onUpdate: UpdateHandler?
    ) async throws {
        if let onStatus {
            await onStatus(UserFacingStatus.preparingDiarization.text)
        }

        let reader = ProcessingTimelineReader(
            directory: processingDirectory(for: sessionID),
            checkpoint: checkpoint
        )
        let derivedDirectory = sessionURL(for: sessionID)
            .appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "derived", directoryHint: .isDirectory)
        let diarizationInputURL = derivedDirectory
            .appending(path: "diarization-input.caf")

        try ProcessingTimelineAudioExporter(
            framesPerBuffer: max(
                1,
                Int64(checkpoint.sampleRate.rounded())
            )
        ).export(
            reader: reader,
            to: diarizationInputURL
        )

        if let onStatus {
            await onStatus(UserFacingStatus.diarizing.text)
        }

        let diarizationRunID =
            "diar_offline_\(UUID().uuidString.lowercased())"
        let coordinator = DiarizationCoordinator(
            sessionID: sessionID,
            runID: diarizationRunID,
            writer: try SessionWriter(
                sessionURL: sessionURL(for: sessionID)
            ),
            engine: diarization,
            materializer: TranscriptMaterializer(
                sampleRate: checkpoint.sampleRate
            )
        )
        let activeRuns = ActiveRuns(
            segmentation: segmentationRunID,
            asr: asrRunID,
            diarization: diarizationRunID
        )
        let result = try await coordinator.process(
            fileURL: diarizationInputURL,
            canonicalSampleRate: checkpoint.sampleRate,
            existingEvents: existingEvents,
            activeRuns: activeRuns
        )

        try selectDiarizationRun(
            sessionID: sessionID,
            diarizationRunID: diarizationRunID
        )

        if let onStatus {
            await onStatus(UserFacingStatus.analyzingScene.text)
        }

        let sceneRunID =
            "scene_\(UUID().uuidString.lowercased())"
        let sceneCoordinator = SceneCoordinator(
            sessionID: sessionID,
            runID: sceneRunID,
            writer: try SessionWriter(
                sessionURL: sessionURL(for: sessionID)
            ),
            materializer: TranscriptMaterializer(
                sampleRate: checkpoint.sampleRate
            )
        )
        let sceneResult = try await sceneCoordinator.process(
            speakerSpans: result.speakerSpans,
            totalFrames: checkpoint.committedFrames,
            sampleRate: checkpoint.sampleRate,
            existingEvents: result.events,
            activeRuns: ActiveRuns(
                segmentation: segmentationRunID,
                asr: asrRunID,
                diarization: diarizationRunID,
                scene: sceneRunID
            )
        )

        try selectSceneRun(
            sessionID: sessionID,
            sceneRunID: sceneRunID
        )

        let sceneContext = try await runSemanticSceneEnrichmentIfAvailable(
            sessionID: sessionID,
            checkpoint: checkpoint,
            speakerSpans: result.speakerSpans,
            localSceneRunID: sceneRunID,
            localSceneResult: sceneResult,
            baseActiveRuns: ActiveRuns(
                segmentation: segmentationRunID,
                asr: asrRunID,
                diarization: diarizationRunID,
                scene: sceneRunID
            ),
            onStatus: onStatus
        )

        if let onStatus {
            await onStatus(UserFacingStatus.analyzingScope.text)
        }

        let scopeRunID =
            "scope_\(UUID().uuidString.lowercased())"
        let scopeCoordinator = ScopeCoordinator(
            sessionID: sessionID,
            runID: scopeRunID,
            writer: try SessionWriter(
                sessionURL: sessionURL(for: sessionID)
            ),
            provider: TimelineProximityEvidenceProvider(
                reader: reader
            ),
            materializer: TranscriptMaterializer(
                sampleRate: checkpoint.sampleRate
            )
        )
        let scopeResult = try await scopeCoordinator.process(
            existingEvents: sceneContext.events,
            speakerSpans: result.speakerSpans,
            activeRuns: ActiveRuns(
                segmentation: segmentationRunID,
                asr: asrRunID,
                diarization: diarizationRunID,
                scene: sceneContext.runID,
                scope: scopeRunID
            )
        )

        try selectScopeRun(
            sessionID: sessionID,
            scopeRunID: scopeRunID
        )

        let jevOutcome = await runJevEnrichmentIfAvailable(
            sessionID: sessionID,
            checkpoint: checkpoint,
            existingEvents: scopeResult.events,
            activeRuns: ActiveRuns(
                segmentation: segmentationRunID,
                asr: asrRunID,
                diarization: diarizationRunID,
                scene: sceneContext.runID,
                scope: scopeRunID
            ),
            fallbackSegments: scopeResult.materializedSegments,
            onStatus: onStatus
        )

        if let onUpdate {
            await onUpdate(jevOutcome.materializedSegments, .complete)
        }
        if let persistenceFailure = jevOutcome.persistenceFailure,
           let onStatus {
            await onStatus(
                "意味分類の再試行状態を保存できませんでした: \(persistenceFailure)"
            )
        } else if !jevOutcome.pendingSegmentIDs.isEmpty, let onStatus {
            await onStatus(UserFacingStatus.jevDeferred.text)
        }
    }

    private func runSemanticSceneEnrichmentIfAvailable(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        speakerSpans: [SpeakerSpan],
        localSceneRunID: String,
        localSceneResult: SceneBatchResult,
        baseActiveRuns: ActiveRuns,
        onStatus: StatusHandler?
    ) async throws -> SceneEnrichmentContext {
        guard let decisions = try makeJevDecisionCoordinatorIfAvailable() else {
            return SceneEnrichmentContext(
                runID: localSceneRunID,
                events: localSceneResult.events,
                materializedSegments: localSceneResult.materializedSegments
            )
        }

        if let onStatus {
            await onStatus(UserFacingStatus.classifyingWithJev.text)
        }

        let semanticRunID =
            "jev_scene_\(UUID().uuidString.lowercased())"
        let collector = JevSceneCueCollector(
            sessionID: sessionID,
            runID: semanticRunID,
            writer: try SessionWriter(
                sessionURL: sessionURL(for: sessionID)
            ),
            decisions: decisions,
            sampleRate: checkpoint.sampleRate
        )
        let collection = try await collector.collect(
            segments: localSceneResult.materializedSegments
        )

        if !collection.retryPendingSegmentIDs.isEmpty,
           let onStatus {
            await onStatus(UserFacingStatus.jevDeferred.text)
        }

        guard !collection.cues.isEmpty else {
            return SceneEnrichmentContext(
                runID: localSceneRunID,
                events: localSceneResult.events,
                materializedSegments: localSceneResult.materializedSegments
            )
        }

        let enhancedRunID =
            "scene_semantic_\(UUID().uuidString.lowercased())"
        let coordinator = SceneCoordinator(
            sessionID: sessionID,
            runID: enhancedRunID,
            writer: try SessionWriter(
                sessionURL: sessionURL(for: sessionID)
            ),
            materializer: TranscriptMaterializer(
                sampleRate: checkpoint.sampleRate
            )
        )
        let result = try await coordinator.process(
            speakerSpans: speakerSpans,
            totalFrames: checkpoint.committedFrames,
            sampleRate: checkpoint.sampleRate,
            existingEvents: localSceneResult.events,
            activeRuns: ActiveRuns(
                segmentation: baseActiveRuns.segmentation,
                asr: baseActiveRuns.asr,
                diarization: baseActiveRuns.diarization,
                scene: enhancedRunID,
                scope: baseActiveRuns.scope,
                contentPriority: baseActiveRuns.contentPriority
            ),
            semanticCues: collection.cues
        )

        try selectSceneRun(
            sessionID: sessionID,
            sceneRunID: enhancedRunID
        )

        return SceneEnrichmentContext(
            runID: enhancedRunID,
            events: result.events,
            materializedSegments: result.materializedSegments
        )
    }

    private func makeJevDecisionCoordinatorIfAvailable() throws
        -> JevDecisionCoordinator? {
        guard allowExternalJev else {
            return nil
        }

        if let jevDecisionCoordinatorFactory {
            return try jevDecisionCoordinatorFactory()
        }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "jev.isPaused") else {
            return nil
        }

        guard let apiKey = try KeychainStore().load(
            account: Self.jevAPIKeyAccount
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
        !apiKey.isEmpty else {
            return nil
        }

        return JevDecisionCoordinator(
            provider: JevClient(apiKey: apiKey),
            usageCounter: jevUsageCounter
        )
    }

    private func runJevEnrichmentIfAvailable(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        existingEvents: [TranscriptEvent],
        activeRuns: ActiveRuns,
        fallbackSegments: [MaterializedTranscriptSegment],
        onStatus: StatusHandler?
    ) async -> JevEnrichmentOutcome {
        let visibleSegments = fallbackSegments.filter {
            JevTranscriptEligibility.isEligible($0.text)
        }
        guard allowExternalJev else {
            return JevEnrichmentOutcome(
                materializedSegments: visibleSegments,
                pendingSegmentIDs: [],
                persistenceFailure: nil
            )
        }
        let allSegmentIDs = visibleSegments.map(\.segmentID)
        let visibleSegmentIDs = Set(allSegmentIDs)
        guard !allSegmentIDs.isEmpty else {
            let persistenceFailure = persistPendingContentPriorityIfPossible(
                sessionID: sessionID,
                segmentIDs: []
            )
            return JevEnrichmentOutcome(
                materializedSegments: [],
                pendingSegmentIDs: [],
                persistenceFailure: persistenceFailure
            )
        }
        let initialPersistenceFailure = persistPendingContentPriorityIfPossible(
            sessionID: sessionID,
            segmentIDs: allSegmentIDs
        )
        let decisions: JevDecisionCoordinator?
        do {
            decisions = try makeJevDecisionCoordinatorIfAvailable()
        } catch {
            if !allSegmentIDs.isEmpty, let onStatus {
                await onStatus(UserFacingStatus.jevDeferred.text)
            }
            return JevEnrichmentOutcome(
                materializedSegments: visibleSegments,
                pendingSegmentIDs: allSegmentIDs,
                persistenceFailure: initialPersistenceFailure
            )
        }
        guard let decisions else {
            if !allSegmentIDs.isEmpty, let onStatus {
                await onStatus(UserFacingStatus.jevDeferred.text)
            }
            return JevEnrichmentOutcome(
                materializedSegments: visibleSegments,
                pendingSegmentIDs: allSegmentIDs,
                persistenceFailure: initialPersistenceFailure
            )
        }

        if let onStatus {
            await onStatus(UserFacingStatus.classifyingWithJev.text)
        }

        let runID = "priority_\(UUID().uuidString.lowercased())"
        let result: JevEnrichmentBatchResult
        do {
            let coordinator = JevEnrichmentCoordinator(
                sessionID: sessionID,
                runID: runID,
                writer: try SessionWriter(
                    sessionURL: sessionURL(for: sessionID)
                ),
                decisions: decisions,
                materializer: TranscriptMaterializer(
                    sampleRate: checkpoint.sampleRate
                )
            )
            result = try await coordinator.process(
                existingEvents: existingEvents.filter { event in
                    guard let segmentID = event.segmentID else { return true }
                    return visibleSegmentIDs.contains(segmentID)
                },
                activeRuns: activeRuns
            )
        } catch {
            let failure = persistPendingContentPriorityIfPossible(
                sessionID: sessionID,
                segmentIDs: allSegmentIDs
            )
            if !allSegmentIDs.isEmpty, let onStatus {
                await onStatus(UserFacingStatus.jevDeferred.text)
            }
            return JevEnrichmentOutcome(
                materializedSegments: visibleSegments,
                pendingSegmentIDs: allSegmentIDs,
                persistenceFailure: failure ?? initialPersistenceFailure
            )
        }

        let selectionFailure: String?
        do {
            try selectContentPriorityRun(
                sessionID: sessionID,
                runID: runID,
                pendingSegmentIDs: result.retryPendingSegmentIDs
            )
            selectionFailure = nil
        } catch {
            selectionFailure = error.localizedDescription
        }

        if !result.retryPendingSegmentIDs.isEmpty,
           let onStatus {
            await onStatus(UserFacingStatus.jevDeferred.text)
        }

        return JevEnrichmentOutcome(
            materializedSegments: result.materializedSegments,
            pendingSegmentIDs: selectionFailure == nil
                ? result.retryPendingSegmentIDs
                : allSegmentIDs,
            persistenceFailure: selectionFailure
        )
    }

    private func reportFailure(
        prefix: String,
        error: Error,
        onStatus: StatusHandler?,
        onUpdate: UpdateHandler?
    ) async {
        if let onStatus {
            await onStatus("\(prefix): \(error.localizedDescription)")
        }
        if let onUpdate {
            await onUpdate(
                [],
                .partialFailure(error.localizedDescription)
            )
        }
    }

    private func selectSuccessfulRuns(
        sessionID: UUID,
        segmentationRunID: String,
        asrRunID: String
    ) throws {
        let store = ProcessingMetadataStore(
            sessionURL: sessionURL(for: sessionID)
        )
        guard let metadata = try store.load() else { return }

        let activeRuns = ActiveRuns(
            segmentation: segmentationRunID,
            asr: asrRunID,
            diarization: metadata.activeRuns?.diarization,
            scene: metadata.activeRuns?.scene,
            scope: metadata.activeRuns?.scope,
            contentPriority: metadata.activeRuns?.contentPriority
        )
        try store.save(metadata.withActiveRuns(activeRuns))
    }

    private func selectDiarizationRun(
        sessionID: UUID,
        diarizationRunID: String
    ) throws {
        let store = ProcessingMetadataStore(
            sessionURL: sessionURL(for: sessionID)
        )
        guard let metadata = try store.load() else { return }

        let activeRuns = ActiveRuns(
            segmentation: metadata.activeRuns?.segmentation,
            asr: metadata.activeRuns?.asr,
            diarization: diarizationRunID,
            scene: metadata.activeRuns?.scene,
            scope: metadata.activeRuns?.scope,
            contentPriority: metadata.activeRuns?.contentPriority
        )
        try store.save(metadata.withActiveRuns(activeRuns))
    }

    private func selectSceneRun(
        sessionID: UUID,
        sceneRunID: String
    ) throws {
        let store = ProcessingMetadataStore(
            sessionURL: sessionURL(for: sessionID)
        )
        guard let metadata = try store.load() else { return }

        let activeRuns = ActiveRuns(
            segmentation: metadata.activeRuns?.segmentation,
            asr: metadata.activeRuns?.asr,
            diarization: metadata.activeRuns?.diarization,
            scene: sceneRunID,
            scope: metadata.activeRuns?.scope,
            contentPriority: metadata.activeRuns?.contentPriority
        )
        try store.save(metadata.withActiveRuns(activeRuns))
    }

    private func selectScopeRun(
        sessionID: UUID,
        scopeRunID: String
    ) throws {
        let store = ProcessingMetadataStore(
            sessionURL: sessionURL(for: sessionID)
        )
        guard let metadata = try store.load() else { return }

        let activeRuns = ActiveRuns(
            segmentation: metadata.activeRuns?.segmentation,
            asr: metadata.activeRuns?.asr,
            diarization: metadata.activeRuns?.diarization,
            scene: metadata.activeRuns?.scene,
            scope: scopeRunID,
            contentPriority: metadata.activeRuns?.contentPriority
        )
        try store.save(metadata.withActiveRuns(activeRuns))
    }

    private func selectContentPriorityRun(
        sessionID: UUID,
        runID: String,
        pendingSegmentIDs: [String]? = nil
    ) throws {
        let store = ProcessingMetadataStore(
            sessionURL: sessionURL(for: sessionID)
        )
        guard let metadata = try store.load() else { return }

        let activeRuns = ActiveRuns(
            segmentation: metadata.activeRuns?.segmentation,
            asr: metadata.activeRuns?.asr,
            diarization: metadata.activeRuns?.diarization,
            scene: metadata.activeRuns?.scene,
            scope: metadata.activeRuns?.scope,
            contentPriority: runID
        )
        let selectedMetadata = metadata.withActiveRuns(activeRuns)
        try store.save(
            pendingSegmentIDs.map {
                selectedMetadata.withPendingContentPrioritySegmentIDs($0)
            } ?? selectedMetadata
        )
    }

    private func persistPendingContentPriority(
        sessionID: UUID,
        segmentIDs: [String]
    ) throws {
        let store = ProcessingMetadataStore(
            sessionURL: sessionURL(for: sessionID)
        )
        guard let metadata = try store.load() else {
            throw ProcessingMetadataStoreError.metadataMissing
        }
        try store.save(metadata.withPendingContentPrioritySegmentIDs(segmentIDs))
    }

    private func persistPendingContentPriorityIfPossible(
        sessionID: UUID,
        segmentIDs: [String]
    ) -> String? {
        do {
            try persistPendingContentPriority(
                sessionID: sessionID,
                segmentIDs: segmentIDs
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func persistProcessingMetadata(sessionID: UUID) throws {
        let store = ProcessingMetadataStore(
            sessionURL: sessionURL(for: sessionID)
        )
        let existingActiveRuns = try store.load()?.activeRuns
        try store.save(makeProcessingMetadata(activeRuns: existingActiveRuns))
    }

    private func makeProcessingMetadata(activeRuns: ActiveRuns?) -> ProcessingMetadata {
        ProcessingMetadata(
            timelineVersion: 1,
            vadVersion: "fluidaudio-0.15.8",
            vadConfigHash: "default-v1",
            asrEngine: "qwen3-asr-swift",
            asrModel: ModelStore.qwen3ASRModelID,
            asrVersion: "speech-swift-c4c2fab",
            diarizationVersion: "fluidaudio-0.15.8",
            sceneAnalyzerVersion: 1,
            jevSchemaVersion: 1,
            policyVersion: 1,
            materializerSchemaVersion: 1,
            activeRuns: activeRuns
        )
    }

    private func loadTranscriptEvents(
        sessionID: UUID,
        activeRuns: ActiveRuns
    ) throws -> [TranscriptEvent] {
        let eventsURL = sessionURL(for: sessionID).appending(path: "events.jsonl")
        let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: eventsURL))
        if recovered.droppedIncompleteTail {
            try recovered.normalizedData.write(to: eventsURL, options: .atomic)
        }
        return try EventLogTranscriptReader().events(
            lines: recovered.lines,
            activeRuns: activeRuns
        )
    }

    private func loadMaterializedSegments(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        activeRuns: ActiveRuns
    ) throws -> [MaterializedTranscriptSegment] {
        TranscriptMaterializer(sampleRate: checkpoint.sampleRate).materialize(
            events: try loadTranscriptEvents(sessionID: sessionID, activeRuns: activeRuns),
            activeRuns: activeRuns
        )
    }

    private func sessionURL(for sessionID: UUID) -> URL {
        sessionsRoot.appending(
            path: sessionID.uuidString,
            directoryHint: .isDirectory
        )
    }

    private func pendingDates(sessionID: UUID, plan: ASRRecoveryPlan) throws -> [String: Date] {
        let data = try Data(contentsOf: sessionURL(for: sessionID).appending(path: "events.jsonl"))
        let recovered = try SessionRecovery.recoverJSONL(data)
        let pendingIDs = Set(plan.pendingSegments.map(\.segmentID))
        let formatter = ISO8601DateFormatter()
        var dates: [String: Date] = [:]
        for line in recovered.lines {
            guard let event = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  event["event_type"] as? String == "asr.pending",
                  event["processing_run_id"] as? String == plan.asrRunID,
                  let segmentID = event["segment_id"] as? String,
                  pendingIDs.contains(segmentID),
                  let timestamp = event["created_at"] as? String,
                  let date = formatter.date(from: timestamp) else { continue }
            dates[segmentID] = date
        }
        return dates
    }

    private func processingDirectory(for sessionID: UUID) -> URL {
        sessionURL(for: sessionID)
            .appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "processing", directoryHint: .isDirectory)
    }
}
