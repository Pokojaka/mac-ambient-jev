import Foundation
import Testing
@testable import MacAmbientJevCore

private func makeSession(sourceKind: SessionSourceKind) throws -> (SessionLayout, SessionManifest) {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let manifest = SessionManifest(
        sessionID: UUID(),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        sourceKind: sourceKind,
        captureSource: .microphone
    )
    let layout = SessionLayout(sessionsRoot: root, sessionID: manifest.sessionID)
    try FileManager.default.createDirectory(at: layout.audioDirectory, withIntermediateDirectories: true)
    return (layout, manifest)
}

@Test
func importedSessionAudioIsTheOriginalEvenWhenATimelineExists() async throws {
    let (layout, manifest) = try makeSession(sourceKind: .importedFile)
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }
    let original = layout.audioDirectory.appending(path: "original.m4a")
    try Data([1, 2, 3]).write(to: original)
    let writer = try DurableAudioWriter(
        directory: layout.processingDirectory, sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1
    )
    try await writer.append(samples: Array(repeating: 0.5, count: 10))
    _ = try await writer.finish()

    guard case .importedOriginal(let url) = try layout.audioSource(for: manifest) else {
        Issue.record("an import must resolve to its original")
        return
    }
    #expect(url.resolvingSymlinksInPath() == original.resolvingSymlinksInPath())
}

@Test
func importedSessionWithoutOriginalIsAnError() throws {
    let (layout, manifest) = try makeSession(sourceKind: .importedFile)
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }

    #expect(throws: SessionAudioSourceError.importedOriginalMissing) {
        _ = try layout.audioSource(for: manifest)
    }
}

@Test
func importedSessionWithSeveralOriginalsIsAnError() throws {
    let (layout, manifest) = try makeSession(sourceKind: .importedFile)
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }
    try Data([1]).write(to: layout.audioDirectory.appending(path: "original.wav"))
    try Data([2]).write(to: layout.audioDirectory.appending(path: "original.m4a"))

    #expect(throws: SessionAudioSourceError.multipleImportedOriginals(["original.m4a", "original.wav"])) {
        _ = try layout.audioSource(for: manifest)
    }
}

@Test
func recordingWithoutCapturedAudioHasNoSource() async throws {
    let (layout, manifest) = try makeSession(sourceKind: .live)
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }
    #expect(try layout.audioSource(for: manifest) == nil)

    _ = try await DurableAudioWriter(
        directory: layout.processingDirectory, sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1
    ).finish()
    #expect(try layout.audioSource(for: manifest) == nil)
}

@Test
func recordingResolvesToItsTimelineAndRejectsACorruptOne() async throws {
    let (layout, manifest) = try makeSession(sourceKind: .live)
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }
    let writer = try DurableAudioWriter(
        directory: layout.processingDirectory, sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1
    )
    try await writer.append(samples: Array(repeating: 0.5, count: 10))
    let checkpoint = try await writer.finish()
    #expect(try layout.audioSource(for: manifest) == .recordedTimeline(checkpoint))

    try Data(count: 3).write(to: layout.processingDirectory.appending(path: checkpoint.chunkFiles[0]))
    #expect(throws: (any Error).self) {
        _ = try layout.audioSource(for: manifest)
    }
}
