import Foundation
import Testing
@testable import MacAmbientJevCore

private struct SecureSessionFixture {
    let root: URL
    let layout: SessionLayout
    let outside: URL
    let sentinel: URL
    let original = Data("outside must remain unchanged".utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        layout = SessionLayout(sessionURL: root.appending(path: "session"))
        outside = root.appending(path: "outside")
        sentinel = outside.appending(path: "sentinel.json")
        try FileManager.default.createDirectory(at: layout.sessionURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try original.write(to: sentinel)
    }

    @discardableResult
    func link(_ url: URL, to target: URL? = nil) throws -> String {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target ?? sentinel)
        return try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func eventWriterRejectsSymlinkAtOpenAndAfterInitialization() async throws {
    let fixture = try SecureSessionFixture()
    defer { fixture.cleanup() }
    try fixture.link(fixture.layout.eventsURL)
    #expect(throws: CocoaError.self) { _ = try SessionWriter(sessionURL: fixture.layout.sessionURL) }
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)

    try FileManager.default.removeItem(at: fixture.layout.eventsURL)
    let writer = try SessionWriter(sessionURL: fixture.layout.sessionURL)
    try FileManager.default.removeItem(at: fixture.layout.eventsURL)
    try fixture.link(fixture.layout.eventsURL)
    await #expect(throws: CocoaError.self) {
        try await writer.append(EventDraft(eventType: "session.started", sessionID: UUID(), payload: "recording"))
    }
    #expect(throws: CocoaError.self) { _ = try SessionWriter.readDurableLog(eventsURL: fixture.layout.eventsURL) }
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
}

@Test func manifestAndMetadataRejectLinkedFilesWithoutReplacingThem() throws {
    let fixture = try SecureSessionFixture()
    defer { fixture.cleanup() }
    try fixture.link(fixture.layout.manifestURL)
    let destination = try fixture.link(fixture.layout.processingMetadataURL)
    let store = ProcessingMetadataStore(sessionURL: fixture.layout.sessionURL)
    #expect(throws: CocoaError.self) { _ = try fixture.layout.loadManifest() }
    #expect(throws: CocoaError.self) { _ = try store.load() }
    #expect(throws: CocoaError.self) {
        try store.beginFinalization(attemptID: "attempt", policy: .replace)
    }
    #expect(throws: CocoaError.self) {
        try store.save(ProcessingMetadata(
            finalizationAttempt: nil, activeRuns: nil,
            pendingClauseBoundarySegments: [], pendingContentPriorityClauses: []
        ))
    }
    #expect(throws: CocoaError.self) {
        try SessionFileAccess.writeAtomically(Data(), to: fixture.layout.manifestURL, relativeTo: fixture.layout.sessionURL)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: store.url.path) == destination)
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
}

@Test func audioDirectorySymlinkBlocksStorageAndProcessingWrites() throws {
    let fixture = try SecureSessionFixture()
    defer { fixture.cleanup() }
    try fixture.link(fixture.layout.audioDirectory, to: fixture.outside)
    #expect(throws: CocoaError.self) {
        try SessionAudioStorageStore(layout: fixture.layout).save(.recordingPCM)
    }
    #expect(throws: CocoaError.self) {
        _ = try DurableAudioWriter(directory: fixture.layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: fixture.layout.sessionURL)
    }
    #expect(throws: CocoaError.self) {
        _ = try AudioCheckpoint.loadRecovered(from: fixture.layout.processingDirectory, relativeTo: fixture.layout.sessionURL)
    }
    #expect(throws: CocoaError.self) { try SessionTransientAudio.remove(layout: fixture.layout, source: .recording(.microphone)) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outside.path) == [fixture.sentinel.lastPathComponent])
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
}

@Test func linkedChunkAndImportedOriginalAreNotRead() async throws {
    let fixture = try SecureSessionFixture()
    defer { fixture.cleanup() }
    let writer = try DurableAudioWriter(directory: fixture.layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: fixture.layout.sessionURL)
    try await writer.append(samples: [0.25, -0.5])
    let checkpoint = try await writer.finish()
    let chunk = fixture.layout.processingDirectory.appending(path: checkpoint.chunkFiles[0])
    try FileManager.default.removeItem(at: chunk)
    try fixture.link(chunk)
    let reader = try ProcessingTimelineReader(directory: fixture.layout.processingDirectory, checkpoint: checkpoint, sessionURL: fixture.layout.sessionURL)
    #expect(throws: CocoaError.self) { _ = try reader.readSamples(frameRange: 0..<2) }
    #expect(throws: CocoaError.self) {
        _ = try AudioCheckpoint.loadRecovered(from: fixture.layout.processingDirectory, relativeTo: fixture.layout.sessionURL)
    }
    try fixture.link(fixture.layout.audioDirectory.appending(path: "original.caf"))
    #expect(throws: CocoaError.self) { _ = try fixture.layout.importedOriginalURL() }
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
}

