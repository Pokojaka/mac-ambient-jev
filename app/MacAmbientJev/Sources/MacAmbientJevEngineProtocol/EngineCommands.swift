import Foundation

private func engineRequire(_ condition: Bool, _ reason: String) throws {
    guard condition else {
        throw EngineProtocolError.invalidJSON(reason)
    }
}

private func engineRequireNonempty(_ value: String, _ field: String) throws {
    try engineRequire(!value.isEmpty, "\(field) must not be empty")
}

private func engineValidateDevice(_ device: EngineDevice) throws {
    if case let .id(value) = device {
        try engineRequireNonempty(value, "device.id")
    }
}

public enum EngineSource: String, Codable, CaseIterable, Equatable, Sendable {
    case microphone
    case systemAudio = "system_audio"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw EngineProtocolError.invalidJSON("unknown source")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum EngineASRSize: String, Codable, CaseIterable, Equatable, Sendable {
    case small = "0.6b"
    case large = "1.7b"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw EngineProtocolError.invalidJSON("unknown ASR size")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum EngineExecutionProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case cpu

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw EngineProtocolError.invalidJSON("unknown execution provider")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum EngineDevice: Codable, Equatable, Sendable {
    case `default`
    case id(String)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case id
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "default":
            try engineRequire(!container.contains(.id), "default device must not include id")
            self = .default
        case "id":
            let value = try container.decode(String.self, forKey: .id)
            try engineRequireNonempty(value, "device.id")
            self = .id(value)
        default:
            throw EngineProtocolError.invalidJSON("unknown device kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .default:
            try container.encode("default", forKey: .kind)
        case let .id(value):
            try engineRequireNonempty(value, "device.id")
            try container.encode("id", forKey: .kind)
            try container.encode(value, forKey: .id)
        }
    }
}

public struct EngineSettings: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let source: EngineSource
    public let device: EngineDevice
    public let asrSize: EngineASRSize
    public let executionProvider: EngineExecutionProvider
    public let threads: Int
    public let lowHeat: Bool
    public let decisionsEnabled: Bool
    public let automaticExport: Bool
    @EngineNullable public private(set) var exportDestinationPath: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case source
        case device
        case asrSize = "asr_size"
        case executionProvider = "execution_provider"
        case threads
        case lowHeat = "low_heat"
        case decisionsEnabled = "decisions_enabled"
        case automaticExport = "automatic_export"
        case exportDestinationPath = "export_destination_path"
    }

    public init(
        schemaVersion: Int,
        source: EngineSource,
        device: EngineDevice,
        asrSize: EngineASRSize,
        executionProvider: EngineExecutionProvider,
        threads: Int,
        lowHeat: Bool,
        decisionsEnabled: Bool,
        automaticExport: Bool,
        exportDestinationPath: String?
    ) throws {
        try engineRequire(schemaVersion == 1, "schema_version must be 1")
        try engineRequire((1...4).contains(threads), "threads must be between 1 and 4")
        try engineValidateDevice(device)
        if let exportDestinationPath {
            try engineRequireNonempty(exportDestinationPath, "export_destination_path")
        }
        self.schemaVersion = schemaVersion
        self.source = source
        self.device = device
        self.asrSize = asrSize
        self.executionProvider = executionProvider
        self.threads = threads
        self.lowHeat = lowHeat
        self.decisionsEnabled = decisionsEnabled
        self.automaticExport = automaticExport
        _exportDestinationPath = EngineNullable(wrappedValue: exportDestinationPath)
    }

    public func validate(logicalCPUCount: Int) throws {
        try engineRequire(logicalCPUCount > 0, "logicalCPUCount must be positive")
        try engineRequire(threads <= min(4, logicalCPUCount), "threads exceed logical CPU limit")
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let source = try container.decode(EngineSource.self, forKey: .source)
        let device = try container.decode(EngineDevice.self, forKey: .device)
        let asrSize = try container.decode(EngineASRSize.self, forKey: .asrSize)
        let executionProvider = try container.decode(EngineExecutionProvider.self, forKey: .executionProvider)
        let threads = try container.decode(Int.self, forKey: .threads)
        let lowHeat = try container.decode(Bool.self, forKey: .lowHeat)
        let decisionsEnabled = try container.decode(Bool.self, forKey: .decisionsEnabled)
        let automaticExport = try container.decode(Bool.self, forKey: .automaticExport)
        let exportDestinationPath = try container.decode(EngineNullable<String>.self, forKey: .exportDestinationPath).wrappedValue
        try self.init(
            schemaVersion: schemaVersion,
            source: source,
            device: device,
            asrSize: asrSize,
            executionProvider: executionProvider,
            threads: threads,
            lowHeat: lowHeat,
            decisionsEnabled: decisionsEnabled,
            automaticExport: automaticExport,
            exportDestinationPath: exportDestinationPath
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(source, forKey: .source)
        try container.encode(device, forKey: .device)
        try container.encode(asrSize, forKey: .asrSize)
        try container.encode(executionProvider, forKey: .executionProvider)
        try container.encode(threads, forKey: .threads)
        try container.encode(lowHeat, forKey: .lowHeat)
        try container.encode(decisionsEnabled, forKey: .decisionsEnabled)
        try container.encode(automaticExport, forKey: .automaticExport)
        try container.encode(_exportDestinationPath, forKey: .exportDestinationPath)
    }
}

