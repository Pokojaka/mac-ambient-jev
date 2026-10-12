import Foundation
import MacAmbientJevCore
import MacAmbientJevAppleSupport

enum NativeSessionProcessorError: LocalizedError {
    case liveASRSessionNotStarted
    case transcriptNotPublished
    case storedAudioMissing
    case duplicateDecisionRetryTarget

    var errorDescription: String? {
        switch self {
        case .liveASRSessionNotStarted:
            "録音中の文字起こしセッションが開始されていません"
        case .transcriptNotPublished:
            "確定済みの文字起こし run がありません"
        case .storedAudioMissing:
            "保存済みの音声がありません"
        case .duplicateDecisionRetryTarget:
            "判定の再試行対象が重複しています"
        }
    }
}

/// Where a finalization gets its audio: the checkpoint of a recording that just finished, or
/// whatever `storage.json` names at the moment finalization begins.
private enum FinalizationAudio {
    case live(AudioCheckpoint)
    case stored
}

extension Optional<DecisionBatchStopReason> {
    /// The status for segments a batch left pending.
    fileprivate var pendingStatus: UserFacingStatus {
        self == .authorizationRejected ? .decisionAuthorizationRequired : .decisionDeferred
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

/// Whether live transcription and finalization send clause boundaries and priorities to the selected decision engine.
public enum ContentPriorityAccess: Sendable {
    case disabled
    /// The factory returns nil when the selected engine is unavailable; results then stay pending.
    /// The counter is shared so pending targets can be cleared even when no provider exists.
    case selectedEngine(NativeSessionProcessor.DecisionCoordinatorFactory, usageCounter: DecisionUsageCounter)
}

public actor NativeSessionProcessor {
    public typealias DecisionCoordinatorFactory = @Sendable () throws
        -> DecisionCoordinator?
    public typealias StatusHandler = @Sendable (_ text: String) async -> Void
    public typealias UpdateHandler = @Sendable (
        _ segments: [MaterializedTranscriptSegment],
        _ state: ProcessingState
    ) async -> Void
    public typealias PauseCheck = @Sendable () async -> Bool
    public typealias PhaseHandler = @Sendable (RunPhase) async -> Void

    private let sessionsRoot: URL
    private let asr: any ASREngine
    private let diarization: any DiarizationEngine
    private let finalTranscriptVAD: any FinalTranscriptVADSegmenter
    private let contentPriority: ContentPriorityAccess
    private var liveASRSessions: [UUID: LiveASRSession] = [:]
    private var liveContentPrioritySessions: [UUID: LiveContentPrioritySession] = [:]
    /// Pending live keys survive a failed/paused takeover until a published replacement clears them.
    private var retiredLivePendingTargets: [UUID: Set<DecisionPendingTarget>] = [:]

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
        let decisionRuns: (boundary: String, priority: String)?
        if case .selectedEngine = contentPriority {
            let suffix = UUID().uuidString.lowercased()
            decisionRuns = ("boundary_live_\(suffix)", "priority_live_\(suffix)")
        } else {
            decisionRuns = nil
        }
        let liveSession = LiveASRSession(
            sessionID: sessionID,
            sessionURL: sessionLayout.sessionURL,
            segmentationRunID: segmentationRunID,
            asrRunID: asrRunID,
            processingDirectory: sessionLayout.processingDirectory,
            writer: writer,
            asr: asr,
            sampleRate: sampleRate,
            clauseBoundaryRunID: decisionRuns?.boundary,
            contentPriorityRunID: decisionRuns?.priority
        )
        liveASRSessions[sessionID] = liveSession
        if case .selectedEngine(let factory, let usageCounter) = contentPriority, let decisionRuns {
            liveContentPrioritySessions[sessionID] = LiveContentPrioritySession(
                sessionID: sessionID,
                boundaryRunID: decisionRuns.boundary,
                priorityRunID: decisionRuns.priority,
                writer: writer,
                liveASR: liveSession,
                makeDecisions: factory,
                usageCounter: usageCounter
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
            onSegmentFinished: { [weak self] status, snapshot in
                await self?.publishLiveSegment(
                    sessionID: sessionID,
                    liveSession: liveSession,
                    status: status,
                    snapshot: snapshot,
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

    /// Shows the saved row at once as normal text, then hands the segment to the decision queue,
    /// which never holds back ASR or later rows.
    private func publishLiveSegment(
        sessionID: UUID,
        liveSession: LiveASRSession,
        status: LiveASRSegmentStatus,
        snapshot: LiveASRSnapshot,
        onStatus: StatusHandler?,
        onUpdate: UpdateHandler?
    ) async {
        guard liveASRSessions[sessionID] === liveSession else { return }
        await onUpdate?(snapshot.progress.materializedSegments, .running)
        guard let enrichment = liveContentPrioritySessions[sessionID] else { return }
        do {
            switch status.outcome {
            case .recognized(let source, _):
                try await enrichment.enqueue(
                    source: source,
                    snapshot: snapshot,
                    onStatus: { text in await onStatus?(text) },
                    onUpdate: { [weak self] _ in
                        await self?.publishLiveRows(
                            sessionID: sessionID, liveSession: liveSession, onUpdate: onUpdate
                        )
                    }
                )
            case .failed, .pending:
                try await enrichment.observe(snapshot: snapshot)
            }
        } catch {
            await enrichment.stop()
            let message = "ライブの発話文判定に失敗しました: \(error.localizedDescription)"
            await onStatus?(message)
            await onUpdate?(snapshot.progress.materializedSegments, .partialFailure(message))
        }
    }

    private func publishLiveRows(
        sessionID: UUID,
        liveSession: LiveASRSession,
        onUpdate: UpdateHandler?
    ) async {
        guard liveASRSessions[sessionID] === liveSession, let onUpdate else { return }
        let snapshot = await liveSession.snapshot()
        guard liveASRSessions[sessionID] === liveSession else { return }
        await onUpdate(snapshot.progress.materializedSegments, .running)
    }

    /// Cancels live decision work. Results already saved stay durable; later responses are dropped.
    /// Returns the pending targets the live session recorded.
    private func stopLiveContentPriority(sessionID: UUID) async -> Set<DecisionPendingTarget> {
        if let enrichment = liveContentPrioritySessions.removeValue(forKey: sessionID) {
            await enrichment.stop()
            let pending = await enrichment.pendingTargets()
            retiredLivePendingTargets[sessionID, default: []].formUnion(pending)
        }
        return retiredLivePendingTargets[sessionID] ?? []
    }

    public func cancelLiveTranscription(sessionID: UUID) async {
        liveASRSessions[sessionID] = nil
        let pending = await stopLiveContentPriority(sessionID: sessionID)
        if case .selectedEngine(_, let usageCounter) = contentPriority {
            await usageCounter.clearDeferred(sessionID: sessionID, targets: pending)
        }
        retiredLivePendingTargets[sessionID] = nil
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
            // ASR has drained: the last segment no longer waits for a successor.
            if let enrichment = liveContentPrioritySessions[sessionID] {
                do {
                    try await enrichment.finishInput(snapshot: await liveSession.snapshot())
                } catch {
                    await onStatus("ライブの発話文判定を終了できませんでした: \(error.localizedDescription)")
                }
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
            audio: .live(checkpoint)
        )
    }

    /// Rebuilds every run from the session's stored audio and publishes the
    /// new run set only after all stages have completed. An import first has its
    /// canonical timeline rebuilt from the original file.
    @discardableResult
    public func processSession(
        sessionID: UUID,
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
            audio: .stored
        )
    }

    /// An import is read only through the timeline built for this run, which finalization removes.
    private static func openAudio(
        _ source: SessionAudioSource,
        layout: SessionLayout,
        onStatus: StatusHandler
    ) async throws -> any TimelineAudioReading {
        guard case .importedOriginal(let originalURL, _) = source else {
            return try SessionAudioReaders.open(source, layout: layout)
        }
        await onStatus(UserFacingStatus.convertingTimeline.text)
        let checkpoint = try await AudioFileTimelineBuilder()
            .build(from: originalURL, into: layout.processingDirectory, sessionURL: layout.sessionURL)
        let reader = try ProcessingTimelineReader(directory: layout.processingDirectory, checkpoint: checkpoint, sessionURL: layout.sessionURL)
        try reader.validateAudio()
        try SessionAudioStorageStore(layout: layout).save(.importedOriginal(reader.info))
        return reader
    }

    /// Requests the pending decision results of the published snapshot again and publishes the new
    /// snapshot in one metadata write. ASR and audio are not processed again.
    public func retryContentPrioritySession(
        sessionID: UUID,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference],
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async {
        var retainedSegments: [MaterializedTranscriptSegment]?
        do {
            guard Set(boundarySegments).count == boundarySegments.count,
                  Set(clauses).count == clauses.count else {
                throw NativeSessionProcessorError.duplicateDecisionRetryTarget
            }

            let sessionLayout = try layout(for: sessionID)
            let metadataStore = ProcessingMetadataStore(sessionURL: sessionLayout.sessionURL)
            guard let metadata = try metadataStore.load(), let activeRuns = metadata.activeRuns else {
                throw NativeSessionProcessorError.transcriptNotPublished
            }
            let lines = try loadTranscriptLines(sessionLayout: sessionLayout)
            _ = try DecisionRetryAnalyzer().retryTargets(lines: lines, metadata: metadata)
            let events = try EventLogTranscriptReader().events(lines: lines, activeRuns: activeRuns)
            let materializer = TranscriptMaterializer(sampleRate: CanonicalAudio.sampleRate)
            let rebuildSnapshot = try DecisionRetryAnalyzer().hasUnpublishedDecisionRun(lines: lines, activeRuns: activeRuns)
            guard !boundarySegments.isEmpty || !clauses.isEmpty || rebuildSnapshot else { return }
            guard case .selectedEngine(let factory, let usageCounter) = contentPriority else {
                await onStatus(UserFacingStatus.decisionDeferred.text)
                return
            }
            let decisions: DecisionCoordinator
            do {
                guard let available = try factory() else {
                    await onStatus(UserFacingStatus.decisionDeferred.text)
                    return
                }
                decisions = available
            } catch DecisionAvailabilityError.stopped {
                await onStatus("\(UserFacingStatus.decisionDeferred.text)。\(DecisionPendingMessage.stopped)")
                return
            } catch {
                await onStatus("\(UserFacingStatus.decisionDeferred.text)。判定エンジンを初期化できませんでした: \(error.localizedDescription)")
                return
            }
            let publishedSegments = try materializer.materialize(events: events, activeRuns: activeRuns)
            retainedSegments = publishedSegments
            await onStatus("保留中の判定を再試行しています（境界 \(boundarySegments.count)区間・優先度 \(clauses.count)節）")
            await onUpdate(publishedSegments, .running)
            let suffix = UUID().uuidString.lowercased()
            let scope = DecisionEnrichmentScope.retry(boundarySegments: Set(boundarySegments), clauses: Set(clauses))
            let boundaryRunID: String
            if boundarySegments.isEmpty, !rebuildSnapshot, let published = activeRuns.clauseBoundary {
                boundaryRunID = published
            } else {
                boundaryRunID = "boundary_retry_\(suffix)"
            }
            let coordinator = DecisionEnrichmentCoordinator(
                sessionID: sessionID,
                boundaryRunID: boundaryRunID,
                priorityRunID: "priority_retry_\(suffix)",
                writer: try SessionWriter(sessionURL: sessionLayout.sessionURL),
                decisions: decisions,
                usageCounter: usageCounter,
                materializer: materializer
            )
            let result = try await coordinator.process(
                existingEvents: events,
                activeRuns: activeRuns,
                scope: scope,
                reusableDecisions: [:],
                onEvent: nil
            )
            try metadataStore.publishDecisionSnapshot(
                basedOn: activeRuns,
                clauseBoundaryRunID: result.boundaryRunID,
                contentPriorityRunID: result.priorityRunID,
                pendingClauseBoundarySegments: result.pendingBoundarySegments,
                pendingContentPriorityClauses: result.pendingPriorityClauses
            )
            await coordinator.recordPublished(result, replacing: metadata.pendingDecisionTargets)

            await onUpdate(result.materializedSegments, .complete)
            if result.pendingTargets.isEmpty {
                await onStatus("保留中の判定を更新しました")
            } else {
                await onStatus(result.stopReason.pendingStatus.text)
            }
        } catch {
            let message = "発話文の判定を再試行できませんでした: \(error.localizedDescription)"
            if let retainedSegments {
                await onUpdate(retainedSegments, .partialFailure(message))
            }
            await onStatus(message)
        }
    }

    // MARK: - Finalization

    /// Runs one finalization attempt, then converges the session's audio storage: a completed
    /// recording is compacted to FLAC, and the attempt's transient audio is removed on every
    /// outcome. A failure of either step is reported in the result.
    private func finalize(
        sessionID: UUID,
        provisional: [MaterializedTranscriptSegment],
        metadataPolicy: UnreadableMetadataPolicy,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping PauseCheck,
        onPhase: @escaping PhaseHandler,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler,
        audio: FinalizationAudio
    ) async -> SessionProcessingResult {
        let sessionLayout: SessionLayout
        let manifest: SessionManifest
        do {
            sessionLayout = try layout(for: sessionID)
            manifest = try sessionLayout.loadManifest()
        } catch {
            liveASRSessions[sessionID] = nil
            _ = await stopLiveContentPriority(sessionID: sessionID)
            return await startFailure(error, provisional: provisional, onPhase: onPhase, onStatus: onStatus, onUpdate: onUpdate)
        }
        // Freeze the durable live decisions first, then cancel the live queue: whatever it saves
        // afterwards is neither reused nor shown. Finalization never waits for live requests.
        let liveDecisions: Result<[ExactClauseTextKey: ReusableClauseDecision], Error>
        if case .selectedEngine = contentPriority {
            liveDecisions = Result {
                try EventLogTranscriptReader().liveContentPriorityDecisions(
                    from: try SessionWriter.readDurableLog(eventsURL: sessionLayout.eventsURL)
                )
            }
        } else {
            liveDecisions = .success([:])
        }
        liveASRSessions[sessionID] = nil
        let livePendingTargets = await stopLiveContentPriority(sessionID: sessionID)
        let source: SessionAudioSource
        switch audio {
        case .live(let checkpoint):
            source = .recordedPCM(checkpoint)
        case .stored:
            do {
                guard let stored = try sessionLayout.audioSource(for: manifest) else {
                    throw NativeSessionProcessorError.storedAudioMissing
                }
                source = stored
            } catch {
                let failed = await startFailure(
                    error, provisional: provisional, onPhase: onPhase, onStatus: onStatus, onUpdate: onUpdate
                )
                return await closeStorage(
                    failed, layout: sessionLayout, manifest: manifest, compactsRecording: false, onStatus: onStatus
                )
            }
        }
        let attemptID = "finalize_\(UUID().uuidString.lowercased())"
        let previous: ProcessingMetadata?
        do {
            previous = try ProcessingMetadataStore(sessionURL: sessionLayout.sessionURL)
                .beginFinalization(attemptID: attemptID, policy: metadataPolicy)
        } catch {
            let failed = await startFailure(
                error, provisional: provisional, onPhase: onPhase, onStatus: onStatus, onUpdate: onUpdate
            )
            return await closeStorage(
                failed, layout: sessionLayout, manifest: manifest, compactsRecording: false, onStatus: onStatus
            )
        }
        let result = await runAttempt(
            sessionID: sessionID,
            sessionLayout: sessionLayout,
            attemptID: attemptID,
            previous: previous,
            liveDecisions: liveDecisions,
            livePendingTargets: livePendingTargets,
            provisional: provisional,
            pacingMode: pacingMode,
            shouldPause: shouldPause,
            onPhase: onPhase,
            onStatus: onStatus,
            onUpdate: onUpdate,
            source: source
        )
        let compactsRecording: Bool
        if case .recordedPCM = source {
            compactsRecording = true
        } else {
            compactsRecording = false
        }
        return await closeStorage(
            result, layout: sessionLayout, manifest: manifest, compactsRecording: compactsRecording, onStatus: onStatus
        )
    }

    private func startFailure(
        _ error: Error,
        provisional: [MaterializedTranscriptSegment],
        onPhase: PhaseHandler,
        onStatus: StatusHandler,
        onUpdate: UpdateHandler
    ) async -> SessionProcessingResult {
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

    private func closeStorage(
        _ attempt: SessionProcessingResult,
        layout: SessionLayout,
        manifest: SessionManifest,
        compactsRecording: Bool,
        onStatus: StatusHandler
    ) async -> SessionProcessingResult {
        var result = attempt
        if result.disposition == .completed, compactsRecording {
            do {
                _ = try await Task.detached {
                    try RecordingAudioCompactor(interrupt: nil).compact(layout: layout)
                }.value
            } catch {
                let message = "文字起こしは保存しましたが、録音を FLAC にできませんでした: \(error.localizedDescription)"
                await onStatus(message)
                result = .failed(message: message, metrics: result.metrics, retained: .finalized)
            }
        }
        do {
            try SessionTransientAudio.remove(layout: layout, source: manifest.source)
        } catch {
            let cleanup = "音声の一時ファイルを削除できませんでした: \(error.localizedDescription)"
            let message: String
            switch result.disposition {
            case .completed:
                message = "文字起こしは保存しましたが、\(cleanup)"
                result = .failed(message: message, metrics: result.metrics, retained: .finalized)
            case .failed:
                guard let runMessage = result.message else {
                    preconditionFailure("a failed result always has a message")
                }
                message = "\(runMessage)。\(cleanup)"
                result = .failed(message: message, metrics: result.metrics, retained: result.retainedTranscript)
            case .paused:
                message = cleanup
            }
            await onStatus(message)
        }
        return result
    }

    private func runAttempt(
        sessionID: UUID,
        sessionLayout: SessionLayout,
        attemptID: String,
        previous: ProcessingMetadata?,
        liveDecisions: Result<[ExactClauseTextKey: ReusableClauseDecision], Error>,
        livePendingTargets: Set<DecisionPendingTarget>,
        provisional: [MaterializedTranscriptSegment],
        pacingMode: ASRPacingMode,
        shouldPause: @escaping PauseCheck,
        onPhase: @escaping PhaseHandler,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler,
        source: SessionAudioSource
    ) async -> SessionProcessingResult {
        let metadataStore = ProcessingMetadataStore(sessionURL: sessionLayout.sessionURL)

        await onPhase(.preparing)
        let outcome: FinalTranscriptPipelineOutcome
        let audio: any TimelineAudioReading
        do {
            audio = try await Self.openAudio(source, layout: sessionLayout, onStatus: onStatus)
            outcome = try await FinalTranscriptPipeline(
                sessionID: sessionID,
                sessionURL: sessionLayout.sessionURL,
                audio: audio,
                asr: asr,
                diarization: diarization,
                vadSegmenter: finalTranscriptVAD
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
            let pendingSources = final.materializedSegments.filter(\.hasRecognizedText).map(\.source)
            do {
                try metadataStore.completeFinalization(
                    attemptID: attemptID,
                    activeRuns: final.activeRuns,
                    pendingClauseBoundarySegments: pendingSources
                )
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
            let localPending = Set(pendingSources.map(DecisionPendingTarget.boundary))
            if case .selectedEngine(_, let usageCounter) = contentPriority {
                await usageCounter.clearDeferred(
                    sessionID: sessionID,
                    targets: livePendingTargets.union(previous?.pendingDecisionTargets ?? [])
                )
                await usageCounter.recordDeferred(sessionID: sessionID, targets: localPending)
            }
            retiredLivePendingTargets[sessionID] = nil
            await onUpdate(final.materializedSegments, .running)
            do {
                try await publishDecisionSnapshot(
                    final,
                    sessionID: sessionID,
                    sessionLayout: sessionLayout,
                    localPending: localPending,
                    liveDecisions: liveDecisions,
                    onPhase: onPhase,
                    onStatus: onStatus,
                    onUpdate: onUpdate
                )
            } catch {
                let message = "境界と優先度の判定を完了できませんでした: \(error.localizedDescription)"
                await onUpdate(final.materializedSegments, .partialFailure(message))
                await onPhase(.complete)
                await onStatus(message)
                return .failed(message: message, metrics: final.metrics, retained: .finalized)
            }
            return .completed(metrics: final.metrics, noSpeech: final.completedCount == 0)
        }
    }

    /// After the local runs are published, runs the optional decision stages and publishes their
    /// snapshot in one metadata write. Without a selected engine, or when saving fails, the local transcript
    /// stays published with every boundary pending.
    private func publishDecisionSnapshot(
        _ final: FinalTranscriptPipelineResult,
        sessionID: UUID,
        sessionLayout: SessionLayout,
        localPending: Set<DecisionPendingTarget>,
        liveDecisions: Result<[ExactClauseTextKey: ReusableClauseDecision], Error>,
        onPhase: PhaseHandler,
        onStatus: @escaping StatusHandler,
        onUpdate: UpdateHandler
    ) async throws {
        let localStatus = "文字起こしと話者分離が完了しました（\(final.completedCount)区間）"
        func complete(_ segments: [MaterializedTranscriptSegment], status: String) async {
            await onUpdate(segments, .complete)
            await onPhase(.complete)
            await onStatus(status)
        }
        guard final.completedCount > 0, !localPending.isEmpty else {
            await complete(final.materializedSegments, status: final.completedCount == 0 ? "発話区間は検出されませんでした" : localStatus)
            return
        }
        guard case .selectedEngine(let factory, let usageCounter) = contentPriority else {
            await complete(final.materializedSegments, status: localStatus)
            return
        }
        let reusable: [ExactClauseTextKey: ReusableClauseDecision]
        switch liveDecisions {
        case .success(let decisions):
            reusable = decisions
        case .failure(let error):
            throw error
        }
        let decisions: DecisionCoordinator?
        do {
            decisions = try factory()
        } catch DecisionAvailabilityError.stopped {
            await complete(final.materializedSegments, status: "\(UserFacingStatus.decisionDeferred.text)。\(DecisionPendingMessage.stopped)")
            return
        } catch {
            await complete(final.materializedSegments, status: "\(UserFacingStatus.decisionDeferred.text)。判定エンジンを初期化できませんでした: \(error.localizedDescription)")
            return
        }
        guard let decisions else {
            await complete(final.materializedSegments, status: UserFacingStatus.decisionDeferred.text)
            return
        }

        await onStatus(UserFacingStatus.classifyingContent.text)
        let suffix = UUID().uuidString.lowercased()
        let coordinator = DecisionEnrichmentCoordinator(
            sessionID: sessionID,
            boundaryRunID: "boundary_\(suffix)",
            priorityRunID: "priority_\(suffix)",
            writer: try SessionWriter(sessionURL: sessionLayout.sessionURL),
            decisions: decisions,
            usageCounter: usageCounter,
            materializer: TranscriptMaterializer(sampleRate: CanonicalAudio.sampleRate)
        )
        let result = try await coordinator.process(
            existingEvents: try loadTranscriptEvents(sessionLayout: sessionLayout, activeRuns: final.activeRuns, metadata: nil),
            activeRuns: final.activeRuns,
            scope: .all,
            reusableDecisions: reusable,
            onEvent: nil
        )
        try ProcessingMetadataStore(sessionURL: sessionLayout.sessionURL).publishDecisionSnapshot(
            basedOn: final.activeRuns,
            clauseBoundaryRunID: result.boundaryRunID,
            contentPriorityRunID: result.priorityRunID,
            pendingClauseBoundarySegments: result.pendingBoundarySegments,
            pendingContentPriorityClauses: result.pendingPriorityClauses
        )
        await coordinator.recordPublished(result, replacing: localPending)
        await complete(
            result.materializedSegments,
            status: result.pendingTargets.isEmpty ? localStatus : result.stopReason.pendingStatus.text
        )
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
            let segments = try TranscriptMaterializer(sampleRate: CanonicalAudio.sampleRate).materialize(
                events: try loadTranscriptEvents(sessionLayout: sessionLayout, activeRuns: activeRuns, metadata: previous),
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

    // MARK: - Session files

    private func loadTranscriptEvents(
        sessionLayout: SessionLayout,
        activeRuns: ActiveRuns,
        metadata: ProcessingMetadata?
    ) throws -> [TranscriptEvent] {
        let lines = try loadTranscriptLines(sessionLayout: sessionLayout)
        if let metadata {
            _ = try DecisionRetryAnalyzer().retryTargets(lines: lines, metadata: metadata)
        }
        return try EventLogTranscriptReader().events(
            lines: lines,
            activeRuns: activeRuns
        )
    }

    private func loadTranscriptLines(sessionLayout: SessionLayout) throws -> [Data] {
        try SessionRecovery.recoverJSONL(
            SessionWriter.readDurableLog(eventsURL: sessionLayout.eventsURL)
        ).lines
    }

    private func layout(for sessionID: UUID) throws -> SessionLayout {
        SessionLayout(sessionURL: try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: sessionsRoot, sessionID: sessionID))
    }
}
