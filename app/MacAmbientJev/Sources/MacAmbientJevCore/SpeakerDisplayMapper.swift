import Foundation

public enum SpeakerDisplayMapper {
    public static func makeLabels(
        spans: [SpeakerSpan],
        limit: Int = 4
    ) -> [String: String] {
        var spansBySpeaker: [String: [SpeakerSpan]] = [:]
        for span in spans where span.startFrame < span.endFrame {
            spansBySpeaker[span.speakerID, default: []].append(span)
        }

        let ranked = spansBySpeaker.map { speakerID, speakerSpans in
            let ordered = speakerSpans.sorted {
                if $0.startFrame != $1.startFrame {
                    return $0.startFrame < $1.startFrame
                }
                return $0.endFrame < $1.endFrame
            }

            var unioned: [(start: Int64, end: Int64)] = []
            for span in ordered {
                if let last = unioned.last, span.startFrame <= last.end {
                    unioned[unioned.count - 1].end = max(last.end, span.endFrame)
                } else {
                    unioned.append((span.startFrame, span.endFrame))
                }
            }

            let duration = unioned.reduce(Int64(0)) { total, interval in
                total + interval.end - interval.start
            }
            return (
                speakerID: speakerID,
                duration: duration,
                firstStart: unioned.first?.start ?? .max
            )
        }
        .sorted { lhs, rhs in
            if lhs.duration != rhs.duration {
                return lhs.duration > rhs.duration
            }
            if lhs.firstStart != rhs.firstStart {
                return lhs.firstStart < rhs.firstStart
            }
            return lhs.speakerID < rhs.speakerID
        }

        let individualLimit = max(0, limit)
        return Dictionary(uniqueKeysWithValues: ranked.enumerated().map { index, speaker in
            let label = index < individualLimit ? "話者\(index + 1)" : "その他"
            return (speaker.speakerID, label)
        })
    }

    public static func label(for rawID: String?, labels: [String: String]) -> String {
        guard let rawID else { return "話者不明" }
        return labels[rawID] ?? "その他"
    }
}
