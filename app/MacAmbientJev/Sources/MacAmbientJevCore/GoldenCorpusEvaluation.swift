import Foundation

public struct GoldenCorpusReference: Codable, Sendable, Equatable {
    public let text: String?
    public let path: String?

    public init(text: String? = nil, path: String? = nil) {
        self.text = text
        self.path = path
    }
}

public struct GoldenCorpusManifest: Codable, Sendable, Equatable {
    public let id: String
    public let audio: String
    public let annotations: GoldenCorpusAnnotations
    public let reference: GoldenCorpusReference?

    public init(
        id: String,
        audio: String,
        annotations: GoldenCorpusAnnotations,
        reference: GoldenCorpusReference? = nil
    ) {
        self.id = id
        self.audio = audio
        self.annotations = annotations
        self.reference = reference
    }
}

public struct GoldenCorpusAnnotations: Codable, Sendable, Equatable {
    public let sceneTransitions: [GoldenSceneTransition]
    public let mustKeepTerms: [String]
    public let mustNotBeLowPriority: [Int]
    public let mustNotBeBackground: [Int]

    public init(
        sceneTransitions: [GoldenSceneTransition],
        mustKeepTerms: [String],
        mustNotBeLowPriority: [Int],
        mustNotBeBackground: [Int]
    ) {
        self.sceneTransitions = sceneTransitions
        self.mustKeepTerms = mustKeepTerms
        self.mustNotBeLowPriority = mustNotBeLowPriority
        self.mustNotBeBackground = mustNotBeBackground
    }

    enum CodingKeys: String, CodingKey {
        case sceneTransitions = "scene_transitions"
        case mustKeepTerms = "must_keep_terms"
        case mustNotBeLowPriority = "must_not_be_low_priority"
        case mustNotBeBackground = "must_not_be_background"
    }
}

public struct GoldenSceneTransition: Codable, Sendable, Equatable {
    public let timeMilliseconds: Int64
    public let to: SceneState

    public init(timeMilliseconds: Int64, to: SceneState) {
        self.timeMilliseconds = timeMilliseconds
        self.to = to
    }

    enum CodingKeys: String, CodingKey {
        case timeMilliseconds = "time_ms"
        case to
    }
}

public struct GoldenRuntimeMetrics: Codable, Sendable, Equatable {
    public let asrRTF: Double?
    public let peakMemoryMB: Double?
    public let oldestPendingAgeMilliseconds: Int64?
    public let asrEvaluation: ASREvaluationResult?

    public init(
        asrRTF: Double? = nil,
        peakMemoryMB: Double? = nil,
        oldestPendingAgeMilliseconds: Int64? = nil
    ) {
        self.asrRTF = asrRTF
        self.peakMemoryMB = peakMemoryMB
        self.oldestPendingAgeMilliseconds = oldestPendingAgeMilliseconds
        self.asrEvaluation = asrEvaluation
    }

    enum CodingKeys: String, CodingKey {
        case asrRTF = "asr_rtf"
        case peakMemoryMB = "peak_memory_mb"
        case oldestPendingAgeMilliseconds = "oldest_pending_age_ms"
        case asrEvaluation = "asr_evaluation"
    }
}

public struct GoldenCorpusReport: Codable, Sendable, Equatable {
    public let technicalTermRetention: Double?
    public let falseLowPriorityCount: Int?
    public let falseBackgroundCount: Int?
    public let sceneTransitionErrorMilliseconds: Int64?
    public let sceneOscillationCount: Int?
    public let asrRTF: Double?
    public let peakMemoryMB: Double?
    public let oldestPendingAgeMilliseconds: Int64?

