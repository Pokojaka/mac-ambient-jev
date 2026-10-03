import Foundation

public struct AcousticSceneFeatures: Codable, Sendable, Equatable {
    public let activeSpeakerCount: Int
    public let turnRate: Double
    public let overlapRatio: Double
    public let dominantSpeakerRatio: Double
    public let voicedDurationRatio: Double

    public init(
        activeSpeakerCount: Int,
        turnRate: Double,
        overlapRatio: Double,
        dominantSpeakerRatio: Double,
        voicedDurationRatio: Double
    ) {
        self.activeSpeakerCount = activeSpeakerCount
        self.turnRate = turnRate
        self.overlapRatio = overlapRatio
        self.dominantSpeakerRatio = dominantSpeakerRatio
        self.voicedDurationRatio = voicedDurationRatio
    }
}

public struct AcousticSceneFeatureExtractor: Sendable {
    public init() {}

    public func extract(
        speakerSpans: [SpeakerSpan],
        window: Range<Int64>,
        sampleRate: Double
    ) -> AcousticSceneFeatures {
        precondition(sampleRate > 0)
        precondition(window.lowerBound <= window.upperBound)

        let windowFrames = max(1, window.upperBound - window.lowerBound)
        let clipped = speakerSpans.compactMap { span -> SpeakerSpan? in
            let start = max(window.lowerBound, span.startFrame)
            let end = min(window.upperBound, span.endFrame)
            guard end > start else { return nil }
            return SpeakerSpan(
                speakerID: span.speakerID,
                startFrame: start,
                endFrame: end,
                confidence: span.confidence
            )
        }

        let activeSpeakers = Set(clipped.map(\.speakerID))
        let sorted = clipped.sorted {
            if $0.startFrame == $1.startFrame {
                return $0.endFrame < $1.endFrame
            }
            return $0.startFrame < $1.startFrame
        }

        var speakerFrames: [String: Int64] = [:]
        for span in clipped {
            speakerFrames[span.speakerID, default: 0] += span.endFrame - span.startFrame
        }

        var boundaries = Set<Int64>([window.lowerBound, window.upperBound])
        for span in clipped {
            boundaries.insert(span.startFrame)
            boundaries.insert(span.endFrame)
        }
        let points = boundaries.sorted()

        var voicedFrames: Int64 = 0
        var overlapFrames: Int64 = 0
        if points.count >= 2 {
            for index in 0..<(points.count - 1) {
                let start = points[index]
                let end = points[index + 1]
                guard end > start else { continue }
                let activeCount = clipped.reduce(into: 0) { partial, span in
                    if span.startFrame < end && span.endFrame > start {
                        partial += 1
                    }
                }
                if activeCount > 0 {
                    voicedFrames += end - start
                }
                if activeCount >= 2 {
                    overlapFrames += end - start
                }
            }
        }

        var turnCount = 0
        var previousSpeaker: String?
        for span in sorted {
            if let previousSpeaker, previousSpeaker != span.speakerID {
                turnCount += 1
            }
            previousSpeaker = span.speakerID
        }

        let windowSeconds = Double(windowFrames) / sampleRate
        let voicedRatio = min(1, Double(voicedFrames) / Double(windowFrames))
        let overlapRatio = voicedFrames > 0
            ? min(1, Double(overlapFrames) / Double(voicedFrames))
            : 0
        let dominantRatio = voicedFrames > 0
            ? min(
                1,
                Double(speakerFrames.values.max() ?? 0) / Double(voicedFrames)
            )
            : 0

        return AcousticSceneFeatures(
            activeSpeakerCount: activeSpeakers.count,
            turnRate: windowSeconds > 0 ? Double(turnCount) / windowSeconds : 0,
            overlapRatio: overlapRatio,
            dominantSpeakerRatio: dominantRatio,
            voicedDurationRatio: voicedRatio
        )
    }
}

public struct SceneTransition: Sendable, Equatable {
    public let from: SceneState
    public let to: SceneState

    public init(from: SceneState, to: SceneState) {
        self.from = from
        self.to = to
    }
}

public struct SceneStateMachineConfig: Sendable, Equatable {
    public let discussionCandidateObservations: Int
    public let discussionConfirmObservations: Int
    public let lectureCandidateObservations: Int
    public let lectureConfirmObservations: Int

