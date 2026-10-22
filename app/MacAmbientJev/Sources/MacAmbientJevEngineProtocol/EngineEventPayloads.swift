import Foundation

fileprivate func enginePayloadRequire(_ condition: Bool, _ reason: String) throws {
    guard condition else {
        throw EngineProtocolError.invalidJSON(reason)
    }
}

fileprivate func enginePayloadRequireNonempty(_ value: String, _ field: String) throws {
    try enginePayloadRequire(!value.isEmpty, "\(field) must not be empty")
}

fileprivate func enginePayloadValidateDevice(_ device: EngineDevice) throws {
    if case let .id(value) = device {
        try enginePayloadRequireNonempty(value, "device.id")
    }
}

fileprivate func enginePayloadRequireUnique<T: Hashable>(_ values: [T], _ field: String) throws {
    var seen = Set<T>()
    for value in values {
        try enginePayloadRequire(seen.insert(value).inserted, "\(field) must be unique")
    }
}

public enum EngineStage: String, Codable, CaseIterable, Equatable, Sendable {
    case startup
    case settings
    case devices
    case capture
    case importing = "import"
    case recovery
    case maintenance
    case validatingModels = "validating_models"
    case loadingModels = "loading_models"
    case vad
    case diarization
    case asr
    case decisions
    case finalization
    case exporting = "export"
    case shutdown
    case protocolValidation = "protocol"
}

public enum EngineErrorCode: String, Codable, CaseIterable, Equatable, Sendable {
    case invalidRequest = "invalid_request"
    case unsupportedVersion = "unsupported_version"
    case invalidRequestID = "invalid_request_id"
    case helloRequired = "hello_required"
    case busy
    case settingsRequired = "settings_required"
    case invalidSettings = "invalid_settings"
    case staleRevision = "stale_revision"
    case invalidCursor = "invalid_cursor"
    case sessionNotFound = "session_not_found"
    case deviceNotFound = "device_not_found"
    case deviceFailure = "device_failure"
    case captureFailure = "capture_failure"
    case diskSpace = "disk_space"
    case powerFailure = "power_failure"
    case filesystem
    case modelMissing = "model_missing"
    case modelCorrupt = "model_corrupt"
    case modelFailure = "model_failure"
    case processingFailure = "processing_failure"
    case exportFailure = "export_failure"
    case rowTooLarge = "row_too_large"
    case cancelled
    case internalError = "internal_error"
}

public enum EngineSeverity: String, Codable, CaseIterable, Equatable, Sendable {
    case warning
    case error
    case fatal
}

public enum EngineRecoveryAction: String, Codable, CaseIterable, Equatable, Sendable {
    case none
    case replaceSettings = "replace_settings"
    case prepareModels = "prepare_models"
    case retry
    case reprocess
    case retryDecisions = "retry_decisions"
    case selectDevice = "select_device"
    case freeDiskSpace = "free_disk_space"
    case inspectSession = "inspect_session"
    case restart
}

public enum EngineScreen: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case live
    case finalizing
    case finalized
}

public enum EngineSetupStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case settingsRequired = "settings_required"
    case modelsRequired = "models_required"
    case ready
}

public enum EngineRecoveryStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case pending
    case running
    case completed
    case failed
}

public enum EngineRecordingPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case starting
    case recording
    case stopping
}

public enum EngineUnavailableCapability: String, Codable, CaseIterable, Equatable, Sendable {
    case none
}

public enum EngineSessionStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case unreadable
    case recording
    case queued
    case processing
    case finalized
    case failed
}

public enum EngineSpeakerLabel: String, Codable, CaseIterable, Equatable, Sendable {
    case speaker1 = "Speaker 1"
    case speaker2 = "Speaker 2"
    case speaker3 = "Speaker 3"
    case speaker4 = "Speaker 4"
    case speaker5 = "Speaker 5"
    case speaker6 = "Speaker 6"
    case speaker7 = "Speaker 7"
    case other = "OTHER"
    case unknown = "UNKNOWN"
}

