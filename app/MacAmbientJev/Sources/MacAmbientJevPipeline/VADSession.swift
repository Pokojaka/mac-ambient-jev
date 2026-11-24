import Foundation
import MacAmbientJevCore

public actor VADSession {
    public nonisolated let segmentationRunID: String
    public private(set) var segments: [SegmentReference]

    private let sessionID: UUID
    private let sampleRate: Double
    private let provenance: RunProvenance
    private let writer: any SessionEventAppending
    private let recoveredSegmentCount: Int
    private let processor: VADTimelineProcessor?
    private var durableConsumedFrames: Int64
    private var sealedFrames: Int64?
    private var regeneratedOrdinal = 0
    private var runStarted: Bool
    private var runCompleted: Bool
    private var finished: Bool
    private var operationInProgress = false
    private var requiresReopen = false

    public static func open(
        sessionID: UUID,
        sessionURL: URL,
        writer: any SessionEventAppending,
        provenance: RunProvenance,
        makeProcessor: @Sendable (String) async throws -> VADTimelineProcessor
    ) async throws -> VADSession {
        let layout = SessionLayout(sessionURL: sessionURL)
        guard let recovery = try ProcessingLogState(eventsURL: layout.eventsURL, sessionID: sessionID) else {
            throw ProcessingLogStateError.missingGeneration
        }
        guard recovery.generation.segmentationProvenance == provenance else {
            throw ProcessingLogStateError.incompatibleSettings
        }
        let processor = recovery.segmentationCompleted ? nil : try await makeProcessor(recovery.segmentationRunID)
        return VADSession(
            sessionID: sessionID,
            provenance: provenance,
            writer: writer,
            processor: processor,
            recovery: recovery
        )
    }

    private init(
        sessionID: UUID,
        provenance: RunProvenance,
        writer: any SessionEventAppending,
        processor: VADTimelineProcessor?,
        recovery: ProcessingLogState
    ) {
        self.sessionID = sessionID
        self.segmentationRunID = recovery.segmentationRunID
        self.sampleRate = recovery.generation.sampleRate
        self.provenance = provenance
        self.writer = writer
        self.segments = recovery.segments
        self.recoveredSegmentCount = recovery.segments.count
        self.processor = processor
        self.durableConsumedFrames = recovery.consumedFrames
        self.sealedFrames = recovery.sealedFrames
        self.runStarted = recovery.runStarts[.segmentation] != nil
        self.runCompleted = recovery.runCompletions[.segmentation] != nil
        self.finished = recovery.segmentationCompleted
    }

    public func processAvailable(reader: any TimelineAudioReading) async throws -> [SegmentReference] {
        try await advance(reader: reader, finishing: false)
    }

    public func finish(reader: any TimelineAudioReading) async throws -> [SegmentReference] {
        try await advance(reader: reader, finishing: true)
    }

    private func advance(reader: any TimelineAudioReading, finishing: Bool) async throws -> [SegmentReference] {
        guard !operationInProgress else { throw SegmentationConsistencyError.operationInProgress }
        operationInProgress = true
        defer { operationInProgress = false }
        guard !requiresReopen else { throw SegmentationConsistencyError.sessionRequiresReopen }

        do {
            guard reader.info.sampleRate == sampleRate else {
                throw ProcessingLogStateError.incompatibleSettings
            }
            let frameCount = reader.info.committedFrames
            guard frameCount >= durableConsumedFrames else {
                throw SegmentationConsistencyError.inputFrameCountMismatch(expected: durableConsumedFrames, actual: frameCount)
            }
            if let sealedFrames, frameCount != sealedFrames {
                throw SegmentationConsistencyError.inputFrameCountMismatch(expected: sealedFrames, actual: frameCount)
            }

            try await ensureRunStarted()
            if finished {
                try await ensureRunCompleted()
                return []
            }
            if finishing, sealedFrames == nil {
                try await writer.append(EventDraft(eventType: "segmentation.input.sealed", sessionID: sessionID,
                                                   segmentationRunID: segmentationRunID,
                                                   payload: SegmentationInputSealedPayload(frameCount: frameCount)))
                sealedFrames = frameCount
            }

            guard let processor else { throw SegmentationConsistencyError.sessionRequiresReopen }
            let emitted = try await (finishing ? processor.finish(reader: reader) : processor.processAvailable(reader: reader))
            var appended: [SegmentReference] = []
            for segment in emitted {
                if regeneratedOrdinal < recoveredSegmentCount {
                    guard segments[regeneratedOrdinal] == segment else {
                        throw SegmentationConsistencyError.segmentMismatch(ordinal: regeneratedOrdinal + 1)
                    }
                } else {
                    try await writer.append(.segmentCreated(sessionID: sessionID, segment: segment))
                    segments.append(segment)
                    appended.append(segment)
                }
                regeneratedOrdinal += 1
            }

            if finishing {
                guard regeneratedOrdinal >= recoveredSegmentCount else {
                    throw SegmentationConsistencyError.incompletePrefix(expected: recoveredSegmentCount, actual: regeneratedOrdinal)
                }
                try await writer.append(EventDraft(eventType: "segmentation.completed", sessionID: sessionID,
                                                   segmentationRunID: segmentationRunID,
                                                   payload: SegmentationCompletedPayload(
                                                       consumedFrames: await processor.consumedFrames,
                                                       segmentCount: segments.count)))
                finished = true
                try await ensureRunCompleted()
            } else {
                let consumedFrames = await processor.consumedFrames
                if consumedFrames > durableConsumedFrames {
                    try await writer.append(EventDraft(eventType: "segmentation.progress", sessionID: sessionID,
                                                       segmentationRunID: segmentationRunID,
                                                       payload: SegmentationProgressPayload(consumedFrames: consumedFrames)))
                    durableConsumedFrames = consumedFrames
                }
            }
            return appended
        } catch {
            requiresReopen = true
            throw error
        }
    }

    private func ensureRunStarted() async throws {
        guard !runStarted else { return }
        try await writer.append(EventDraft(
            eventType: "processing.run.started",
            sessionID: sessionID,
            processingRunID: segmentationRunID,
            payload: ProcessingRunStartedPayload(stage: .segmentation, provenance: provenance)
        ))
        runStarted = true
    }

    private func ensureRunCompleted() async throws {
        guard !runCompleted else { return }
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
        runCompleted = true
    }
}