    public init(
        discussionCandidateObservations: Int,
        discussionConfirmObservations: Int,
        lectureCandidateObservations: Int,
        lectureConfirmObservations: Int
    ) {
        precondition(discussionCandidateObservations > 0)
        precondition(discussionConfirmObservations >= discussionCandidateObservations)
        precondition(lectureCandidateObservations > 0)
        precondition(lectureConfirmObservations >= lectureCandidateObservations)

        self.discussionCandidateObservations = discussionCandidateObservations
        self.discussionConfirmObservations = discussionConfirmObservations
        self.lectureCandidateObservations = lectureCandidateObservations
        self.lectureConfirmObservations = lectureConfirmObservations
    }

    public static let production = SceneStateMachineConfig(
        discussionCandidateObservations: 8,
        discussionConfirmObservations: 12,
        lectureCandidateObservations: 10,
        lectureConfirmObservations: 15
    )

    public static let test = SceneStateMachineConfig(
        discussionCandidateObservations: 3,
        discussionConfirmObservations: 6,
        lectureCandidateObservations: 3,
        lectureConfirmObservations: 6
    )
}

public struct SceneStateMachine: Sendable {
    private enum Phase: Sendable {
        case settled(SceneState)
        case building(target: SceneState, origin: SceneState, streak: Int)
    }

    public let config: SceneStateMachineConfig
    private var phase: Phase

    public init(
        state: SceneState,
        config: SceneStateMachineConfig
    ) {
        switch state {
        case .discussionCandidate:
            self.phase = .building(
                target: .discussion,
                origin: .lecture,
                streak: config.discussionCandidateObservations
            )
        case .lectureCandidate:
            self.phase = .building(
                target: .lecture,
                origin: .discussion,
                streak: config.lectureCandidateObservations
            )
        default:
            self.phase = .settled(state)
        }
        self.config = config
    }

    public var state: SceneState {
        switch phase {
        case .settled(let state):
            return state
        case .building(let target, let origin, let streak):
            return streak >= candidateObservations(for: target)
                ? candidateState(for: target)
                : origin
        }
    }

    @discardableResult
    public mutating func observe(
        _ features: AcousticSceneFeatures
    ) -> SceneTransition? {
        let previous = state
        let origin = settledState

        if let target = target(for: features), target != origin {
            let streak = streak(toward: target) + 1
            phase = streak >= confirmObservations(for: target)
                ? .settled(target)
                : .building(target: target, origin: origin, streak: streak)
        } else {
            phase = .settled(origin)
        }

        return transition(from: previous)
    }

    private var settledState: SceneState {
        switch phase {
        case .settled(let state):
            return state
        case .building(_, let origin, _):
            return origin
        }
    }

    private func streak(toward target: SceneState) -> Int {
        guard case .building(target, _, let streak) = phase else { return 0 }
        return streak
    }

    private func transition(from previous: SceneState) -> SceneTransition? {
        guard state != previous else { return nil }
        return SceneTransition(from: previous, to: state)
    }

    private func target(for features: AcousticSceneFeatures) -> SceneState? {
        if isDiscussionEvidence(features) {
            return .discussion
        }
        if isLectureEvidence(features) {
            return .lecture
        }
        return nil
    }

    private func isDiscussionEvidence(_ features: AcousticSceneFeatures) -> Bool {
        features.activeSpeakerCount >= 3
            && features.turnRate >= 0.25
            && features.dominantSpeakerRatio <= 0.65
    }

    private func isLectureEvidence(_ features: AcousticSceneFeatures) -> Bool {
        features.activeSpeakerCount <= 2
            && features.turnRate <= 0.15
            && features.dominantSpeakerRatio >= 0.75
    }

    private func candidateState(for target: SceneState) -> SceneState {
        target == .discussion ? .discussionCandidate : .lectureCandidate
    }

    private func candidateObservations(for target: SceneState) -> Int {
        target == .discussion
            ? config.discussionCandidateObservations
            : config.lectureCandidateObservations
    }

    private func confirmObservations(for target: SceneState) -> Int {
        target == .discussion
            ? config.discussionConfirmObservations
            : config.lectureConfirmObservations
    }
}
