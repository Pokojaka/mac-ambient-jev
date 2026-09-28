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
            _ = try CaptureSystemAudioOptions.parse(arguments)
        }
    }
    let parsed = try CaptureSystemAudioOptions.parse(
        ["--sessions-root", safe.path, "--transcribe", "--duration", "1.25"]
    )
    #expect(parsed.sessionsRoot == safe)
    #expect(parsed.duration == 1.25)
    #expect(parsed.transcribe)
}

@Test
func captureRejectsInvalidDurationAndAmbiguousOptions() throws {
    let safe = FileManager.default.temporaryDirectory
        .appending(path: "system-audio-test-\(UUID().uuidString)")
    for duration in ["0", "-1", "nan", "inf", "1e300", "text"] {
        #expect(throws: CaptureSystemAudioError.self) {
            _ = try CaptureSystemAudioOptions.parse(
                ["--duration", duration, "--sessions-root", safe.path]
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
                ["--duration", "1", "--sessions-root", safe.path] + suffix
            )
        }
    }
}

@Test
func captureNeverTargetsRealAppDataEvenWhenExplicitlyNamed() throws {
    let defaults = AppPaths.systemDefault()
    for root in [
        defaults.root,
        defaults.sessionsRoot,
        defaults.sessionsRoot.appending(path: "subfolder"),
        defaults.applicationSupportURL,
        defaults.cachesRoot,
    ] {
        #expect(throws: CaptureSystemAudioError.unsafeSessionsRoot) {
            _ = try CaptureSystemAudioOptions.parse(
                ["--duration", "1", "--sessions-root", root.path]
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
        cacheURL: directory.appending(path: "Library/Caches")
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
    #expect(parsed.sessionsRoot == selected)
}
