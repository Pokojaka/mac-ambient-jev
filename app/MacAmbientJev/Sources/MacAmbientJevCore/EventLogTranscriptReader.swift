import Foundation

public enum EventLogTranscriptReaderError: Error, Equatable, LocalizedError {
    /// The line is not a JSON event with `event_seq` and `event_type`.
    case unreadableLine(index: Int)
    /// An event the reader needs is missing a required field or has a field of the wrong type.
    case malformedEvent(eventSeq: UInt64, eventType: String)
    /// An `asr.completed` event whose `outcome` contradicts its `text`.
    case asrOutcomeMismatch(eventSeq: UInt64)

    public var errorDescription: String? {
        switch self {
        case .unreadableLine(let index):
            "イベントログの \(index + 1) 行目を読めません"
        case .malformedEvent(let eventSeq, let eventType):
            "イベントログの \(eventType)（event_seq \(eventSeq)）が壊れています"
        case .asrOutcomeMismatch(let eventSeq):
            "イベントログの asr.completed（event_seq \(eventSeq)）の outcome が本文と一致しません"
        }
    }
}

/// One `events.jsonl` line. The envelope header is decoded first; a typed body is decoded
/// only for events the caller needs, so other runs and unknown event types stay unparsed.
struct EventLogLine {
    struct Header: Decodable {
        let eventSeq: UInt64
        let eventType: String
        let processingRunID: String?
        let segmentationRunID: String?

        private enum CodingKeys: String, CodingKey {
            case eventSeq = "event_seq"
            case eventType = "event_type"
            case processingRunID = "processing_run_id"
            case segmentationRunID = "segmentation_run_id"
        }
    }

    let header: Header
    private let data: Data

    init(index: Int, data: Data) throws {
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch is DecodingError {
            throw EventLogTranscriptReaderError.unreadableLine(index: index)
        }
        self.data = data
    }

    func body<Body: Decodable>(_ type: Body.Type) throws -> Body {
        do {
            return try JSONDecoder().decode(Body.self, from: data)
        } catch is DecodingError {
            throw EventLogTranscriptReaderError.malformedEvent(
                eventSeq: header.eventSeq,
                eventType: header.eventType
            )
        }
    }

    static func decode(_ lines: [Data]) throws -> [EventLogLine] {
        try lines.enumerated().map { try EventLogLine(index: $0.offset, data: $0.element) }
    }
}

private enum EventLogKeys: String, CodingKey {
    case processingRunID = "processing_run_id"
    case segmentationRunID = "segmentation_run_id"
    case segmentID = "segment_id"
    case sourceStartFrame = "source_start_frame"
    case sourceEndFrame = "source_end_frame"
    case payload
}

private struct SegmentCreatedBody: Decodable {
    let segmentID: String
    let startFrame: Int64
    let endFrame: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EventLogKeys.self)
        segmentID = try container.decode(String.self, forKey: .segmentID)
        startFrame = try container.decode(Int64.self, forKey: .sourceStartFrame)
        endFrame = try container.decode(Int64.self, forKey: .sourceEndFrame)
    }
}

private struct ASRCompletedBody: Decodable {
    let segmentID: String
    let text: String
    let detectedLanguage: String?
    let outcome: ASRRecognitionOutcome

    private enum PayloadKeys: String, CodingKey {
        case text
        case detectedLanguage = "detected_language"
        case outcome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EventLogKeys.self)
        segmentID = try container.decode(String.self, forKey: .segmentID)
        let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        text = try payload.decode(String.self, forKey: .text)
        detectedLanguage = try payload.decodeIfPresent(String.self, forKey: .detectedLanguage)
        outcome = try payload.decode(ASRRecognitionOutcome.self, forKey: .outcome)
    }
}

private struct SpeakerSpanBody: Decodable {
    let span: SpeakerSpan

    private enum PayloadKeys: String, CodingKey {
        case speakerID = "speaker_id"
        case startFrame = "start_frame"
        case endFrame = "end_frame"
        case confidence
    }

    init(from decoder: Decoder) throws {
        let payload = try decoder.container(keyedBy: EventLogKeys.self)
            .nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        span = SpeakerSpan(
            speakerID: try payload.decode(String.self, forKey: .speakerID),
            startFrame: try payload.decode(Int64.self, forKey: .startFrame),
            endFrame: try payload.decode(Int64.self, forKey: .endFrame),
            confidence: try payload.decodeIfPresent(Double.self, forKey: .confidence)
        )
    }
}

private struct SceneChangedBody: Decodable {
    let frame: Int64
    let scene: SceneState

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EventLogKeys.self)
        frame = try container.decode(Int64.self, forKey: .sourceStartFrame)
        scene = try container.decode(SceneState.self, forKey: .payload)
    }
}

private struct ScopeSpanBody: Decodable {
    let span: ScopeSpan

