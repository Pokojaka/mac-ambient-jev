import Foundation

public enum EventLogTranscriptReaderError: Error, Equatable {
    case malformedEvent
}

public struct EventLogTranscriptReader: Sendable {
    public init() {}

    public func events(
        lines: [Data],
        activeRuns: ActiveRuns
    ) throws -> [TranscriptEvent] {
        let dictionaries = try decode(lines: lines)
        var events: [TranscriptEvent] = []

        for event in dictionaries {
            guard let seq = uint64(event["event_seq"]),
                  let eventType = event["event_type"] as? String else {
                continue
            }

            switch eventType {
            case "segment.created":
                guard event["segmentation_run_id"] as? String
                        == activeRuns.segmentation,
                      let segmentID =
                        event["segment_id"] as? String,
                      let startFrame =
                        int64(event["source_start_frame"]),
                      let endFrame =
                        int64(event["source_end_frame"])
                else {
                    continue
                }

                events.append(.segmentCreated(
                    seq: seq,
                    segmentationRunID:
                        event["segmentation_run_id"] as! String,
                    segmentID: segmentID,
                    startFrame: startFrame,
                    endFrame: endFrame
                ))

            case "asr.completed":
                guard event["processing_run_id"] as? String
                        == activeRuns.asr,
                      event["segmentation_run_id"] as? String
                        == activeRuns.segmentation,
                      let segmentationRunID =
                        event["segmentation_run_id"] as? String,
                      let segmentID =
                        event["segment_id"] as? String,
                      let payload =
                        event["payload"] as? [String: Any],
                      let text = payload["text"] as? String
                else {
                    continue
                }

                events.append(.asrCompleted(
                    seq: seq,
                    runID: event["processing_run_id"] as! String,
                    segmentationRunID: segmentationRunID,
                    segmentID: segmentID,
                    text: text,
                    detectedLanguage:
                        payload["detected_language"] as? String
                ))

            case "speaker.span":
                guard event["processing_run_id"] as? String
                        == activeRuns.diarization,
                      let runID =
                        event["processing_run_id"] as? String,
                      let payload =
                        event["payload"] as? [String: Any],
                      let speakerID =
                        payload["speaker_id"] as? String,
                      let startFrame =
                        int64(payload["start_frame"]),
                      let endFrame =
                        int64(payload["end_frame"])
                else {
                    continue
                }

                events.append(.speakerSpan(
                    seq: seq,
                    runID: runID,
                    speakerID: speakerID,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    confidence: double(payload["confidence"])
                ))

            case "scene.changed":
                guard event["processing_run_id"] as? String
                        == activeRuns.scene,
                      let runID =
                        event["processing_run_id"] as? String,
                      let frame =
                        int64(event["source_start_frame"]),
                      let rawScene = event["payload"] as? String,
                      let scene = SceneState(rawValue: rawScene)
                else {
                    continue
                }

                events.append(.sceneChanged(
                    seq: seq,
                    runID: runID,
                    atFrame: frame,
                    scene: scene
                ))

            case "scope.span":
                guard event["processing_run_id"] as? String
                        == activeRuns.scope,
                      let runID =
                        event["processing_run_id"] as? String,
                      let payload =
                        event["payload"] as? [String: Any],
                      let startFrame =
                        int64(payload["start_frame"]),
                      let endFrame =
                        int64(payload["end_frame"]),
                      let rawScope = payload["scope"] as? String,
                      let scope =
                        AcousticScope(rawValue: rawScope),
                      let confidence =
                        double(payload["confidence"])
                else {
                    continue
                }

                events.append(.scopeSpan(
                    seq: seq,
                    runID: runID,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    scope: scope,
                    confidence: confidence
                ))

            case "content_priority.assigned":
                guard event["processing_run_id"] as? String
                        == activeRuns.contentPriority,
                      let runID =
                        event["processing_run_id"] as? String,
                      let segmentID =
                        event["segment_id"] as? String,
                      let payload =
                        event["payload"] as? [String: Any],
                      let rawPriority =
                        payload["priority"] as? String,
                      let priority =
                        ContentPriority(rawValue: rawPriority)
                else {
                    continue
                }

                events.append(.contentPriority(
                    seq: seq,
                    runID: runID,
                    segmentID: segmentID,
                    priority: priority
                ))

            default:
                continue
            }
        }

        return events.sorted { $0.eventSeq < $1.eventSeq }
    }

    private func decode(
        lines: [Data]
    ) throws -> [[String: Any]] {
        try lines.map { line in
            guard let object = try JSONSerialization.jsonObject(
                with: line
            ) as? [String: Any] else {
                throw EventLogTranscriptReaderError.malformedEvent
            }
            return object
        }
    }

    private func uint64(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
            ?? value as? UInt64
    }

    private func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
            ?? value as? Int64
    }

    private func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
            ?? value as? Double
    }
}

public struct ContentPriorityRecoveryState: Sendable, Equatable {
    public let latestRunID: String?
    public let pendingSegmentIDs: [String]
    public let hasAssignments: Bool

    public init(
        latestRunID: String?,
        pendingSegmentIDs: [String],
        hasAssignments: Bool
    ) {
        self.latestRunID = latestRunID
        self.pendingSegmentIDs = pendingSegmentIDs
        self.hasAssignments = hasAssignments
    }
}

public struct JevRetryAnalyzer: Sendable {
    public init() {}

    public func contentPriorityState(
        lines: [Data]
    ) throws -> ContentPriorityRecoveryState {
        var latestBySegment: [
            String: (
                seq: UInt64,
                runID: String,
                needsRetry: Bool
            )
        ] = [:]
        var latestRun: (seq: UInt64, runID: String)?

        for line in lines {
            guard let event = try JSONSerialization.jsonObject(
                with: line
            ) as? [String: Any] else {
                throw EventLogTranscriptReaderError.malformedEvent
            }
            guard event["event_type"] as? String
                    == "content_priority.assigned",
                  let seq = uint64(event["event_seq"]),
                  let runID =
                    event["processing_run_id"] as? String,
                  let segmentID =
                    event["segment_id"] as? String,
                  let payload =
                    event["payload"] as? [String: Any],
                  let needsRetry =
                    payload["needs_retry"] as? Bool
            else {
                continue
            }

            if latestRun == nil || seq > latestRun!.seq {
                latestRun = (seq, runID)
            }

            if let existing = latestBySegment[segmentID],
               existing.seq >= seq {
                continue
            }
            latestBySegment[segmentID] = (
                seq,
                runID,
                needsRetry
            )
        }

        let pending = latestBySegment
            .filter { $0.value.needsRetry }
            .sorted { lhs, rhs in
                lhs.value.seq < rhs.value.seq
            }
            .map(\.key)

        return ContentPriorityRecoveryState(
            latestRunID: latestRun?.runID,
            pendingSegmentIDs: pending,
            hasAssignments: !latestBySegment.isEmpty
        )
    }

    private func uint64(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
            ?? value as? UInt64
    }
}
