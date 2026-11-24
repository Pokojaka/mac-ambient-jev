import Foundation

/// The recognized sources of the published ASR run in time order, and what follows each.
struct SourceTimeline {
    enum Successor {
        case none
        case empty
        case missing
        case recognized(SegmentTextReference, String)
    }

    struct Entry {
        let source: SegmentTextReference
        let text: String
        let position: Int
    }

    /// Every segment of the active segmentation in time order, with its ASR result if any.
    private let segments: [(segmentID: String, result: (source: SegmentTextReference, text: String)?)]
    let sources: [Entry]
    private let texts: [SegmentTextReference: String]

    init(events: [TranscriptEvent], activeRuns: ActiveRuns) throws {
        guard let segmentationRunID = activeRuns.segmentation, activeRuns.asr != nil else {
            throw DecisionEnrichmentError.missingPublishedTranscript
        }
        var results: [String: (source: SegmentTextReference, text: String)] = [:]
        var created: [(segmentID: String, startFrame: Int64)] = []
        var createdIDs: Set<String> = []
        for event in events.sorted(by: { $0.eventSeq < $1.eventSeq }) {
            switch event.kind {
            case .segmentCreated where event.segmentationRunID == segmentationRunID:
                guard let segmentID = event.segmentID, let start = event.sourceStartFrame,
                      let end = event.sourceEndFrame, start >= 0, end > start,
                      createdIDs.insert(segmentID).inserted else {
                    throw DecisionEnrichmentError.invalidSourceTimeline
                }
                created.append((segmentID, start))
            case .asrCompleted(let result) where event.processingRunID == activeRuns.asr
                && event.segmentationRunID == segmentationRunID:
                guard let segmentID = event.segmentID, createdIDs.contains(segmentID),
                      let source = try event.asrSource() else {
                    throw DecisionEnrichmentError.invalidSourceTimeline
                }
                results[segmentID] = (source, result.text)
            default:
                break
            }
        }
        segments = created.sorted { $0.startFrame < $1.startFrame }.map { ($0.segmentID, results[$0.segmentID]) }
        var entries: [Entry] = []
        var texts: [SegmentTextReference: String] = [:]
        for (position, segment) in segments.enumerated() {
            guard let result = segment.result else { continue }
            texts[result.source] = result.text
            if ASRRecognitionOutcome(text: result.text) == .recognized {
                if let previous = entries.last, previous.source.asrEventSeq >= result.source.asrEventSeq {
                    throw DecisionEnrichmentError.invalidSourceTimeline
                }
                entries.append(Entry(source: result.source, text: result.text, position: position))
            }
        }
        sources = entries
        self.texts = texts
    }

    func successor(ofSourceAt index: Int) -> Successor {
        let next = sources[index].position + 1
        guard next < segments.count else { return .none }
        guard let result = segments[next].result else { return .missing }
        return ASRRecognitionOutcome(text: result.text) == .recognized ? .recognized(result.source, result.text) : .empty
    }

    /// An empty result since the preceding recognized source resets unresolved ranges,
    /// even when a missing ASR segment came between that source and the empty result.
    func hasEmptySeparator(beforeSourceAt index: Int) -> Bool {
        for position in stride(from: sources[index].position - 1, through: 0, by: -1) {
            guard let result = segments[position].result else { continue }
            return ASRRecognitionOutcome(text: result.text) != .recognized
        }
        return false
    }

    func hasMissingPredecessor(ofSourceAt index: Int) -> Bool {
        let position = sources[index].position
        return position > 0 && segments[position - 1].result == nil
    }

    func text(of source: SegmentTextReference) throws -> String {
        guard let text = texts[source] else { throw TranscriptMaterializationError.missingClauseSource }
        return text
    }
}