    public init(
        technicalTermRetention: Double?,
        falseLowPriorityCount: Int?,
        falseBackgroundCount: Int?,
        sceneTransitionErrorMilliseconds: Int64?,
        sceneOscillationCount: Int?,
        asrRTF: Double?,
        peakMemoryMB: Double?,
        oldestPendingAgeMilliseconds: Int64?,
        asrEvaluation: ASREvaluationResult? = nil
    ) {
        self.technicalTermRetention = technicalTermRetention
        self.falseLowPriorityCount = falseLowPriorityCount
        self.falseBackgroundCount = falseBackgroundCount
        self.sceneTransitionErrorMilliseconds = sceneTransitionErrorMilliseconds
        self.sceneOscillationCount = sceneOscillationCount
        self.asrRTF = asrRTF
        self.peakMemoryMB = peakMemoryMB
        self.oldestPendingAgeMilliseconds = oldestPendingAgeMilliseconds
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(technicalTermRetention, forKey: .technicalTermRetention)
        try container.encode(falseLowPriorityCount, forKey: .falseLowPriorityCount)
        try container.encode(falseBackgroundCount, forKey: .falseBackgroundCount)
        try container.encode(
            sceneTransitionErrorMilliseconds,
            forKey: .sceneTransitionErrorMilliseconds
        )
        try container.encode(sceneOscillationCount, forKey: .sceneOscillationCount)
        try container.encodeIfPresent(asrRTF, forKey: .asrRTF)
        try container.encodeIfPresent(peakMemoryMB, forKey: .peakMemoryMB)
        try container.encodeIfPresent(
            oldestPendingAgeMilliseconds,
            forKey: .oldestPendingAgeMilliseconds
        )
        try container.encodeIfPresent(
            asrEvaluation,
            forKey: .asrEvaluation
        )
    }

    enum CodingKeys: String, CodingKey {
        case technicalTermRetention = "technical_term_retention"
        case falseLowPriorityCount = "false_low_priority_count"
        case falseBackgroundCount = "false_background_count"
        case sceneTransitionErrorMilliseconds = "scene_transition_error_ms"
        case sceneOscillationCount = "scene_oscillation_count"
        case asrRTF = "asr_rtf"
        case peakMemoryMB = "peak_memory_mb"
        case oldestPendingAgeMilliseconds = "oldest_pending_age_ms"
    }
}

public enum GoldenCorpusEvaluationError: LocalizedError, Sendable, Equatable {
    case segmentAnnotationIndexOutOfBounds(
        annotation: String,
        index: Int,
        segmentCount: Int
    )
    case emptyRequiredTerm(index: Int)

    public var errorDescription: String? {
        switch self {
        case let .segmentAnnotationIndexOutOfBounds(annotation, index, segmentCount):
            return "\(annotation)[\(index)] は segments の範囲外です（segments.count: \(segmentCount) 件）。"
        case let .emptyRequiredTerm(index):
            return "must_keep_terms[\(index)] は空文字または空白のみです。"
        }
    }
}

public enum GoldenCorpusEvaluator {
    public static func evaluate(
        segments: [MaterializedTranscriptSegment],
        manifest: GoldenCorpusManifest,
        observedSceneTransitions: [GoldenSceneTransition]? = nil,
        runtimeMetrics: GoldenRuntimeMetrics = GoldenRuntimeMetrics(),
        referenceText: String? = nil
    ) throws -> GoldenCorpusReport {
        let annotations = manifest.annotations
        try validateSegmentAnnotationIndices(
            annotations.mustNotBeLowPriority,
            annotation: "must_not_be_low_priority",
            segmentCount: segments.count
        )
        try validateSegmentAnnotationIndices(
            annotations.mustNotBeBackground,
            annotation: "must_not_be_background",
            segmentCount: segments.count
        )
        if let index = annotations.mustKeepTerms.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            throw GoldenCorpusEvaluationError.emptyRequiredTerm(index: index)
        }

        let transcript = segments.map(\.text).joined(separator: "\n")
        let requiredTerms = annotations.mustKeepTerms
        let retainedTerms = requiredTerms.filter { transcript.contains($0) }

