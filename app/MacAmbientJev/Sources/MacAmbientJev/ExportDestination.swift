import Foundation

enum ExportDestinationError: LocalizedError {
    case notSet
    case unavailable
    case bookmarkRefreshFailed(String)
    case autoExportSettingUnreadable

    var errorDescription: String? {
        switch self {
        case .notSet:
            "書き出し先フォルダが設定されていません。設定の「保存先」で選んでください"
        case .unavailable:
            "書き出し先フォルダが見つかりません。設定の「保存先」で選び直してください"
        case .bookmarkRefreshFailed(let reason):
            "書き出し先フォルダの参照を更新できません。設定の「保存先」で選び直してください: \(reason)"
        case .autoExportSettingUnreadable:
            "自動書き出しの設定を読めないため、自動では書き出しません。設定の「保存先」で切り替え直してください"
        }
    }
}

@MainActor
struct ExportDestinationStore {
    static let autoExportKey = "export.autoExport"
    /// Auto-export is on until the user turns it off.
    static let autoExportInitialValue = true
    private static let bookmarkKey = "export.destinationBookmark"
    private static let pathKey = "export.destinationPath"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var path: String? {
        defaults.data(forKey: Self.bookmarkKey) == nil ? nil : defaults.string(forKey: Self.pathKey)
    }

    /// Throws when the stored value is not a Bool, so a damaged setting never turns on
    /// writes to the external folder.
    func isAutoExportEnabled() throws -> Bool {
        guard let stored = defaults.object(forKey: Self.autoExportKey) else {
            return Self.autoExportInitialValue
        }
        guard let value = stored as? Bool else {
            throw ExportDestinationError.autoExportSettingUnreadable
        }
        return value
    }

    func save(directory: URL) throws {
        let bookmark = try directory.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        defaults.set(directory.path, forKey: Self.pathKey)
    }

    func withAccess<T>(_ body: (URL) async throws -> T) async throws -> T {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else {
            throw ExportDestinationError.notSet
        }
        var isStale = false
        let directory: URL
        do {
            directory = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw ExportDestinationError.unavailable
        }

        let accessed = directory.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                directory.stopAccessingSecurityScopedResource()
            }
        }
        let isDirectory: Bool
        do {
            isDirectory = try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        } catch {
            throw ExportDestinationError.unavailable
        }
        guard isDirectory else {
            throw ExportDestinationError.unavailable
        }
        if isStale {
            do {
                try save(directory: directory)
            } catch {
                throw ExportDestinationError.bookmarkRefreshFailed(error.localizedDescription)
            }
        }
        return try await body(directory)
    }
}
