import Foundation

public enum ContentPriority: String, Codable, Sendable, Equatable {
    case primary
    case lowPriority
}

public enum SceneState: String, Codable, Sendable, Equatable {
    case unknown
    case lecture
    case discussionCandidate
    case discussion
    case lectureCandidate
}

public enum AcousticScope: String, Codable, Sendable, Equatable {
    case near
    case background
    case unknown
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

public struct ScopeSpan: Codable, Sendable, Equatable {
    public let startFrame: Int64
    public let endFrame: Int64
    public let scope: AcousticScope
    public let confidence: Double

    public init(startFrame: Int64, endFrame: Int64, scope: AcousticScope, confidence: Double) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.scope = scope
        self.confidence = confidence
    }
}
