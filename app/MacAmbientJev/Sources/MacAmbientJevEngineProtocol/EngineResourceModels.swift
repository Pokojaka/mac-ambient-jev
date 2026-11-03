import Foundation

private func engineResourceRequireNonempty(_ value: String, _ field: String) throws {
    guard !value.isEmpty else { throw EngineProtocolError.invalidJSON("\(field) must not be empty") }
}

public enum EngineResourceWorkload: String, Codable, CaseIterable, Equatable, Sendable {
    case load
    case live
    case finalization
}

public enum EngineResourceReadiness: String, Codable, CaseIterable, Equatable, Sendable {
    case ready
    case warning
    case blocked
}

public enum EngineResourceReason: String, Codable, CaseIterable, Equatable, Sendable {
    case ready
    case unsupportedCPUCount = "unsupported_cpu_count"
    case invalidThreads = "invalid_threads"
    case lowMemory = "low_memory"
    case insufficientPhysicalMemory = "insufficient_physical_memory"
    case insufficientCommitHeadroom = "insufficient_commit_headroom"
    case envelopeUnmeasured = "envelope_unmeasured"
    case envelopeStale = "envelope_stale"
    case rtfUnmeasured = "rtf_unmeasured"
    case rtfStale = "rtf_stale"
    case liveTooSlow = "live_too_slow"
}

public struct EngineResourcesPreflightPayload: Codable, Equatable, Sendable {
    public let workload: EngineResourceWorkload

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case workload
    }

    public init(workload: EngineResourceWorkload) {
        self.workload = workload
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        self.init(workload: try container.decode(EngineResourceWorkload.self, forKey: .workload))
    }
}

public struct EngineResourcesAcknowledgePayload: Codable, Equatable, Sendable {
    public let assessmentID: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case assessmentID = "assessment_id"
    }

    public init(assessmentID: String) throws {
        try engineResourceRequireNonempty(assessmentID, "assessment_id")
        self.assessmentID = assessmentID
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(assessmentID: container.decode(String.self, forKey: .assessmentID))
    }
}

public struct EngineResourceAssessment: Codable, Equatable, Sendable {
    public let assessmentID: String
    public let result: EngineResourceReadiness
    public let reason: EngineResourceReason
    public let explanation: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case assessmentID = "assessment_id"
        case result
        case reason
        case explanation
    }

    public init(assessmentID: String, result: EngineResourceReadiness,
                reason: EngineResourceReason, explanation: String) throws {
        try engineResourceRequireNonempty(assessmentID, "assessment_id")
        try engineResourceRequireNonempty(explanation, "explanation")
        self.assessmentID = assessmentID
        self.result = result
        self.reason = reason
        self.explanation = explanation
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            assessmentID: container.decode(String.self, forKey: .assessmentID),
            result: container.decode(EngineResourceReadiness.self, forKey: .result),
            reason: container.decode(EngineResourceReason.self, forKey: .reason),
            explanation: container.decode(String.self, forKey: .explanation)
        )
    }
}
