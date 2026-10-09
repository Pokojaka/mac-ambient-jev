import FluidAudio
import Foundation
import MacAmbientJevCore
import MacAmbientJevAppleSupport

public protocol FinalTranscriptVADSegmenter: Sendable {
    var provenance: RunProvenance { get }
    func segment(
        reader: any TimelineAudioReading,
        runID: String
    ) async throws -> [SegmentReference]
}

struct FluidFinalTranscriptVADSegmenter: FinalTranscriptVADSegmenter {
    static let version = "FluidAudio@0.15.8"

    var provenance: RunProvenance {
        RunProvenance(
            engine: "fluidaudio-silero-vad",
            model: Repo.vad.rawValue,
            version: Self.version,
            configuration: [
                "pre_roll_seconds": String(FluidVADSegmentationEngine.preRollSeconds),
                "max_segment_seconds": String(FluidVADSegmentationEngine.maxSegmentSeconds),
                "min_silence_seconds": String(FluidVADSegmentationEngine.minSilenceSeconds),
                "minimum_segment_seconds": String(FluidVADSegmentationEngine.minimumSegmentSeconds),
            ]
        )
    }

    func segment(
        reader: any TimelineAudioReading,
        runID: String
    ) async throws -> [SegmentReference] {
        let engine = try await FluidVADSegmentationEngine.make(
            segmentationRunID: runID,
            canonicalSampleRate: reader.info.sampleRate,
            measureMicInputLevels: false
        )
        return try await FluidVADTimelineProcessor(engine: engine).segmentAll(reader: reader)
    }
}


struct FinalTranscriptPipelineResult: Sendable {
    let activeRuns: ActiveRuns
    let materializedSegments: [MaterializedTranscriptSegment]
    let completedCount: Int
    let metrics: ASRBatchMetrics
}

enum FinalTranscriptPipelineOutcome: Sendable {
    case completed(FinalTranscriptPipelineResult)
    /// ASR stopped before every segment was transcribed; nothing was published.
    case paused(metrics: ASRBatchMetrics)
}

/// A pipeline failure with the ASR metrics gathered before it (nil when ASR never started).
struct FinalTranscriptPipelineFailure: Error, LocalizedError {
    let message: String
    let metrics: ASRBatchMetrics?

    var errorDescription: String? { message }
}

enum FinalTranscriptPipelineError: LocalizedError {
    case missingRunEvent(eventType: String, stage: ProcessingStage, runID: String)
    case invalidVADRange(String)
    case invalidSpeakerSpan(speakerID: String, startFrame: Int64, endFrame: Int64, totalFrames: Int64)
    case persistedSegmentsMismatch(String)

    var errorDescription: String? {
        switch self {
        case let .missingRunEvent(eventType, stage, runID):
            "\(stage.rawValue) run \(runID) の \(eventType) を確認できません"
        case let .invalidVADRange(segmentID):
            "VAD 区間 \(segmentID) の範囲が不正です"
        case let .invalidSpeakerSpan(speakerID, startFrame, endFrame, totalFrames):
            "話者 \(speakerID) の区間 \(startFrame)〜\(endFrame) が音声の範囲 0〜\(totalFrames) を外れています"
        case let .persistedSegmentsMismatch(runID):
            "segmentation run \(runID) の保存済み区間が一致しません"
        }
    }
}

struct FinalTranscriptPipeline: Sendable {
    let sessionID: UUID
    let sessionURL: URL
    let audio: any TimelineAudioReading
    let asr: any ASREngine
    let diarization: any DiarizationEngine
    let vadSegmenter: any FinalTranscriptVADSegmenter

    /// - Throws: `FinalTranscriptPipelineFailure`.
    func process(
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping @Sendable () async -> Bool,
        onPhase: @escaping @Sendable (RunPhase) async -> Void
    ) async throws -> FinalTranscriptPipelineOutcome {
        var asrMetrics: ASRBatchMetrics?
        do {
            return try await run(
                onStatus: onStatus,
                pacingMode: pacingMode,
                shouldPause: shouldPause,
                onPhase: onPhase,
                asrMetrics: &asrMetrics
            )
        } catch {
            throw FinalTranscriptPipelineFailure(
                message: error.localizedDescription,
                metrics: asrMetrics
            )
        }
    }

