import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevCaptureSystemAudio

@Test
func captureRequiresExplicitDurationAndSessionsRoot() throws {
    let safe = FileManager.default.temporaryDirectory
        .appending(path: "system-audio-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    for arguments in [
        [],
        ["--duration", "1"],
        ["--sessions-root", safe.path],
        ["--transcribe", "--duration", "1"],
        ["--duration", "1", "--sessions-root"],
    ] {
        #expect(throws: CaptureSystemAudioError.self) {
            _ = try CaptureSystemAudioOptions.parse(arguments, appPaths: try AppPaths.systemDefault(fileManager: .default))
        }
    }
    let parsed = try CaptureSystemAudioOptions.parse(
        ["--sessions-root", safe.path, "--transcribe", "--duration", "1.25"], appPaths: try AppPaths.systemDefault(fileManager: .default)
    )
    #expect(parsed.sessionsRoot.path == safe.path)
    #expect(parsed.duration == 1.25)
    #expect(parsed.transcribe)
}

@Test
func captureReadyFileIsOptionalAndAcceptsEitherOptionOrder() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "system-audio-ready-\(UUID().uuidString)")
    let sessions = directory.appending(path: "sessions")
    let ready = directory.appending(path: "started")
    let withoutReady = try CaptureSystemAudioOptions.parse(
        ["--duration", "1", "--sessions-root", sessions.path], appPaths: try AppPaths.systemDefault(fileManager: .default)
    )
    #expect(withoutReady.readyFile == nil)
    for arguments in [
        ["--ready-file", ready.path, "--sessions-root", sessions.path, "--duration", "1"],
        ["--sessions-root", sessions.path, "--duration", "1", "--ready-file", ready.path],
    ] {
        let parsed = try CaptureSystemAudioOptions.parse(arguments, appPaths: try AppPaths.systemDefault(fileManager: .default))
        #expect(parsed.readyFile == ready)
    }
}

@Test
func captureReadyFileRejectsMissingAndDuplicatePaths() {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "system-audio-ready-\(UUID().uuidString)")
    let base = ["--duration", "1", "--sessions-root", directory.path]
    for arguments in [
        base + ["--ready-file"],
        base + ["--ready-file", ""],
        base + ["--ready-file", "--transcribe"],
        ["--ready-file", "--duration"] + base,
        base + ["--ready-file", directory.appending(path: "ready").path,
                "--ready-file", directory.appending(path: "other").path],
    ] {
        #expect(throws: CaptureSystemAudioError.usage) {
            _ = try CaptureSystemAudioOptions.parse(arguments, appPaths: try AppPaths.systemDefault(fileManager: .default))
        }
    }
}

@Test
func captureRejectsInvalidDurationAndAmbiguousOptions() throws {
    let safe = FileManager.default.temporaryDirectory
        .appending(path: "system-audio-test-\(UUID().uuidString)")
    for duration in ["0", "-1", "nan", "inf", "1e300", "text"] {
        #expect(throws: CaptureSystemAudioError.self) {
            _ = try CaptureSystemAudioOptions.parse(
                ["--duration", duration, "--sessions-root", safe.path], appPaths: try AppPaths.systemDefault(fileManager: .default)
            )
        }
    }
    for suffix in [
        ["--duration", "2"],
        ["--sessions-root", safe.path],
        ["--transcribe", "--transcribe"],
        ["unexpected"],
    ] {
        #expect(throws: CaptureSystemAudioError.self) {
            _ = try CaptureSystemAudioOptions.parse(
                ["--duration", "1", "--sessions-root", safe.path] + suffix, appPaths: try AppPaths.systemDefault(fileManager: .default)
            )
        }
    }
}

@Test
func captureNeverTargetsRealAppDataEvenWhenExplicitlyNamed() throws {
    let defaults = try AppPaths.systemDefault(fileManager: .default)
    for root in [
        defaults.root,
        defaults.sessionsRoot,
        defaults.sessionsRoot.appending(path: "subfolder"),
        defaults.applicationSupportURL,
        defaults.cachesRoot,
    ] {
        #expect(throws: CaptureSystemAudioError.unsafeSessionsRoot) {
            _ = try CaptureSystemAudioOptions.parse(
                ["--duration", "1", "--sessions-root", root.path], appPaths: try AppPaths.systemDefault(fileManager: .default)
            )
        }
    }
}

@Test
func captureRejectsSymlinkAliasToAppDataRoot() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "system-audio-guards-\(UUID().uuidString)")
    let appSupport = directory.appending(path: "Library/Application Support")
    let paths = AppPaths(
        applicationSupportURL: appSupport,
        cacheURL: directory.appending(path: "Library/Caches"),
        sessionsRootOverride: nil
    )
    let alias = directory.appending(path: "alias")
    try FileManager.default.createDirectory(at: paths.sessionsRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: paths.root)

    for root in [alias, alias.appending(path: "sessions/other")] {
        #expect(throws: CaptureSystemAudioError.unsafeSessionsRoot) {
            _ = try CaptureSystemAudioOptions.parse(
                ["--duration", "1", "--sessions-root", root.path],
                appPaths: paths
            )
        }
    }
    let selected = directory.appending(path: "separate-sessions")
    let parsed = try CaptureSystemAudioOptions.parse(
        ["--duration", "1", "--sessions-root", selected.path], appPaths: paths
    )
    #expect(parsed.sessionsRoot.path == selected.path)
}

@Test
func captureRequiresDirectoryAndProtectsBothAppStorageTrees() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "system-audio-root-\(UUID().uuidString)")
    let paths = AppPaths(
        applicationSupportURL: directory.appending(path: "Library/Application Support"),
        cacheURL: directory.appending(path: "Library/Caches"),
        sessionsRootOverride: nil
    )
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.cachesRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appending(path: "recording-is-a-file")
    try Data().write(to: file)
    for root in [
        file,
        paths.cachesRoot.appending(path: "sessions"),
        paths.cacheURL,
        directory.appending(path: "Library"),
    ] {
        #expect(throws: CaptureSystemAudioError.unsafeSessionsRoot) {
            _ = try CaptureSystemAudioOptions.parse(
                ["--duration", "1", "--sessions-root", root.path], appPaths: paths
            )
        }
    }

    let safe = directory.appending(path: "independent-sessions")
    let parsed = try CaptureSystemAudioOptions.parse(
        ["--duration", "1", "--sessions-root", safe.path], appPaths: paths
    )
    #expect(parsed.sessionsRoot.path == safe.path)
}
