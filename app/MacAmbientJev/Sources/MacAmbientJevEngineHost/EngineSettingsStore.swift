import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol

public enum EngineSettingsError: Error, LocalizedError, Equatable {
    case required(path: String)
    case corrupt(path: String, reason: String)
    case invalid(reason: String)
    case staleRevision(expected: EngineID?, actual: EngineID?)
    case revisionExhausted
    case filesystem(path: String, reason: String)

    public var errorCode: EngineErrorCode {
        switch self {
        case .required: .settingsRequired
        case .corrupt, .invalid: .invalidSettings
        case .staleRevision: .staleRevision
        case .revisionExhausted: .internalError
        case .filesystem: .filesystem
        }
    }

    public var recoveryAction: EngineRecoveryAction {
        switch self {
        case .required, .corrupt, .invalid: .replaceSettings
        case .staleRevision: .retry
        case .revisionExhausted: .none
        case .filesystem: .retry
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .required(path):
            "設定が必要です。設定ファイルがありません: \(path)"
        case let .corrupt(path, reason):
            "設定ファイルが不正です。設定を全体置換してください: \(path) (\(reason))"
        case let .invalid(reason):
            "設定が不正です: \(reason)"
        case let .staleRevision(expected, actual):
            "設定の revision が一致しません（期待: \(expected?.rawValue ?? "null"), 実際: \(actual?.rawValue ?? "なし")）"
        case .revisionExhausted:
            "設定の revision が上限に達しました"
        case let .filesystem(path, reason):
            "設定ファイルにアクセスできません: \(path) (\(reason))"
        }
    }
}

/// The engine settings file `<application root>/settings.json`: one `EngineSettingsResult` object
/// (`revision` plus the strictly typed `settings`), replaced durably as a whole.
///
/// There are no defaults and no migration. A missing file is `required`; an unreadable or invalid file is
/// `corrupt` and only a full replacement with `expectedRevision == nil` repairs it, restarting at revision 1.
/// Callers serialize `load` and `replace`; the engine controller owns both.
public struct EngineSettingsStore: Sendable {
    public static let fileName = "settings.json"

    public let root: URL
    public let logicalCPUCount: Int

    public init(paths: AppPaths, logicalCPUCount: Int) {
        self.root = paths.root
        self.logicalCPUCount = logicalCPUCount
    }

    public var fileURL: URL {
        root.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    public func load() throws -> EngineSettingsResult {
        guard let result = try readCurrent() else {
            throw EngineSettingsError.required(path: fileURL.path)
        }
        return result
    }

    @discardableResult
    public func replace(expectedRevision: EngineID?, settings: EngineSettings) throws -> EngineSettingsResult {
        do {
            try settings.validate(logicalCPUCount: logicalCPUCount)
        } catch {
            throw EngineSettingsError.invalid(reason: String(describing: error))
        }

        let current: EngineSettingsResult?
        do {
            current = try readCurrent()
        } catch EngineSettingsError.corrupt where expectedRevision == nil {
            return try publish(revision: try Self.next(after: nil), settings: settings)
        }
        guard current?.revision == expectedRevision else {
            throw EngineSettingsError.staleRevision(expected: expectedRevision, actual: current?.revision)
        }
        return try publish(revision: try Self.next(after: current?.revision), settings: settings)
    }

    private func publish(revision: EngineID, settings: EngineSettings) throws -> EngineSettingsResult {
        let result = EngineSettingsResult(revision: revision, settings: settings)
        let data: Data
        do {
            data = try Self.makeEncoder().encode(result)
            try EngineJSONValidator.validate(data)
        } catch {
            throw EngineSettingsError.invalid(reason: String(describing: error))
        }
        do {
            try SessionFileAccess.createDirectory(root, relativeTo: root)
            try SessionFileAccess.writeAtomically(data, to: fileURL, relativeTo: root)
        } catch {
            throw EngineSettingsError.filesystem(path: fileURL.path, reason: error.localizedDescription)
        }
        return result
    }

    private func readCurrent() throws -> EngineSettingsResult? {
        let data: Data?
        do {
            data = try SessionFileAccess.readIfPresent(fileURL, relativeTo: root)
        } catch {
            throw EngineSettingsError.filesystem(path: fileURL.path, reason: error.localizedDescription)
        }
        guard let data else { return nil }
        do {
            try EngineJSONValidator.validate(data)
            let result = try JSONDecoder().decode(EngineSettingsResult.self, from: data)
            try result.settings.validate(logicalCPUCount: logicalCPUCount)
            return result
        } catch {
            throw EngineSettingsError.corrupt(path: fileURL.path, reason: String(describing: error))
        }
    }

    private static func next(after revision: EngineID?) throws -> EngineID {
        guard let revision else { return try EngineID(1) }
        let (value, overflow) = revision.value.addingReportingOverflow(1)
        guard !overflow else { throw EngineSettingsError.revisionExhausted }
        return try EngineID(value)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
