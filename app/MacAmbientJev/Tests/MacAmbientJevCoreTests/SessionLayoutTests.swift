import Foundation
import Testing
@testable import MacAmbientJevCore

private func makeSession(source: SessionSource) throws -> (SessionLayout, SessionManifest) {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let manifest = SessionManifest(
        sessionID: UUID(),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: source
    )
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let layout = SessionLayout(sessionURL: try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: manifest.sessionID, source: source,
        createdAt: manifest.createdAt, timeZone: TimeZone(secondsFromGMT: 0)!
    ))
    try FileManager.default.createDirectory(at: layout.audioDirectory, withIntermediateDirectories: true)
    return (layout, manifest)
}

@Test
func importedSessionAudioIsTheOriginalEvenWhenATimelineExists() async throws {
    let (layout, manifest) = try makeSession(source: .imported(originalFilename: "lecture.m4a"))
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }
    let original = layout.audioDirectory.appending(path: "original.m4a")
    try Data([1, 2, 3]).write(to: original)
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: layout.sessionURL)
    try await writer.append(samples: Array(repeating: 0.5, count: 10))
    _ = try await writer.finish()

    guard case .importedOriginal(let url, let timeline) = try layout.audioSource(for: manifest) else {
        Issue.record("an import must resolve to its original")
        return
    }
    #expect(url.resolvingSymlinksInPath() == original.resolvingSymlinksInPath())
    #expect(timeline == nil)
}

@Test
func importedSessionWithoutOriginalIsAnError() throws {
    let (layout, manifest) = try makeSession(source: .imported(originalFilename: "lecture.m4a"))
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }

    #expect(throws: SessionAudioSourceError.importedOriginalMissing) {
        _ = try layout.audioSource(for: manifest)
    }
}

@Test
func importedSessionWithSeveralOriginalsIsAnError() throws {
    let (layout, manifest) = try makeSession(source: .imported(originalFilename: "lecture.m4a"))
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }
    try Data([1]).write(to: layout.audioDirectory.appending(path: "original.wav"))
    try Data([2]).write(to: layout.audioDirectory.appending(path: "original.m4a"))

    #expect(throws: SessionAudioSourceError.multipleImportedOriginals(["original.m4a", "original.wav"])) {
        _ = try layout.audioSource(for: manifest)
    }
}

@Test
func recordingWithoutCapturedAudioHasNoSource() async throws {
    let (layout, manifest) = try makeSession(source: .recording(.microphone))
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }
    #expect(try layout.audioSource(for: manifest) == nil)

    _ = try await DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: layout.sessionURL).finish()
    #expect(try layout.audioSource(for: manifest) == nil)
}

@Test
func recordingResolvesToItsTimelineAndRejectsACorruptOne() async throws {
    let (layout, manifest) = try makeSession(source: .recording(.microphone))
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: layout.sessionURL)
    try await writer.append(samples: Array(repeating: 0.5, count: 10))
    let checkpoint = try await writer.finish()
    #expect(try layout.audioSource(for: manifest) == .recordedPCM(checkpoint))

    try Data(count: 3).write(to: layout.processingDirectory.appending(path: checkpoint.chunkFiles[0]))
    #expect(throws: (any Error).self) {
        _ = try layout.audioSource(for: manifest)
    }
}

@Test
func flacRecordingResolvesFromStorageStateAndRequiresTheFile() throws {
    let (layout, manifest) = try makeSession(source: .recording(.microphone))
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }
    let info = try TimelineAudioInfo(committedFrames: 16_000, gapEvents: [])
    try SessionAudioStorageStore(layout: layout).save(.recordingFLAC(info))

    #expect(throws: SessionAudioSourceError.recordingFLACMissing) {
        _ = try layout.audioSource(for: manifest)
    }
    try Data([0]).write(to: layout.recordingFLACURL)
    #expect(try layout.audioSource(for: manifest) == .recordedFLAC(info))
}

@Test
func missingStorageStateIsAnError() throws {
    let (layout, manifest) = try makeSession(source: .recording(.microphone))
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }
    try FileManager.default.removeItem(at: layout.audioStorageURL)

    #expect(throws: SessionAudioStorageError.missing) {
        _ = try layout.audioSource(for: manifest)
    }
}

@Test
func storageStateMustMatchHowTheSessionWasCreated() throws {
    let (layout, manifest) = try makeSession(source: .imported(originalFilename: "lecture.m4a"))
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }
    try SessionAudioStorageStore(layout: layout).save(.recordingPCM)

    #expect(throws: SessionAudioStorageError.sourceMismatch) {
        _ = try layout.audioSource(for: manifest)
    }
}

@Test
func storageStateRoundTripsEveryCase() throws {
    let info = try TimelineAudioInfo(
        committedFrames: 32_000,
        gapEvents: [AudioGapEvent(startFrame: 100, frameCount: 50, reason: .overflow)]
    )
    let (layout, _) = try makeSession(source: .recording(.microphone))
    defer { try? FileManager.default.removeItem(at: layout.sessionURL.deletingLastPathComponent()) }
    let store = SessionAudioStorageStore(layout: layout)
    for state: SessionAudioStorage in [.recordingPCM, .recordingFLAC(info), .importedOriginal(nil), .importedOriginal(info)] {
        try store.save(state)
        #expect(try store.load() == state)
    }
}
