import Foundation

public enum SpeakerIdentityError: Error, Sendable, Equatable {
    case invalidTrackedIndex(Int)
}

public struct SpeakerIdentity: Codable, Sendable, Hashable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case tracked
        case other
        case unknown
    }

    public let kind: Kind
    public let index: Int?

    private init(kind: Kind, index: Int?) {
        self.kind = kind
        self.index = index
    }

    public static func tracked(_ index: Int) throws -> Self {
        guard (1...7).contains(index) else {
            throw SpeakerIdentityError.invalidTrackedIndex(index)
        }
        return Self(kind: .tracked, index: index)
    }

    public static let other = Self(kind: .other, index: nil)
    public static let unknown = Self(kind: .unknown, index: nil)

    private enum CodingKeys: String, CodingKey {
        case kind
        case index
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .tracked:
            self = try Self.tracked(
                container.decode(Int.self, forKey: .index)
            )
        case .other:
            if try container.decodeIfPresent(
                Int.self,
                forKey: .index
            ) != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .index,
                    in: container,
                    debugDescription:
                        "other speaker must not have an index"
                )
            }
            self = .other
        case .unknown:
            if try container.decodeIfPresent(
                Int.self,
                forKey: .index
            ) != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .index,
                    in: container,
                    debugDescription:
                        "unknown speaker must not have an index"
                )
            }
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if let index {
            try container.encode(index, forKey: .index)
        }
    }
}

public struct SourceSpeakerSpan: Sendable, Equatable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let speakerLabel: String

    public init(
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        speakerLabel: String
    ) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.speakerLabel = speakerLabel
    }
}

public struct SpeakerEvaluationSpan: Codable, Sendable, Equatable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let speaker: SpeakerIdentity

    public init(
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        speaker: SpeakerIdentity
    ) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.speaker = speaker
    }
}

public enum SpeakerArrivalCollapser {
    public static func collapse(
        _ spans: [SourceSpeakerSpan]
    ) throws -> [SpeakerEvaluationSpan] {
        let ordered = spans.enumerated().sorted { lhs, rhs in
            if lhs.element.startMilliseconds
                != rhs.element.startMilliseconds {
                return lhs.element.startMilliseconds
                    < rhs.element.startMilliseconds
            }
            return lhs.offset < rhs.offset
        }

        var assignments: [String: SpeakerIdentity] = [:]
        var nextTrackedIndex = 1
        var result: [SpeakerEvaluationSpan] = []
        result.reserveCapacity(spans.count)

        for (_, span) in ordered {
            let label = span.speakerLabel.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let speaker: SpeakerIdentity
            if label.isEmpty {
                speaker = .unknown
            } else if let existing = assignments[label] {
                speaker = existing
            } else if nextTrackedIndex <= 7 {
                speaker = try .tracked(nextTrackedIndex)
                assignments[label] = speaker
                nextTrackedIndex += 1
            } else {
                speaker = .other
                assignments[label] = speaker
            }

            result.append(
                SpeakerEvaluationSpan(
                    startMilliseconds: span.startMilliseconds,
                    endMilliseconds: span.endMilliseconds,
                    speaker: speaker
                )
            )
        }
        return result
    }
}

public struct CollapsedDiarizationMetrics:
    Codable, Sendable, Equatable
{
    public let totalReferenceSpeakerMilliseconds: Int64
    public let missMilliseconds: Int64
    public let falseAlarmMilliseconds: Int64
    public let confusionMilliseconds: Int64
    public let unknownMilliseconds: Int64
    public let otherToTrackedLeakageMilliseconds: Int64
    public let trackedToOtherLeakageMilliseconds: Int64
    public let trackedSpeakerConfusionMilliseconds: Int64
    public let referenceOverlapMilliseconds: Int64
    public let detectedOverlapMilliseconds: Int64
    public let otherPrecision: Double?
    public let otherRecall: Double?
    public let unknownRate: Double
    public let overflowDetectionRecall: Double?
    public let overlapRecall: Double?
    public let der: Double

    enum CodingKeys: String, CodingKey {
        case totalReferenceSpeakerMilliseconds =
            "total_reference_speaker_ms"
        case missMilliseconds = "miss_ms"
        case falseAlarmMilliseconds = "false_alarm_ms"
        case confusionMilliseconds = "confusion_ms"
        case unknownMilliseconds = "unknown_ms"
        case otherToTrackedLeakageMilliseconds =
            "other_to_tracked_leakage_ms"
        case trackedToOtherLeakageMilliseconds =
            "tracked_to_other_leakage_ms"
        case trackedSpeakerConfusionMilliseconds =
            "tracked_speaker_confusion_ms"
        case referenceOverlapMilliseconds =
            "reference_overlap_ms"
        case detectedOverlapMilliseconds =
            "detected_overlap_ms"
        case otherPrecision = "other_precision"
        case otherRecall = "other_recall"
        case unknownRate = "unknown_rate"
        case overflowDetectionRecall =
            "overflow_detection_recall"
        case overlapRecall = "overlap_recall"
        case der
    }
}