public enum EngineClauseState: String, Codable, CaseIterable, Equatable, Sendable {
    case awaitingNextSegment = "awaiting_next_segment"
    case boundaryPending = "boundary_pending"
    case priorityPending = "priority_pending"
    case classified
}

public enum EngineRowsKind: String, Codable, CaseIterable, Equatable, Sendable {
    case snapshot
    case changes
    case reloadRequired = "reload_required"
}

public struct EngineErrorDetail: Codable, Equatable, Sendable {
    public let domain: String
    public let code: String
    public let message: String
    @EngineNullable public private(set) var path: String?
    @EngineNullable public private(set) var deviceID: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case domain
        case code
        case message
        case path
        case deviceID = "device_id"
    }

    public init(domain: String, code: String, message: String, path: String?, deviceID: String?) throws {
        try enginePayloadRequireNonempty(domain, "domain")
        try enginePayloadRequireNonempty(code, "code")
        try enginePayloadRequireNonempty(message, "message")
        if let path { try enginePayloadRequireNonempty(path, "path") }
        if let deviceID { try enginePayloadRequireNonempty(deviceID, "device_id") }
        self.domain = domain
        self.code = code
        self.message = message
        _path = EngineNullable(wrappedValue: path)
        _deviceID = EngineNullable(wrappedValue: deviceID)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            domain: container.decode(String.self, forKey: .domain),
            code: container.decode(String.self, forKey: .code),
            message: container.decode(String.self, forKey: .message),
            path: container.decode(EngineNullable<String>.self, forKey: .path).wrappedValue,
            deviceID: container.decode(EngineNullable<String>.self, forKey: .deviceID).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domain, forKey: .domain)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(_path, forKey: .path)
        try container.encode(_deviceID, forKey: .deviceID)
    }
}

public struct EngineFailure: Codable, Equatable, Sendable {
    public let code: EngineErrorCode
    public let message: String
    public let stage: EngineStage
    @EngineNullable public private(set) var requestID: EngineID?
    @EngineNullable public private(set) var sessionID: String?
    public let severity: EngineSeverity
    public let recoveryAction: EngineRecoveryAction
    public let details: [EngineErrorDetail]
    public let cleanupErrors: [EngineErrorDetail]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code
        case message
        case stage
        case requestID = "request_id"
        case sessionID = "session_id"
        case severity
        case recoveryAction = "recovery_action"
        case details
        case cleanupErrors = "cleanup_errors"
    }

    public init(
        code: EngineErrorCode,
        message: String,
        stage: EngineStage,
        requestID: EngineID?,
        sessionID: String?,
        severity: EngineSeverity,
        recoveryAction: EngineRecoveryAction,
        details: [EngineErrorDetail],
        cleanupErrors: [EngineErrorDetail]
    ) throws {
        try enginePayloadRequireNonempty(message, "message")
        if let sessionID { try enginePayloadRequireNonempty(sessionID, "session_id") }
        self.code = code
        self.message = message
        self.stage = stage
        _requestID = EngineNullable(wrappedValue: requestID)
        _sessionID = EngineNullable(wrappedValue: sessionID)
        self.severity = severity
        self.recoveryAction = recoveryAction
        self.details = details
        self.cleanupErrors = cleanupErrors
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            code: container.decode(EngineErrorCode.self, forKey: .code),
            message: container.decode(String.self, forKey: .message),
            stage: container.decode(EngineStage.self, forKey: .stage),
            requestID: container.decode(EngineNullable<EngineID>.self, forKey: .requestID).wrappedValue,
            sessionID: container.decode(EngineNullable<String>.self, forKey: .sessionID).wrappedValue,
            severity: container.decode(EngineSeverity.self, forKey: .severity),
            recoveryAction: container.decode(EngineRecoveryAction.self, forKey: .recoveryAction),
            details: container.decode([EngineErrorDetail].self, forKey: .details),
            cleanupErrors: container.decode([EngineErrorDetail].self, forKey: .cleanupErrors)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(stage, forKey: .stage)
        try container.encode(_requestID, forKey: .requestID)
        try container.encode(_sessionID, forKey: .sessionID)
        try container.encode(severity, forKey: .severity)
        try container.encode(recoveryAction, forKey: .recoveryAction)
        try container.encode(details, forKey: .details)
        try container.encode(cleanupErrors, forKey: .cleanupErrors)
    }
}

