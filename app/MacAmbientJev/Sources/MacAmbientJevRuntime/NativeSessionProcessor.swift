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

public actor NativeSessionProcessor {
    public typealias StatusHandler = @Sendable (_ text: String) async -> Void
    public typealias UpdateHandler = @Sendable (
        _ segments: [MaterializedTranscriptSegment],
        _ state: ProcessingState
    ) async -> Void

    private static let jevAPIKeyAccount = "jev-api-key"

    private let paths: AppPaths
    private let asr: NativeQwen3ASREngine
    private let diarization: FluidOfflineDiarizationEngine
    private let allowExternalJev: Bool
    public let jevUsageCounter: JevUsageCounter
    private var liveASRSessions: [UUID: LiveASRSession] = [:]

    public init(
        paths: AppPaths,
        allowExternalJev: Bool = false,
        jevUsageCounter: JevUsageCounter = JevUsageCounter()
    ) {
        self.paths = paths
        self.asr = NativeQwen3ASREngine(
            modelStore: ModelStore(paths: paths)
        )
        self.diarization = FluidOfflineDiarizationEngine(paths: paths)
        self.allowExternalJev = allowExternalJev
        self.jevUsageCounter = jevUsageCounter
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
            writer: SessionWriter(sessionURL: sessionURL(for: sessionID)),
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

        do {
            if !finalSegments.isEmpty {
                _ = try await processLiveSegments(
                    sessionID: sessionID,
                    segments: finalSegments,
                    checkpoint: checkpoint,
                    onStatus: onStatus,
                    onUpdate: onUpdate
                )
            }

            let completion = try await liveSession.finish()
            liveASRSessions[sessionID] = nil

            guard completion.succeeded else {
                if let onUpdate {
                    await onUpdate(
                        completion.materializedSegments,
                        .partialFailure("一部の発話を録音中に文字起こしできませんでした")
                    )
                }
                return .fallbackRequired(
                    "録音中の文字起こしを完了できませんでした（失敗 \(completion.failedCount)区間、未処理 \(completion.pendingCount)区間）"
                )
            }

            try selectSuccessfulRuns(
                sessionID: sessionID,
                segmentationRunID: liveSession.segmentationRunID,
                asrRunID: liveSession.asrRunID
            )

            if completion.completedCount == 0 {
                if let onStatus {
                    await onStatus("発話区間は検出されませんでした")
                }
                if let onUpdate {
                    await onUpdate([], .complete)
                }
                return .noSpeech
            }

            do {
                try await runOfflineDiarization(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    existingEvents: completion.events,
                    segmentationRunID: liveSession.segmentationRunID,
                    asrRunID: liveSession.asrRunID,
                    onStatus: onStatus,
                    onUpdate: onUpdate
                )
                return .completed
            } catch {
                if let onStatus {
                    await onStatus(
                        "文字起こしは保存しましたが、後処理に失敗しました: \(error.localizedDescription)"
                    )
                }
                if let onUpdate {
                    await onUpdate(
                        completion.materializedSegments,
                        .partialFailure(error.localizedDescription)
                    )
                }
                return .postProcessingFailed(error.localizedDescription)
            }
        } catch {
            liveASRSessions[sessionID] = nil
            if let onStatus {
                await onStatus(
                    "録音中の文字起こしを完了できませんでした: \(error.localizedDescription)"
                )
            }
            return .fallbackRequired(error.localizedDescription)
        }
    }

    public func cancelLiveTranscription(sessionID: UUID) async {
        liveASRSessions[sessionID] = nil
    }

    public func processImportedSession(
        sessionID: UUID,
        originalURL: URL,
        onStatus: StatusHandler? = nil,
        onUpdate: UpdateHandler? = nil
    ) async {
        let processingDirectory = processingDirectory(for: sessionID)

        do {
            if let onStatus {
                await onStatus(UserFacingStatus.convertingTimeline.text)
            }

            let checkpoint = try await AudioFileTimelineBuilder()
                .build(from: originalURL, into: processingDirectory)

            try await processTimeline(
                sessionID: sessionID,
                checkpoint: checkpoint,
                processingDirectory: processingDirectory,
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
        }
    }

    public func processTimelineSession(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        onStatus: StatusHandler? = nil,
        onUpdate: UpdateHandler? = nil
    ) async {
        do {
            try await processTimeline(
                sessionID: sessionID,
                checkpoint: checkpoint,
                processingDirectory: processingDirectory(for: sessionID),
                onStatus: onStatus,
                onUpdate: onUpdate
            )
        } catch {
            await reportFailure(
                prefix: "録音を処理できませんでした",
                error: error,
                onStatus: onStatus,
                onUpdate: onUpdate
            )
        }
    }

    public func resumePendingASRSession(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        plan: ASRRecoveryPlan,
        onStatus: StatusHandler? = nil,
        onUpdate: UpdateHandler? = nil
    ) async {
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
                state: state
            )

            let result = await coordinator.resumePendingASR(
                segments: plan.pendingSegments,
                existingEvents: plan.transcriptEvents
            ) { materialized, processingState in
                if let onUpdate {
                    await onUpdate(materialized, processingState)
                }
            }

            if result.failedCount == 0 {
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
            }

            if let onStatus {
                if result.failedCount == 0 {
                    await onStatus(
                        "文字起こし、話者分離、場面判定、音響範囲整理を復旧しました（\(result.completedCount)区間）"
                    )
                } else {
                    await onStatus(
                        "文字起こしの復旧中に\(result.failedCount)区間失敗しました"
                    )
                }
            }
        } catch {
            await reportFailure(
                prefix: "文字起こしを復旧できませんでした",
                error: error,
                onStatus: onStatus,
                onUpdate: onUpdate
            )
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
        onStatus: StatusHandler?,
        onUpdate: UpdateHandler?
    ) async throws {
        guard checkpoint.committedFrames > 0 else {
            if let onStatus {
                await onStatus("処理できる音声がありません")
            }
            if let onUpdate {
                await onUpdate([], .complete)
            }
            return
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
            await state.setProcessing(.complete)
            if let onStatus {
                await onStatus("発話区間は検出されませんでした")
            }
            if let onUpdate {
                await onUpdate([], .complete)
            }
            return
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
            state: state
        )

        let result = await coordinator.process(
            segments: segments
        ) { materialized, processingState in
            if let onUpdate {
                await onUpdate(materialized, processingState)
            }
        }

        if result.failedCount == 0 {
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
        }

        if let onStatus {
            if result.failedCount == 0 {
                await onStatus(
                    "文字起こし、話者分離、場面判定、音響範囲整理が完了しました（\(result.completedCount)区間）"
                )
            } else {
                await onStatus(
                    "文字起こしが完了しました（成功 \(result.completedCount)区間、失敗 \(result.failedCount)区間）"
                )
            }
        }
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
            provider: UnknownProximityEvidenceProvider(),
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

        let finalSegments = try await runJevEnrichmentIfAvailable(
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
            await onUpdate(finalSegments, .complete)
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
    ) async throws -> [MaterializedTranscriptSegment] {
        guard let decisions = try makeJevDecisionCoordinatorIfAvailable() else {
            return fallbackSegments
        }

        if let onStatus {
            await onStatus(UserFacingStatus.classifyingWithJev.text)
        }

        let runID = "priority_\(UUID().uuidString.lowercased())"
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
        let result = try await coordinator.process(
            existingEvents: existingEvents,
            activeRuns: activeRuns
        )

        try selectContentPriorityRun(
            sessionID: sessionID,
            runID: runID
        )

        if !result.retryPendingSegmentIDs.isEmpty,
           let onStatus {
            await onStatus(UserFacingStatus.jevDeferred.text)
        }

        return result.materializedSegments
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
        runID: String
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
        try store.save(metadata.withActiveRuns(activeRuns))
    }

    private func persistProcessingMetadata(sessionID: UUID) throws {
        let store = ProcessingMetadataStore(
            sessionURL: sessionURL(for: sessionID)
        )
        let existingActiveRuns = try store.load()?.activeRuns

        let metadata = ProcessingMetadata(
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
            activeRuns: existingActiveRuns
        )

        try store.save(metadata)
    }

    private func sessionURL(for sessionID: UUID) -> URL {
        paths.sessionsRoot.appending(
            path: sessionID.uuidString,
            directoryHint: .isDirectory
        )
    }

    private func processingDirectory(for sessionID: UUID) -> URL {
        sessionURL(for: sessionID)
            .appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "processing", directoryHint: .isDirectory)
    }
}