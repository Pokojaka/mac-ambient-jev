import Foundation

/// Payload of `processing.run.started`: written once when a run begins and
/// records what produced it.
public struct ProcessingRunStartedPayload: Codable, Sendable, Equatable {
    public let stage: ProcessingStage
    public let provenance: RunProvenance
    private enum CodingKeys: String, CodingKey { case stage, provenance }

    public init(stage: ProcessingStage, provenance: RunProvenance) {
        self.stage = stage
        self.provenance = provenance
    }
}

public struct ProcessingRunCompletedPayload: Codable, Sendable, Equatable {
    public let stage: ProcessingStage
    public let succeeded: Bool
    public let completedCount: Int
    public let failedCount: Int
    private enum CodingKeys: String, CodingKey {
        case stage, succeeded
        case completedCount = "completed_count", failedCount = "failed_count"
    }

    public init(
        stage: ProcessingStage,
        succeeded: Bool,
        completedCount: Int,
        failedCount: Int
    ) {
        self.stage = stage
        self.succeeded = succeeded
        self.completedCount = completedCount
        self.failedCount = failedCount
    }
}

public enum BatchDisposition: String, Codable, Sendable, Equatable {
    case completed
    case failed
    case paused
}

public enum RunPhase: String, Codable, Sendable {
    case preparing
    case asr
    case postprocessing
    case complete
}

public struct ASRRunCancellation: Error, Sendable {
    public let metrics: ASRBatchMetrics
}

public struct ASRBatchMetrics: Codable, Sendable, Equatable {
    public var modelLoadSeconds: Double = 0
    public var asrCallSeconds: Double = 0
    public var processedAudioSeconds: Double = 0
    public var pacingWaitSeconds: Double = 0
    public var pacingWaitCount: Int = 0
    public var initialPendingCount: Int = 0
    public var maximumPendingCount: Int = 0
    public var oldestPendingAgeSeconds: Double = 0

    public static let zero = ASRBatchMetrics()
    public init() {}

    public var asrRTF: Double? {
        processedAudioSeconds > 0 ? asrCallSeconds / processedAudioSeconds : nil
    }
}

public enum ASRPacingMode: Sendable, Equatable {
    case normal
    case lowHeat
}

/// Why an ASR run did not succeed: recognition failures by kind, and the first
/// event-log write that failed.
public struct ASRRunFailure: Error, LocalizedError, Sendable, Equatable {
    public let failedSegmentCount: Int
    public let failureCounts: [ASRFailureKind: Int]
    public let firstRecognitionMessage: String?
    public let persistenceFailure: String?

    public var errorDescription: String? {
        var parts: [String] = []
        if !failureCounts.isEmpty {
            let breakdown = ASRFailureKind.reportingOrder.compactMap { kind -> String? in
                failureCounts[kind].map { "\(kind.label) \($0)区間" }
            }.joined(separator: "、")
            let detail = firstRecognitionMessage.map { ": \($0)" } ?? ""
            parts.append("文字起こしに失敗しました（\(breakdown)）\(detail)")
        }
        if let persistenceFailure {
            parts.append("イベントログへ保存できませんでした: \(persistenceFailure)")
        }
        return "確定文字起こしで\(failedSegmentCount)区間失敗しました。" + parts.joined(separator: "。")
    }
}

private extension ASRFailureKind {
    static let reportingOrder: [ASRFailureKind] = [.engineUnavailable, .audioUnreadable, .transcriptionFailed]

    var label: String {
        switch self {
        case .engineUnavailable: "音声認識エンジンを使えない"
        case .audioUnreadable: "音声を読めない"
        case .transcriptionFailed: "認識できない"
        }
    }
}

public enum ASRRunDisposition: Sendable, Equatable {
    case completed
    case paused
    case failed(ASRRunFailure)
}

public struct ASRRunResult: Sendable {
    /// `existingEvents` followed by this run's persisted `asr.completed` events.
    public let events: [TranscriptEvent]
    public let completedCount: Int
    public let metrics: ASRBatchMetrics
    public let disposition: ASRRunDisposition
}

public enum PipelineCoordinatorError: Error, LocalizedError, Equatable {
    case missingPendingTime(segmentID: String)

    public var errorDescription: String? {
        switch self {
        case .missingPendingTime(let segmentID):
            "区間 \(segmentID) の asr.pending 記録時刻がありません"
        }
    }
}