public struct EngineCapabilities: Codable, Equatable, Sendable {
    public let sources: [EngineSource]
    public let asrSizes: [EngineASRSize]
    public let executionProviders: [EngineExecutionProvider]
    public let maximumThreads: Int
    public let automaticInputVolume: EngineUnavailableCapability
    public let thermalMonitoring: EngineUnavailableCapability

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sources
        case asrSizes = "asr_sizes"
        case executionProviders = "execution_providers"
        case maximumThreads = "maximum_threads"
        case automaticInputVolume = "automatic_input_volume"
        case thermalMonitoring = "thermal_monitoring"
    }

    public init(
        sources: [EngineSource],
        asrSizes: [EngineASRSize],
        executionProviders: [EngineExecutionProvider],
        maximumThreads: Int,
        automaticInputVolume: EngineUnavailableCapability,
        thermalMonitoring: EngineUnavailableCapability
    ) throws {
        try enginePayloadRequire(!sources.isEmpty, "sources must not be empty")
        try enginePayloadRequire(!asrSizes.isEmpty, "asr_sizes must not be empty")
        try enginePayloadRequire(!executionProviders.isEmpty, "execution_providers must not be empty")
        try enginePayloadRequireUnique(sources.map(\.rawValue), "sources")
        try enginePayloadRequireUnique(asrSizes.map(\.rawValue), "asr_sizes")
        try enginePayloadRequireUnique(executionProviders.map(\.rawValue), "execution_providers")
        try enginePayloadRequire((1...4).contains(maximumThreads), "maximum_threads must be between 1 and 4")
        self.sources = sources
        self.asrSizes = asrSizes
        self.executionProviders = executionProviders
        self.maximumThreads = maximumThreads
        self.automaticInputVolume = automaticInputVolume
        self.thermalMonitoring = thermalMonitoring
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            sources: container.decode([EngineSource].self, forKey: .sources),
            asrSizes: container.decode([EngineASRSize].self, forKey: .asrSizes),
            executionProviders: container.decode([EngineExecutionProvider].self, forKey: .executionProviders),
            maximumThreads: container.decode(Int.self, forKey: .maximumThreads),
            automaticInputVolume: container.decode(EngineUnavailableCapability.self, forKey: .automaticInputVolume),
            thermalMonitoring: container.decode(EngineUnavailableCapability.self, forKey: .thermalMonitoring)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sources, forKey: .sources)
        try container.encode(asrSizes, forKey: .asrSizes)
        try container.encode(executionProviders, forKey: .executionProviders)
        try container.encode(maximumThreads, forKey: .maximumThreads)
        try container.encode(automaticInputVolume, forKey: .automaticInputVolume)
        try container.encode(thermalMonitoring, forKey: .thermalMonitoring)
    }
}

public struct EngineRecordingState: Codable, Equatable, Sendable {
    public let sessionID: String
    public let source: EngineSource
    public let device: EngineDevice
    public let phase: EngineRecordingPhase

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID = "session_id"
        case source
        case device
        case phase
    }

    public init(sessionID: String, source: EngineSource, device: EngineDevice, phase: EngineRecordingPhase) throws {
        try enginePayloadRequireNonempty(sessionID, "session_id")
        try enginePayloadValidateDevice(device)
        self.sessionID = sessionID
        self.source = source
        self.device = device
        self.phase = phase
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            source: container.decode(EngineSource.self, forKey: .source),
            device: container.decode(EngineDevice.self, forKey: .device),
            phase: container.decode(EngineRecordingPhase.self, forKey: .phase)
        )
    }

    public func encode(to encoder: Encoder) throws {
        try enginePayloadValidateDevice(device)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(source, forKey: .source)
        try container.encode(device, forKey: .device)
        try container.encode(phase, forKey: .phase)
    }
}

