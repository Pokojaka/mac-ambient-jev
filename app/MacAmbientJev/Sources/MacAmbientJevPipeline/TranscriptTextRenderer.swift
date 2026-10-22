import Foundation
import MacAmbientJevCore

public enum TranscriptTextRendererError: Error, LocalizedError, Equatable {
    case missingSpeakerHeading(segmentID: String)

    public var errorDescription: String? {
        switch self {
        case .missingSpeakerHeading(let segmentID):
            "話者分離されていない発話（\(segmentID)）があるため書き出せません"
        }
    }
}

/// Writes the rows the screen shows, one line per utterance:
/// `[mm:ss] <speakers joined by " / ">: <text with line breaks replaced by spaces>`.
public enum TranscriptTextRenderer {
    public static func render(_ segments: [MaterializedTranscriptSegment]) throws -> String {
        try LiveTranscriptProjection().rows(for: segments).map { row in
            guard !row.displaySpeakerLabels.isEmpty else {
                throw TranscriptTextRendererError.missingSpeakerHeading(segmentID: row.segmentID)
            }
            let totalSeconds = row.startMilliseconds / 1000
            let time = String(format: "%02lld:%02lld", totalSeconds / 60, totalSeconds % 60)
            let speakers = row.displaySpeakerLabels.joined(separator: " / ")
            return "[\(time)] \(speakers): \(singleLine(row.text))\n"
        }
        .joined()
    }

    /// Each line break (CRLF, LF, CR, U+2028, U+2029) becomes one space.
    private static func singleLine(_ text: String) -> String {
        String(text.map { character in
            character.isNewline ? " " : character
        })
    }
}
