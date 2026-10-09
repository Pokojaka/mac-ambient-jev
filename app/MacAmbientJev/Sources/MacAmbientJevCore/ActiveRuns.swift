import Foundation

public enum ProcessingStage: String, Codable, Sendable, Hashable {
    case segmentation
    case asr
    case diarization
    /// Optional external stage: Jev clause boundaries.
    case clauseBoundary
    /// Optional external stage: Jev clause priorities.
    case contentPriority
}

public enum ActiveRunsError: Error, Equatable {
    case runNotSuccessfullyCompleted(stage: ProcessingStage, runID: String)
}

private struct RunKey: Hashable, Sendable {
    let stage: ProcessingStage
    let runID: String
}

public struct ActiveRuns: Codable, Sendable, Equatable {
    public private(set) var segmentation: String?
    public private(set) var asr: String?
    public private(set) var diarization: String?
    public private(set) var clauseBoundary: String?
    public private(set) var contentPriority: String?

    private var successfulRuns: Set<RunKey>

    private enum CodingKeys: String, CodingKey {
        case segmentation
        case asr
        case diarization
        case clauseBoundary = "clause_boundary"
        case contentPriority = "content_priority"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.segmentation = try container.decodeIfPresent(String.self, forKey: .segmentation)
        self.asr = try container.decodeIfPresent(String.self, forKey: .asr)
        self.diarization = try container.decodeIfPresent(String.self, forKey: .diarization)
        self.clauseBoundary = try container.decodeIfPresent(String.self, forKey: .clauseBoundary)
        self.contentPriority = try container.decodeIfPresent(String.self, forKey: .contentPriority)
        self.successfulRuns = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(segmentation, forKey: .segmentation)
        try container.encodeIfPresent(asr, forKey: .asr)
        try container.encodeIfPresent(diarization, forKey: .diarization)
        try container.encodeIfPresent(clauseBoundary, forKey: .clauseBoundary)
        try container.encodeIfPresent(contentPriority, forKey: .contentPriority)
    }

    public init(
        segmentation: String? = nil,
        asr: String? = nil,
        diarization: String? = nil,
        clauseBoundary: String? = nil,
        contentPriority: String? = nil
    ) {
        self.segmentation = segmentation
        self.asr = asr
        self.diarization = diarization
        self.clauseBoundary = clauseBoundary
        self.contentPriority = contentPriority
        self.successfulRuns = []
    }

    /// The same local runs with the given Jev runs.
    public func withJevRuns(clauseBoundary: String?, contentPriority: String?) -> ActiveRuns {
        ActiveRuns(
            segmentation: segmentation, asr: asr, diarization: diarization,
            clauseBoundary: clauseBoundary, contentPriority: contentPriority
        )
    }

    /// True when both name the same run for every stage.
    public func selectsSameRuns(as other: ActiveRuns) -> Bool {
        segmentation == other.segmentation && asr == other.asr && diarization == other.diarization
            && clauseBoundary == other.clauseBoundary && contentPriority == other.contentPriority
    }

    public mutating func markCompleted(
        stage: ProcessingStage,
        runID: String,
        succeeded: Bool
    ) {
        let key = RunKey(stage: stage, runID: runID)
        if succeeded {
            successfulRuns.insert(key)
        } else {
            successfulRuns.remove(key)
        }
    }

    public mutating func select(stage: ProcessingStage, runID: String) throws {
        let key = RunKey(stage: stage, runID: runID)
        guard successfulRuns.contains(key) else {
            throw ActiveRunsError.runNotSuccessfullyCompleted(stage: stage, runID: runID)
        }

        switch stage {
        case .segmentation: segmentation = runID
        case .asr: asr = runID
        case .diarization: diarization = runID
        case .clauseBoundary: clauseBoundary = runID
        case .contentPriority: contentPriority = runID
        }
    }
}
