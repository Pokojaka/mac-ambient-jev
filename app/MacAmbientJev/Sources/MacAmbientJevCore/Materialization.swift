import Foundation

public enum TranscriptEventKind: Sendable, Equatable {
    case segmentCreated
    case asrCompleted(ASRResult)
    case speakerSpan(SpeakerSpan)
    case sceneChanged(SceneState)
    case scopeSpan(ScopeSpan)
    case contentPriority(ContentPriority)
}

public struct TranscriptEvent: Sendable, Equatable {
    public let eventSeq: UInt64
    public let processingRunID: String?
    public let segmentationRunID: String?
    public let segmentID: String?
    public let sourceStartFrame: Int64?
    public let sourceEndFrame: Int64?
    public let kind: TranscriptEventKind

    public init(
        eventSeq: UInt64,
        processingRunID: String? = nil,
        segmentationRunID: String? = nil,
        segmentID: String? = nil,
        sourceStartFrame: Int64? = nil,
        sourceEndFrame: Int64? = nil,
        kind: TranscriptEventKind
    ) {
        self.eventSeq = eventSeq
        self.processingRunID = processingRunID
        self.segmentationRunID = segmentationRunID
        self.segmentID = segmentID
        self.sourceStartFrame = sourceStartFrame
        self.sourceEndFrame = sourceEndFrame
        self.kind = kind
    }

    public static func segmentCreated(
        seq: UInt64, segmentationRunID: String, segmentID: String,
        startFrame: Int64, endFrame: Int64
    ) -> TranscriptEvent {
        TranscriptEvent(
            eventSeq: seq,
            segmentationRunID: segmentationRunID,
            segmentID: segmentID,
            sourceStartFrame: startFrame,
            sourceEndFrame: endFrame,
            kind: .segmentCreated
        )
    }

    public static func asrCompleted(
        seq: UInt64, runID: String, segmentationRunID: String,
        segmentID: String, text: String, detectedLanguage: String? = nil
    ) -> TranscriptEvent {
        TranscriptEvent(
            eventSeq: seq,
            processingRunID: runID,
            segmentationRunID: segmentationRunID,
            segmentID: segmentID,
            kind: .asrCompleted(ASRResult(text: text, detectedLanguage: detectedLanguage))
        )
    }

    public static func speakerSpan(
        seq: UInt64, runID: String, speakerID: String,
        startFrame: Int64, endFrame: Int64, confidence: Double?
    ) -> TranscriptEvent {
        TranscriptEvent(
            eventSeq: seq,
            processingRunID: runID,
            sourceStartFrame: startFrame,
            sourceEndFrame: endFrame,
            kind: .speakerSpan(
                SpeakerSpan(
                    speakerID: speakerID,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    confidence: confidence
                )
            )
        )
    }

    public static func sceneChanged(
        seq: UInt64, runID: String, atFrame: Int64, scene: SceneState
    ) -> TranscriptEvent {
        TranscriptEvent(
            eventSeq: seq,
            processingRunID: runID,
            sourceStartFrame: atFrame,
            kind: .sceneChanged(scene)
        )
    }

    public static func scopeSpan(
        seq: UInt64, runID: String, startFrame: Int64, endFrame: Int64,
        scope: AcousticScope, confidence: Double
    ) -> TranscriptEvent {
        TranscriptEvent(
            eventSeq: seq,
            processingRunID: runID,
            sourceStartFrame: startFrame,
            sourceEndFrame: endFrame,
            kind: .scopeSpan(
                ScopeSpan(
                    startFrame: startFrame,
                    endFrame: endFrame,
                    scope: scope,
                    confidence: confidence
                )
            )
        )
    }

    public static func contentPriority(
        seq: UInt64, runID: String, segmentID: String, priority: ContentPriority
    ) -> TranscriptEvent {
        TranscriptEvent(
            eventSeq: seq,
            processingRunID: runID,
            segmentID: segmentID,
            kind: .contentPriority(priority)
        )
    }
}

public struct MaterializedSpeakerSpan: Codable, Sendable, Equatable {
    public let id: String
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let confidence: Double?
    public let displayLabel: String?

