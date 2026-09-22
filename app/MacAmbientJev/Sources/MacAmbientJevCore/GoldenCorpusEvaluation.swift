import Foundation

public struct GoldenCorpusManifest: Codable, Sendable, Equatable {
    public let id: String
    public let audio: String
    public let annotations: GoldenCorpusAnnotations

    public init(
        id: String,
        audio: String,
        annotations: GoldenCorpusAnnotations
    ) {
        self.id = id
        self.audio = audio
        self.annotations = annotations
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

    public init(
        asrRTF: Double? = nil,
        peakMemoryMB: Double? = nil,
        oldestPendingAgeMilliseconds: Int64? = nil
    ) {
        self.asrRTF = asrRTF
        self.peakMemoryMB = peakMemoryMB
        self.oldestPendingAgeMilliseconds = oldestPendingAgeMilliseconds
    }

    enum CodingKeys: String, CodingKey {
        case asrRTF = "asr_rtf"
        case peakMemoryMB = "peak_memory_mb"
        case oldestPendingAgeMilliseconds = "oldest_pending_age_ms"
    }
}

public struct GoldenCorpusReport: Codable, Sendable, Equatable {
    public let technicalTermRetention: Double
    public let falseLowPriorityCount: Int
    public let falseBackgroundCount: Int
    public let sceneTransitionErrorMilliseconds: Int64
    public let sceneOscillationCount: Int
    public let asrRTF: Double?
    public let peakMemoryMB: Double?
    public let oldestPendingAgeMilliseconds: Int64?

    public init(
        technicalTermRetention: Double,
        falseLowPriorityCount: Int,
        falseBackgroundCount: Int,
        sceneTransitionErrorMilliseconds: Int64,
        sceneOscillationCount: Int,
        asrRTF: Double?,
        peakMemoryMB: Double?,
        oldestPendingAgeMilliseconds: Int64?
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

public enum GoldenCorpusEvaluator {
    public static func evaluate(
        segments: [MaterializedTranscriptSegment],
        manifest: GoldenCorpusManifest,
        observedSceneTransitions: [GoldenSceneTransition] = [],
        runtimeMetrics: GoldenRuntimeMetrics = GoldenRuntimeMetrics()
    ) -> GoldenCorpusReport {
        let transcript = segments.map(\.text).joined(separator: "\n")
        let requiredTerms = manifest.annotations.mustKeepTerms
        let retainedTerms = requiredTerms.filter { transcript.contains($0) }

        let technicalTermRetention: Double
        if requiredTerms.isEmpty {
            technicalTermRetention = 1
        } else {
            technicalTermRetention =
                Double(retainedTerms.count) / Double(requiredTerms.count)
        }

        let falseLowPriorityCount = manifest.annotations.mustNotBeLowPriority
            .reduce(into: 0) { count, index in
                guard segments.indices.contains(index) else { return }
                if segments[index].contentPriority == .lowPriority {
                    count += 1
                }
            }

        let falseBackgroundCount = manifest.annotations.mustNotBeBackground
            .reduce(into: 0) { count, index in
                guard segments.indices.contains(index) else { return }
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

        let sceneTransitionErrorMilliseconds = transitionError(
            expected: manifest.annotations.sceneTransitions,
            observed: observedSceneTransitions
        )

        return GoldenCorpusReport(
            technicalTermRetention: technicalTermRetention,
            falseLowPriorityCount: falseLowPriorityCount,
            falseBackgroundCount: falseBackgroundCount,
            sceneTransitionErrorMilliseconds: sceneTransitionErrorMilliseconds,
            sceneOscillationCount: oscillationCount(
                observedSceneTransitions
            ),
            asrRTF: runtimeMetrics.asrRTF,
            peakMemoryMB: runtimeMetrics.peakMemoryMB,
            oldestPendingAgeMilliseconds:
                runtimeMetrics.oldestPendingAgeMilliseconds
        )
    }

    private static func transitionError(
        expected: [GoldenSceneTransition],
        observed: [GoldenSceneTransition]
    ) -> Int64 {
        guard !expected.isEmpty else { return 0 }

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
