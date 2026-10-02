import Foundation

public enum SpeakerDisplayMapper {
    public static let individualSpeakerLimit = 7
    public static let other = "OTHER"
    public static let unknown = "UNKNOWN"

    public static func makeLabels(spans: [SpeakerSpan]) -> [String: String] {
        var firstStartBySpeaker: [String: Int64] = [:]
        for span in spans where span.startFrame < span.endFrame {
            firstStartBySpeaker[span.speakerID] = min(
                firstStartBySpeaker[span.speakerID] ?? .max,
                span.startFrame
            )
        }

        let ordered = firstStartBySpeaker.sorted { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value < rhs.value
            }
            return lhs.key < rhs.key
        }

        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, speaker in
            let label = index < individualSpeakerLimit ? "Speaker \(index + 1)" : other
            return (speaker.key, label)
        })
    }

    public static func label(for rawID: String, labels: [String: String]) -> String {
        labels[rawID] ?? unknown
    }

    /// Heading for one diarized segment: the speaker covering at least 80% of the
    /// overlapped time, otherwise every overlapping speaker in order of appearance,
    /// and `UNKNOWN` when no speaker span overlaps the segment.
    public static func turnLabels(
        for segment: MaterializedTranscriptSegment,
        labels: [String: String]
    ) -> [String] {
        var overlapBySpeaker: [String: Int64] = [:]
        for span in segment.speakers {
            let overlap = min(segment.endMilliseconds, span.endMilliseconds)
                - max(segment.startMilliseconds, span.startMilliseconds)
            if overlap > 0 { overlapBySpeaker[span.id, default: 0] += overlap }
        }
        let total = overlapBySpeaker.values.reduce(Int64.zero, +)
        guard total > 0 else { return [unknown] }

        func displayLabel(_ rawID: String) -> String {
            segment.speakers.first(where: { $0.id == rawID })?.displayLabel
                ?? label(for: rawID, labels: labels)
        }

        if let dominant = overlapBySpeaker.max(by: { $0.value < $1.value }),
           Double(dominant.value) / Double(total) >= 0.8 {
            return [displayLabel(dominant.key)]
        }

        var result: [String] = []
        for span in segment.speakers.sorted(by: { $0.startMilliseconds < $1.startMilliseconds })
        where overlapBySpeaker[span.id] != nil {
            let spanLabel = displayLabel(span.id)
            if !result.contains(spanLabel) { result.append(spanLabel) }
        }
        return result
    }
}