public struct EngineEmptyPayload: Codable, Equatable, Sendable {
    private struct CodingKeys: CodingKey, CaseIterable {
        let stringValue: String
        let intValue: Int?
        static let allCases: [CodingKeys] = []

        init?(stringValue: String) {
            return nil
        }

        init?(intValue: Int) {
            return nil
        }
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        _ = try engineContainer(decoder, keyedBy: CodingKeys.self)
    }

    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: CodingKeys.self)
    }
}

public struct EngineDevicesListPayload: Codable, Equatable, Sendable {
    public let source: EngineSource

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source
    }

    public init(source: EngineSource) {
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        source = try container.decode(EngineSource.self, forKey: .source)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
    }
}

public struct EngineRecordingStartPayload: Codable, Equatable, Sendable {
    public let source: EngineSource
    public let device: EngineDevice

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source
        case device
    }

    public init(source: EngineSource, device: EngineDevice) throws {
        try engineValidateDevice(device)
        self.source = source
        self.device = device
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            source: container.decode(EngineSource.self, forKey: .source),
            device: container.decode(EngineDevice.self, forKey: .device)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(device, forKey: .device)
    }
}

public struct EngineSessionPayload: Codable, Equatable, Sendable {
    public let sessionID: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID = "session_id"
    }

    public init(sessionID: String) throws {
        try engineRequireNonempty(sessionID, "session_id")
        self.sessionID = sessionID
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(sessionID: container.decode(String.self, forKey: .sessionID))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
    }
}

public struct EngineSessionInspectPayload: Codable, Equatable, Sendable {
    public let folderID: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case folderID = "folder_id"
    }

    public init(folderID: String) throws {
        try engineRequireNonempty(folderID, "folder_id")
        self.folderID = folderID
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(folderID: container.decode(String.self, forKey: .folderID))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(folderID, forKey: .folderID)
    }
}

public struct EngineImportPayload: Codable, Equatable, Sendable {
    public let inputPath: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case inputPath = "input_path"
    }

    public init(inputPath: String) throws {
        try engineRequireNonempty(inputPath, "input_path")
        self.inputPath = inputPath
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(inputPath: container.decode(String.self, forKey: .inputPath))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputPath, forKey: .inputPath)
    }
}

public struct EngineSessionListPayload: Codable, Equatable, Sendable {
    @EngineNullable public private(set) var cursor: String?
    public let limit: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case cursor
        case limit
    }

    public init(cursor: String?, limit: Int) throws {
        if let cursor {
            try engineRequireNonempty(cursor, "cursor")
        }
        try engineRequire((1...100).contains(limit), "limit must be between 1 and 100")
        _cursor = EngineNullable(wrappedValue: cursor)
        self.limit = limit
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let cursor = try container.decode(EngineNullable<String>.self, forKey: .cursor).wrappedValue
        try self.init(cursor: cursor, limit: container.decode(Int.self, forKey: .limit))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_cursor, forKey: .cursor)
        try container.encode(limit, forKey: .limit)
    }
}