public struct EngineQueuedOperation: Codable, Equatable, Sendable {
    public let sessionID: String
    public let stage: EngineStage

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID = "session_id"
        case stage
    }

    public init(sessionID: String, stage: EngineStage) throws {
        try enginePayloadRequireNonempty(sessionID, "session_id")
        self.sessionID = sessionID
        self.stage = stage
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(sessionID: container.decode(String.self, forKey: .sessionID), stage: container.decode(EngineStage.self, forKey: .stage))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(stage, forKey: .stage)
    }
}

public struct EngineState: Codable, Equatable, Sendable {
    public let revision: EngineID
    public let screen: EngineScreen
    public let setup: EngineSetupStatus
    public let recovery: EngineRecoveryStatus
    @EngineNullable public private(set) var recording: EngineRecordingState?
    public let queue: [EngineQueuedOperation]
    public let failures: [EngineFailure]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case revision
        case screen
        case setup
        case recovery
        case recording
        case queue
        case failures
    }

    public init(
        revision: EngineID,
        screen: EngineScreen,
        setup: EngineSetupStatus,
        recovery: EngineRecoveryStatus,
        recording: EngineRecordingState?,
        queue: [EngineQueuedOperation],
        failures: [EngineFailure]
    ) throws {
        try enginePayloadRequire(queue.count <= 16, "queue must contain at most 16 operations")
        self.revision = revision
        self.screen = screen
        self.setup = setup
        self.recovery = recovery
        _recording = EngineNullable(wrappedValue: recording)
        self.queue = queue
        self.failures = failures
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            revision: container.decode(EngineID.self, forKey: .revision),
            screen: container.decode(EngineScreen.self, forKey: .screen),
            setup: container.decode(EngineSetupStatus.self, forKey: .setup),
            recovery: container.decode(EngineRecoveryStatus.self, forKey: .recovery),
            recording: container.decode(EngineNullable<EngineRecordingState>.self, forKey: .recording).wrappedValue,
            queue: container.decode([EngineQueuedOperation].self, forKey: .queue),
            failures: container.decode([EngineFailure].self, forKey: .failures)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(screen, forKey: .screen)
        try container.encode(setup, forKey: .setup)
        try container.encode(recovery, forKey: .recovery)
        try container.encode(_recording, forKey: .recording)
        try container.encode(queue, forKey: .queue)
        try container.encode(failures, forKey: .failures)
    }
}

public struct EngineReadyPayload: Codable, Equatable, Sendable {
    public let capabilities: EngineCapabilities
    public let state: EngineState

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case capabilities
        case state
    }

    public init(capabilities: EngineCapabilities, state: EngineState) {
        self.capabilities = capabilities
        self.state = state
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        self.init(capabilities: try container.decode(EngineCapabilities.self, forKey: .capabilities), state: try container.decode(EngineState.self, forKey: .state))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(state, forKey: .state)
    }
}

public struct EngineDeviceInfo: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case name
        case isDefault = "is_default"
    }

    public init(id: String, name: String, isDefault: Bool) throws {
        try enginePayloadRequireNonempty(id, "id")
        try enginePayloadRequireNonempty(name, "name")
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            isDefault: container.decode(Bool.self, forKey: .isDefault)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isDefault, forKey: .isDefault)
    }
}

