import Foundation
import MacAmbientJevCore
import MacAmbientJevAppleSupport

enum NativeSessionProcessorError: LocalizedError {
    case liveASRSessionNotStarted
    case transcriptNotPublished
    case processingTimelineMissing

    var errorDescription: String? {
        switch self {
        case .liveASRSessionNotStarted:
            "録音中の文字起こしセッションが開始されていません"
        case .transcriptNotPublished:
            "確定済みの文字起こし run がありません"
        case .processingTimelineMissing:
            "処理用タイムラインのチェックポイントがありません"
        }
    }
}

private struct JevEnrichmentOutcome: Sendable {
    let materializedSegments: [MaterializedTranscriptSegment]
    let pendingSegmentIDs: [String]
    let persistenceFailure: String?
    let stopReason: JevBatchStopReason?
}

extension Optional<JevBatchStopReason> {
    /// The status for segments a batch left pending.
    fileprivate var pendingStatus: UserFacingStatus {
        self == .authorizationRejected ? .jevAuthorizationRequired : .jevDeferred
    }
}

/// What stays on screen when a finalization does not complete.
public enum RetainedTranscript: Sendable, Equatable {
    /// The previously published finalized transcript.
    case finalized
    /// The provisional live transcript the caller passed in.
    case provisional
    /// Nothing: no finalized transcript existed and there was no provisional one.
    case nothing
}

public struct SessionProcessingResult: Sendable {
    public let disposition: BatchDisposition
    public let metrics: ASRBatchMetrics?
    public let message: String?
    /// True when a completed finalization found no speech.
    public let noSpeech: Bool
    /// Set when the finalization did not complete and a display was retained.
    public let retainedTranscript: RetainedTranscript?

    /// `metrics` is nil only when nothing was processed.
    public static func completed(metrics: ASRBatchMetrics?, noSpeech: Bool) -> SessionProcessingResult {
        SessionProcessingResult(
            disposition: .completed,
            metrics: metrics,
            message: nil,
            noSpeech: noSpeech,
            retainedTranscript: nil
        )
    }

    public static func paused(
        metrics: ASRBatchMetrics,
        retained: RetainedTranscript
    ) -> SessionProcessingResult {
        SessionProcessingResult(
            disposition: .paused,
            metrics: metrics,
            message: UserFacingStatus.finalizationPausedForHeat.text,
            noSpeech: false,
            retainedTranscript: retained
        )
    }

    public static func failed(
        message: String,
        metrics: ASRBatchMetrics?,
        retained: RetainedTranscript?
    ) -> SessionProcessingResult {
        SessionProcessingResult(
            disposition: .failed,
            metrics: metrics,
            message: message,
            noSpeech: false,
            retainedTranscript: retained
        )
    }
}

/// The engines a processor runs. Tests substitute fakes; the app and CLIs use `production(paths:)`.
public struct SessionProcessingEngines: Sendable {
    public let asr: any ASREngine
    public let diarization: any DiarizationEngine
    public let finalTranscriptVAD: any FinalTranscriptVADSegmenter

    public init(
        asr: any ASREngine,
        diarization: any DiarizationEngine,
        finalTranscriptVAD: any FinalTranscriptVADSegmenter
    ) {
        self.asr = asr
        self.diarization = diarization
        self.finalTranscriptVAD = finalTranscriptVAD
    }

    public static func production(paths: AppPaths) -> SessionProcessingEngines {
        SessionProcessingEngines(
            asr: NativeQwen3ASREngine(modelStore: ModelStore(paths: paths)),
            diarization: FluidOfflineDiarizationEngine(paths: paths),
            finalTranscriptVAD: FluidFinalTranscriptVADSegmenter()
        )
    }
}

/// Whether live transcription and finalization classify content priority through Jev.
public enum ContentPriorityAccess: Sendable {
    case disabled
    /// The factory returns nil when Jev is currently unavailable; segments then stay pending.
    case jev(NativeSessionProcessor.JevDecisionCoordinatorFactory)
}