public struct EngineTranscriptReadPayload: Codable, Equatable, Sendable {
    public let sessionID: String
    @EngineNullable public private(set) var revision: EngineID?
    @EngineNullable public private(set) var cursor: String?
    public let limit: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID = "session_id"
        case revision
        case cursor
        case limit
    }

    public init(sessionID: String, revision: EngineID?, cursor: String?, limit: Int) throws {
        try engineRequireNonempty(sessionID, "session_id")
        if let cursor {
            try engineRequireNonempty(cursor, "cursor")
        }
        try engineRequire((1...200).contains(limit), "limit must be between 1 and 200")
        self.sessionID = sessionID
        _revision = EngineNullable(wrappedValue: revision)
        _cursor = EngineNullable(wrappedValue: cursor)
        self.limit = limit
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let revision = try container.decode(EngineNullable<EngineID>.self, forKey: .revision).wrappedValue
        let cursor = try container.decode(EngineNullable<String>.self, forKey: .cursor).wrappedValue
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            revision: revision,
            cursor: cursor,
            limit: container.decode(Int.self, forKey: .limit)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(_revision, forKey: .revision)
        try container.encode(_cursor, forKey: .cursor)
        try container.encode(limit, forKey: .limit)
    }
}

public struct EngineExportPayload: Codable, Equatable, Sendable {
    public let sessionID: String
    public let destinationPath: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID = "session_id"
        case destinationPath = "destination_path"
    }

    public init(sessionID: String, destinationPath: String) throws {
        try engineRequireNonempty(sessionID, "session_id")
        try engineRequireNonempty(destinationPath, "destination_path")
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

public struct EngineSettingsReplacePayload: Codable, Equatable, Sendable {
    @EngineNullable public private(set) var expectedRevision: EngineID?
    public let settings: EngineSettings

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case expectedRevision = "expected_revision"
        case settings
    }

    public init(expectedRevision: EngineID?, settings: EngineSettings) {
        _expectedRevision = EngineNullable(wrappedValue: expectedRevision)
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let expectedRevision = try container.decode(EngineNullable<EngineID>.self, forKey: .expectedRevision).wrappedValue
        try self.init(expectedRevision: expectedRevision, settings: container.decode(EngineSettings.self, forKey: .settings))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_expectedRevision, forKey: .expectedRevision)
        try container.encode(settings, forKey: .settings)
    }
}

public enum EngineCommandName: String, Codable, CaseIterable, Equatable, Sendable {
    case hello
    case stateGet = "state.get"
    case diagnosticsGet = "diagnostics.get"
    case devicesList = "devices.list"
    case recordingStart = "recording.start"
    case recordingStop = "recording.stop"
    case sessionImport = "session.import"
    case sessionInspect = "session.inspect"
    case sessionReprocess = "session.reprocess"
    case sessionRetryDecisions = "session.retry_decisions"
    case sessionList = "session.list"
    case transcriptRead = "transcript.read"
    case transcriptWatch = "transcript.watch"
    case sessionExport = "session.export"
    case settingsGet = "settings.get"
    case settingsReplace = "settings.replace"
    case modelsPrepare = "models.prepare"
    case modelsInspect = "models.inspect"
    case shutdown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw EngineProtocolError.invalidJSON("unknown command")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum EngineCommand: Codable, Equatable, Sendable {
    case hello
    case stateGet
    case diagnosticsGet
    case devicesList(EngineDevicesListPayload)
    case recordingStart(EngineRecordingStartPayload)
    case recordingStop(EngineSessionPayload)
    case sessionImport(EngineImportPayload)
    case sessionInspect(EngineSessionInspectPayload)
    case sessionReprocess(EngineSessionPayload)
    case sessionRetryDecisions(EngineSessionPayload)
    case sessionList(EngineSessionListPayload)
    case transcriptRead(EngineTranscriptReadPayload)
    case transcriptWatch(EngineSessionPayload)
    case sessionExport(EngineExportPayload)
    case settingsGet
    case settingsReplace(EngineSettingsReplacePayload)
    case modelsPrepare
    case modelsInspect
    case shutdown

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case command
        case payload
    }