    private enum PayloadKeys: String, CodingKey {
        case startFrame = "start_frame"
        case endFrame = "end_frame"
        case scope
        case confidence
    }

    init(from decoder: Decoder) throws {
        let payload = try decoder.container(keyedBy: EventLogKeys.self)
            .nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        span = ScopeSpan(
            startFrame: try payload.decode(Int64.self, forKey: .startFrame),
            endFrame: try payload.decode(Int64.self, forKey: .endFrame),
            scope: try payload.decode(AcousticScope.self, forKey: .scope),
            confidence: try payload.decode(Double.self, forKey: .confidence)
        )
    }
}

private struct ContentPriorityBody: Decodable {
    let segmentID: String
    let priority: ContentPriority
    let needsRetry: Bool

    private enum PayloadKeys: String, CodingKey {
        case priority
        case needsRetry = "needs_retry"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EventLogKeys.self)
        segmentID = try container.decode(String.self, forKey: .segmentID)
        let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        priority = try payload.decode(ContentPriority.self, forKey: .priority)
        needsRetry = try payload.decode(Bool.self, forKey: .needsRetry)
    }
}

private struct LiveRunStartedBody: Decodable {
    let payload: ProcessingRunStartedPayload
}

private struct LivePriorityBody: Decodable {
    let segmentID: String
    let priority: ContentPriority
    let classified: Bool

    private enum PayloadKeys: String, CodingKey {
        case priority, decision
        case needsRetry = "needs_retry"
    }
    private enum DecisionKeys: String, CodingKey { case classified }
    private struct Classified: Decodable {
        let confidence: Double
        let model: String?
        let inputTokens: Int?
        private enum CodingKeys: String, CodingKey {
            case confidence, model
            case inputTokens = "input_tokens"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EventLogKeys.self)
        segmentID = try container.decode(String.self, forKey: .segmentID)
        let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        priority = try payload.decode(ContentPriority.self, forKey: .priority)
        let decision = try payload.nestedContainer(keyedBy: DecisionKeys.self, forKey: .decision)
        let needsRetry = try payload.decode(Bool.self, forKey: .needsRetry)
        if decision.contains(.classified) {
            _ = try decision.decode(Classified.self, forKey: .classified)
            classified = !needsRetry
        } else {
            classified = false
        }
    }
}

/// Reads the events of the active runs. Events of other runs and unknown event types are skipped;
/// an active-run event with a missing or mistyped field throws.
public struct EventLogTranscriptReader: Sendable {
    public init() {}

    /// Reuses only durable classified live decisions, retaining their exact source identity.
    public func liveContentPriorityDecisions(
        lines: [Data]
    ) throws -> [String: ContentPriorityEventPayload] {
        struct SegmentKey: Hashable {
            let segmentationRunID: String
            let segmentID: String
        }
        let decoded = try EventLogLine.decode(lines).sorted { $0.header.eventSeq < $1.header.eventSeq }
        var livePriorityRuns: Set<String> = []
        for line in decoded where line.header.eventType == "processing.run.started" {
            let runID = try requiredRunID(line.header.processingRunID, of: line.header)
            let started = try line.body(LiveRunStartedBody.self).payload
            guard started.provenance.configuration["mode"] == "live" else { continue }
            if started.stage == .contentPriority { livePriorityRuns.insert(runID) }
        }
        var texts: [SegmentKey: String] = [:]
        var result: [String: ContentPriorityEventPayload] = [:]
        for line in decoded {
            let header = line.header
            guard let runID = header.processingRunID else { continue }
            if header.eventType == "asr.completed" {
                let segmentationRunID = try requiredRunID(header.segmentationRunID, of: header)
                let body = try line.body(ASRCompletedBody.self)
                guard body.outcome == ASRRecognitionOutcome(text: body.text) else {
                    throw EventLogTranscriptReaderError.asrOutcomeMismatch(eventSeq: header.eventSeq)
                }
                texts[SegmentKey(segmentationRunID: segmentationRunID, segmentID: body.segmentID)]
                    = ContentPriorityText.normalized(body.text)
            } else if header.eventType == "content_priority.assigned", livePriorityRuns.contains(runID) {
                let segmentationRunID = try requiredRunID(header.segmentationRunID, of: header)
                let body = try line.body(LivePriorityBody.self)
                guard body.classified,
                      let text = texts[SegmentKey(segmentationRunID: segmentationRunID, segmentID: body.segmentID)],
                      !text.isEmpty else { continue }
                result[text] = ContentPriorityEventPayload(
                    priority: body.priority,
                    decision: .carriedOver(
                        sourceRunID: runID,
                        sourceSegmentationRunID: segmentationRunID,
                        sourceSegmentID: body.segmentID
                    )
                )
            }
        }
        return result
    }

