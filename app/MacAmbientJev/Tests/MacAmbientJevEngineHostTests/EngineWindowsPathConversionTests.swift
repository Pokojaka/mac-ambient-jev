#if os(Windows)
import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineHost

@Suite struct EngineWindowsPathConversionTests {
    @Test func fileURLPathsUseHostPathConversion() {
        // This is a URL-only fixture: the test never reads or writes under C:\\Users.
        let appRoot = URL(
            fileURLWithPath: #"C:\Users\Aki\AppData\Local\mac-ambient-jev"#,
            isDirectory: true
        )
        let sessionFolderName = "2025-03-08_19-22-31_録音_00000002"
        let folderURL = appRoot.appending(
            path: "sessions/\(sessionFolderName)", directoryHint: .isDirectory
        )
        let appSupportURL = appRoot.deletingLastPathComponent()
        let paths = AppPaths(
            applicationSupportURL: appSupportURL,
            cacheURL: appSupportURL.appending(path: "Caches", directoryHint: .isDirectory),
            sessionsRootOverride: nil
        )
        let settingsStore = EngineSettingsStore(paths: paths, logicalCPUCount: 4)
        let settingsURL = settingsStore.fileURL
        let missingSettingsMessage = EngineSettingsError.required(path: settingsURL.path).localizedDescription

        #expect(appRoot.isFileURL)
        #expect(folderURL.isFileURL)
        #expect(settingsStore.root.isFileURL)
        #expect(settingsURL.isFileURL)
        #expect(folderURL.lastPathComponent == sessionFolderName)
        #expect(Array(folderURL.pathComponents.suffix(2)) == ["sessions", sessionFolderName])
        #expect(Array(settingsURL.pathComponents.suffix(2)) == ["mac-ambient-jev", "settings.json"])

        #expect(settingsStore.root.path == appRoot.path)
        #expect(settingsURL.path == appRoot.appending(path: "settings.json", directoryHint: .notDirectory).path)
        #expect(
            URL(fileURLWithPath: settingsStore.root.path, isDirectory: true).standardizedFileURL.path
                == appRoot.standardizedFileURL.path
        )
        #expect(
            URL(fileURLWithPath: folderURL.path, isDirectory: true).standardizedFileURL.path
                == folderURL.standardizedFileURL.path
        )
        #expect(
            URL(fileURLWithPath: settingsURL.path).standardizedFileURL.path
                == settingsURL.standardizedFileURL.path
        )
        #expect(folderURL.path == "C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/2025-03-08_19-22-31_録音_00000002")
        #expect(settingsURL.path == "C:/Users/Aki/AppData/Local/mac-ambient-jev/settings.json")
        #expect(missingSettingsMessage == "設定が必要です。設定ファイルがありません: C:/Users/Aki/AppData/Local/mac-ambient-jev/settings.json")
    }
}
#endif