    public var name: EngineCommandName {
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
        case .transcriptWatch: .transcriptWatch
        case .sessionExport: .sessionExport
        case .settingsGet: .settingsGet
        case .settingsReplace: .settingsReplace
        case .modelsPrepare: .modelsPrepare
        case .modelsInspect: .modelsInspect
        case .shutdown: .shutdown
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let name = try container.decode(EngineCommandName.self, forKey: .command)
        self = try Self.decode(name: name, payload: container.superDecoder(forKey: .payload))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .command)
        try encodePayload(to: container.superEncoder(forKey: .payload))
    }

    static func decode(name: EngineCommandName, payload: Decoder) throws -> EngineCommand {
        switch name {
        case .hello:
            _ = try EngineEmptyPayload(from: payload)
            return .hello
        case .stateGet:
            _ = try EngineEmptyPayload(from: payload)
            return .stateGet
        case .diagnosticsGet:
            _ = try EngineEmptyPayload(from: payload)
            return .diagnosticsGet
        case .devicesList:
            return .devicesList(try EngineDevicesListPayload(from: payload))
        case .recordingStart:
            return .recordingStart(try EngineRecordingStartPayload(from: payload))
        case .recordingStop:
            return .recordingStop(try EngineSessionPayload(from: payload))
        case .sessionImport:
            return .sessionImport(try EngineImportPayload(from: payload))
        case .sessionInspect:
            return .sessionInspect(try EngineSessionInspectPayload(from: payload))
        case .sessionReprocess:
            return .sessionReprocess(try EngineSessionPayload(from: payload))
        case .sessionRetryDecisions:
            return .sessionRetryDecisions(try EngineSessionPayload(from: payload))
        case .sessionList:
            return .sessionList(try EngineSessionListPayload(from: payload))
        case .transcriptRead:
            return .transcriptRead(try EngineTranscriptReadPayload(from: payload))
        case .transcriptWatch:
            return .transcriptWatch(try EngineSessionPayload(from: payload))
        case .sessionExport:
            return .sessionExport(try EngineExportPayload(from: payload))
        case .settingsGet:
            _ = try EngineEmptyPayload(from: payload)
            return .settingsGet
        case .settingsReplace:
            return .settingsReplace(try EngineSettingsReplacePayload(from: payload))
        case .modelsPrepare:
            _ = try EngineEmptyPayload(from: payload)
            return .modelsPrepare
        case .modelsInspect:
            _ = try EngineEmptyPayload(from: payload)
            return .modelsInspect
        case .shutdown:
            _ = try EngineEmptyPayload(from: payload)
            return .shutdown
        }
    }

    func encodePayload(to encoder: Encoder) throws {
        switch self {
        case .hello, .stateGet, .diagnosticsGet, .settingsGet, .modelsPrepare, .modelsInspect, .shutdown:
            try EngineEmptyPayload().encode(to: encoder)
        case let .devicesList(payload):
            try payload.encode(to: encoder)
        case let .recordingStart(payload):
            try payload.encode(to: encoder)
        case let .recordingStop(payload), let .sessionReprocess(payload), let .sessionRetryDecisions(payload), let .transcriptWatch(payload):
            try payload.encode(to: encoder)
        case let .sessionImport(payload):
            try payload.encode(to: encoder)
        case let .sessionInspect(payload):
            try payload.encode(to: encoder)
        case let .sessionList(payload):
            try payload.encode(to: encoder)
        case let .transcriptRead(payload):
            try payload.encode(to: encoder)
        case let .sessionExport(payload):
            try payload.encode(to: encoder)
        case let .settingsReplace(payload):
            try payload.encode(to: encoder)
        }
    }
}

public struct EngineRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: EngineID
    public let command: EngineCommand

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case requestID = "request_id"
        case command
        case payload
    }

    public init(version: Int, requestID: EngineID, command: EngineCommand) throws {
        guard version == 1 else {
            throw EngineProtocolError.unsupportedVersion(version)
        }
        self.version = version
        self.requestID = requestID
        self.command = command
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else {
            throw EngineProtocolError.unsupportedVersion(version)
        }
        let requestID = try container.decode(EngineID.self, forKey: .requestID)
        let name = try container.decode(EngineCommandName.self, forKey: .command)
        let command = try EngineCommand.decode(name: name, payload: container.superDecoder(forKey: .payload))
        try self.init(version: version, requestID: requestID, command: command)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(command.name, forKey: .command)
        try command.encodePayload(to: container.superEncoder(forKey: .payload))
    }
}