    public func events(
        lines: [Data],
        activeRuns: ActiveRuns
    ) throws -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []

        for line in try EventLogLine.decode(lines) {
            let header = line.header
            let seq = header.eventSeq

            switch header.eventType {
            case "segment.created":
                let segmentationRunID = try requiredRunID(header.segmentationRunID, of: header)
                guard segmentationRunID == activeRuns.segmentation else { continue }
                let body = try line.body(SegmentCreatedBody.self)
                events.append(.segmentCreated(
                    seq: seq,
                    segmentationRunID: segmentationRunID,
                    segmentID: body.segmentID,
                    startFrame: body.startFrame,
                    endFrame: body.endFrame
                ))

            case "asr.completed":
                let runID = try requiredRunID(header.processingRunID, of: header)
                let segmentationRunID = try requiredRunID(header.segmentationRunID, of: header)
                guard runID == activeRuns.asr,
                      segmentationRunID == activeRuns.segmentation else { continue }
                let body = try line.body(ASRCompletedBody.self)
                guard body.outcome == ASRRecognitionOutcome(text: body.text) else {
                    throw EventLogTranscriptReaderError.asrOutcomeMismatch(eventSeq: seq)
                }
                events.append(.asrCompleted(
                    seq: seq,
                    runID: runID,
                    segmentationRunID: segmentationRunID,
                    segmentID: body.segmentID,
                    text: body.text,
                    detectedLanguage: body.detectedLanguage
                ))

            case "speaker.span":
                let runID = try requiredRunID(header.processingRunID, of: header)
                guard runID == activeRuns.diarization else { continue }
                let span = try line.body(SpeakerSpanBody.self).span
                events.append(.speakerSpan(
                    seq: seq,
                    runID: runID,
                    speakerID: span.speakerID,
                    startFrame: span.startFrame,
                    endFrame: span.endFrame,
                    confidence: span.confidence
                ))

            case "scene.changed":
                let runID = try requiredRunID(header.processingRunID, of: header)
                guard runID == activeRuns.scene else { continue }
                let body = try line.body(SceneChangedBody.self)
                events.append(.sceneChanged(seq: seq, runID: runID, atFrame: body.frame, scene: body.scene))

            case "scope.span":
                let runID = try requiredRunID(header.processingRunID, of: header)
                guard runID == activeRuns.scope else { continue }
                let span = try line.body(ScopeSpanBody.self).span
                events.append(.scopeSpan(
                    seq: seq,
                    runID: runID,
                    startFrame: span.startFrame,
                    endFrame: span.endFrame,
                    scope: span.scope,
                    confidence: span.confidence
                ))

            case "content_priority.assigned":
                let runID = try requiredRunID(header.processingRunID, of: header)
                guard runID == activeRuns.contentPriority else { continue }
                let body = try line.body(ContentPriorityBody.self)
                events.append(.contentPriority(
                    seq: seq,
                    runID: runID,
                    segmentID: body.segmentID,
                    priority: body.priority
                ))

            default:
                continue
            }
        }

        return events.sorted { $0.eventSeq < $1.eventSeq }
    }

    /// The run ID a known event type is keyed by; its absence makes the event unattributable.
    private func requiredRunID(_ value: String?, of header: EventLogLine.Header) throws -> String {
        guard let value else {
            throw EventLogTranscriptReaderError.malformedEvent(
                eventSeq: header.eventSeq,
                eventType: header.eventType
            )
        }
        return value
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

/// Reads every run's `content_priority.assigned` events; a malformed one throws.
public struct JevRetryAnalyzer: Sendable {
    public init() {}

    public func contentPriorityState(
        lines: [Data]
    ) throws -> ContentPriorityRecoveryState {
        var latestBySegment: [String: (seq: UInt64, needsRetry: Bool)] = [:]
        var latestRun: (seq: UInt64, runID: String)?

        for line in try EventLogLine.decode(lines)
        where line.header.eventType == "content_priority.assigned" {
            let seq = line.header.eventSeq
            guard let runID = line.header.processingRunID else {
                throw EventLogTranscriptReaderError.malformedEvent(
                    eventSeq: seq,
                    eventType: line.header.eventType
                )
            }
            let body = try line.body(ContentPriorityBody.self)

            if latestRun.map({ seq > $0.seq }) != false {
                latestRun = (seq, runID)
            }
            if let existing = latestBySegment[body.segmentID], existing.seq >= seq {
                continue
            }
            latestBySegment[body.segmentID] = (seq, body.needsRetry)
        }

        let pending = latestBySegment
            .filter { $0.value.needsRetry }
            .sorted { $0.value.seq < $1.value.seq }
            .map(\.key)

        return ContentPriorityRecoveryState(
            latestRunID: latestRun?.runID,
            pendingSegmentIDs: pending,
            hasAssignments: !latestBySegment.isEmpty
        )
    }
}
