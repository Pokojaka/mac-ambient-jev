import Foundation
import MacAmbientJevCore

public actor VADSession {
    public nonisolated let segmentationRunID: String
    public private(set) var segments: [SegmentReference]

    private let sessionID: UUID
    private let writer: any SessionEventAppending
    private let recoveredSegmentCount: Int
    private let processor: VADTimelineProcessor?
    private var durableConsumedFrames: Int64
    private var sealedFrames: Int64?
    private var regeneratedOrdinal = 0
    private var finished: Bool
    private var operationInProgress = false
    private var requiresReopen = false

    public static func open(sessionID: UUID, segmentationRunID: String, sessionURL: URL,
                            writer: any SessionEventAppending,
                            makeProcessor: @Sendable () async throws -> VADTimelineProcessor) async throws -> VADSession {
        let recovery = try ASRSessionRecovery(eventsURL: SessionLayout(sessionURL: sessionURL).eventsURL,
                                              sessionID: sessionID, segmentationRunID: segmentationRunID,
                                              asrRunID: nil)
        let processor = recovery.segmentationCompleted ? nil : try await makeProcessor()
        return VADSession(sessionID: sessionID, segmentationRunID: segmentationRunID, writer: writer,
                          segments: recovery.segments, processor: processor,
                          durableConsumedFrames: recovery.consumedFrames, sealedFrames: recovery.sealedFrames,
                          finished: recovery.segmentationCompleted)
    }

    private init(sessionID: UUID, segmentationRunID: String, writer: any SessionEventAppending,
                 segments: [SegmentReference], processor: VADTimelineProcessor?,
                 durableConsumedFrames: Int64, sealedFrames: Int64?, finished: Bool) {
        self.sessionID = sessionID
        self.segmentationRunID = segmentationRunID
        self.writer = writer
        self.segments = segments
        self.recoveredSegmentCount = segments.count
        self.processor = processor
        self.durableConsumedFrames = durableConsumedFrames
        self.sealedFrames = sealedFrames
        self.finished = finished
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
            let frameCount = reader.info.committedFrames
            guard frameCount >= durableConsumedFrames else {
                throw SegmentationConsistencyError.inputFrameCountMismatch(expected: durableConsumedFrames, actual: frameCount)
            }
            if let sealedFrames, frameCount != sealedFrames {
                throw SegmentationConsistencyError.inputFrameCountMismatch(expected: sealedFrames, actual: frameCount)
            }
            guard !finished else { return [] }
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
}
