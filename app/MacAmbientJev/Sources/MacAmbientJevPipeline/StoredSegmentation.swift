import Foundation
import MacAmbientJevCore

public protocol SessionProcessingAudioHandling: Sendable {
    func open(
        _ source: SessionAudioSource,
        layout: SessionLayout,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> any TimelineAudioReading
    /// Finishes the storage step of a drained recording (FLAC conversion) off the calling actor.
    func convergeStorage(layout: SessionLayout, manifest: SessionManifest) async throws
}

public protocol SessionVADSegmenter: Sendable {
    var provenance: RunProvenance { get }
    func segment(
        reader: any TimelineAudioReading,
        runID: String
    ) async throws -> [SegmentReference]
}

enum StoredSegmentationError: Error, LocalizedError {
    case invalidSegment(String)
    case segmentPrefixMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidSegment(let id): "VAD 区間 \(id) の範囲または順序が不正です"
        case .segmentPrefixMismatch(let runID): "segmentation run \(runID) の保存済み区間が再生成結果と一致しません"
        }
    }
}

enum StoredSegmentation {
    static func finish(
        state: ProcessingLogState,
        sessionID: UUID,
        audio: any TimelineAudioReading,
        segmenter: any SessionVADSegmenter,
        writer: SessionWriter
    ) async throws {
        let generationID = state.generation.id
        let runID = state.segmentationRunID
        let frameCount = audio.info.committedFrames
        guard audio.info.sampleRate == state.generation.sampleRate,
              segmenter.provenance == state.generation.segmentationProvenance else {
            throw ProcessingLogStateError.incompatibleSettings
        }
        guard frameCount >= state.consumedFrames else {
            throw SegmentationConsistencyError.inputFrameCountMismatch(
                expected: state.consumedFrames, actual: frameCount
            )
        }
        if let sealedFrames = state.sealedFrames, sealedFrames != frameCount {
            throw SegmentationConsistencyError.inputFrameCountMismatch(
                expected: sealedFrames, actual: frameCount
            )
        }

        if state.runStarts[.segmentation] == nil {
            try await writer.append(EventDraft(
                eventType: "processing.run.started", sessionID: sessionID, processingRunID: runID,
                payload: ProcessingRunStartedPayload(
                    stage: .segmentation, provenance: state.generation.segmentationProvenance
                )
            ))
        }

        let segmentCount: Int
        var runCompletionMissing = state.runCompletions[.segmentation] == nil
        if state.segmentationCompleted {
            segmentCount = state.segments.count
        } else {
            if state.sealedFrames == nil {
                try await writer.append(EventDraft(
                    eventType: "segmentation.input.sealed", sessionID: sessionID,
                    segmentationRunID: runID,
                    payload: SegmentationInputSealedPayload(frameCount: frameCount)
                ))
            }

            let generated = try await segmenter.segment(reader: audio, runID: runID)
            try validate(generated, runID: runID, frameCount: frameCount)
            guard generated.count >= state.segments.count,
                  Array(generated.prefix(state.segments.count)) == state.segments else {
                throw StoredSegmentationError.segmentPrefixMismatch(runID)
            }

            // The segmenter may suspend while another writer advances the durable prefix.
            let durable = try await currentState(sessionID: sessionID, generationID: generationID, writer: writer)
            guard durable.sealedFrames == frameCount,
                  durable.segments.count >= state.segments.count,
                  durable.segments.count <= generated.count,
                  Array(generated.prefix(durable.segments.count)) == durable.segments else {
                throw StoredSegmentationError.segmentPrefixMismatch(runID)
            }
            runCompletionMissing = durable.runCompletions[.segmentation] == nil
            if durable.segmentationCompleted {
                guard durable.segments == generated else {
                    throw StoredSegmentationError.segmentPrefixMismatch(runID)
                }
                segmentCount = durable.segments.count
            } else {
                for segment in generated.dropFirst(durable.segments.count) {
                    try await writer.append(.segmentCreated(sessionID: sessionID, segment: segment))
                }
                try await writer.append(EventDraft(
                    eventType: "segmentation.completed", sessionID: sessionID,
                    segmentationRunID: runID,
                    payload: SegmentationCompletedPayload(consumedFrames: frameCount, segmentCount: generated.count)
                ))
                segmentCount = generated.count
            }
        }

        if runCompletionMissing {
            try await writer.append(EventDraft(
                eventType: "processing.run.completed", sessionID: sessionID, processingRunID: runID,
                payload: ProcessingRunCompletedPayload(
                    stage: .segmentation, succeeded: true, completedCount: segmentCount, failedCount: 0
                )
            ))
        }
    }

    private static func validate(_ segments: [SegmentReference], runID: String, frameCount: Int64) throws {
        var ids: Set<String> = []
        var previousEnd: Int64 = 0
        for segment in segments {
            guard segment.segmentationRunID == runID,
                  !segment.segmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ids.insert(segment.segmentID).inserted,
                  SegmentReference.isValid(segment.speechRanges),
                  segment.endFrame <= frameCount,
                  segment.startFrame >= previousEnd else {
                throw StoredSegmentationError.invalidSegment(segment.segmentID)
            }
            previousEnd = segment.endFrame
        }
    }

    private static func currentState(
        sessionID: UUID, generationID: UUID, writer: SessionWriter
    ) async throws -> ProcessingLogState {
        let eventsURL = await writer.eventsURL
        guard let state = try ProcessingLogState(eventsURL: eventsURL, sessionID: sessionID),
              state.generation.id == generationID else {
            throw ProcessingLogStateError.missingGeneration
        }
        return state
    }
}
