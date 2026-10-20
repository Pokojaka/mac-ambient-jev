import Foundation
import MacAmbientJevCore

public struct FileTranscriptionSegment: Sendable {
    public let reference: SegmentReference
    public let text: String
}

public struct FileTranscriptionResult: Sendable {
    public let segments: [FileTranscriptionSegment]
    public let metrics: ASRBatchMetrics
    public let segmentationSeconds: Double
    public let asrWallSeconds: Double
}

public enum FileTranscriptionPipelineError: LocalizedError, Sendable, Equatable {
    case invalidAudioInfo
    case invalidVADSegment(segmentID: String)
    case invalidVADOrder(segmentID: String)
    case missingASRText(segmentID: String)
    case completedCountMismatch(expected: Int, actual: Int)
    case paused

    public var errorDescription: String? {
        switch self {
        case .invalidAudioInfo:
            "保存済み音声は正規形式で、長さが1フレーム以上必要です"
        case .invalidVADSegment(let segmentID):
            "VAD 区間 \(segmentID) の参照IDまたは範囲が不正です"
        case .invalidVADOrder(let segmentID):
            "VAD 区間 \(segmentID) は時系列順で重複しない必要があります"
        case .missingASRText(let segmentID):
            "区間 \(segmentID) の文字起こし結果がありません"
        case .completedCountMismatch(let expected, let actual):
            "ASR 完了区間数が一致しません（期待値: \(expected)、実際: \(actual)）"
        case .paused:
            "ファイル文字起こしは一時停止されました"
        }
    }
}

public struct FileTranscriptionPipeline: Sendable {
    private let audio: any TimelineAudioReading
    private let asr: any ASREngine
    private let vadSegmenter: any FinalTranscriptVADSegmenter

    public init(
        audio: any TimelineAudioReading,
        asr: any ASREngine,
        vadSegmenter: any FinalTranscriptVADSegmenter
    ) {
        self.audio = audio
        self.asr = asr
        self.vadSegmenter = vadSegmenter
    }

    public func process(sessionID: UUID, sessionURL: URL) async throws -> FileTranscriptionResult {
        let info = audio.info
        guard info.committedFrames > 0,
              info.sampleRate == CanonicalAudio.sampleRate,
              info.channelCount == CanonicalAudio.channelCount,
              info.durationSeconds.isFinite,
              info.durationSeconds > 0 else {
            throw FileTranscriptionPipelineError.invalidAudioInfo
        }
        try audio.validateAudio()

        let writer = try SessionWriter(sessionURL: sessionURL)
        let segmentationRunID = "seg_file_\(UUID().uuidString.lowercased())"
        let asrRunID = "asr_file_\(UUID().uuidString.lowercased())"
        try await writer.append(EventDraft(
            eventType: "processing.run.started",
            sessionID: sessionID,
            processingRunID: segmentationRunID,
            payload: ProcessingRunStartedPayload(stage: .segmentation, provenance: vadSegmenter.provenance)
        ))

        let clock = ContinuousClock()
        let segmentationStart = clock.now
        let segments = try await vadSegmenter.segment(reader: audio, runID: segmentationRunID)
        let segmentationSeconds = seconds(segmentationStart.duration(to: clock.now))
        try validate(segments, runID: segmentationRunID, committedFrames: info.committedFrames)

        try await writer.append(EventDraft(
            eventType: "processing.run.started",
            sessionID: sessionID,
            processingRunID: asrRunID,
            payload: ProcessingRunStartedPayload(stage: .asr, provenance: asr.provenance)
        ))

        var pendingSince: [String: Date] = [:]
        var existingEvents: [TranscriptEvent] = []
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
            existingEvents.append(.segmentCreated(
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
                completedCount: segments.count,
                failedCount: 0
            )
        ))

        let coordinator = PipelineCoordinator(
            sessionID: sessionID,
            segmentationRunID: segmentationRunID,
            asrRunID: asrRunID,
            writer: writer,
            asr: asr,
            loader: ASRAudioLoader(reader: audio),
            pacingMode: .normal,
            sleep: { try await Task.sleep(for: $0) },
            shouldPause: { false }
        )
        let asrStart = clock.now
        let asrResult = try await coordinator.run(
            segments: segments,
            pendingSince: pendingSince,
            existingEvents: existingEvents
        )
        let asrWallSeconds = seconds(asrStart.duration(to: clock.now))

        switch asrResult.disposition {
        case .completed:
            break
        case .failed(let failure):
            throw failure
        case .paused:
            throw FileTranscriptionPipelineError.paused
        }

        guard asrResult.completedCount == segments.count else {
            throw FileTranscriptionPipelineError.completedCountMismatch(
                expected: segments.count,
                actual: asrResult.completedCount
            )
        }
        var textBySegmentID: [String: String] = [:]
        for event in asrResult.events {
            guard event.processingRunID == asrRunID,
                  event.segmentationRunID == segmentationRunID,
                  let segmentID = event.segmentID,
                  case .asrCompleted(let result) = event.kind else {
                continue
            }
            textBySegmentID[segmentID] = result.text
        }
        let transcriptSegments = try segments.map { segment in
            guard let text = textBySegmentID[segment.segmentID] else {
                throw FileTranscriptionPipelineError.missingASRText(segmentID: segment.segmentID)
            }
            return FileTranscriptionSegment(reference: segment, text: text)
        }
        return FileTranscriptionResult(
            segments: transcriptSegments,
            metrics: asrResult.metrics,
            segmentationSeconds: segmentationSeconds,
            asrWallSeconds: asrWallSeconds
        )
    }

    private func validate(_ segments: [SegmentReference], runID: String, committedFrames: Int64) throws {
        var segmentIDs: Set<String> = []
        var previousEndFrame: Int64?
        for segment in segments {
            guard segment.segmentationRunID == runID,
                  !segment.segmentID.isEmpty,
                  segmentIDs.insert(segment.segmentID).inserted,
                  segment.startFrame >= 0,
                  segment.startFrame < segment.endFrame,
                  segment.endFrame <= committedFrames else {
                throw FileTranscriptionPipelineError.invalidVADSegment(segmentID: segment.segmentID)
            }
            if let previousEndFrame, segment.startFrame < previousEndFrame {
                throw FileTranscriptionPipelineError.invalidVADOrder(segmentID: segment.segmentID)
            }
            previousEndFrame = segment.endFrame
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}
