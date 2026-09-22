                guard event.processingRunID == activeRuns.diarization,
                      case .speakerSpan(let span) = event.kind else { return nil }
                let clippedStart = max(startFrame, span.startFrame)
                let clippedEnd = min(endFrame, span.endFrame)
                guard clippedStart < clippedEnd else { return nil }
                return MaterializedSpeakerSpan(
                    id: span.speakerID,
                    startMilliseconds: milliseconds(forFrame: clippedStart),
                    endMilliseconds: milliseconds(forFrame: clippedEnd),
                    confidence: span.confidence
                )
            }

            let scopeSpans = ordered.compactMap { event -> MaterializedScopeSpan? in
                guard event.processingRunID == activeRuns.scope,
                      case .scopeSpan(let span) = event.kind else { return nil }
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

            let scene = ordered.last(where: { event in
                guard event.processingRunID == activeRuns.scene,
                      let transitionFrame = event.sourceStartFrame,
                      transitionFrame <= startFrame else { return false }
                if case .sceneChanged = event.kind { return true }
                return false
            }).flatMap { event -> SceneState? in
                if case .sceneChanged(let value) = event.kind { return value }
                return nil
            } ?? .unknown

            let priority = ordered.last(where: { event in
                guard event.processingRunID == activeRuns.contentPriority,
                      event.segmentID == segmentID else { return false }
                if case .contentPriority = event.kind { return true }
                return false
            }).flatMap { event -> ContentPriority? in
                if case .contentPriority(let value) = event.kind { return value }
                return nil
            }

            return MaterializedTranscriptSegment(
                segmentID: segmentID,
                startMilliseconds: milliseconds(forFrame: startFrame),
                endMilliseconds: milliseconds(forFrame: endFrame),
                text: asrResult.text,
                scene: scene,
                speakers: speakers,
                scopeSpans: scopeSpans,
                contentPriority: priority
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
    public let text: String
    public let scene: SceneState
    public let speakers: [MaterializedSpeakerSpan]
    public let scopeSpans: [MaterializedScopeSpan]
    public let isLowPriority: Bool

    public init(
        segmentID: String,
        startMilliseconds: Int64,
        text: String,
        scene: SceneState,
        speakers: [MaterializedSpeakerSpan],
        scopeSpans: [MaterializedScopeSpan],
        isLowPriority: Bool
    ) {
        self.segmentID = segmentID
        self.startMilliseconds = startMilliseconds
        self.text = text
        self.scene = scene
        self.speakers = speakers
        self.scopeSpans = scopeSpans
        self.isLowPriority = isLowPriority
    }
}

public struct LiveTranscriptProjection: Sendable {
    public init() {}

    public func rows(for segments: [MaterializedTranscriptSegment]) -> [LiveTranscriptRow] {
        segments.compactMap { segment in
            let isBackgroundOnly = segment.scene == .discussion
                && !segment.scopeSpans.isEmpty
                && segment.scopeSpans.allSatisfy { $0.scope == .background }

            guard !isBackgroundOnly else { return nil }

            return LiveTranscriptRow(
                segmentID: segment.segmentID,
                startMilliseconds: segment.startMilliseconds,
                text: segment.text,
                scene: segment.scene,
                speakers: segment.speakers,
                scopeSpans: segment.scopeSpans,
                isLowPriority: segment.contentPriority == .lowPriority
            )
        }
    }
}