public enum CollapsedDiarizationEvaluator {
    public static func evaluate(
        reference: [SpeakerEvaluationSpan],
        hypothesis: [SpeakerEvaluationSpan]
    ) -> CollapsedDiarizationMetrics {
        let all = reference + hypothesis
        let boundaries = Array(
            Set(
                all.flatMap {
                    [$0.startMilliseconds, $0.endMilliseconds]
                }
            )
        ).sorted()

        var totalReference: Int64 = 0
        var miss: Int64 = 0
        var falseAlarm: Int64 = 0
        var confusion: Int64 = 0
        var unknown: Int64 = 0
        var otherToTracked: Int64 = 0
        var trackedToOther: Int64 = 0
        var trackedSpeakerConfusion: Int64 = 0
        var referenceOverlap: Int64 = 0
        var detectedOverlap: Int64 = 0
        var otherReference: Int64 = 0
        var otherCorrect: Int64 = 0
        var otherHypothesis: Int64 = 0
        var overflowDetected: Int64 = 0

        for index in 0..<max(boundaries.count - 1, 0) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            let duration = end - start
            guard duration > 0 else { continue }

            let ref = activeSpeakers(
                in: start..<end,
                spans: reference
            )
            let hyp = activeSpeakers(
                in: start..<end,
                spans: hypothesis
            )
            let common = ref.intersection(hyp)
            let refTracked = Set(
                ref.filter { $0.kind == .tracked }
            )
            let hypTracked = Set(
                hyp.filter { $0.kind == .tracked }
            )
            let commonTracked = refTracked.intersection(
                hypTracked
            )

            totalReference += Int64(ref.count) * duration
            miss += Int64(max(ref.count - hyp.count, 0)) * duration
            falseAlarm +=
                Int64(max(hyp.count - ref.count, 0)) * duration
            confusion += Int64(
                max(min(ref.count, hyp.count) - common.count, 0)
            ) * duration
            trackedSpeakerConfusion += Int64(
                max(
                    min(refTracked.count, hypTracked.count)
                        - commonTracked.count,
                    0
                )
            ) * duration

            if ref.count >= 2 {
                referenceOverlap += duration
                if hyp.count >= 2 {
                    detectedOverlap += duration
                }
            }
            if hyp.contains(.unknown) {
                unknown += duration
            }
            if hyp.contains(.other) {
                otherHypothesis += duration
            }
            if ref.contains(.other) {
                otherReference += duration
                if hyp.contains(.other) {
                    otherCorrect += duration
                    overflowDetected += duration
                } else if hyp.contains(.unknown) {
                    overflowDetected += duration
                } else if hyp.contains(where: {
                    $0.kind == .tracked
                }) {
                    otherToTracked += duration
                }
            }
            if hyp.contains(.other),
               !ref.contains(.other),
               ref.contains(where: { $0.kind == .tracked }) {
                trackedToOther += duration
            }
        }

        let error = miss + falseAlarm + confusion
        let der = totalReference == 0
            ? (error == 0 ? 0 : 1)
            : Double(error) / Double(totalReference)
        let otherPrecision = otherHypothesis == 0
            ? nil
            : Double(otherCorrect) / Double(otherHypothesis)
        let otherRecall = otherReference == 0
            ? nil
            : Double(otherCorrect) / Double(otherReference)
        let unknownRate = totalReference == 0
            ? (unknown == 0 ? 0 : 1)
            : Double(unknown) / Double(totalReference)
        let overflowDetectionRecall = otherReference == 0
            ? nil
            : Double(overflowDetected) / Double(otherReference)
        let overlapRecall = referenceOverlap == 0
            ? nil
            : Double(detectedOverlap) / Double(referenceOverlap)

