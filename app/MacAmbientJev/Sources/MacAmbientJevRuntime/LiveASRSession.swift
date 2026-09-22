import Foundation
import MacAmbientJevCore

public struct LiveASRProgress: Sendable, Equatable {
    public let materializedSegments: [MaterializedTranscriptSegment]
    public let completedCount: Int
    public let failedCount: Int

    public init(
        materializedSegments: [MaterializedTranscriptSegment],
        completedCount: Int,
        failedCount: Int
    ) {
        self.materializedSegments = materializedSegments
        self.completedCount = completedCount
        self.failedCount = failedCount
    }
}

public struct LiveASRCompletion: Sendable, Equatable {
    public let events: [TranscriptEvent]
    public let materializedSegments: [MaterializedTranscriptSegment]
    public let completedCount: Int
    public let failedCount: Int

    public var succeeded: Bool { failedCount == 0 }

    public init(
        events: [TranscriptEvent],
        materializedSegments: [MaterializedTranscriptSegment],
        completedCount: Int,
        failedCount: Int
    ) {
        self.events = events
        self.materializedSegments = materializedSegments
        self.completedCount = completedCount
        self.failedCount = failedCount
    }
}

/// Incremental ASR run used while recording.
///
/// A segment is registered in the append-only event log before transcription.
/// Re-supplying an already-seen segment is a no-op. Model preparation is lazy,
/// so starting capture never waits for the ASR model to load.
public actor LiveASRSession {
    public nonisolated let segmentationRunID: String
    public nonisolated let asrRunID: String

    private let sessionID: UUID
    private let processingDirectory: URL
    private let writer: SessionWriter
    private let asr: any ASREngine
    private let materializer: TranscriptMaterializer

    private var transcriptEvents: [TranscriptEvent] = []
    private var seenSegmentIDs: Set<String> = []
    private var completedCount = 0
    private var failedCount = 0
    private var prepared = false
    private var finalized = false

    public init(
        sessionID: UUID,
        segmentationRunID: String,
        asrRunID: String,
        processingDirectory: URL,
        writer: SessionWriter,
        asr: any ASREngine,
        sampleRate: Double
    ) {
        self.sessionID = sessionID
        self.segmentationRunID = segmentationRunID
        self.asrRunID = asrRunID
        self.processingDirectory = processingDirectory
        self.writer = writer
        self.asr = asr
        self.materializer = TranscriptMaterializer(sampleRate: sampleRate)
    }

    public func process(
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint
    ) async throws -> LiveASRProgress {
        guard !finalized else {
            return currentProgress()
        }

        let newSegments = segments.filter { segment in
            !seenSegmentIDs.contains(segment.segmentID)
        }
        guard !newSegments.isEmpty else {
            return currentProgress()
        }

        if !prepared {
            try await asr.prepare()
            prepared = true
        }

        let loader = ASRAudioLoader(
            reader: ProcessingTimelineReader(
                directory: processingDirectory,
                checkpoint: checkpoint
            )
        )

        for segment in newSegments {
            seenSegmentIDs.insert(segment.segmentID)

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

            do {
                let result = try await asr.transcribe(
                    loader.load(segment: segment)
                )
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
            } catch {
                failedCount += 1
                _ = try? await writer.append(EventDraft(
                    eventType: "asr.failed",
                    sessionID: sessionID,
                    processingRunID: asrRunID,
                    segmentationRunID: segmentationRunID,
                    segmentID: segment.segmentID,
                    sourceStartFrame: segment.startFrame,
                    sourceEndFrame: segment.endFrame,
                    payload: ASRFailedEventPayload(
                        message: error.localizedDescription
                    )
                ))
            }
        }

        return currentProgress()
    }

    public func finish() async throws -> LiveASRCompletion {
        guard !finalized else {
            return currentCompletion()
        }

        finalized = true
        _ = try await writer.append(EventDraft(
            eventType: "processing.run.completed",
            sessionID: sessionID,
            processingRunID: asrRunID,
            payload: ProcessingRunCompletedPayload(
                stage: .asr,
                succeeded: failedCount == 0,
                completedCount: completedCount,
                failedCount: failedCount
            )
        ))

        return currentCompletion()
    }

    private func currentProgress() -> LiveASRProgress {
        LiveASRProgress(
            materializedSegments: materializer.materialize(
                events: transcriptEvents,
                activeRuns: ActiveRuns(
                    segmentation: segmentationRunID,
                    asr: asrRunID
                )
            ),
            completedCount: completedCount,
            failedCount: failedCount
        )
    }

    private func currentCompletion() -> LiveASRCompletion {
        let progress = currentProgress()
        return LiveASRCompletion(
            events: transcriptEvents,
            materializedSegments: progress.materializedSegments,
            completedCount: completedCount,
            failedCount: failedCount
        )
    }
}
