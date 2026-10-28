import Foundation

private func engineEventRequire(_ condition: Bool, _ reason: String) throws {
    guard condition else {
        throw EngineProtocolError.invalidJSON(reason)
    }
}

private func engineEventRequireNonempty(_ value: String, _ field: String) throws {
    try engineEventRequire(!value.isEmpty, "\(field) must not be empty")
}

public struct EngineExportResult: Codable, Equatable, Sendable {
    public let sessionID: String
    public let destinationPath: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID = "session_id"
        case destinationPath = "destination_path"
    }

    public init(sessionID: String, destinationPath: String) throws {
        try engineEventRequireNonempty(sessionID, "session_id")
        try engineEventRequireNonempty(destinationPath, "destination_path")
        self.sessionID = sessionID
        self.destinationPath = destinationPath
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            destinationPath: container.decode(String.self, forKey: .destinationPath)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(destinationPath, forKey: .destinationPath)
    }
}

public enum EngineResult: Codable, Equatable, Sendable {
    case hello(EngineReadyPayload)
    case stateGet(EngineState)
    case diagnosticsGet(EngineDiagnosticsResult)
    case devicesList(EngineDevicesResult)
    case recordingStart(EngineSessionPayload)
    /// Completion means capture stopped durably and finalization was queued, not that the transcript is final.
    case recordingStop(EngineSessionPayload)
    /// Completion means the retained import was queued for finalization, not that the transcript is final.
    case sessionImport(EngineSessionPayload)
    case sessionInspect(EngineSessionSummary)
    /// Completion is terminal: the requested reprocessing work has finished.
    case sessionReprocess(EngineSessionPayload)
    /// Completion is terminal: the requested decision retry has finished.
    case sessionRetryDecisions(EngineSessionPayload)
    case sessionList(EngineSessionListResult)
    case transcriptRead(EngineTranscriptPage)
    case transcriptRowDetails(EngineTranscriptRowDetailsPage)
    case transcriptWatch(EngineTranscriptPage)
    /// Completion means the bundle has been published.
    case sessionExport(EngineExportResult)
    case settingsGet(EngineSettingsResult)
    case settingsReplace(EngineSettingsResult)
    case modelsPrepare
    case modelsInspect(EngineModelsInspection)
    case profilesEvaluate(EngineProfileEvaluation)
    case shutdown

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case command
        case result
    }

    public var command: EngineCommandName {
        switch self {
        case .hello: .hello
        case .stateGet: .stateGet
        case .diagnosticsGet: .diagnosticsGet
        case .devicesList: .devicesList
        case .recordingStart: .recordingStart
        case .recordingStop: .recordingStop
        case .sessionImport: .sessionImport
        case .sessionInspect: .sessionInspect
        case .sessionReprocess: .sessionReprocess
        case .sessionRetryDecisions: .sessionRetryDecisions
        case .sessionList: .sessionList
        case .transcriptRead: .transcriptRead
        case .transcriptRowDetails: .transcriptRowDetails
        case .transcriptWatch: .transcriptWatch
        case .sessionExport: .sessionExport
        case .settingsGet: .settingsGet
        case .settingsReplace: .settingsReplace
        case .modelsPrepare: .modelsPrepare
        case .modelsInspect: .modelsInspect
        case .profilesEvaluate: .profilesEvaluate
        case .shutdown: .shutdown
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let command = try container.decode(EngineCommandName.self, forKey: .command)
        self = try Self.decode(command: command, result: container.superDecoder(forKey: .result))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try encodeResult(to: container.superEncoder(forKey: .result))
    }

    static func decode(command: EngineCommandName, result: Decoder) throws -> EngineResult {
        switch command {
        case .hello:
            return .hello(try EngineReadyPayload(from: result))
        case .stateGet:
            return .stateGet(try EngineState(from: result))
        case .diagnosticsGet:
            return .diagnosticsGet(try EngineDiagnosticsResult(from: result))
        case .devicesList:
            return .devicesList(try EngineDevicesResult(from: result))
        case .recordingStart:
            return .recordingStart(try EngineSessionPayload(from: result))
        case .recordingStop:
            return .recordingStop(try EngineSessionPayload(from: result))
        case .sessionImport:
            return .sessionImport(try EngineSessionPayload(from: result))
        case .sessionInspect:
            return .sessionInspect(try EngineSessionSummary(from: result))
        case .sessionReprocess:
            return .sessionReprocess(try EngineSessionPayload(from: result))
        case .sessionRetryDecisions:
            return .sessionRetryDecisions(try EngineSessionPayload(from: result))
        case .sessionList:
            return .sessionList(try EngineSessionListResult(from: result))
        case .transcriptRead:
            return .transcriptRead(try EngineTranscriptPage(from: result))
        case .transcriptRowDetails:
            return .transcriptRowDetails(try EngineTranscriptRowDetailsPage(from: result))
        case .transcriptWatch:
            return .transcriptWatch(try EngineTranscriptPage(from: result))
        case .sessionExport:
            return .sessionExport(try EngineExportResult(from: result))
        case .settingsGet:
            return .settingsGet(try EngineSettingsResult(from: result))
        case .settingsReplace:
            return .settingsReplace(try EngineSettingsResult(from: result))
        case .modelsPrepare:
            _ = try EngineEmptyPayload(from: result)
            return .modelsPrepare
        case .modelsInspect:
            return .modelsInspect(try EngineModelsInspection(from: result))
        case .profilesEvaluate:
            return .profilesEvaluate(try EngineProfileEvaluation(from: result))
        case .shutdown:
            _ = try EngineEmptyPayload(from: result)
            return .shutdown
        }
    }

    func encodeResult(to encoder: Encoder) throws {
        switch self {
        case let .hello(payload):
            try payload.encode(to: encoder)
        case let .stateGet(state):
            try state.encode(to: encoder)
        case let .diagnosticsGet(result):
            try result.encode(to: encoder)
        case let .devicesList(result):
            try result.encode(to: encoder)
        case let .recordingStart(payload), let .recordingStop(payload), let .sessionImport(payload),
             let .sessionReprocess(payload), let .sessionRetryDecisions(payload):
            try payload.encode(to: encoder)
        case let .sessionInspect(summary):
            try summary.encode(to: encoder)
        case let .sessionList(result):
            try result.encode(to: encoder)
        case let .transcriptRead(page), let .transcriptWatch(page):
            try page.encode(to: encoder)
        case let .transcriptRowDetails(page):
            try page.encode(to: encoder)
        case let .sessionExport(result):
            try result.encode(to: encoder)
        case let .settingsGet(result), let .settingsReplace(result):
            try result.encode(to: encoder)
        case .modelsPrepare, .shutdown:
            try EngineEmptyPayload().encode(to: encoder)
        case let .modelsInspect(inspection):
            try inspection.encode(to: encoder)
        case let .profilesEvaluate(evaluation):
            try evaluation.encode(to: encoder)
        }
    }
}