public struct EngineDevicesResult: Codable, Equatable, Sendable {
    public let source: EngineSource
    public let devices: [EngineDeviceInfo]
    @EngineNullable public private(set) var defaultDeviceID: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source
        case devices
        case defaultDeviceID = "default_device_id"
    }

    public init(source: EngineSource, devices: [EngineDeviceInfo], defaultDeviceID: String?) throws {
        try enginePayloadRequireUnique(devices.map(\.id), "device ids")
        let defaults = devices.filter(\.isDefault)
        try enginePayloadRequire(defaults.count <= 1, "at most one device may be default")
        if let defaultDeviceID {
            try enginePayloadRequireNonempty(defaultDeviceID, "default_device_id")
            try enginePayloadRequire(defaults.count == 1, "default_device_id requires exactly one default device")
            try enginePayloadRequire(defaults[0].id == defaultDeviceID, "default_device_id must name the default device")
        } else {
            try enginePayloadRequire(defaults.isEmpty, "default device requires default_device_id")
        }
        self.source = source
        self.devices = devices
        _defaultDeviceID = EngineNullable(wrappedValue: defaultDeviceID)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            source: container.decode(EngineSource.self, forKey: .source),
            devices: container.decode([EngineDeviceInfo].self, forKey: .devices),
            defaultDeviceID: container.decode(EngineNullable<String>.self, forKey: .defaultDeviceID).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(devices, forKey: .devices)
        try container.encode(_defaultDeviceID, forKey: .defaultDeviceID)
    }
}

public struct EngineSettingsResult: Codable, Equatable, Sendable {
    public let revision: EngineID
    public let settings: EngineSettings

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case revision
        case settings
    }

    public init(revision: EngineID, settings: EngineSettings) {
        self.revision = revision
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        self.init(revision: try container.decode(EngineID.self, forKey: .revision), settings: try container.decode(EngineSettings.self, forKey: .settings))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(settings, forKey: .settings)
    }
}

public struct EngineSessionSummary: Codable, Equatable, Sendable {
    public let folderID: String
    @EngineNullable public private(set) var sessionID: String?
    public let status: EngineSessionStatus
    @EngineNullable public private(set) var error: EngineFailure?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case folderID = "folder_id"
        case sessionID = "session_id"
        case status
        case error
    }

    public init(folderID: String, sessionID: String?, status: EngineSessionStatus, error: EngineFailure?) throws {
        try enginePayloadRequireNonempty(folderID, "folder_id")
        if let sessionID { try enginePayloadRequireNonempty(sessionID, "session_id") }
        if status == .unreadable {
            try enginePayloadRequire(sessionID == nil, "unreadable session must not have session_id")
            try enginePayloadRequire(error != nil, "unreadable session requires error")
        } else {
            try enginePayloadRequire(sessionID != nil, "readable session requires session_id")
        }
        self.folderID = folderID
        _sessionID = EngineNullable(wrappedValue: sessionID)
        self.status = status
        _error = EngineNullable(wrappedValue: error)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            folderID: container.decode(String.self, forKey: .folderID),
            sessionID: container.decode(EngineNullable<String>.self, forKey: .sessionID).wrappedValue,
            status: container.decode(EngineSessionStatus.self, forKey: .status),
            error: container.decode(EngineNullable<EngineFailure>.self, forKey: .error).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(folderID, forKey: .folderID)
        try container.encode(_sessionID, forKey: .sessionID)
        try container.encode(status, forKey: .status)
        try container.encode(_error, forKey: .error)
    }
}

public struct EngineSessionListResult: Codable, Equatable, Sendable {
    public let sessions: [EngineSessionSummary]
    @EngineNullable public private(set) var nextCursor: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessions
        case nextCursor = "next_cursor"
    }

    public init(sessions: [EngineSessionSummary], nextCursor: String?) throws {
        try enginePayloadRequire(sessions.count <= 100, "sessions must contain at most 100 entries")
        try enginePayloadRequireUnique(sessions.map(\.folderID), "folder ids")
        if let nextCursor { try enginePayloadRequireNonempty(nextCursor, "next_cursor") }
        self.sessions = sessions
        _nextCursor = EngineNullable(wrappedValue: nextCursor)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            sessions: container.decode([EngineSessionSummary].self, forKey: .sessions),
            nextCursor: container.decode(EngineNullable<String>.self, forKey: .nextCursor).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(_nextCursor, forKey: .nextCursor)
    }
}

