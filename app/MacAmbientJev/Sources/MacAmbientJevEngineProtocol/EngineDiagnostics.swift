import Foundation

private func engineDiagnosticsRequire(_ condition: Bool, _ reason: String) throws {
    guard condition else {
        throw EngineProtocolError.invalidJSON(reason)
    }
}

private func engineDiagnosticsRequireNonnegative(_ value: Int, _ field: String) throws {
    try engineDiagnosticsRequire(value >= 0, "\(field) must not be negative")
}

private func engineDiagnosticsSum(_ lhs: Int, _ rhs: Int, _ field: String) throws -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    try engineDiagnosticsRequire(!overflow, "\(field) overflow")
    return sum
}

public struct EngineDecisionRequestUsage: Codable, Equatable, Sendable {
    public let sendCount: Int
    public let inputTokens: Int
    public let successCount: Int
    public let failureCount: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sendCount = "send_count"
        case inputTokens = "input_tokens"
        case successCount = "success_count"
        case failureCount = "failure_count"
    }

    public init(sendCount: Int, inputTokens: Int, successCount: Int, failureCount: Int) throws {
        try engineDiagnosticsRequireNonnegative(sendCount, "send_count")
        try engineDiagnosticsRequireNonnegative(inputTokens, "input_tokens")
        try engineDiagnosticsRequireNonnegative(successCount, "success_count")
        try engineDiagnosticsRequireNonnegative(failureCount, "failure_count")
        let completedCount = try engineDiagnosticsSum(successCount, failureCount, "success_count + failure_count")
        try engineDiagnosticsRequire(completedCount <= sendCount, "success_count + failure_count must not exceed send_count")

        self.sendCount = sendCount
        self.inputTokens = inputTokens
        self.successCount = successCount
        self.failureCount = failureCount
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            sendCount: container.decode(Int.self, forKey: .sendCount),
            inputTokens: container.decode(Int.self, forKey: .inputTokens),
            successCount: container.decode(Int.self, forKey: .successCount),
            failureCount: container.decode(Int.self, forKey: .failureCount)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sendCount, forKey: .sendCount)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(successCount, forKey: .successCount)
        try container.encode(failureCount, forKey: .failureCount)
    }
}

public struct EngineDecisionUsageSnapshot: Codable, Equatable, Sendable {
    public let sendCount: Int
    public let inputTokens: Int
    public let successCount: Int
    public let failureCount: Int
    public let pendingBoundarySegmentCount: Int
    public let pendingPriorityClauseCount: Int
    public let boundaryRequests: EngineDecisionRequestUsage
    public let priorityRequests: EngineDecisionRequestUsage

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sendCount = "send_count"
        case inputTokens = "input_tokens"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case pendingBoundarySegmentCount = "pending_boundary_segment_count"
        case pendingPriorityClauseCount = "pending_priority_clause_count"
        case boundaryRequests = "boundary_requests"
        case priorityRequests = "priority_requests"
    }

    public init(
        sendCount: Int,
        inputTokens: Int,
        successCount: Int,
        failureCount: Int,
        pendingBoundarySegmentCount: Int,
        pendingPriorityClauseCount: Int,
        boundaryRequests: EngineDecisionRequestUsage,
        priorityRequests: EngineDecisionRequestUsage
    ) throws {
        try engineDiagnosticsRequireNonnegative(sendCount, "send_count")
        try engineDiagnosticsRequireNonnegative(inputTokens, "input_tokens")
        try engineDiagnosticsRequireNonnegative(successCount, "success_count")
        try engineDiagnosticsRequireNonnegative(failureCount, "failure_count")
        try engineDiagnosticsRequireNonnegative(pendingBoundarySegmentCount, "pending_boundary_segment_count")
        try engineDiagnosticsRequireNonnegative(pendingPriorityClauseCount, "pending_priority_clause_count")

        try engineDiagnosticsRequire(
            sendCount == engineDiagnosticsSum(boundaryRequests.sendCount, priorityRequests.sendCount, "send_count"),
            "send_count must equal boundary_requests.send_count + priority_requests.send_count"
        )
        try engineDiagnosticsRequire(
            inputTokens == engineDiagnosticsSum(boundaryRequests.inputTokens, priorityRequests.inputTokens, "input_tokens"),
            "input_tokens must equal boundary_requests.input_tokens + priority_requests.input_tokens"
        )
        try engineDiagnosticsRequire(
            successCount == engineDiagnosticsSum(boundaryRequests.successCount, priorityRequests.successCount, "success_count"),
            "success_count must equal boundary_requests.success_count + priority_requests.success_count"
        )
        try engineDiagnosticsRequire(
            failureCount == engineDiagnosticsSum(boundaryRequests.failureCount, priorityRequests.failureCount, "failure_count"),
            "failure_count must equal boundary_requests.failure_count + priority_requests.failure_count"
        )

        self.sendCount = sendCount
        self.inputTokens = inputTokens
        self.successCount = successCount
        self.failureCount = failureCount
        self.pendingBoundarySegmentCount = pendingBoundarySegmentCount
        self.pendingPriorityClauseCount = pendingPriorityClauseCount
        self.boundaryRequests = boundaryRequests
        self.priorityRequests = priorityRequests
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            sendCount: container.decode(Int.self, forKey: .sendCount),
            inputTokens: container.decode(Int.self, forKey: .inputTokens),
            successCount: container.decode(Int.self, forKey: .successCount),
            failureCount: container.decode(Int.self, forKey: .failureCount),
            pendingBoundarySegmentCount: container.decode(Int.self, forKey: .pendingBoundarySegmentCount),
            pendingPriorityClauseCount: container.decode(Int.self, forKey: .pendingPriorityClauseCount),
            boundaryRequests: container.decode(EngineDecisionRequestUsage.self, forKey: .boundaryRequests),
            priorityRequests: container.decode(EngineDecisionRequestUsage.self, forKey: .priorityRequests)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sendCount, forKey: .sendCount)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(successCount, forKey: .successCount)
        try container.encode(failureCount, forKey: .failureCount)
        try container.encode(pendingBoundarySegmentCount, forKey: .pendingBoundarySegmentCount)
        try container.encode(pendingPriorityClauseCount, forKey: .pendingPriorityClauseCount)
        try container.encode(boundaryRequests, forKey: .boundaryRequests)
        try container.encode(priorityRequests, forKey: .priorityRequests)
    }
}

