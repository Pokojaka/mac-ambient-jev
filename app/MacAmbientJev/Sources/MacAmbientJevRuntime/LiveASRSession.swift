import Foundation
import MacAmbientJevCore

public struct LiveASRProgress: Sendable, Equatable {
    public let materializedSegments: [MaterializedTranscriptSegment]
    public let completedCount: Int
    public let failedCount: Int
    public let pendingCount: Int

    public init(
        materializedSegments: [MaterializedTranscriptSegment],
        completedCount: Int,
        failedCount: Int,
        pendingCount: Int
    ) {
        self.materializedSegments = materializedSegments
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.pendingCount = pendingCount
    }
}

public enum LiveTranscriptionFinishResult: Sendable, Equatable {
    case completed
    case noSpeech
    case fallbackRequired(String)
    case postProcessingFailed(String)
}

public struct LiveASRCompletion: Sendable, Equatable {
    public let events: [TranscriptEvent]
    public let materializedSegments: [MaterializedTranscriptSegment]
    public let completedCount: Int
    public let failedCount: Int
    public let pendingCount: Int

    public var succeeded: Bool {
        failedCount == 0 && pendingCount == 0
    }

    public init(
        events: [TranscriptEvent],
        materializedSegments: [MaterializedTranscriptSegment],
        completedCount: Int,
        failedCount: Int,
        pendingCount: Int
    ) {
        self.events = events
        self.materializedSegments = materializedSegments
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.pendingCount = pendingCount
    }
}

/// Incremental ASR run used while recording.
///
/// Detection and transcription are intentionally separate. register first
/// persists segment.created and asr.pending, making the backlog recoverable
/// before model inference starts. process is idempotent for both registration
/// and transcription.
public actor LiveASRSession {
    public nonisolated let segmentationRunID: String
    public nonisolated let asrRunID: String

    private let sessionID: UUID
    private let processingDirectory: URL
    private let writer: SessionWriter
    private let asr: any ASREngine
    private let materializer: TranscriptMaterializer

    private var transcriptEvents: [TranscriptEvent] = []
    private var registeredSegmentIDs: Set<String> = []
    private var registeringSegmentIDs: Set<String> = []
    private var finishedSegmentIDs: Set<String> = []
    private var completedCount = 0
    private var failedCount = 0
    private var prepared = false
    private var finalized = false
    private var completedFinish: LiveASRCompletion?
    private var finishing = false
    private var finishWaiters: [CheckedContinuation<LiveASRCompletion, any Error>] = []
    private var activeWorkCount = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

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

    /// Durably registers newly detected speech before it enters the ASR queue.
    @discardableResult
    public func register(
        segments: [SegmentReference]
    ) async throws -> LiveASRProgress {
        guard !finalized else {
            return currentProgress()
        }
        beginWork()
        defer { endWork() }

        for segment in segments
        where !registeredSegmentIDs.contains(segment.segmentID)
            && !registeringSegmentIDs.contains(segment.segmentID) {
            guard !finalized else { break }
            registeringSegmentIDs.insert(segment.segmentID)
            defer { registeringSegmentIDs.remove(segment.segmentID) }
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
            registeredSegmentIDs.insert(segment.segmentID)
        }

        return currentProgress()
    }

    @discardableResult
    public func process(
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint
    ) async throws -> LiveASRProgress {
        guard !finalized else {
            return currentProgress()
        }
        beginWork()
        defer { endWork() }

        _ = try await register(segments: segments)
        guard !finalized else {
            return currentProgress()
        }

        let pendingSegments = segments.filter { segment in
            registeredSegmentIDs.contains(segment.segmentID)
                && !finishedSegmentIDs.contains(segment.segmentID)
        }
        guard !pendingSegments.isEmpty else {
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

        for segment in pendingSegments {
            guard !finalized else { break }
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

            finishedSegmentIDs.insert(segment.segmentID)
        }

        return currentProgress()
    }

    public func finish() async throws -> LiveASRCompletion {
        if let completedFinish {
            return completedFinish
        }
        if finishing {
            return try await withCheckedThrowingContinuation { continuation in
                finishWaiters.append(continuation)
            }
        }
        finishing = true
        finalized = true

        do {
            if activeWorkCount > 0 {
                await withCheckedContinuation { continuation in
                    idleWaiters.append(continuation)
                }
            }

            let pendingCount =
                registeredSegmentIDs.subtracting(finishedSegmentIDs).count
            _ = try await writer.append(EventDraft(
                eventType: "processing.run.completed",
                sessionID: sessionID,
                processingRunID: asrRunID,
                payload: ProcessingRunCompletedPayload(
                    stage: .asr,
                    succeeded: failedCount == 0 && pendingCount == 0,
                    completedCount: completedCount,
                    failedCount: failedCount
                )
            ))

            let completion = currentCompletion()
            completedFinish = completion
            finishing = false
            let waiters = finishWaiters
            finishWaiters = []
            waiters.forEach { $0.resume(returning: completion) }
            return completion
        } catch {
            finishing = false
            let waiters = finishWaiters
            finishWaiters = []
            waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func beginWork() {
        activeWorkCount += 1
    }

    private func endWork() {
        activeWorkCount -= 1
        guard activeWorkCount == 0 else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
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
            failedCount: failedCount,
            pendingCount:
                registeredSegmentIDs.subtracting(finishedSegmentIDs).count
        )
    }

    private func currentCompletion() -> LiveASRCompletion {
        let progress = currentProgress()
        return LiveASRCompletion(
            events: transcriptEvents,
            materializedSegments: progress.materializedSegments,
            completedCount: completedCount,
            failedCount: failedCount,
            pendingCount: progress.pendingCount
        )
    }
}
