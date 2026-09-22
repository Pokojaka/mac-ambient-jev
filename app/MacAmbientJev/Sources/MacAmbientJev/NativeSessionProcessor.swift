import Foundation
import MacAmbientJevCore

actor NativeSessionProcessor {
    typealias StatusHandler = @Sendable (_ text: String) async -> Void
    typealias UpdateHandler = @Sendable (
        _ segments: [MaterializedTranscriptSegment],
        _ state: ProcessingState
    ) async -> Void

    private let paths: AppPaths
    private let asr: NativeQwen3ASREngine

    init(paths: AppPaths) {
        self.paths = paths
        self.asr = NativeQwen3ASREngine(
            modelStore: ModelStore(paths: paths)
        )
    }

    func processImportedSession(
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
            if let onStatus {
                await onStatus("音声ファイルを処理できませんでした: \(error.localizedDescription)")
            }
            if let onUpdate {
                await onUpdate(
                    [],
                    .partialFailure(error.localizedDescription)
                )
            }
        }
    }

    func processTimelineSession(
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
            if let onStatus {
                await onStatus("録音を処理できませんでした: \(error.localizedDescription)")
            }
            if let onUpdate {
                await onUpdate(
                    [],
                    .partialFailure(error.localizedDescription)
                )
            }
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
        }

        if let onStatus {
            if result.failedCount == 0 {
                await onStatus(
                    "文字起こしが完了しました（\(result.completedCount)区間）"
                )
            } else {
                await onStatus(
                    "文字起こしが完了しました（成功 \(result.completedCount)区間、失敗 \(result.failedCount)区間）"
                )
            }
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
