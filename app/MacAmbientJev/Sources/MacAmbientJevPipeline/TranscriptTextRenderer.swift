import Foundation
import MacAmbientJevCore

/// Writes the rows the screen shows, one line per utterance:
/// `[mm:ss] <text with line breaks replaced by spaces>`.
public enum TranscriptTextRenderer {
    public static func render(_ segments: [MaterializedTranscriptSegment]) throws -> String {
        try LiveTranscriptProjection().rows(for: segments).map { row in
            let totalSeconds = row.startMilliseconds / 1000
            let time = String(format: "%02lld:%02lld", totalSeconds / 60, totalSeconds % 60)
            return "[\(time)] \(singleLine(row.text))\n"
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
