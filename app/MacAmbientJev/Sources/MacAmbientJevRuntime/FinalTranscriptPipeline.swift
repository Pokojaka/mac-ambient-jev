import Foundation
import MacAmbientJevCore
import MacAmbientJevAppleSupport

public protocol FinalTranscriptVADSegmenter: Sendable {
    func segment(
        reader: ProcessingTimelineReader,
        runID: String
    ) async throws -> [SegmentReference]
}

struct FluidFinalTranscriptVADSegmenter: FinalTranscriptVADSegmenter {
    func segment(
        reader: ProcessingTimelineReader,
        runID: String
    ) async throws -> [SegmentReference] {
        let engine = try await FluidVADSegmentationEngine.make(
            segmentationRunID: runID,
            canonicalSampleRate: reader.checkpoint.sampleRate
        )
        return try await FluidVADTimelineProcessor(
            reader: reader,
            engine: engine
        ).segmentAll()
    }
}

struct FinalTranscriptPipelineResult: Sendable {
    let activeRuns: ActiveRuns
    let materializedSegments: [MaterializedTranscriptSegment]
    let completedCount: Int
    let metrics: ASRBatchMetrics
}

enum FinalTranscriptPipelineError: LocalizedError {
    case asrFailed(failedCount: Int, disposition: BatchDisposition, reason: String?)
    case missingSuccessfulStage(ProcessingStage, String)
    case invalidVADRange(String)

    var errorDescription: String? {
        switch self {
        case let .asrFailed(failedCount, disposition, reason):
            if disposition == .paused {
                return "熱状態のため確定文字起こしを完了できませんでした"
            }
            let detail = reason.map { "（\($0)）" } ?? ""
            return "確定文字起こしで\(failedCount)区間失敗しました\(detail)"
        case let .missingSuccessfulStage(stage, runID):
            return "\(stage.rawValue) run \(runID) の成功イベントを確認できません"
        case let .invalidVADRange(segmentID):
            return "VAD 区間 \(segmentID) の範囲が不正です"
        }
    }
}

struct FinalTranscriptPipeline: Sendable {
    let sessionID: UUID
    let sessionURL: URL
    let processingDirectory: URL
    let checkpoint: AudioCheckpoint
    let asr: any ASREngine
    let diarization: any DiarizationEngine
    let vadSegmenter: any FinalTranscriptVADSegmenter
    let proximityEvidenceProvider: any ProximityEvidenceProvider

    func process(
        onStatus: NativeSessionProcessor.StatusHandler?,
        onPhase: @escaping @Sendable (RunPhase) async -> Void = { _ in }
    ) async throws -> FinalTranscriptPipelineResult {
        let reader = ProcessingTimelineReader(
            directory: processingDirectory,
            checkpoint: checkpoint
        )
        let materializer = TranscriptMaterializer(sampleRate: checkpoint.sampleRate)
        let writer = try SessionWriter(sessionURL: sessionURL)
        let segmentationRunID = "seg_final_\(UUID().uuidString.lowercased())"
        let asrRunID = "asr_final_\(UUID().uuidString.lowercased())"
        let diarizationRunID = "diar_final_\(UUID().uuidString.lowercased())"
        let sceneRunID = "scene_final_\(UUID().uuidString.lowercased())"
        let scopeRunID = "scope_final_\(UUID().uuidString.lowercased())"

        if let onStatus { await onStatus(UserFacingStatus.detectingSpeech.text) }
        let vadSegments = try await vadSegmenter.segment(reader: reader, runID: segmentationRunID)
        try validateVADSegments(vadSegments, runID: segmentationRunID)

        let derivedDirectory = sessionURL
            .appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "derived", directoryHint: .isDirectory)
        let diarizationInputURL = derivedDirectory.appending(path: "diarization-input.caf")
        try ProcessingTimelineAudioExporter(
            framesPerBuffer: max(1, Int64(checkpoint.sampleRate.rounded()))
        ).export(reader: reader, to: diarizationInputURL)

        if let onStatus { await onStatus(UserFacingStatus.preparingDiarization.text) }
        let diarizationCoordinator = DiarizationCoordinator(
            sessionID: sessionID,
            runID: diarizationRunID,
            writer: writer,
            engine: diarization,
            materializer: materializer
        )
        if let onStatus { await onStatus(UserFacingStatus.diarizing.text) }
        let diarizationResult = try await diarizationCoordinator.process(
            fileURL: diarizationInputURL,
            canonicalSampleRate: checkpoint.sampleRate,
            existingEvents: [],
            activeRuns: ActiveRuns(
                segmentation: segmentationRunID,
                asr: asrRunID,
                diarization: diarizationRunID
            )
        )

