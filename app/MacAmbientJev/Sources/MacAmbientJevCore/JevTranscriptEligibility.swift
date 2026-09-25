import Foundation

/// Keeps empty ASR output and the app's no-recognition placeholder out of Jev requests.
public enum JevTranscriptEligibility {
    public static func isEligible(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let withoutPunctuation = trimmed.trimmingCharacters(
            in: .punctuationCharacters.union(.whitespacesAndNewlines)
        )
        return withoutPunctuation != "聞き取れませんでした"
            && withoutPunctuation != "認識できませんでした"
    }
}