private struct FailureTally {
    var failureCounts: [ASRFailureKind: Int] = [:]
    var firstRecognitionMessage: String?
    var persistenceFailedCount = 0
    var persistenceFailure: String?

    mutating func recordPersistenceFailure(_ error: any Error) {
        if persistenceFailure == nil { persistenceFailure = error.localizedDescription }
    }
}

/// Runs one ASR run over segments whose `asr.pending` events are already persisted.
public actor PipelineCoordinator {
    private let sessionID: UUID
    private let segmentationRunID: String
    private let asrRunID: String
    private let writer: SessionWriter
    private let asr: any ASREngine
    private let loader: ASRAudioLoader
    private let pacingMode: ASRPacingMode
    private let sleep: @Sendable (Duration) async throws -> Void
    private let shouldPause: @Sendable () async -> Bool

    public init(
        sessionID: UUID,
        segmentationRunID: String,
        asrRunID: String,
        writer: SessionWriter,
        asr: any ASREngine,
        loader: ASRAudioLoader,
        pacingMode: ASRPacingMode,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        shouldPause: @escaping @Sendable () async -> Bool
    ) {
        self.sessionID = sessionID
        self.segmentationRunID = segmentationRunID
        self.asrRunID = asrRunID
        self.writer = writer
        self.asr = asr
        self.loader = loader
        self.pacingMode = pacingMode
        self.sleep = sleep
        self.shouldPause = shouldPause
    }

    /// - Parameter pendingSince: the `created_at` of each segment's `asr.pending` event.
    public func run(
        segments: [SegmentReference],
        pendingSince: [String: Date],
        existingEvents: [TranscriptEvent]
    ) async throws -> ASRRunResult {
        let pendingDates = try segments.map { segment in
            guard let date = pendingSince[segment.segmentID] else {
                throw PipelineCoordinatorError.missingPendingTime(segmentID: segment.segmentID)
            }
            return date
        }

        var transcriptEvents = existingEvents
        var completedCount = 0
        var tally = FailureTally()
        var metrics = ASRBatchMetrics()
        metrics.initialPendingCount = segments.count
        metrics.maximumPendingCount = segments.count
        let clock = ContinuousClock()

        do {
            var prepared = true
            if !segments.isEmpty {
                try Task.checkCancellation()
                let start = clock.now
                do {
                    try await asr.prepare()
                    metrics.modelLoadSeconds = seconds(start.duration(to: clock.now))
                } catch let cancellation as CancellationError {
                    metrics.modelLoadSeconds += seconds(start.duration(to: clock.now))
                    throw cancellation
                } catch {
                    metrics.modelLoadSeconds += seconds(start.duration(to: clock.now))
                    try Task.checkCancellation()
                    prepared = false
                    for segment in segments {
                        try await recordFailure(segment, kind: .engineUnavailable, error: error, in: &tally)
                    }
                }
            }

            var paused = false
            if prepared {
                for (index, segment) in segments.enumerated() {
                    try Task.checkCancellation()
                    let pauseRequested = await shouldPause()
                    try Task.checkCancellation()
                    if pauseRequested {
                        paused = true
                        break
                    }
                    if let oldest = pendingDates[index...].min() {
                        metrics.oldestPendingAgeSeconds = max(
                            metrics.oldestPendingAgeSeconds,
                            Date().timeIntervalSince(oldest)
                        )
                    }
                    let input: ASRAudioInput
                    do {
                        input = try loader.load(segment: segment)
                    } catch let cancellation as CancellationError {
                        throw cancellation
                    } catch {
                        try Task.checkCancellation()
                        try await recordFailure(segment, kind: .audioUnreadable, error: error, in: &tally)
                        continue
                    }
                    try Task.checkCancellation()

                    let start = clock.now
                    let result: ASRResult
                    do {
                        result = try await asr.transcribe(input)
                    } catch let cancellation as CancellationError {
                        if !input.isShorterThanMinimumASRDuration {
                            metrics.asrCallSeconds += seconds(start.duration(to: clock.now))
                        }
                        throw cancellation
                    } catch {
                        if !input.isShorterThanMinimumASRDuration {
                            metrics.asrCallSeconds += seconds(start.duration(to: clock.now))
                        }
                        try Task.checkCancellation()
                        try await recordFailure(segment, kind: .transcriptionFailed, error: error, in: &tally)
                        continue
                    }
                    if !input.isShorterThanMinimumASRDuration, input.sampleRate > 0 {
                        metrics.asrCallSeconds += seconds(start.duration(to: clock.now))
                        metrics.processedAudioSeconds += Double(input.samples.count) / Double(input.sampleRate)
                    }

                    try Task.checkCancellation()
                    do {
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
                                provenance: asr.provenance
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
                    } catch let cancellation as CancellationError {
                        throw cancellation
                    } catch {
                        try Task.checkCancellation()
                        tally.persistenceFailedCount += 1
                        tally.recordPersistenceFailure(error)
                        continue
                    }

                    if pacingMode == .lowHeat, index < segments.count - 1 {
                        let start = clock.now
                        do {
                            try await sleep(.seconds(2))
                        } catch let cancellation as CancellationError {
                            metrics.pacingWaitSeconds += seconds(start.duration(to: clock.now))
                            metrics.pacingWaitCount += 1
                            throw cancellation
                        } catch {
                            metrics.pacingWaitSeconds += seconds(start.duration(to: clock.now))
                            metrics.pacingWaitCount += 1
                            try Task.checkCancellation()
                            throw error
                        }
                        metrics.pacingWaitSeconds += seconds(start.duration(to: clock.now))
                        metrics.pacingWaitCount += 1
                        try Task.checkCancellation()
                    }
                }
            }

            if paused {
                try Task.checkCancellation()
                return ASRRunResult(
                    events: transcriptEvents,
                    completedCount: completedCount,
                    metrics: metrics,
                    disposition: .paused
                )
            }

            try Task.checkCancellation()
            let failedCount = tally.failureCounts.values.reduce(0, +) + tally.persistenceFailedCount
            do {
                try await writer.append(EventDraft(
                    eventType: "processing.run.completed",
                    sessionID: sessionID,
                    processingRunID: asrRunID,
                    payload: ProcessingRunCompletedPayload(
                        stage: .asr,
                        succeeded: failedCount == 0 && tally.persistenceFailure == nil,
                        completedCount: completedCount,
                        failedCount: failedCount
                    )
                ))
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                try Task.checkCancellation()
                tally.recordPersistenceFailure(error)
            }
            try Task.checkCancellation()

            let disposition: ASRRunDisposition
            if failedCount == 0, tally.persistenceFailure == nil {
                disposition = .completed
            } else {
                disposition = .failed(ASRRunFailure(
                    failedSegmentCount: failedCount,
                    failureCounts: tally.failureCounts,
                    firstRecognitionMessage: tally.firstRecognitionMessage,
                    persistenceFailure: tally.persistenceFailure
                ))
            }
            return ASRRunResult(
                events: transcriptEvents,
                completedCount: completedCount,
                metrics: metrics,
                disposition: disposition
            )
        } catch is CancellationError {
            throw ASRRunCancellation(metrics: metrics)
        }
    }

    /// Records a recognition failure and its `asr.failed` event; a failed write is kept as a persistence failure.
    private func recordFailure(
        _ segment: SegmentReference,
        kind: ASRFailureKind,
        error: any Error,
        in tally: inout FailureTally
    ) async throws {
        try Task.checkCancellation()
        tally.failureCounts[kind, default: 0] += 1
        if tally.firstRecognitionMessage == nil {
            tally.firstRecognitionMessage = error.localizedDescription
        }
        do {
            try await appendFailure(segment: segment, kind: kind, error: error)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            try Task.checkCancellation()
            tally.recordPersistenceFailure(error)
        }
    }

    private func appendFailure(
        segment: SegmentReference,
        kind: ASRFailureKind,
        error: any Error
    ) async throws {
        try Task.checkCancellation()
        try await writer.append(EventDraft(
            eventType: "asr.failed",
            sessionID: sessionID,
            processingRunID: asrRunID,
            segmentationRunID: segmentationRunID,
            segmentID: segment.segmentID,
            sourceStartFrame: segment.startFrame,
            sourceEndFrame: segment.endFrame,
            payload: ASRFailedEventPayload(
                kind: kind,
                message: error.localizedDescription
            )
        ))
        try Task.checkCancellation()
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}