public struct EngineTranscriptRow: Codable, Equatable, Sendable {
    public let rowID: String
    public let startMS: Int64
    public let endMS: Int64
    public let text: String
    public let headings: [EngineSpeakerLabel]
    @EngineNullable public private(set) var clauseState: EngineClauseState?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case rowID = "row_id"
        case startMS = "start_ms"
        case endMS = "end_ms"
        case text
        case headings
        case clauseState = "clause_state"
    }

    public init(rowID: String, startMS: Int64, endMS: Int64, text: String, headings: [EngineSpeakerLabel], clauseState: EngineClauseState?) throws {
        try enginePayloadRequireNonempty(rowID, "row_id")
        try enginePayloadRequire(startMS >= 0, "start_ms must not be negative")
        try enginePayloadRequire(endMS >= startMS, "end_ms must not precede start_ms")
        try enginePayloadRequire(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "text must not be blank")
        self.rowID = rowID
        self.startMS = startMS
        self.endMS = endMS
        self.text = text
        self.headings = headings
        _clauseState = EngineNullable(wrappedValue: clauseState)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            rowID: container.decode(String.self, forKey: .rowID),
            startMS: container.decode(Int64.self, forKey: .startMS),
            endMS: container.decode(Int64.self, forKey: .endMS),
            text: container.decode(String.self, forKey: .text),
            headings: container.decode([EngineSpeakerLabel].self, forKey: .headings),
            clauseState: container.decode(EngineNullable<EngineClauseState>.self, forKey: .clauseState).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rowID, forKey: .rowID)
        try container.encode(startMS, forKey: .startMS)
        try container.encode(endMS, forKey: .endMS)
        try container.encode(text, forKey: .text)
        try container.encode(headings, forKey: .headings)
        try container.encode(_clauseState, forKey: .clauseState)
    }
}

public struct EngineTranscriptPage: Codable, Equatable, Sendable {
    public let sessionID: String
    public let revision: EngineID
    public let rows: [EngineTranscriptRow]
    @EngineNullable public private(set) var nextCursor: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID = "session_id"
        case revision
        case rows
        case nextCursor = "next_cursor"
    }

    public init(sessionID: String, revision: EngineID, rows: [EngineTranscriptRow], nextCursor: String?) throws {
        try enginePayloadRequireNonempty(sessionID, "session_id")
        try enginePayloadRequire(rows.count <= 200, "rows must contain at most 200 entries")
        try enginePayloadRequireUnique(rows.map(\.rowID), "row ids")
        if let nextCursor { try enginePayloadRequireNonempty(nextCursor, "next_cursor") }
        self.sessionID = sessionID
        self.revision = revision
        self.rows = rows
        _nextCursor = EngineNullable(wrappedValue: nextCursor)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            revision: container.decode(EngineID.self, forKey: .revision),
            rows: container.decode([EngineTranscriptRow].self, forKey: .rows),
            nextCursor: container.decode(EngineNullable<String>.self, forKey: .nextCursor).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(revision, forKey: .revision)
        try container.encode(rows, forKey: .rows)
        try container.encode(_nextCursor, forKey: .nextCursor)
    }
}

