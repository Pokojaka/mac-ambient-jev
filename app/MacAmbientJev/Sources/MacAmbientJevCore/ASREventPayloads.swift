import Foundation

public enum ASRRecognitionOutcome: String, Codable, Sendable, Equatable {
    case recognized
    case empty

    /// The single rule for "the engine produced no text": empty after trimming whitespace/newlines.
    public init(text: String) {
        self = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .recognized
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
