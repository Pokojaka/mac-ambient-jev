import Foundation

public enum ContentPriority: String, Codable, Sendable, Equatable {
    case primary
    case lowPriority
}

public struct SpeakerSpan: Codable, Sendable, Equatable {
    public let speakerID: String
    public let startFrame: Int64
    public let endFrame: Int64
    public let confidence: Double?

    public init(speakerID: String, startFrame: Int64, endFrame: Int64, confidence: Double?) {
        self.speakerID = speakerID
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.confidence = confidence
    }
}
