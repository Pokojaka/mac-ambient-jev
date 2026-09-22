import Foundation
import MacAmbientJevCore

enum NativeSessionProcessorError: LocalizedError {
    case invalidRecoveredRun

    var errorDescription: String? {
        switch self {
        case .invalidRecoveredRun:
            "復旧対象の文字起こし run が完了状態ではありません"
        }
    }
}

public actor NativeSessionProcessor {
    public typealias StatusHandler = @Sendable (_ text: String) async -> Void
    public typealias UpdateHandler = @Sendable (
        _ segments: [MaterializedTranscriptSegment],
        _ state: ProcessingState
    ) async -> Void

    private let paths: AppPaths
    private let asr: NativeQwen3ASREngine
    private let diarization: FluidOfflineDiarizationEngine

    public init(paths: AppPaths) {
        self.paths = paths
        self.asr = NativeQwen3ASREngine(
            modelStore: ModelStore(paths: paths)
        )
        self.diarization = FluidOfflineDiarizationEngine(paths: paths)
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
                await onStatus("音声ファイルを処理用タイムラインへ変換しています")
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
                        "文字起こしと話者分離を復旧しました（\(result.completedCount)区間）"
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
                    "完了済みの文字起こしと話者分離を復旧しました（\(materialized.count)区間）"
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
            await onStatus("発話区間を検出しています")
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
            await onStatus("音声認識モデルを準備しています")
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
                    "文字起こしと話者分離が完了しました（\(result.completedCount)区間）"
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
            await onStatus("話者分離を準備しています")
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
            await onStatus("話者を分離しています")
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

        if let onUpdate {
            await onUpdate(result.materializedSegments, .complete)
        }
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