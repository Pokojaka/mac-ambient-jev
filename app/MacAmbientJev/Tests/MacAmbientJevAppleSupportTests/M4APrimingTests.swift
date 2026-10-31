import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevAppleSupport

/// The same fixtures and numbers as the Windows import tests: 12,288 frames with the signal at 3,074
/// where `elst` or `iTunSMPB` names the priming, and every decoded frame (13,312, signal at 4,098) without metadata.
@Test(arguments: [
    ("windows_audio_fixture", Int64(4_096), 1_025),
    ("windows_audio_fixture_itunsmpb", Int64(4_096), 1_025),
    ("windows_audio_fixture_no_edit_metadata", Int64(4_437), 1_366),
])
func m4aImportFollowsItsPrimingMetadata(name: String, canonicalFrames: Int64, canonicalOnset: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = try #require(Bundle.module.url(forResource: name, withExtension: "m4a", subdirectory: "Resources"))
    let source = root.appending(path: "original.m4a")
    try FileManager.default.copyItem(at: fixture, to: source)

    let processing = root.appending(path: "processing", directoryHint: .isDirectory)
    let checkpoint = try await AudioFileTimelineBuilder(readFrameCount: 97).build(
        from: source, into: processing, sessionURL: root
    )
    #expect(checkpoint.committedFrames == canonicalFrames)
    let samples = try ProcessingTimelineReader(directory: processing, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<checkpoint.committedFrames)
    let onset = try #require(samples.firstIndex(where: { abs($0) > 0.05 }))
    #expect(abs(onset - canonicalOnset) <= 2)
}

/// ALAC in M4A has no encoder priming: the import keeps every frame. The fixture is 4,000 frames at 16 kHz,
/// silent for the first 1,000 and a 440 Hz tone after.
@Test func alacM4AImportKeepsEveryFrame() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = try #require(Bundle.module.url(forResource: "alac_fixture", withExtension: "m4a", subdirectory: "Resources"))
    let source = root.appending(path: "original.m4a")
    try FileManager.default.copyItem(at: fixture, to: source)

    let processing = root.appending(path: "processing", directoryHint: .isDirectory)
    let checkpoint = try await AudioFileTimelineBuilder(readFrameCount: 97).build(
        from: source, into: processing, sessionURL: root
    )
    #expect(checkpoint.committedFrames == 4_000)
    let samples = try ProcessingTimelineReader(directory: processing, checkpoint: checkpoint, sessionURL: root)
        .readSamples(frameRange: 0..<checkpoint.committedFrames)
    let onset = try #require(samples.firstIndex(where: { abs($0) > 0.05 }))
    #expect(abs(onset - 1_000) <= 2)
}