public actor NativeSessionProcessor {
    public typealias JevDecisionCoordinatorFactory = @Sendable () throws
        -> JevDecisionCoordinator?
    public typealias StatusHandler = @Sendable (_ text: String) async -> Void
    public typealias UpdateHandler = @Sendable (
        _ segments: [MaterializedTranscriptSegment],
        _ state: ProcessingState
    ) async -> Void
    public typealias PauseCheck = @Sendable () async -> Bool
    public typealias PhaseHandler = @Sendable (RunPhase) async -> Void

    private static let jevAPIKeyAccount = "jev-api-key"

    private let sessionsRoot: URL
    private let asr: any ASREngine
    private let diarization: any DiarizationEngine
    private let finalTranscriptVAD: any FinalTranscriptVADSegmenter
    private let contentPriority: ContentPriorityAccess
    private var liveASRSessions: [UUID: LiveASRSession] = [:]
    private var liveContentPrioritySessions: [UUID: LiveContentPrioritySession] = [:]

    public init(
        paths: AppPaths,
        engines: SessionProcessingEngines,
        contentPriority: ContentPriorityAccess
    ) {
        self.sessionsRoot = paths.sessionsRoot
        self.asr = engines.asr
        self.diarization = engines.diarization
        self.finalTranscriptVAD = engines.finalTranscriptVAD
        self.contentPriority = contentPriority
    }

    /// Builds Jev from the API key saved in the Keychain, unless the user paused Jev.
    public static func storedCredentialJevFactory(
        usageCounter: JevUsageCounter
    ) -> JevDecisionCoordinatorFactory {
        {
            guard !UserDefaults.standard.bool(forKey: "jev.isPaused") else {
                return nil
            }
            guard let apiKey = try KeychainStore().load(
                account: jevAPIKeyAccount
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty else {
                return nil
            }
            return JevDecisionCoordinator(
                provider: JevClient(apiKey: apiKey, transport: URLSessionJevHTTPTransport(session: .shared)),
                usageCounter: usageCounter
            )
        }
    }

    public func prepareASR(
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        try await asr.prepare(onProgress: onProgress)
    }

    /// Unloads the ASR and diarization models; unloading the ASR model also clears the MLX buffer cache. Call only while
    /// no recording, live transcription, or finalization is running. `prepareASR` loads again.
    public func releaseIdleResources() async {
        await asr.unload()
        await diarization.unload()
    }

    @discardableResult
    public func startLiveTranscription(
        sessionID: UUID,
        segmentationRunID: String,
        sampleRate: Double
    ) throws -> String {
        let asrRunID = "asr_live_\(UUID().uuidString.lowercased())"
        let sessionLayout = try layout(for: sessionID)
        let writer = try SessionWriter(sessionURL: sessionLayout.sessionURL)
        let liveSession = LiveASRSession(
            sessionID: sessionID,
            segmentationRunID: segmentationRunID,
            asrRunID: asrRunID,
            processingDirectory: sessionLayout.processingDirectory,
            writer: writer,
            asr: asr,
            sampleRate: sampleRate
        )
        liveASRSessions[sessionID] = liveSession
        if case .jev(let factory) = contentPriority {
            liveContentPrioritySessions[sessionID] = LiveContentPrioritySession(
                sessionID: sessionID,
                runID: "priority_live_\(UUID().uuidString.lowercased())",
                writer: writer,
                liveASR: liveSession,
                sampleRate: sampleRate,
                makeDecisions: factory
            )
        }
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
        onStatus: StatusHandler?,
        onUpdate: UpdateHandler?
    ) async throws -> LiveASRProgress {
        guard let liveSession = liveASRSessions[sessionID] else {
            throw NativeSessionProcessorError.liveASRSessionNotStarted
        }

        if let onStatus, !segments.isEmpty {
            await onStatus("録音中の発話を文字起こししています")
        }

        let progress = try await liveSession.process(
            segments: segments,
            checkpoint: checkpoint,
            onRecognized: { [weak self] segmentID, _ in
                await self?.publishLiveRecognition(
                    sessionID: sessionID,
                    liveSession: liveSession,
                    segmentID: segmentID,
                    onStatus: onStatus,
                    onUpdate: onUpdate
                )
            }
        )

        guard liveASRSessions[sessionID] === liveSession else {
            return progress
        }
        await publishLiveRows(sessionID: sessionID, liveSession: liveSession, onUpdate: onUpdate)
        return progress
    }

    private func publishLiveRecognition(
        sessionID: UUID,
        liveSession: LiveASRSession,
        segmentID: String,
        onStatus: StatusHandler?,
        onUpdate: UpdateHandler?
    ) async {
        guard liveASRSessions[sessionID] === liveSession else { return }
        let snapshot = await liveSession.snapshot()
        // Queued before publishing so the new row is held back until its decision arrives.
        if let enrichment = liveContentPrioritySessions[sessionID] {
            await enrichment.enqueue(
                segmentID: segmentID,
                snapshot: snapshot,
                onStatus: { text in await onStatus?(text) },
                onUpdate: { [weak self] _ in
                    await self?.publishLiveRows(
                        sessionID: sessionID, liveSession: liveSession, onUpdate: onUpdate
                    )
                }
            )
        }
        await publishLiveRows(sessionID: sessionID, liveSession: liveSession, onUpdate: onUpdate)
    }

    private func publishLiveRows(
        sessionID: UUID,
        liveSession: LiveASRSession,
        onUpdate: UpdateHandler?
    ) async {
        guard liveASRSessions[sessionID] === liveSession, let onUpdate else { return }
        let rows = await liveSession.snapshot().progress.materializedSegments
        let displayable: [MaterializedTranscriptSegment]
        if let enrichment = liveContentPrioritySessions[sessionID] {
            displayable = await enrichment.displayable(rows)
        } else {
            displayable = rows
        }
        await onUpdate(displayable, .running)
    }

    /// Stops external classification immediately; the ASR backlog may still drain locally.
    public func stopLiveContentPriority(sessionID: UUID) async {
        if let enrichment = liveContentPrioritySessions.removeValue(forKey: sessionID) {
            await enrichment.stop()
        }
    }

    public func cancelLiveTranscription(sessionID: UUID) async {
        await stopLiveContentPriority(sessionID: sessionID)
        liveASRSessions[sessionID] = nil
    }

    /// Ends live transcription, if any, and finalizes the whole recording from
    /// its saved timeline. The live transcript is only a provisional display.
    public func finishLiveTranscription(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        finalSegments: [SegmentReference],
        pacingMode: ASRPacingMode,
        shouldPause: @escaping PauseCheck,
        onPhase: @escaping PhaseHandler,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async -> SessionProcessingResult {
        await stopLiveContentPriority(sessionID: sessionID)
        var provisional: [MaterializedTranscriptSegment] = []
        if let liveSession = liveASRSessions[sessionID] {
            if !finalSegments.isEmpty {
                do {
                    try await processLiveSegments(
                        sessionID: sessionID,
                        segments: finalSegments,
                        checkpoint: checkpoint,
                        onStatus: onStatus,
                        onUpdate: onUpdate
                    )
                } catch {
                    await onStatus("録音の最後の発話をライブ文字起こしできませんでした: \(error.localizedDescription)")
                }
            }
            do {
                provisional = try await liveSession.finish().materializedSegments
                await onUpdate(provisional, .running)
            } catch {
                await onStatus("ライブ文字起こしを終了できませんでした: \(error.localizedDescription)")
            }
            liveASRSessions[sessionID] = nil
        }

        return await finalize(
            sessionID: sessionID,
            provisional: provisional,
            metadataPolicy: .reject,
            pacingMode: pacingMode,
            shouldPause: shouldPause,
            onPhase: onPhase,
            onStatus: onStatus,
            onUpdate: onUpdate,
            timeline: { _ in checkpoint }
        )
    }

    /// Rebuilds every run from the saved processing timeline and publishes the
    /// new run set only after all stages have completed.
    @discardableResult
    public func processFinalTranscript(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping PauseCheck,
        onPhase: @escaping PhaseHandler,
        metadataPolicy: UnreadableMetadataPolicy,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async -> SessionProcessingResult {
        await finalize(
            sessionID: sessionID,
            provisional: [],
            metadataPolicy: metadataPolicy,
            pacingMode: pacingMode,
            shouldPause: shouldPause,
            onPhase: onPhase,
            onStatus: onStatus,
            onUpdate: onUpdate,
            timeline: { _ in checkpoint }
        )
    }

    /// Rebuilds the processing timeline from the imported original, then finalizes it.
    @discardableResult
    public func processImportedSession(
        sessionID: UUID,
        originalURL: URL,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping PauseCheck,
        onPhase: @escaping PhaseHandler,
        metadataPolicy: UnreadableMetadataPolicy,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async -> SessionProcessingResult {
        return await finalize(
            sessionID: sessionID,
            provisional: [],
            metadataPolicy: metadataPolicy,
            pacingMode: pacingMode,
            shouldPause: shouldPause,
            onPhase: onPhase,
            onStatus: onStatus,
            onUpdate: onUpdate,
            timeline: { sessionLayout in
                await onStatus(UserFacingStatus.convertingTimeline.text)
                return try await AudioFileTimelineBuilder()
                    .build(from: originalURL, into: sessionLayout.processingDirectory)
            }
        )
    }

    public func retryContentPrioritySession(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        segmentIDs: [String],
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async {
        do {
            guard !segmentIDs.isEmpty else {
                return
            }

            guard let decisions = try makeJevDecisionCoordinatorIfAvailable() else {
                await onStatus(UserFacingStatus.jevDeferred.text)
                return
            }

            let sessionLayout = try layout(for: sessionID)
            let metadataStore = ProcessingMetadataStore(sessionURL: sessionLayout.sessionURL)
            guard let activeRuns = try metadataStore.load()?.activeRuns else {
                throw NativeSessionProcessorError.transcriptNotPublished
            }

            let events = try loadTranscriptEvents(sessionLayout: sessionLayout, activeRuns: activeRuns)
            let materializer = TranscriptMaterializer(sampleRate: checkpoint.sampleRate)
            let visible = materializer.materialize(
                events: events,
                activeRuns: activeRuns
            ).filter(\.hasRecognizedText)

            await onStatus("保留中の意味分類を再試行しています（\(segmentIDs.count)区間）")
            await onUpdate(visible, .running)

            let runID = "priority_retry_\(UUID().uuidString.lowercased())"
            let writer = try SessionWriter(sessionURL: sessionLayout.sessionURL)
            try await startContentPriorityRun(runID: runID, sessionID: sessionID, writer: writer)
            let coordinator = JevEnrichmentCoordinator(
                sessionID: sessionID,
                runID: runID,
                writer: writer,
                decisions: decisions,
                materializer: materializer
            )
            let result = try await coordinator.process(
                existingEvents: events,
                activeRuns: activeRuns,
                scope: .retry(Set(segmentIDs)),
                reusableDecisions: [:],
                completeRun: true,
                onAssignment: nil
            )

            try selectContentPriorityRun(
                sessionLayout: sessionLayout,
                runID: runID,
                pendingSegmentIDs: result.retryPendingSegmentIDs
            )

            await onUpdate(result.materializedSegments, .complete)
            if result.retryPendingSegmentIDs.isEmpty {
                await onStatus("保留中の意味分類を更新しました")
            } else {
                await onStatus(result.stopReason.pendingStatus.text)
            }
        } catch {
            await onStatus("意味分類を再試行できませんでした: \(error.localizedDescription)")
        }
    }

    // MARK: - Finalization

    private func finalize(
        sessionID: UUID,
        provisional: [MaterializedTranscriptSegment],
        metadataPolicy: UnreadableMetadataPolicy,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping PauseCheck,
        onPhase: @escaping PhaseHandler,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler,
        timeline: @Sendable (SessionLayout) async throws -> AudioCheckpoint
    ) async -> SessionProcessingResult {
        await stopLiveContentPriority(sessionID: sessionID)
        let sessionLayout: SessionLayout
        let metadataStore: ProcessingMetadataStore
        let attemptID = "finalize_\(UUID().uuidString.lowercased())"
        let previous: ProcessingMetadata?
        do {
            sessionLayout = try layout(for: sessionID)
            metadataStore = ProcessingMetadataStore(sessionURL: sessionLayout.sessionURL)
            previous = try metadataStore.beginFinalization(attemptID: attemptID, policy: metadataPolicy)
        } catch {
            let message = "確定処理を開始できませんでした: \(error.localizedDescription)"
            await onPhase(.complete)
            await onStatus(message)
            await onUpdate(provisional, .partialFailure(message))
            return .failed(
                message: message,
                metrics: nil,
                retained: provisional.isEmpty ? .nothing : .provisional
            )
        }

        // Freeze durable live decisions before any final recognition. In-flight live
        // requests never become a dependency of finalization.
        let reusableDecisions: [String: ContentPriorityEventPayload]
        let liveDecisionReadFailure: String?
        do {
            if case .jev = contentPriority {
                let lines = try SessionRecovery.recoverJSONL(Data(contentsOf: sessionLayout.eventsURL)).lines
                reusableDecisions = try EventLogTranscriptReader().liveContentPriorityDecisions(lines: lines)
            } else {
                reusableDecisions = [:]
            }
            liveDecisionReadFailure = nil
        } catch {
            reusableDecisions = [:]
            liveDecisionReadFailure = error.localizedDescription
        }

        await onPhase(.preparing)
        let outcome: FinalTranscriptPipelineOutcome
        let checkpoint: AudioCheckpoint
        do {
            checkpoint = try await timeline(sessionLayout)
            outcome = try await FinalTranscriptPipeline(
                sessionID: sessionID,
                sessionURL: sessionLayout.sessionURL,
                checkpoint: checkpoint,
                asr: asr,
                diarization: diarization,
                vadSegmenter: finalTranscriptVAD,
                proximityEvidenceProvider: TimelineProximityEvidenceProvider(
                    reader: ProcessingTimelineReader(
                        directory: sessionLayout.processingDirectory,
                        checkpoint: checkpoint
                    )
                )
            ).process(
                onStatus: onStatus,
                pacingMode: pacingMode,
                shouldPause: shouldPause,
                onPhase: onPhase
            )
        } catch {
            let metrics = (error as? FinalTranscriptPipelineFailure)?.metrics
            return await failFinalization(
                attemptID: attemptID,
                message: error.localizedDescription,
                metrics: metrics,
                sessionLayout: sessionLayout,
                previous: previous,
                provisional: provisional,
                onPhase: onPhase,
                onStatus: onStatus,
                onUpdate: onUpdate
            )
        }

        switch outcome {
        case .paused(let metrics):
            do {
                try metadataStore.pauseFinalization(attemptID: attemptID)
            } catch {
                return await failFinalization(
                    attemptID: attemptID,
                    message: "一時停止を保存できませんでした: \(error.localizedDescription)",
                    metrics: metrics,
                    sessionLayout: sessionLayout,
                    previous: previous,
                    provisional: provisional,
                    onPhase: onPhase,
                    onStatus: onStatus,
                    onUpdate: onUpdate
                )
            }
            let retained = await retainedDisplay(
                sessionLayout: sessionLayout,
                previous: previous,
                provisional: provisional
            )
            await onPhase(.complete)
            if let readFailure = retained.readFailure {
                await onStatus(readFailure)
            }
            await onStatus(UserFacingStatus.finalizationPausedForHeat.text)
            await onUpdate(retained.segments, .backlogged)
            return .paused(metrics: metrics, retained: retained.kind)

        case .completed(let final):
            do {
                try metadataStore.completeFinalization(attemptID: attemptID, activeRuns: final.activeRuns)
            } catch {
                return await failFinalization(
                    attemptID: attemptID,
                    message: "確定結果を公開できませんでした: \(error.localizedDescription)",
                    metrics: final.metrics,
                    sessionLayout: sessionLayout,
                    previous: previous,
                    provisional: provisional,
                    onPhase: onPhase,
                    onStatus: onStatus,
                    onUpdate: onUpdate
                )
            }
            await onUpdate(final.materializedSegments, .running)
            await publishCompletion(
                final,
                sessionID: sessionID,
                sessionLayout: sessionLayout,
                checkpoint: checkpoint,
                reusableDecisions: reusableDecisions,
                liveDecisionReadFailure: liveDecisionReadFailure,
                onPhase: onPhase,
                onStatus: onStatus,
                onUpdate: onUpdate
            )
            return .completed(metrics: final.metrics, noSpeech: final.completedCount == 0)
        }
    }

    private func publishCompletion(
        _ final: FinalTranscriptPipelineResult,
        sessionID: UUID,
        sessionLayout: SessionLayout,
        checkpoint: AudioCheckpoint,
        reusableDecisions: [String: ContentPriorityEventPayload],
        liveDecisionReadFailure: String?,
        onPhase: PhaseHandler,
        onStatus: @escaping StatusHandler,
        onUpdate: UpdateHandler
    ) async {
        var finalSegments = final.materializedSegments
        var deferredContentPriorityIDs: [String] = []
        var deferredContentPriorityStatus = UserFacingStatus.jevDeferred
        var retryStatePersistenceFailure: String?
        if case .jev = contentPriority, !final.materializedSegments.isEmpty,
           liveDecisionReadFailure == nil {
            do {
                let events = try loadTranscriptEvents(sessionLayout: sessionLayout, activeRuns: final.activeRuns)
                let outcome = await runJevEnrichmentIfAvailable(
                    sessionID: sessionID,
                    sessionLayout: sessionLayout,
                    checkpoint: checkpoint,
                    existingEvents: events,
                    activeRuns: final.activeRuns,
                    segments: final.materializedSegments,
                    reusableDecisions: reusableDecisions,
                    onStatus: onStatus
                )
                finalSegments = outcome.materializedSegments
                deferredContentPriorityIDs = outcome.pendingSegmentIDs
                deferredContentPriorityStatus = outcome.stopReason.pendingStatus
                retryStatePersistenceFailure = outcome.persistenceFailure
            } catch {
                deferredContentPriorityIDs = final.materializedSegments
                    .filter(\.hasRecognizedText)
                    .map(\.segmentID)
                retryStatePersistenceFailure = persistPendingContentPriority(
                    sessionLayout: sessionLayout,
                    segmentIDs: deferredContentPriorityIDs
                )
            }
        }
        if liveDecisionReadFailure != nil {
            deferredContentPriorityIDs = final.materializedSegments.filter(\.hasRecognizedText).map(\.segmentID)
            retryStatePersistenceFailure = persistPendingContentPriority(
                sessionLayout: sessionLayout, segmentIDs: deferredContentPriorityIDs
            )
        }

        await onUpdate(finalSegments, .complete)
        await onPhase(.complete)
        if let retryStatePersistenceFailure {
            await onStatus("意味分類の再試行状態を保存できませんでした: \(retryStatePersistenceFailure)")
        }
        if final.completedCount == 0 {
            await onStatus("発話区間は検出されませんでした")
        } else if let liveDecisionReadFailure {
            await onStatus("ライブの意味分類を読み込めないため、意味分類を保留しました: \(liveDecisionReadFailure)")
        } else if !deferredContentPriorityIDs.isEmpty {
            await onStatus(deferredContentPriorityStatus.text)
        } else if retryStatePersistenceFailure == nil {
            await onStatus(
                "文字起こし、話者分離、場面判定、音響範囲整理が完了しました（\(final.completedCount)区間）"
            )
        }
    }

    private func failFinalization(
        attemptID: String,
        message: String,
        metrics: ASRBatchMetrics?,
        sessionLayout: SessionLayout,
        previous: ProcessingMetadata?,
        provisional: [MaterializedTranscriptSegment],
        onPhase: PhaseHandler,
        onStatus: StatusHandler,
        onUpdate: UpdateHandler
    ) async -> SessionProcessingResult {
        var message = message
        do {
            try ProcessingMetadataStore(sessionURL: sessionLayout.sessionURL)
                .failFinalization(attemptID: attemptID, reason: message)
        } catch {
            message += "（処理状態も保存できませんでした: \(error.localizedDescription)）"
        }
        let retained = await retainedDisplay(
            sessionLayout: sessionLayout,
            previous: previous,
            provisional: provisional
        )
        if let readFailure = retained.readFailure {
            message += "（\(readFailure)）"
        }
        await onPhase(.complete)
        await onStatus("確定処理に失敗しました: \(message)")
        await onUpdate(retained.segments, .partialFailure(message))
        return .failed(message: message, metrics: metrics, retained: retained.kind)
    }

    /// The display kept when a finalization stops: the previously published
    /// transcript if there is one, otherwise the caller's provisional transcript.
    private func retainedDisplay(
        sessionLayout: SessionLayout,
        previous: ProcessingMetadata?,
        provisional: [MaterializedTranscriptSegment]
    ) async -> (segments: [MaterializedTranscriptSegment], kind: RetainedTranscript, readFailure: String?) {
        let unpublishedKind: RetainedTranscript = provisional.isEmpty ? .nothing : .provisional
        guard let activeRuns = previous?.activeRuns else {
            return (provisional, unpublishedKind, nil)
        }
        do {
            guard let checkpoint = try AudioCheckpoint.loadRecovered(
                from: sessionLayout.processingDirectory
            ) else {
                throw NativeSessionProcessorError.processingTimelineMissing
            }
            let segments = TranscriptMaterializer(sampleRate: checkpoint.sampleRate).materialize(
                events: try loadTranscriptEvents(sessionLayout: sessionLayout, activeRuns: activeRuns),
                activeRuns: activeRuns
            ).filter(\.hasRecognizedText)
            return (segments, .finalized, nil)
        } catch {
            return (
                provisional,
                unpublishedKind,
                "以前の確定結果を読み込めませんでした: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Content priority

    private func makeJevDecisionCoordinatorIfAvailable() throws
        -> JevDecisionCoordinator? {
        switch contentPriority {
        case .disabled:
            nil
        case .jev(let factory):
            try factory()
        }
    }

    /// The model is recorded on each Jev response; the run records the service and policy.
    private static let contentPriorityProvenance = RunProvenance(
        engine: "jev",
        model: nil,
        version: "1",
        configuration: [
            "endpoint": JevClient.endpoint.absoluteString,
            "minimum_demotion_confidence": String(ContentPriorityPolicy.minimumDemotionConfidence),
        ]
    )

    private func startContentPriorityRun(
        runID: String,
        sessionID: UUID,
        writer: SessionWriter
    ) async throws {
        try await writer.append(EventDraft(
            eventType: "processing.run.started",
            sessionID: sessionID,
            processingRunID: runID,
            payload: ProcessingRunStartedPayload(
                stage: .contentPriority,
                provenance: Self.contentPriorityProvenance
            )
        ))
    }

    private func runJevEnrichmentIfAvailable(
        sessionID: UUID,
        sessionLayout: SessionLayout,
        checkpoint: AudioCheckpoint,
        existingEvents: [TranscriptEvent],
        activeRuns: ActiveRuns,
        segments: [MaterializedTranscriptSegment],
        reusableDecisions: [String: ContentPriorityEventPayload],
        onStatus: StatusHandler
    ) async -> JevEnrichmentOutcome {
        let visibleSegments = segments.filter(\.hasRecognizedText)
        let allSegmentIDs = visibleSegments.map(\.segmentID)
        let visibleSegmentIDs = Set(allSegmentIDs)
        guard !allSegmentIDs.isEmpty else {
            return JevEnrichmentOutcome(
                materializedSegments: [],
                pendingSegmentIDs: [],
                persistenceFailure: nil,
                stopReason: nil
            )
        }
        let initialPersistenceFailure = persistPendingContentPriority(
            sessionLayout: sessionLayout,
            segmentIDs: allSegmentIDs
        )
        let deferred = JevEnrichmentOutcome(
            materializedSegments: visibleSegments,
            pendingSegmentIDs: allSegmentIDs,
            persistenceFailure: initialPersistenceFailure,
            stopReason: nil
        )
        let decisions: JevDecisionCoordinator?
        do {
            decisions = try makeJevDecisionCoordinatorIfAvailable()
        } catch {
            await onStatus("意味分類を開始できませんでした: \(error.localizedDescription)")
            return deferred
        }
        guard decisions != nil || !reusableDecisions.isEmpty else {
            await onStatus(UserFacingStatus.jevDeferred.text)
            return deferred
        }

        await onStatus(UserFacingStatus.classifyingWithJev.text)

        let runID = "priority_\(UUID().uuidString.lowercased())"
        let result: JevEnrichmentBatchResult
        do {
            let writer = try SessionWriter(sessionURL: sessionLayout.sessionURL)
            try await startContentPriorityRun(runID: runID, sessionID: sessionID, writer: writer)
            let coordinator = JevEnrichmentCoordinator(
                sessionID: sessionID,
                runID: runID,
                writer: writer,
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
                activeRuns: activeRuns,
                scope: .all,
                reusableDecisions: reusableDecisions,
                completeRun: true,
                onAssignment: nil
            )
        } catch {
            await onStatus(UserFacingStatus.jevDeferred.text)
            return deferred
        }

        let selectionFailure: String?
        do {
            try selectContentPriorityRun(
                sessionLayout: sessionLayout,
                runID: runID,
                pendingSegmentIDs: result.retryPendingSegmentIDs
            )
            selectionFailure = nil
        } catch {
            selectionFailure = error.localizedDescription
        }

        if !result.retryPendingSegmentIDs.isEmpty {
            await onStatus(result.stopReason.pendingStatus.text)
        }

        return JevEnrichmentOutcome(
            materializedSegments: result.materializedSegments,
            pendingSegmentIDs: selectionFailure == nil
                ? result.retryPendingSegmentIDs
                : allSegmentIDs,
            persistenceFailure: selectionFailure,
            stopReason: result.stopReason
        )
    }

    private func selectContentPriorityRun(
        sessionLayout: SessionLayout,
        runID: String,
        pendingSegmentIDs: [String]
    ) throws {
        try ProcessingMetadataStore(sessionURL: sessionLayout.sessionURL).update { metadata in
            guard let activeRuns = metadata.activeRuns else {
                throw NativeSessionProcessorError.transcriptNotPublished
            }
            metadata.activeRuns = ActiveRuns(
                segmentation: activeRuns.segmentation,
                asr: activeRuns.asr,
                diarization: activeRuns.diarization,
                scene: activeRuns.scene,
                scope: activeRuns.scope,
                contentPriority: runID
            )
            metadata.pendingContentPrioritySegmentIDs = pendingSegmentIDs
        }
    }

    /// Returns the failure message, if saving failed.
    private func persistPendingContentPriority(
        sessionLayout: SessionLayout,
        segmentIDs: [String]
    ) -> String? {
        do {
            try ProcessingMetadataStore(sessionURL: sessionLayout.sessionURL).update {
                $0.pendingContentPrioritySegmentIDs = segmentIDs
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Session files

    private func loadTranscriptEvents(
        sessionLayout: SessionLayout,
        activeRuns: ActiveRuns
    ) throws -> [TranscriptEvent] {
        let eventsURL = sessionLayout.eventsURL
        let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: eventsURL))
        if recovered.droppedIncompleteTail {
            try recovered.normalizedData.write(to: eventsURL, options: .atomic)
        }
        return try EventLogTranscriptReader().events(
            lines: recovered.lines,
            activeRuns: activeRuns
        )
    }

    private func layout(for sessionID: UUID) throws -> SessionLayout {
        SessionLayout(sessionURL: try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: sessionsRoot, sessionID: sessionID))
    }
}