public struct EngineRowsPayload: Codable, Equatable, Sendable {
    public let sessionID: String
    public let revision: EngineID
    public let kind: EngineRowsKind
    public let rows: [EngineTranscriptRow]
    public let removedRowIDs: [String]
    @EngineNullable public private(set) var nextCursor: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID = "session_id"
        case revision
        case kind
        case rows
        case removedRowIDs = "removed_row_ids"
        case nextCursor = "next_cursor"
    }

    public init(
        sessionID: String,
        revision: EngineID,
        kind: EngineRowsKind,
        rows: [EngineTranscriptRow],
        removedRowIDs: [String],
        nextCursor: String?
    ) throws {
        try enginePayloadRequireNonempty(sessionID, "session_id")
        try enginePayloadRequire(rows.count + removedRowIDs.count <= 200, "rows and removed_row_ids must total at most 200 entries")
        try enginePayloadRequireUnique(rows.map(\.rowID), "row ids")
        try enginePayloadRequireUnique(removedRowIDs, "removed_row_ids")
        for rowID in removedRowIDs { try enginePayloadRequireNonempty(rowID, "removed_row_id") }
        try enginePayloadRequireUnique(rows.map(\.rowID) + removedRowIDs, "row and removed ids")
        if let nextCursor { try enginePayloadRequireNonempty(nextCursor, "next_cursor") }
        switch kind {
        case .snapshot:
            try enginePayloadRequire(removedRowIDs.isEmpty, "snapshot must not remove rows")
        case .changes:
            try enginePayloadRequire(nextCursor == nil, "changes must have a null next_cursor")
        case .reloadRequired:
            try enginePayloadRequire(rows.isEmpty && removedRowIDs.isEmpty, "reload_required must not include row data")
            try enginePayloadRequire(nextCursor == nil, "reload_required must have a null next_cursor")
        }
        self.sessionID = sessionID
        self.revision = revision
        self.kind = kind
        self.rows = rows
        self.removedRowIDs = removedRowIDs
        _nextCursor = EngineNullable(wrappedValue: nextCursor)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            revision: container.decode(EngineID.self, forKey: .revision),
            kind: container.decode(EngineRowsKind.self, forKey: .kind),
            rows: container.decode([EngineTranscriptRow].self, forKey: .rows),
            removedRowIDs: container.decode([String].self, forKey: .removedRowIDs),
            nextCursor: container.decode(EngineNullable<String>.self, forKey: .nextCursor).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(revision, forKey: .revision)
        try container.encode(kind, forKey: .kind)
        try container.encode(rows, forKey: .rows)
        try container.encode(removedRowIDs, forKey: .removedRowIDs)
        try container.encode(_nextCursor, forKey: .nextCursor)
    }
}

public struct EngineProgressPayload: Codable, Equatable, Sendable {
    public let stage: EngineStage
    public let completedUnits: UInt64
    @EngineNullable public private(set) var totalUnits: UInt64?
    @EngineNullable public private(set) var sessionID: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case stage
        case completedUnits = "completed_units"
        case totalUnits = "total_units"
        case sessionID = "session_id"
    }

    public init(stage: EngineStage, completedUnits: UInt64, totalUnits: UInt64?, sessionID: String?) throws {
        if let totalUnits {
            try enginePayloadRequire(completedUnits <= totalUnits, "completed_units must not exceed total_units")
        }
        if let sessionID { try enginePayloadRequireNonempty(sessionID, "session_id") }
        self.stage = stage
        self.completedUnits = completedUnits
        _totalUnits = EngineNullable(wrappedValue: totalUnits)
        _sessionID = EngineNullable(wrappedValue: sessionID)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            stage: container.decode(EngineStage.self, forKey: .stage),
            completedUnits: container.decode(UInt64.self, forKey: .completedUnits),
            totalUnits: container.decode(EngineNullable<UInt64>.self, forKey: .totalUnits).wrappedValue,
            sessionID: container.decode(EngineNullable<String>.self, forKey: .sessionID).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stage, forKey: .stage)
        try container.encode(completedUnits, forKey: .completedUnits)
        try container.encode(_totalUnits, forKey: .totalUnits)
        try container.encode(_sessionID, forKey: .sessionID)
    }
}