public struct EngineAcceptedPayload: Codable, Equatable, Sendable {
    public let command: EngineCommandName

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case command
    }

    public init(command: EngineCommandName) {
        self.command = command
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        command = try container.decode(EngineCommandName.self, forKey: .command)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
    }
}

public enum EngineEventName: String, Codable, CaseIterable, Equatable, Sendable {
    case ready
    case state
    case accepted
    case completed
    case progress
    case rows
    case error

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw EngineProtocolError.invalidJSON("unknown event")
        }
        self = value
    }

}

public enum EngineEvent: Codable, Equatable, Sendable {
    case ready(EngineReadyPayload)
    case state(EngineState)
    case accepted(EngineAcceptedPayload)
    case completed(EngineResult)
    case progress(EngineProgressPayload)
    case rows(EngineRowsPayload)
    case error(EngineFailure)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case event
        case payload
    }

    public var name: EngineEventName {
        switch self {
        case .ready: .ready
        case .state: .state
        case .accepted: .accepted
        case .completed: .completed
        case .progress: .progress
        case .rows: .rows
        case .error: .error
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let name = try container.decode(EngineEventName.self, forKey: .event)
        self = try Self.decode(name: name, payload: container.superDecoder(forKey: .payload))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .event)
        try encodePayload(to: container.superEncoder(forKey: .payload))
    }

    static func decode(name: EngineEventName, payload: Decoder) throws -> EngineEvent {
        switch name {
        case .ready:
            return .ready(try EngineReadyPayload(from: payload))
        case .state:
            return .state(try EngineState(from: payload))
        case .accepted:
            return .accepted(try EngineAcceptedPayload(from: payload))
        case .completed:
            return .completed(try EngineResult(from: payload))
        case .progress:
            return .progress(try EngineProgressPayload(from: payload))
        case .rows:
            return .rows(try EngineRowsPayload(from: payload))
        case .error:
            return .error(try EngineFailure(from: payload))
        }
    }

    func encodePayload(to encoder: Encoder) throws {
        switch self {
        case let .ready(payload):
            try payload.encode(to: encoder)
        case let .state(state):
            try state.encode(to: encoder)
        case let .accepted(payload):
            try payload.encode(to: encoder)
        case let .completed(result):
            try result.encode(to: encoder)
        case let .progress(payload):
            try payload.encode(to: encoder)
        case let .rows(payload):
            try payload.encode(to: encoder)
        case let .error(failure):
            try failure.encode(to: encoder)
        }
    }
}

public struct EngineOutput: Codable, Equatable, Sendable {
    public let version: Int
    public let sequence: EngineID
    @EngineNullable public private(set) var requestID: EngineID?
    public let event: EngineEvent

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case sequence
        case requestID = "request_id"
        case event
        case payload
    }

    public init(version: Int, sequence: EngineID, requestID: EngineID?, event: EngineEvent) throws {
        guard version == 1 else {
            throw EngineProtocolError.unsupportedVersion(version)
        }
        try Self.validateCorrelation(requestID: requestID, event: event)
        self.version = version
        self.sequence = sequence
        _requestID = EngineNullable(wrappedValue: requestID)
        self.event = event
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else {
            throw EngineProtocolError.unsupportedVersion(version)
        }
        let sequence = try container.decode(EngineID.self, forKey: .sequence)
        let requestID = try container.decode(EngineNullable<EngineID>.self, forKey: .requestID).wrappedValue
        let name = try container.decode(EngineEventName.self, forKey: .event)
        let event = try EngineEvent.decode(name: name, payload: container.superDecoder(forKey: .payload))
        try self.init(version: version, sequence: sequence, requestID: requestID, event: event)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(_requestID, forKey: .requestID)
        try container.encode(event.name, forKey: .event)
        try event.encodePayload(to: container.superEncoder(forKey: .payload))
    }

    private static func validateCorrelation(requestID: EngineID?, event: EngineEvent) throws {
        switch event {
        case .ready:
            try engineEventRequire(requestID == nil, "ready must be unsolicited")
        case .accepted, .completed:
            try engineEventRequire(requestID != nil, "accepted and completed require request_id")
        case let .error(failure):
            try engineEventRequire(requestID == failure.requestID, "error request_id must match payload")
        case .state, .progress, .rows:
            break
        }
    }
}
