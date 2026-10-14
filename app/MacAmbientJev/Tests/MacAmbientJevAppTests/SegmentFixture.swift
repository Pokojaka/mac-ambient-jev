import Foundation
@testable import MacAmbientJevCore

extension MaterializedTranscriptSegment {
    /// A materialized row built directly, as the materializer would for an ASR event `asrEventSeq`.
    static func fixture(
        segmentID: String, startMilliseconds: Int64, endMilliseconds: Int64,
        text: String, speakers: [MaterializedSpeakerSpan], isDiarized: Bool,
        asrEventSeq: UInt64 = 1,
        clauseState: TranscriptClauseState? = nil,
        clauseSlices: [ClauseRowSlice] = []
    ) throws -> MaterializedTranscriptSegment {
        try MaterializedTranscriptSegment(
            segmentID: segmentID,
            source: try SegmentTextReference(
                segmentationRunID: "seg", segmentID: segmentID, asrRunID: "asr", asrEventSeq: asrEventSeq
            ),
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            text: text,
            textProjection: try TranscriptTextProjector(detector: FillerTextSpanDetector()).project(sourceText: text),
            speakers: speakers,
            clauseState: clauseState ?? (ASRRecognitionOutcome(text: text) == .recognized ? .boundaryPending : nil),
            clauseSlices: clauseSlices,
            isDiarized: isDiarized
        )
    }
}