    public init(
        id: String, startMilliseconds: Int64, endMilliseconds: Int64,
        confidence: Double?, displayLabel: String? = nil
    ) {
        self.id = id
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.confidence = confidence
        self.displayLabel = displayLabel
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        startMilliseconds = try container.decode(Int64.self, forKey: .startMilliseconds)
        endMilliseconds = try container.decode(Int64.self, forKey: .endMilliseconds)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        displayLabel = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startMilliseconds, forKey: .startMilliseconds)
        try container.encode(endMilliseconds, forKey: .endMilliseconds)
        try container.encodeIfPresent(confidence, forKey: .confidence)
    }
}

public struct MaterializedScopeSpan: Codable, Sendable, Equatable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let scope: AcousticScope
    public let confidence: Double

    public init(
        startMilliseconds: Int64, endMilliseconds: Int64,
        scope: AcousticScope, confidence: Double
    ) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.scope = scope
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case scope
        case confidence
    }
}

public struct MaterializedTranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: String { segmentID }
    public let segmentID: String
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let text: String
    public let scene: SceneState
    public let speakers: [MaterializedSpeakerSpan]
    public let scopeSpans: [MaterializedScopeSpan]
    public let contentPriority: ContentPriority?

    public init(
        segmentID: String, startMilliseconds: Int64, endMilliseconds: Int64,
        text: String, scene: SceneState, speakers: [MaterializedSpeakerSpan],
        scopeSpans: [MaterializedScopeSpan], contentPriority: ContentPriority?
    ) {
        self.segmentID = segmentID
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
        self.scene = scene
        self.speakers = speakers
        self.scopeSpans = scopeSpans
        self.contentPriority = contentPriority
    }

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case text
        case scene
        case speakers
        case scopeSpans = "scope_spans"
        case contentPriority = "content_priority"
    }
}

public struct TranscriptMaterializer: Sendable {
    public let sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    public func materialize(
        events: [TranscriptEvent],
        activeRuns: ActiveRuns
    ) -> [MaterializedTranscriptSegment] {
        let ordered = events.sorted { $0.eventSeq < $1.eventSeq }
        var asrResults: [String?: [String: ASRResult]] = [:]
        var speakerSpans: [SpeakerSpan] = []
        var activeScopeSpans: [ScopeSpan] = []
        var sceneTransitions: [(frame: Int64, scene: SceneState)] = []
        var priorities: [String: ContentPriority] = [:]
        for event in ordered {
            switch event.kind {
            case .asrCompleted(let result) where event.processingRunID == activeRuns.asr:
                if let segmentID = event.segmentID {
                    asrResults[event.segmentationRunID, default: [:]][segmentID] = result
                }
            case .speakerSpan(let span) where event.processingRunID == activeRuns.diarization:
                speakerSpans.append(span)
            case .scopeSpan(let span) where event.processingRunID == activeRuns.scope:
                activeScopeSpans.append(span)
            case .sceneChanged(let scene) where event.processingRunID == activeRuns.scene:
                if let frame = event.sourceStartFrame {
                    sceneTransitions.append((frame, scene))
                }
            case .contentPriority(let priority) where event.processingRunID == activeRuns.contentPriority:
                if let segmentID = event.segmentID {
                    priorities[segmentID] = priority
                }
            default:
                break
            }
        }
        let speakerLabels = SpeakerDisplayMapper.makeLabels(spans: speakerSpans)
        let segmentEvents = ordered.filter { event in
            guard case .segmentCreated = event.kind else { return false }
            return activeRuns.segmentation == nil
                || event.segmentationRunID == activeRuns.segmentation
        }

        return segmentEvents.compactMap { segmentEvent in
            guard let segmentID = segmentEvent.segmentID,
                  let startFrame = segmentEvent.sourceStartFrame,
                  let endFrame = segmentEvent.sourceEndFrame,
                  let asrResult = asrResults[segmentEvent.segmentationRunID]?[segmentID] else {
                return nil
            }

            let speakers = speakerSpans.compactMap { span -> MaterializedSpeakerSpan? in
                let clippedStart = max(startFrame, span.startFrame)
                let clippedEnd = min(endFrame, span.endFrame)
                guard clippedStart < clippedEnd else { return nil }
                return MaterializedSpeakerSpan(
                    id: span.speakerID,
                    startMilliseconds: milliseconds(forFrame: clippedStart),
                    endMilliseconds: milliseconds(forFrame: clippedEnd),
                    confidence: span.confidence,
                    displayLabel: speakerLabels[span.speakerID]
                )
            }

            let scopeSpans = activeScopeSpans.compactMap { span -> MaterializedScopeSpan? in
                let clippedStart = max(startFrame, span.startFrame)
                let clippedEnd = min(endFrame, span.endFrame)
                guard clippedStart < clippedEnd else { return nil }
                return MaterializedScopeSpan(
                    startMilliseconds: milliseconds(forFrame: clippedStart),
                    endMilliseconds: milliseconds(forFrame: clippedEnd),
                    scope: span.scope,
                    confidence: span.confidence
                )
            }

            var scene = SceneState.unknown
            var sceneFrame = Int64.min
            for transition in sceneTransitions
            where transition.frame <= startFrame && transition.frame >= sceneFrame {
                scene = transition.scene
                sceneFrame = transition.frame
            }

            return MaterializedTranscriptSegment(
                segmentID: segmentID,
                startMilliseconds: milliseconds(forFrame: startFrame),
                endMilliseconds: milliseconds(forFrame: endFrame),
                text: asrResult.text,
                scene: scene,
                speakers: speakers,
                scopeSpans: scopeSpans,
                contentPriority: priorities[segmentID]
            )
        }
        .sorted { $0.startMilliseconds < $1.startMilliseconds }
    }