        if let onStatus { await onStatus(UserFacingStatus.preparingASR.text) }
        let state = SessionProcessingState(captureState: .stopped)
        let asrSegments = try SpeakerTurnSegmenter.split(
            vadSegments,
            speakerSpans: diarizationResult.speakerSpans,
            sampleRate: checkpoint.sampleRate
        )
        try validateVADSegments(asrSegments, runID: segmentationRunID)
        var transcriptEvents = diarizationResult.events
        for segment in asrSegments {
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
        _ = try await writer.append(EventDraft(
            eventType: "processing.run.completed",
            sessionID: sessionID,
            processingRunID: segmentationRunID,
            payload: ProcessingRunCompletedPayload(
                stage: .segmentation,
                succeeded: true,
                completedCount: asrSegments.count,
                failedCount: 0
            )
        ))
        let asrCoordinator = PipelineCoordinator(
            sessionID: sessionID,
            segmentationRunID: segmentationRunID,
            asrRunID: asrRunID,
            writer: writer,
            asr: asr,
            loader: ASRAudioLoader(reader: reader),
            materializer: materializer,
            state: state
        )
        let asrResult = await asrCoordinator.resumePendingASR(
            segments: asrSegments,
            existingEvents: transcriptEvents
        )
        guard asrResult.disposition == .completed else {
            throw FinalTranscriptPipelineError.asrFailed(
                failedCount: asrResult.failedCount,
                disposition: asrResult.disposition,
                reason: try failureReason(forRunID: asrRunID)
            )
        }
        transcriptEvents = asrResult.events

        if let onStatus { await onStatus(UserFacingStatus.analyzingScene.text) }
        await onPhase(.postprocessing)
        let sceneCoordinator = SceneCoordinator(
            sessionID: sessionID,
            runID: sceneRunID,
            writer: writer,
            materializer: materializer
        )
        let sceneResult = try await sceneCoordinator.process(
            speakerSpans: diarizationResult.speakerSpans,
            totalFrames: checkpoint.committedFrames,
            sampleRate: checkpoint.sampleRate,
            existingEvents: transcriptEvents,
            activeRuns: ActiveRuns(
                segmentation: segmentationRunID,
                asr: asrRunID,
                diarization: diarizationRunID,
                scene: sceneRunID
            )
        )

        if let onStatus { await onStatus(UserFacingStatus.analyzingScope.text) }
        let scopeCoordinator = ScopeCoordinator(
            sessionID: sessionID,
            runID: scopeRunID,
            writer: writer,
            provider: proximityEvidenceProvider,
            materializer: materializer
        )
        let activeRuns = ActiveRuns(
            segmentation: segmentationRunID,
            asr: asrRunID,
            diarization: diarizationRunID,
            scene: sceneRunID,
            scope: scopeRunID
        )
        let scopeResult = try await scopeCoordinator.process(
            existingEvents: sceneResult.events,
            speakerSpans: diarizationResult.speakerSpans,
            activeRuns: activeRuns
        )

        try validateSuccessfulStages(
            sessionURL: sessionURL,
            expected: [
                (.segmentation, segmentationRunID),
                (.diarization, diarizationRunID),
                (.asr, asrRunID),
                (.scene, sceneRunID),
                (.scope, scopeRunID)
            ]
        )

        return FinalTranscriptPipelineResult(
            activeRuns: activeRuns,
            materializedSegments: materializer.materialize(
                events: scopeResult.events,
                activeRuns: activeRuns
            ),
            completedCount: asrResult.completedCount,
            metrics: asrResult.metrics
        )
    }

    private func validateVADSegments(
        _ segments: [SegmentReference],
        runID: String
    ) throws {
        var ids = Set<String>()
        for segment in segments {
            guard segment.segmentationRunID == runID,
                  segment.segmentID.isEmpty == false,
                  ids.insert(segment.segmentID).inserted,
                  segment.startFrame >= 0,
                  segment.startFrame < segment.endFrame,
                  segment.endFrame <= checkpoint.committedFrames else {
                throw FinalTranscriptPipelineError.invalidVADRange(segment.segmentID)
            }
        }
    }

    private func validateSuccessfulStages(
        sessionURL: URL,
        expected: [(ProcessingStage, String)]
    ) throws {
        let eventData = try Data(contentsOf: sessionURL.appending(path: "events.jsonl"))
        let recovered = try SessionRecovery.recoverJSONL(eventData)
        let stages = try recovered.lines.compactMap { line -> (String, String, Bool)? in
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["event_type"] as? String == "processing.run.completed",
                  let runID = object["processing_run_id"] as? String,
                  let payload = object["payload"] as? [String: Any],
                  let stage = payload["stage"] as? String,
                  let succeeded = payload["succeeded"] as? Bool else {
                return nil
            }
            return (runID, stage, succeeded)
        }
        for (stage, runID) in expected {
            guard stages.contains(where: {
                $0.0 == runID && $0.1 == stage.rawValue && $0.2
            }) else {
                throw FinalTranscriptPipelineError.missingSuccessfulStage(stage, runID)
            }
        }
    }

    private func failureReason(forRunID runID: String) throws -> String? {
        let eventData = try Data(contentsOf: sessionURL.appending(path: "events.jsonl"))
        let recovered = try SessionRecovery.recoverJSONL(eventData)
        for line in recovered.lines.reversed() {
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["event_type"] as? String == "asr.failed",
                  object["processing_run_id"] as? String == runID,
                  let payload = object["payload"] as? [String: Any],
                  let message = payload["message"] as? String else {
                continue
            }
            return message
        }
        return nil
    }
}