        let technicalTermRetention: Double? = requiredTerms.isEmpty
            ? nil
            : (
                Double(retainedTerms.count) / Double(requiredTerms.count)
            )

        let lowPriorityAnnotations = annotations.mustNotBeLowPriority
        let falseLowPriorityCount: Int? = lowPriorityAnnotations.isEmpty
            ? nil
            : lowPriorityAnnotations
            .reduce(into: 0) { count, index in
                if segments[index].contentPriority == .lowPriority {
                    count += 1
                }
            }

        let backgroundAnnotations = annotations.mustNotBeBackground
        let falseBackgroundCount: Int? = backgroundAnnotations.isEmpty
            ? nil
            : backgroundAnnotations
            .reduce(into: 0) { count, index in
                let segment = segments[index]
                let wouldBeHiddenAsBackground =
                    segment.scene == .discussion
                    && !segment.scopeSpans.isEmpty
                    && segment.scopeSpans.allSatisfy {
                        $0.scope == .background
                    }

                if wouldBeHiddenAsBackground {
                    count += 1
                }
            }

        let sceneTransitionErrorMilliseconds: Int64?
        let sceneOscillationCount: Int?
        if let observedSceneTransitions {
            sceneTransitionErrorMilliseconds = transitionError(
                expected: annotations.sceneTransitions,
                observed: observedSceneTransitions
            )
            sceneOscillationCount = oscillationCount(observedSceneTransitions)
        } else {
            sceneTransitionErrorMilliseconds = nil
            sceneOscillationCount = nil
        }

        let resolvedReferenceText = referenceText ?? manifest.reference?.text
        let asrEvaluation = resolvedReferenceText.map {
            ASREvaluation.evaluate(
                reference: $0,
                hypothesis: transcript
            )
        }

        return GoldenCorpusReport(
            technicalTermRetention: technicalTermRetention,
            falseLowPriorityCount: falseLowPriorityCount,
            falseBackgroundCount: falseBackgroundCount,
            sceneTransitionErrorMilliseconds: sceneTransitionErrorMilliseconds,
            sceneOscillationCount: sceneOscillationCount,
            asrRTF: runtimeMetrics.asrRTF,
            peakMemoryMB: runtimeMetrics.peakMemoryMB,
            oldestPendingAgeMilliseconds:
                runtimeMetrics.oldestPendingAgeMilliseconds,
            asrEvaluation: asrEvaluation
        )
    }

    private static func validateSegmentAnnotationIndices(
        _ indices: [Int],
        annotation: String,
        segmentCount: Int
    ) throws {
        guard let index = indices.first(where: { !(0..<segmentCount).contains($0) }) else {
            return
        }
        throw GoldenCorpusEvaluationError.segmentAnnotationIndexOutOfBounds(
            annotation: annotation,
            index: index,
            segmentCount: segmentCount
        )
    }

    private static func transitionError(
        expected: [GoldenSceneTransition],
        observed: [GoldenSceneTransition]
    ) -> Int64? {
        guard !expected.isEmpty else { return nil }

        let errors = expected.compactMap { target -> Int64? in
            observed
                .filter { $0.to == target.to }
                .map {
                    abs($0.timeMilliseconds - target.timeMilliseconds)
                }
                .min()
        }

        guard errors.count == expected.count else {
            return -1
        }

        return errors.reduce(0, +) / Int64(errors.count)
    }

    private static func oscillationCount(
        _ transitions: [GoldenSceneTransition]
    ) -> Int {
        let ordered = transitions.sorted {
            $0.timeMilliseconds < $1.timeMilliseconds
        }
        guard ordered.count >= 3 else { return 0 }

        var count = 0
        for index in 0..<(ordered.count - 2) {
            let first = ordered[index]
            let middle = ordered[index + 1]
            let last = ordered[index + 2]

            if first.to == last.to,
               first.to != middle.to,
               last.timeMilliseconds - first.timeMilliseconds <= 30_000 {
                count += 1
            }
        }
        return count
    }
}