@Test func sessionDirectorySymlinkIsReportedByCatalogAndRecovery() throws {
    let fixture = try SecureSessionFixture()
    defer { fixture.cleanup() }
    let sessions = fixture.root.appending(path: "sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let linkedSession = sessions.appending(path: "linked-session")
    try fixture.link(linkedSession, to: fixture.outside)
    let catalog = try SavedSessionCatalog(fileManager: .default).list(sessionsRoot: sessions)
    #expect(catalog.count == 1)
    #expect(catalog[0].sessionURL.path == linkedSession.path)
    let recovery = try SessionRecoveryScanner(sessionsRoot: sessions).pendingSessions()
    #expect(recovery.candidates.isEmpty)
    #expect(recovery.failures.count == 1)
    #expect(throws: CocoaError.self) { _ = try SessionLayout(sessionURL: linkedSession).loadManifest() }
    #expect(throws: CocoaError.self) { try SessionFileAccess.removeIfPresent(linkedSession, relativeTo: sessions) }
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
}

@Test func openedHandleStaysOnOriginalFileAfterPathBecomesSymlink() throws {
    let fixture = try SecureSessionFixture()
    defer { fixture.cleanup() }
    let url = fixture.layout.eventsURL
    let original = Data("initial".utf8)
    try original.write(to: url)
    let handle = try SessionFileAccess.openHandle(url, relativeTo: fixture.layout.sessionURL, writable: true)
    defer { try? handle.close() }
    let retained = fixture.layout.sessionURL.appending(path: "retained.jsonl")
    try FileManager.default.moveItem(at: url, to: retained)
    try fixture.link(url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(" appended".utf8))
    try handle.synchronize()
    #expect(try Data(contentsOf: retained) == Data("initial appended".utf8))
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
    #expect(throws: CocoaError.self) { _ = try SessionFileAccess.read(url, relativeTo: fixture.layout.sessionURL) }
}

@Test func normalSessionStorageRoundTripsUnderExplicitBoundary() async throws {
    let fixture = try SecureSessionFixture()
    defer { fixture.cleanup() }
    let writer = try SessionWriter(sessionURL: fixture.layout.sessionURL)
    let sessionID = UUID()
    let envelope = try await writer.append(EventDraft(eventType: "session.started", sessionID: sessionID, payload: "recording"))
    #expect(envelope.eventSeq == 1)
    let recovered = try SessionRecovery.recoverJSONL(SessionWriter.readDurableLog(eventsURL: fixture.layout.eventsURL))
    #expect(recovered.lastEventSequence == 1)
    let metadata = ProcessingMetadataStore(sessionURL: fixture.layout.sessionURL)
    try metadata.beginFinalization(attemptID: "attempt", policy: .reject)
    #expect(try metadata.load()?.finalizationAttempt?.attemptID == "attempt")
    try SessionAudioStorageStore(layout: fixture.layout).save(.recordingPCM)
    #expect(try SessionAudioStorageStore(layout: fixture.layout).load() == .recordingPCM)
    let audio = try DurableAudioWriter(directory: fixture.layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: fixture.layout.sessionURL)
    try await audio.append(samples: [0.25, -0.5])
    let checkpoint = try await audio.finish()
    #expect(try ProcessingTimelineReader(directory: fixture.layout.processingDirectory, checkpoint: checkpoint, sessionURL: fixture.layout.sessionURL).readSamples(frameRange: 0..<2) == [0.25, -0.5])
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
}

@Test(arguments: [DurableAudioWriter.checkpointFilename, DurableAudioWriter.chunkIndexFilename, DurableAudioWriter.gapEventsFilename])
func processingRecoveryRefusesLinkedCheckpointAndJournals(filename: String) async throws {
    let fixture = try SecureSessionFixture()
    defer { fixture.cleanup() }
    let writer = try DurableAudioWriter(directory: fixture.layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: fixture.layout.sessionURL)
    try await writer.append(samples: [0.25])
    _ = try await writer.finish()
    let url = fixture.layout.processingDirectory.appending(path: filename)
    try FileManager.default.removeItem(at: url)
    let destination = try fixture.link(url)
    #expect(throws: CocoaError.self) {
        _ = try AudioCheckpoint.loadRecovered(from: fixture.layout.processingDirectory, relativeTo: fixture.layout.sessionURL)
    }
    #expect(throws: CocoaError.self) {
        _ = try DurableAudioWriter(directory: fixture.layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: fixture.layout.sessionURL)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == destination)
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
}

@Test func audioStorageStateRejectsLinkedLeafOnReadAndAtomicSave() throws {
    let fixture = try SecureSessionFixture()
    defer { fixture.cleanup() }
    let destination = try fixture.link(fixture.layout.audioStorageURL)
    let store = SessionAudioStorageStore(layout: fixture.layout)
    #expect(throws: CocoaError.self) { _ = try store.load() }
    #expect(throws: CocoaError.self) { try store.save(.recordingPCM) }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.layout.audioStorageURL.path) == destination)
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
}

@Test func outputWriteFollowsSymlinkedParentButRejectsSymlinkedOutput() throws {
    let fixture = try SecureSessionFixture()
    defer { fixture.cleanup() }
    let linkedParent = fixture.root.appending(path: "linked")
    try fixture.link(linkedParent, to: fixture.outside)
    let bytes = Data("report".utf8)
    try SessionFileAccess.writeOutputAtomically(bytes, to: linkedParent.appending(path: "report.json"))
    #expect(try Data(contentsOf: fixture.outside.appending(path: "report.json")) == bytes)

    try fixture.link(fixture.outside.appending(path: "alias.json"))
    #expect(throws: CocoaError.self) {
        try SessionFileAccess.writeOutputAtomically(bytes, to: linkedParent.appending(path: "alias.json"))
    }
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
}