    private func milliseconds(forFrame frame: Int64) -> Int64 {
        Int64((Double(frame) * 1_000.0 / sampleRate).rounded(.towardZero))
    }
}

public struct LiveTranscriptRow: Sendable, Equatable, Identifiable {
    public var id: String { segmentID }
    public let segmentID: String
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let text: String
    public let textFragments: [TranscriptTextFragment]
    public let scene: SceneState
    public let speakers: [MaterializedSpeakerSpan]
    public let displaySpeakerLabels: [String]
    public let scopeSpans: [MaterializedScopeSpan]
    public let isLowPriority: Bool

    public init(
        segmentID: String,
        startMilliseconds: Int64,
        endMilliseconds: Int64 = 0,
        text: String,
        textFragments: [TranscriptTextFragment]? = nil,
        scene: SceneState,
        speakers: [MaterializedSpeakerSpan],
        displaySpeakerLabels: [String] = [],
        scopeSpans: [MaterializedScopeSpan],
        isLowPriority: Bool
    ) {
        self.segmentID = segmentID
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
        self.textFragments = textFragments ?? FillerTextSpanDetector().fragments(in: text)
        self.scene = scene
        self.speakers = speakers
        self.displaySpeakerLabels = displaySpeakerLabels
        self.scopeSpans = scopeSpans
        self.isLowPriority = isLowPriority
    }
}

public struct LiveTranscriptProjection: Sendable {
    public init() {}

    public func rows(
        for segments: [MaterializedTranscriptSegment]
    ) -> [LiveTranscriptRow] {
        let allSpeakerSpans = segments.flatMap(\.speakers).map { span in
            SpeakerSpan(
                speakerID: span.id,
                startFrame: span.startMilliseconds,
                endFrame: span.endMilliseconds,
                confidence: span.confidence
            )
        }
        let labels = SpeakerDisplayMapper.makeLabels(spans: allSpeakerSpans)

        return segments.compactMap { segment in
            let isBackgroundOnly = segment.scene == .discussion
                && !segment.scopeSpans.isEmpty
                && segment.scopeSpans.allSatisfy { $0.scope == .background }

            guard !isBackgroundOnly,
                  JevTranscriptEligibility.isEligible(segment.text) else { return nil }

            return LiveTranscriptRow(
                segmentID: segment.segmentID,
                startMilliseconds: segment.startMilliseconds,
                endMilliseconds: segment.endMilliseconds,
                text: segment.text,
                textFragments: FillerTextSpanDetector().fragments(in: segment.text),
                scene: segment.scene,
                speakers: segment.speakers,
                displaySpeakerLabels: SpeakerDisplayMapper.turnLabels(for: segment, labels: labels),
                scopeSpans: segment.scopeSpans,
                isLowPriority: segment.contentPriority == .lowPriority
            )
        }
    }
}
