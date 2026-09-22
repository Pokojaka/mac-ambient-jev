import Foundation

public struct ASRRecoveryPlan: Sendable, Equatable {
    public let segmentationRunID: String
    public let asrRunID: String
    public let pendingSegments: [SegmentReference]
    public let transcriptEvents: [TranscriptEvent]
    public let runSucceeded: Bool
    public let hasFailures: Bool

    public init(
        segmentationRunID: String,
        asrRunID: String,
        pendingSegments: [SegmentReference],
        transcriptEvents: [TranscriptEvent],
        runSucceeded: Bool,
        hasFailures: Bool
    ) {
        self.segmentationRunID = segmentationRunID
        self.asrRunID = asrRunID
        self.pendingSegments = pendingSegments
        self.transcriptEvents = transcriptEvents
        self.runSucceeded = runSucceeded
        self.hasFailures = hasFailures
    }
}

public enum EventLogRecoveryAnalyzerError: Error, Equatable {
    case malformedEvent
}

public struct EventLogRecoveryAnalyzer: Sendable {
    public init() {}

    public func latestASRPlan(
        lines: [Data]
    ) throws -> ASRRecoveryPlan? {
        var dictionaries: [[String: Any]] = []
        dictionaries.reserveCapacity(lines.count)

        for line in lines {
            guard let object = try JSONSerialization.jsonObject(
                with: line
            ) as? [String: Any] else {
                throw EventLogRecoveryAnalyzerError.malformedEvent
            }
            dictionaries.append(object)
        }

        let pendingEvents = dictionaries.compactMap { event -> (
            seq: UInt64,
            asrRunID: String,
            segmentationRunID: String,
            segmentID: String,
            startFrame: Int64,
            endFrame: Int64
        )? in
            guard event["event_type"] as? String == "asr.pending",
                  let seq = uint64(event["event_seq"]),
                  let asrRunID = event["processing_run_id"] as? String,
                  let segmentationRunID = event["segmentation_run_id"] as? String,
                  let segmentID = event["segment_id"] as? String,
                  let startFrame = int64(event["source_start_frame"]),
                  let endFrame = int64(event["source_end_frame"])
            else {
                return nil
            }

            return (
                seq,
                asrRunID,
                segmentationRunID,
                segmentID,
                startFrame,
                endFrame
            )
        }

        guard let latestPending = pendingEvents.max(
            by: { $0.seq < $1.seq }
        ) else {
            return nil
        }

        let asrRunID = latestPending.asrRunID
        let segmentationRunID = latestPending.segmentationRunID
        let runPending = pendingEvents.filter {
            $0.asrRunID == asrRunID
                && $0.segmentationRunID == segmentationRunID
        }

        let completedIDs = Set(dictionaries.compactMap { event -> String? in
            guard event["event_type"] as? String == "asr.completed",
                  event["processing_run_id"] as? String == asrRunID,
                  event["segmentation_run_id"] as? String == segmentationRunID
            else {
                return nil
            }
            return event["segment_id"] as? String
        })

        let failedIDs = Set(dictionaries.compactMap { event -> String? in
            guard event["event_type"] as? String == "asr.failed",
                  event["processing_run_id"] as? String == asrRunID,
                  event["segmentation_run_id"] as? String == segmentationRunID
            else {
                return nil
            }
            return event["segment_id"] as? String
        })

        var seenPendingIDs = Set<String>()
        let pendingSegments = runPending
            .sorted { $0.seq < $1.seq }
            .compactMap { event -> SegmentReference? in
                guard !seenPendingIDs.contains(event.segmentID) else {
                    return nil
                }
                seenPendingIDs.insert(event.segmentID)

                guard !completedIDs.contains(event.segmentID),
                      !failedIDs.contains(event.segmentID) else {
                    return nil
                }

                return SegmentReference(
                    segmentationRunID: segmentationRunID,
                    segmentID: event.segmentID,
                    startFrame: event.startFrame,
                    endFrame: event.endFrame
                )
            }

        var transcriptEvents: [TranscriptEvent] = []

        for event in dictionaries {
            guard let seq = uint64(event["event_seq"]),
                  let eventType = event["event_type"] as? String
            else {
                continue
            }

            switch eventType {
            case "segment.created":
                guard event["segmentation_run_id"] as? String == segmentationRunID,
                      let segmentID = event["segment_id"] as? String,
                      let startFrame = int64(event["source_start_frame"]),
                      let endFrame = int64(event["source_end_frame"])
                else {
                    continue
                }

                transcriptEvents.append(.segmentCreated(
                    seq: seq,
                    segmentationRunID: segmentationRunID,
                    segmentID: segmentID,
                    startFrame: startFrame,
                    endFrame: endFrame
                ))

            case "asr.completed":
                guard event["processing_run_id"] as? String == asrRunID,
                      event["segmentation_run_id"] as? String == segmentationRunID,
                      let segmentID = event["segment_id"] as? String,
                      let payload = event["payload"] as? [String: Any],
                      let text = payload["text"] as? String
                else {
                    continue
                }

                transcriptEvents.append(.asrCompleted(
                    seq: seq,
                    runID: asrRunID,
                    segmentationRunID: segmentationRunID,
                    segmentID: segmentID,
                    text: text,
                    detectedLanguage: payload["detected_language"] as? String
                ))

            default:
                continue
            }
        }

        let runSucceeded = dictionaries.contains { event in
            guard event["event_type"] as? String == "processing.run.completed",
                  event["processing_run_id"] as? String == asrRunID,
                  let payload = event["payload"] as? [String: Any],
                  payload["stage"] as? String == ProcessingStage.asr.rawValue
            else {
                return false
            }
            return payload["succeeded"] as? Bool == true
        }

        return ASRRecoveryPlan(
            segmentationRunID: segmentationRunID,
            asrRunID: asrRunID,
            pendingSegments: pendingSegments,
            transcriptEvents: transcriptEvents.sorted {
                $0.eventSeq < $1.eventSeq
            },
            runSucceeded: runSucceeded,
            hasFailures: !failedIDs.isEmpty
        )
    }

    private func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let value = value as? UInt64 {
            return value
        }
        return nil
    }

    private func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let value = value as? Int64 {
            return value
        }
        return nil
    }
}
