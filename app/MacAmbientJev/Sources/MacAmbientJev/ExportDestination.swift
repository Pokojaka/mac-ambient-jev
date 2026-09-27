import Foundation

enum ExportDestinationError: LocalizedError {
    case notSet
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notSet:
            "書き出し先フォルダが設定されていません。設定の「保存先」で選んでください"
        case .unavailable:
            "書き出し先フォルダが見つかりません。設定の「保存先」で選び直してください"
        }
    }
}

@MainActor
struct ExportDestinationStore {
    static let autoExportKey = "export.autoExport"
    private static let bookmarkKey = "export.destinationBookmark"
    private static let pathKey = "export.destinationPath"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var path: String? {
        defaults.data(forKey: Self.bookmarkKey) == nil ? nil : defaults.string(forKey: Self.pathKey)
    }

    var isAutoExportEnabled: Bool {
        defaults.object(forKey: Self.autoExportKey) as? Bool ?? true
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
        guard let directory = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            throw ExportDestinationError.unavailable
        }

        let accessed = directory.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                directory.stopAccessingSecurityScopedResource()
            }
        }
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw ExportDestinationError.unavailable
        }
        if isStale {
            try? save(directory: directory)
        }
        return try await body(directory)
    }
}
