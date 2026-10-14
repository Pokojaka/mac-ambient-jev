import Foundation

public enum ASRRecognitionOutcome: String, Codable, Sendable, Equatable {
    case recognized
    case empty

    /// An ASR result is empty only when every Unicode scalar is whitespace, a newline, or punctuation.
    public init(text: String) {
        let emptyCharacters = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        self = text.unicodeScalars.allSatisfy { emptyCharacters.contains($0) } ? .empty : .recognized
    }
}

public enum ASRFailureKind: String, Codable, Sendable, Equatable {
    case engineUnavailable = "engine_unavailable"
    case audioUnreadable = "audio_unreadable"
    case transcriptionFailed = "transcription_failed"
}

public struct ASRCompletedEventPayload: Codable, Sendable, Equatable {
    public let text: String
    public let detectedLanguage: String?
    public let engine: String
    public let model: String?
    public let outcome: ASRRecognitionOutcome

    /// `engine` and `model` come from the provenance of the engine that produced `text`.
    public init(
        text: String,
        detectedLanguage: String?,
        provenance: RunProvenance
    ) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.engine = provenance.engine
        self.model = provenance.model
        self.outcome = ASRRecognitionOutcome(text: text)
    }
}

public struct ASRFailedEventPayload: Codable, Sendable, Equatable {
    public let kind: ASRFailureKind
    public let message: String

    public init(kind: ASRFailureKind, message: String) {
        self.kind = kind
        self.message = message
    }
}