public enum EngineDecisionUsage: Codable, Equatable, Sendable {
    case available(EngineDecisionUsageSnapshot)
    case unavailable(EngineFailure)

    internal enum Kind: String, Codable, CaseIterable, Sendable {
        case available
        case unavailable

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let value = Self(rawValue: rawValue) else {
                throw EngineProtocolError.invalidJSON("unknown decision usage kind: \(rawValue)")
            }
            self = value
        }
    }

    internal var kind: Kind {
        switch self {
        case .available:
            .available
        case .unavailable:
            .unavailable
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case snapshot
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let dynamic = try decoder.container(keyedBy: EngineCodingKey.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .available:
            try engineDiagnosticsRequire(
                Set(dynamic.allKeys.map(\.stringValue)) == ["kind", "snapshot"],
                "available decision usage must contain only kind and snapshot"
            )
            self = .available(try container.decode(EngineDecisionUsageSnapshot.self, forKey: .snapshot))
        case .unavailable:
            try engineDiagnosticsRequire(
                Set(dynamic.allKeys.map(\.stringValue)) == ["kind", "error"],
                "unavailable decision usage must contain only kind and error"
            )
            self = .unavailable(try container.decode(EngineFailure.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case let .available(snapshot):
            try container.encode(snapshot, forKey: .snapshot)
        case let .unavailable(error):
            try container.encode(error, forKey: .error)
        }
    }
}

public enum EngineDiagnosticsScope: String, Codable, CaseIterable, Equatable, Sendable {
    case engineProcess = "engine_process"
}

public struct EngineDiagnosticsResult: Codable, Equatable, Sendable {
    public let scope: EngineDiagnosticsScope
    public let decisionUsage: EngineDecisionUsage
    public let automaticInputVolume: EngineUnavailableCapability
    public let thermalMonitoring: EngineUnavailableCapability

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case scope
        case decisionUsage = "decision_usage"
        case automaticInputVolume = "automatic_input_volume"
        case thermalMonitoring = "thermal_monitoring"
    }

    public init(
        scope: EngineDiagnosticsScope,
        decisionUsage: EngineDecisionUsage,
        automaticInputVolume: EngineUnavailableCapability,
        thermalMonitoring: EngineUnavailableCapability
    ) {
        self.scope = scope
        self.decisionUsage = decisionUsage
        self.automaticInputVolume = automaticInputVolume
        self.thermalMonitoring = thermalMonitoring
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        self.init(
            scope: try container.decode(EngineDiagnosticsScope.self, forKey: .scope),
            decisionUsage: try container.decode(EngineDecisionUsage.self, forKey: .decisionUsage),
            automaticInputVolume: try container.decode(EngineUnavailableCapability.self, forKey: .automaticInputVolume),
            thermalMonitoring: try container.decode(EngineUnavailableCapability.self, forKey: .thermalMonitoring)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scope, forKey: .scope)
        try container.encode(decisionUsage, forKey: .decisionUsage)
        try container.encode(automaticInputVolume, forKey: .automaticInputVolume)
        try container.encode(thermalMonitoring, forKey: .thermalMonitoring)
    }
}