        return CollapsedDiarizationMetrics(
            totalReferenceSpeakerMilliseconds: totalReference,
            missMilliseconds: miss,
            falseAlarmMilliseconds: falseAlarm,
            confusionMilliseconds: confusion,
            unknownMilliseconds: unknown,
            otherToTrackedLeakageMilliseconds: otherToTracked,
            trackedToOtherLeakageMilliseconds: trackedToOther,
            trackedSpeakerConfusionMilliseconds:
                trackedSpeakerConfusion,
            referenceOverlapMilliseconds: referenceOverlap,
            detectedOverlapMilliseconds: detectedOverlap,
            otherPrecision: otherPrecision,
            otherRecall: otherRecall,
            unknownRate: unknownRate,
            overflowDetectionRecall: overflowDetectionRecall,
            overlapRecall: overlapRecall,
            der: der
        )
    }

    private static func activeSpeakers(
        in range: Range<Int64>,
        spans: [SpeakerEvaluationSpan]
    ) -> Set<SpeakerIdentity> {
        Set(
            spans.lazy
                .filter {
                    $0.startMilliseconds < range.upperBound
                        && $0.endMilliseconds > range.lowerBound
                }
                .map(\.speaker)
        )
    }
}

public struct StandardDiarizationMetrics:
    Codable, Sendable, Equatable
{
    public let totalReferenceSpeakerMilliseconds: Int64
    public let missMilliseconds: Int64
    public let falseAlarmMilliseconds: Int64
    public let confusionMilliseconds: Int64
    public let referenceOverlapMilliseconds: Int64
    public let detectedOverlapMilliseconds: Int64
    public let overlapRecall: Double?
    public let speakerSwitchBoundaryMAEMilliseconds: Double?
    public let der: Double

    enum CodingKeys: String, CodingKey {
        case totalReferenceSpeakerMilliseconds =
            "total_reference_speaker_ms"
        case missMilliseconds = "miss_ms"
        case falseAlarmMilliseconds = "false_alarm_ms"
        case confusionMilliseconds = "confusion_ms"
        case referenceOverlapMilliseconds =
            "reference_overlap_ms"
        case detectedOverlapMilliseconds =
            "detected_overlap_ms"
        case overlapRecall = "overlap_recall"
        case speakerSwitchBoundaryMAEMilliseconds =
            "speaker_switch_boundary_mae_ms"
        case der
    }
}

public enum StandardDiarizationEvaluator {
    public static func evaluate(
        reference: [SourceSpeakerSpan],
        hypothesis: [SourceSpeakerSpan]
    ) -> StandardDiarizationMetrics {
        let all = reference + hypothesis
        let boundaries = Array(
            Set(
                all.flatMap {
                    [$0.startMilliseconds, $0.endMilliseconds]
                }
            )
        ).sorted()

        var totalReference: Int64 = 0
        var miss: Int64 = 0
        var falseAlarm: Int64 = 0
        var paired: Int64 = 0
        var referenceOverlap: Int64 = 0
        var detectedOverlap: Int64 = 0
        var overlapByPair: [SpeakerPair: Int64] = [:]
        var referenceLabels = Set<String>()
        var hypothesisLabels = Set<String>()

        for index in 0..<max(boundaries.count - 1, 0) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            let duration = end - start
            guard duration > 0 else { continue }

            let ref = activeLabels(
                in: start..<end,
                spans: reference
            )
            let hyp = activeLabels(
                in: start..<end,
                spans: hypothesis
            )

            referenceLabels.formUnion(ref)
            hypothesisLabels.formUnion(hyp)
            totalReference += Int64(ref.count) * duration
            miss +=
                Int64(max(ref.count - hyp.count, 0)) * duration
            falseAlarm +=
                Int64(max(hyp.count - ref.count, 0)) * duration
            paired +=
                Int64(min(ref.count, hyp.count)) * duration

            if ref.count >= 2 {
                referenceOverlap += duration
                if hyp.count >= 2 {
                    detectedOverlap += duration
                }
            }

            for referenceLabel in ref {
                for hypothesisLabel in hyp {
                    overlapByPair[
                        SpeakerPair(
                            reference: referenceLabel,
                            hypothesis: hypothesisLabel
                        ),
                        default: 0
                    ] += duration
                }
            }
        }

        let mappedOverlap = maximumMappedOverlap(
            referenceLabels: Array(referenceLabels),
            hypothesisLabels: Array(hypothesisLabels),
            overlapByPair: overlapByPair
        )
        let confusion = max(paired - mappedOverlap, 0)
        let error = miss + falseAlarm + confusion
        let der = totalReference == 0
            ? (error == 0 ? 0 : 1)
            : Double(error) / Double(totalReference)
        let overlapRecall = referenceOverlap == 0
            ? nil
            : Double(detectedOverlap) / Double(referenceOverlap)
        let switchBoundaryMAE = switchBoundaryMAE(
            reference: reference,
            hypothesis: hypothesis
        )