    private func run(
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping @Sendable () async -> Bool,
        onPhase: @escaping @Sendable (RunPhase) async -> Void,
        asrMetrics: inout ASRBatchMetrics?
    ) async throws -> FinalTranscriptPipelineOutcome {
        let info = audio.info
        let layout = SessionLayout(sessionURL: sessionURL)
        let materializer = TranscriptMaterializer(sampleRate: info.sampleRate)
        let writer = try SessionWriter(sessionURL: sessionURL)
        let segmentationRunID = "seg_final_\(UUID().uuidString.lowercased())"
        let asrRunID = "asr_final_\(UUID().uuidString.lowercased())"
        let diarizationRunID = "diar_final_\(UUID().uuidString.lowercased())"

        func startRun(_ stage: ProcessingStage, _ runID: String, _ provenance: RunProvenance) async throws {
            try await writer.append(EventDraft(
                eventType: "processing.run.started",
                sessionID: sessionID,
                processingRunID: runID,
                payload: ProcessingRunStartedPayload(stage: stage, provenance: provenance)
            ))
        }

        func completeEmptyRun(_ stage: ProcessingStage, _ runID: String) async throws {
            try await writer.append(EventDraft(
                eventType: "processing.run.completed",
                sessionID: sessionID,
                processingRunID: runID,
                payload: ProcessingRunCompletedPayload(
                    stage: stage,
                    succeeded: true,
                    completedCount: 0,
                    failedCount: 0
                )
            ))
        }

        await onStatus(UserFacingStatus.detectingSpeech.text)
        try await startRun(.segmentation, segmentationRunID, vadSegmenter.provenance)
        let vadSegments = try await vadSegmenter.segment(reader: audio, runID: segmentationRunID)
        try validateVADSegments(vadSegments, runID: segmentationRunID)

        let speakerSpans: [SpeakerSpan]
        var transcriptEvents: [TranscriptEvent]
        if vadSegments.isEmpty {
            try await startRun(.diarization, diarizationRunID, diarization.provenance)
            try await completeEmptyRun(.diarization, diarizationRunID)
            speakerSpans = []
            transcriptEvents = []
        } else {
            let diarizationInputURL = layout.diarizationInputURL
            try ProcessingTimelineAudioExporter(
                framesPerBuffer: max(1, Int64(info.sampleRate.rounded()))
            ).export(reader: audio, to: diarizationInputURL, sessionURL: layout.sessionURL)

            await onStatus(UserFacingStatus.preparingDiarization.text)
            try await startRun(.diarization, diarizationRunID, diarization.provenance)
            let diarizationCoordinator = DiarizationCoordinator(
                sessionID: sessionID,
                runID: diarizationRunID,
                writer: writer,
                engine: diarization,
                materializer: materializer
            )
            await onStatus(UserFacingStatus.diarizing.text)
            let diarizationResult = try await diarizationCoordinator.process(
                fileURL: diarizationInputURL,
                canonicalSampleRate: info.sampleRate,
                existingEvents: [],
                activeRuns: ActiveRuns(
                    segmentation: segmentationRunID,
                    asr: asrRunID,
                    diarization: diarizationRunID
                )
            )
            try validateSpeakerSpans(diarizationResult.speakerSpans)
            speakerSpans = diarizationResult.speakerSpans
            transcriptEvents = diarizationResult.events
        }

        if !vadSegments.isEmpty {
            await onStatus(UserFacingStatus.preparingASR.text)
        }
        let asrSegments = try SpeakerTurnSegmenter.split(
            vadSegments,
            speakerSpans: speakerSpans,
            sampleRate: info.sampleRate
        )
        try validateVADSegments(asrSegments, runID: segmentationRunID)
        try await startRun(.asr, asrRunID, asr.provenance)
        var pendingSince: [String: Date] = [:]
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
            let pending = try await writer.append(EventDraft(
                eventType: "asr.pending",
                sessionID: sessionID,
                processingRunID: asrRunID,
                segmentationRunID: segmentationRunID,
                segmentID: segment.segmentID,
                sourceStartFrame: segment.startFrame,
                sourceEndFrame: segment.endFrame,
                payload: EmptyPayload()
            ))
            pendingSince[segment.segmentID] = pending.createdAt
        }
        try await writer.append(EventDraft(
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
            loader: ASRAudioLoader(reader: audio),
            pacingMode: pacingMode,
            sleep: { try await Task.sleep(for: $0) },
            shouldPause: shouldPause
        )
        await onPhase(.asr)
        let asrResult = try await asrCoordinator.run(
            segments: asrSegments,
            pendingSince: pendingSince,
            existingEvents: transcriptEvents
        )
        asrMetrics = asrResult.metrics
        switch asrResult.disposition {
        case .completed:
            break
        case .paused:
            return .paused(metrics: asrResult.metrics)
        case .failed(let failure):
            throw failure
        }
        transcriptEvents = asrResult.events

        await onPhase(.postprocessing)
        let activeRuns = ActiveRuns(
            segmentation: segmentationRunID,
            asr: asrRunID,
            diarization: diarizationRunID
        )

        try validatePersistedRuns(
            segmentationRunID: segmentationRunID,
            segments: asrSegments,
            expected: [
                (.segmentation, segmentationRunID),
                (.diarization, diarizationRunID),
                (.asr, asrRunID)
            ]
        )

        return .completed(FinalTranscriptPipelineResult(
            activeRuns: activeRuns,
            materializedSegments: try materializer.materialize(
                events: transcriptEvents,
                activeRuns: activeRuns
            ),
            completedCount: asrResult.completedCount,
            metrics: asrResult.metrics
        ))
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
                  segment.endFrame <= audio.info.committedFrames else {
                throw FinalTranscriptPipelineError.invalidVADRange(segment.segmentID)
            }
        }
    }

    private func validateSpeakerSpans(_ spans: [SpeakerSpan]) throws {
        for span in spans {
            guard span.startFrame >= 0,
                  span.startFrame < span.endFrame,
                  span.endFrame <= audio.info.committedFrames else {
                throw FinalTranscriptPipelineError.invalidSpeakerSpan(
                    speakerID: span.speakerID,
                    startFrame: span.startFrame,
                    endFrame: span.endFrame,
                    totalFrames: audio.info.committedFrames
                )
            }
        }
    }

    private func validatePersistedRuns(
        segmentationRunID: String,
        segments: [SegmentReference],
        expected: [(ProcessingStage, String)]
    ) throws {
        let eventData = try SessionFileAccess.read(SessionLayout(sessionURL: sessionURL).eventsURL, relativeTo: sessionURL)
        let recovered = try SessionRecovery.recoverJSONL(eventData)
        let objects = try recovered.lines.compactMap { line in
            try JSONSerialization.jsonObject(with: line) as? [String: Any]
        }
        struct RunEvent {
            let eventType: String
            let runID: String
            let stage: String
            let succeeded: Bool?
            let completedCount: Int?
        }
        let runEvents = objects.compactMap { object -> RunEvent? in
            guard let eventType = object["event_type"] as? String,
                  eventType == "processing.run.started" || eventType == "processing.run.completed",
                  let runID = object["processing_run_id"] as? String,
                  let payload = object["payload"] as? [String: Any],
                  let stage = payload["stage"] as? String else {
                return nil
            }
            return RunEvent(
                eventType: eventType,
                runID: runID,
                stage: stage,
                succeeded: payload["succeeded"] as? Bool,
                completedCount: payload["completed_count"] as? Int
            )
        }
        for (stage, runID) in expected {
            let ofRun = runEvents.filter { $0.runID == runID && $0.stage == stage.rawValue }
            guard ofRun.filter({ $0.eventType == "processing.run.started" }).count == 1 else {
                throw FinalTranscriptPipelineError.missingRunEvent(
                    eventType: "processing.run.started", stage: stage, runID: runID
                )
            }
            guard ofRun.contains(where: { $0.eventType == "processing.run.completed" && $0.succeeded == true }) else {
                throw FinalTranscriptPipelineError.missingRunEvent(
                    eventType: "processing.run.completed", stage: stage, runID: runID
                )
            }
        }
        let persisted = objects.compactMap { object -> SegmentReference? in
            guard object["event_type"] as? String == "segment.created",
                  object["segmentation_run_id"] as? String == segmentationRunID,
                  let segmentID = object["segment_id"] as? String,
                  let startFrame = (object["source_start_frame"] as? NSNumber)?.int64Value,
                  let endFrame = (object["source_end_frame"] as? NSNumber)?.int64Value else {
                return nil
            }
            return SegmentReference(
                segmentationRunID: segmentationRunID,
                segmentID: segmentID,
                startFrame: startFrame,
                endFrame: endFrame
            )
        }
        let completedCounts = runEvents.filter {
            $0.eventType == "processing.run.completed"
                && $0.runID == segmentationRunID
                && $0.succeeded == true
        }.map(\.completedCount)
        guard persisted == segments, completedCounts == [segments.count] else {
            throw FinalTranscriptPipelineError.persistedSegmentsMismatch(segmentationRunID)
        }
    }
}
