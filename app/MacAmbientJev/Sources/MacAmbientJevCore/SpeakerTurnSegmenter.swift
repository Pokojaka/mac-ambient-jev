import Foundation

public enum SpeakerTurnSegmentationError: Error, Equatable {
    case invalidSampleRate
    case invalidSegment(String)
    case duplicateSegmentID(String)
    case invalidSpeakerSpan(Int)
}

/// Splits VAD ranges only when a clean, sufficiently long speaker change can be established.
public enum SpeakerTurnSegmenter {
    private static let minimumEvidenceSeconds = 0.3
    private static let minimumChunkSeconds = 0.3

    private struct Atom {
        let start: Int64
        let end: Int64
        let speakers: Set<String>
    }

    public static func split(
        _ segments: [SegmentReference],
        speakerSpans: [SpeakerSpan],
        sampleRate: Double
    ) throws -> [SegmentReference] {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw SpeakerTurnSegmentationError.invalidSampleRate
        }

        var ids = Set<String>()
        for segment in segments {
            guard segment.startFrame >= 0, segment.endFrame > segment.startFrame,
                  !segment.segmentationRunID.isEmpty, !segment.segmentID.isEmpty else {
                throw SpeakerTurnSegmentationError.invalidSegment(segment.segmentID)
            }
            guard ids.insert(segment.segmentID).inserted else {
                throw SpeakerTurnSegmentationError.duplicateSegmentID(segment.segmentID)
            }
        }
        // Generated child IDs share the caller's namespace; fail explicitly if one
        // would collide with another parent or previously generated child.
        var outputIDs = Set<String>()
        for (index, span) in speakerSpans.enumerated() {
            guard !span.speakerID.isEmpty, span.startFrame >= 0, span.endFrame > span.startFrame,
                  span.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
                throw SpeakerTurnSegmentationError.invalidSpeakerSpan(index)
            }
        }

        var output: [SegmentReference] = []
        var outputByParent: [[SegmentReference]] = []
        for segment in segments {
            let cuts = candidateCuts(in: segment, spans: speakerSpans, sampleRate: sampleRate)
                .filter { $0 > segment.startFrame && $0 < segment.endFrame }
                .sorted()
            var boundaries = [segment.startFrame]
            for cut in cuts where cut > (boundaries.last ?? segment.startFrame) {
                // Reject any cut that would create a child shorter than the ASR minimum.
                let minimumFrames = Int64(ceil(minimumChunkSeconds * sampleRate))
                guard cut - (boundaries.last ?? segment.startFrame) >= minimumFrames,
                      segment.endFrame - cut >= minimumFrames else { continue }
                boundaries.append(cut)
            }
            boundaries.append(segment.endFrame)
            guard boundaries.count > 2 else {
                guard outputIDs.insert(segment.segmentID).inserted else {
                    throw SpeakerTurnSegmentationError.duplicateSegmentID(segment.segmentID)
                }
                output.append(segment)
                outputByParent.append([segment])
                continue
            }
            var children: [SegmentReference] = []
            for index in 0..<(boundaries.count - 1) {
                let id = childID(parentID: segment.segmentID, index: index + 1)
                guard outputIDs.insert(id).inserted else {
                    throw SpeakerTurnSegmentationError.duplicateSegmentID(id)
                }
                let child = SegmentReference(
                    segmentationRunID: segment.segmentationRunID,
                    segmentID: id,
                    startFrame: boundaries[index],
                    endFrame: boundaries[index + 1]
                )
                output.append(child)
                children.append(child)
            }
            outputByParent.append(children)
        }
        // Defensive invariant check: each parent's generated ranges are built from
        // adjacent boundaries, so no samples may be omitted or repeated.
        for (parent, children) in zip(segments, outputByParent) {
            guard children.first?.startFrame == parent.startFrame,
                  children.last?.endFrame == parent.endFrame,
                  zip(children, children.dropFirst()).allSatisfy({ $0.endFrame == $1.startFrame }) else {
                throw SpeakerTurnSegmentationError.invalidSegment(parent.segmentID)
            }
        }
        return output
    }

    private static func candidateCuts(
        in segment: SegmentReference,
        spans: [SpeakerSpan],
        sampleRate: Double
    ) -> [Int64] {
        let relevant = spans.filter { $0.endFrame > segment.startFrame && $0.startFrame < segment.endFrame }
        guard relevant.count > 1 else { return [] }
        let endpoints = Set([segment.startFrame, segment.endFrame] + relevant.flatMap {
            [max(segment.startFrame, $0.startFrame), min(segment.endFrame, $0.endFrame)]
        }).sorted()
        guard endpoints.count > 1 else { return [] }

        var atoms: [Atom] = []
        for i in 0..<(endpoints.count - 1) where endpoints[i + 1] > endpoints[i] {
            let start = endpoints[i], end = endpoints[i + 1]
            let active = Set(relevant.filter { $0.startFrame < end && $0.endFrame > start }.map(\.speakerID))
            atoms.append(Atom(start: start, end: end, speakers: active))
        }

        // A change is valid only between singleton speaker regions. Empty atoms may
        // separate them; any overlapping or nested speaker region makes it ambiguous.
        var candidates: [Int64] = []
        for leftIndex in atoms.indices where atoms[leftIndex].speakers.count == 1 {
            let left = atoms[leftIndex]
            var rightIndex = leftIndex + 1
            while rightIndex < atoms.count && atoms[rightIndex].speakers.isEmpty { rightIndex += 1 }
            guard rightIndex < atoms.count else { continue }
            let right = atoms[rightIndex]
            guard right.speakers.count == 1,
                  left.speakers != right.speakers,
                  !atoms[(leftIndex + 1)..<rightIndex].contains(where: { !$0.speakers.isEmpty }) else { continue }

            let leftID = left.speakers.first!, rightID = right.speakers.first!
            // Require each voice to have at least 300 ms of evidence in its local run.
            let leftEvidence = contiguousEvidence(around: leftIndex, atoms: atoms, speakerID: leftID, direction: -1)
            let rightEvidence = contiguousEvidence(around: rightIndex, atoms: atoms, speakerID: rightID, direction: 1)
            let minimumEvidence = Int64(ceil(minimumEvidenceSeconds * sampleRate))
            guard leftEvidence >= minimumEvidence, rightEvidence >= minimumEvidence else { continue }

            let cut: Int64
            if left.end == right.start { cut = left.end }
            else { cut = left.end + (right.start - left.end) / 2 }
            guard cut > segment.startFrame, cut < segment.endFrame else { continue }
            candidates.append(cut)
        }
        return Array(Set(candidates)).sorted()
    }

    private static func contiguousEvidence(
        around index: Int,
        atoms: [Atom],
        speakerID: String,
        direction: Int
    ) -> Int64 {
        var total: Int64 = 0
        var cursor = index
        while atoms.indices.contains(cursor), atoms[cursor].speakers == [speakerID] {
            total += atoms[cursor].end - atoms[cursor].start
            cursor += direction
        }
        return total
    }

    private static func childID(parentID: String, index: Int) -> String {
        "\(parentID)_turn_\(String(format: "%04d", index))"
    }
}