        return StandardDiarizationMetrics(
            totalReferenceSpeakerMilliseconds: totalReference,
            missMilliseconds: miss,
            falseAlarmMilliseconds: falseAlarm,
            confusionMilliseconds: confusion,
            referenceOverlapMilliseconds: referenceOverlap,
            detectedOverlapMilliseconds: detectedOverlap,
            overlapRecall: overlapRecall,
            speakerSwitchBoundaryMAEMilliseconds:
                switchBoundaryMAE,
            der: der
        )
    }

    private struct SpeakerPair: Hashable {
        let reference: String
        let hypothesis: String
    }

    private static func normalizedLabel(_ label: String) -> String? {
        let normalized = label.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized.isEmpty ? nil : normalized
    }

    private static func activeLabels(
        in range: Range<Int64>,
        spans: [SourceSpeakerSpan]
    ) -> Set<String> {
        Set(
            spans.lazy.compactMap { span in
                guard
                    span.startMilliseconds < range.upperBound,
                    span.endMilliseconds > range.lowerBound
                else {
                    return nil
                }
                return normalizedLabel(span.speakerLabel)
            }
        )
    }

    private static func maximumMappedOverlap(
        referenceLabels: [String],
        hypothesisLabels: [String],
        overlapByPair: [SpeakerPair: Int64]
    ) -> Int64 {
        guard
            !referenceLabels.isEmpty,
            !hypothesisLabels.isEmpty
        else {
            return 0
        }

        let referenceIsSmaller =
            referenceLabels.count <= hypothesisLabels.count
        let smaller = referenceIsSmaller
            ? referenceLabels
            : hypothesisLabels
        let larger = referenceIsSmaller
            ? hypothesisLabels
            : referenceLabels

        var scores: [Int: Int64] = [0: 0]
        for largerLabel in larger {
            var next = scores
            for (mask, current) in scores {
                for (
                    smallIndex,
                    smallerLabel
                ) in smaller.enumerated() {
                    let bit = 1 << smallIndex
                    guard mask & bit == 0 else { continue }

                    let pair = referenceIsSmaller
                        ? SpeakerPair(
                            reference: smallerLabel,
                            hypothesis: largerLabel
                        )
                        : SpeakerPair(
                            reference: largerLabel,
                            hypothesis: smallerLabel
                        )
                    let candidate = current
                        + overlapByPair[pair, default: 0]
                    let newMask = mask | bit
                    next[newMask] = max(
                        next[newMask, default: 0],
                        candidate
                    )
                }
            }
            scores = next
        }
        return scores.values.max() ?? 0
    }

    private static func switchBoundaries(
        in spans: [SourceSpeakerSpan]
    ) -> [Int64] {
        let boundaries = Array(
            Set(
                spans.flatMap {
                    [$0.startMilliseconds, $0.endMilliseconds]
                }
            )
        ).sorted()
        guard boundaries.count >= 3 else { return [] }

        var result: [Int64] = []
        for index in 1..<(boundaries.count - 1) {
            let boundary = boundaries[index]
            let before = activeLabels(
                in: boundaries[index - 1]..<boundary,
                spans: spans
            )
            let after = activeLabels(
                in: boundary..<boundaries[index + 1],
                spans: spans
            )
            if !before.isEmpty,
               !after.isEmpty,
               before != after {
                result.append(boundary)
            }
        }
        return result
    }

    private static func switchBoundaryMAE(
        reference: [SourceSpeakerSpan],
        hypothesis: [SourceSpeakerSpan]
    ) -> Double? {
        let referenceBoundaries =
            switchBoundaries(in: reference)
        guard !referenceBoundaries.isEmpty else {
            return nil
        }

        let hypothesisBoundaries =
            switchBoundaries(in: hypothesis)
        guard !hypothesisBoundaries.isEmpty else {
            return nil
        }

        let totalError = referenceBoundaries.reduce(Int64(0)) {
            partial, boundary in
            let nearest = hypothesisBoundaries
                .map { abs($0 - boundary) }
                .min() ?? 0
            return partial + nearest
        }
        return Double(totalError)
            / Double(referenceBoundaries.count)
    }
}

