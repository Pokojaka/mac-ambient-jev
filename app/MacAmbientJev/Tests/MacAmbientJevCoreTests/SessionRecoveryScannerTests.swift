import Foundation
import Testing
@testable import MacAmbientJevCore

private func writeRecoveryManifest(
    sessionID: UUID,
    sourceKind: SessionSourceKind,
    to sessionURL: URL
) throws {
    try FileManager.default.createDirectory(
        at: sessionURL,
        withIntermediateDirectories: true
    )
    let manifest = SessionManifest(
        sessionID: sessionID,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        sourceKind: sourceKind,
        originalFilename: sourceKind == .importedFile ? "fixture.wav" : nil
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(
        to: sessionURL.appending(path: "session.json"),
        options: .atomic
    )
}

@Test
func recoveryScannerFindsImportedSessionBeforeTimelineExists() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let sessionURL = root.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(
        sessionID: sessionID,
        sourceKind: .importedFile,
        to: sessionURL
    )

    let audioURL = sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
    let original = audioURL.appending(path: "original.wav")
    try Data([0, 1, 2, 3]).write(to: original)

    let candidates = try SessionRecoveryScanner(
        sessionsRoot: root
    ).pendingSessions()

    #expect(candidates.count == 1)
    #expect(candidates.first?.manifest.sessionID == sessionID)
    guard case .importedOriginal(let recoveredURL) = candidates.first?.source else {
        Issue.record("imported original should be recoverable")
        return
    }
    #expect(
        recoveredURL.resolvingSymlinksInPath()
            == original.resolvingSymlinksInPath()
    )
}

@Test
func recoveryScannerPrefersExistingProcessingCheckpoint() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let sessionURL = root.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(
        sessionID: sessionID,
        sourceKind: .live,
        to: sessionURL
    )

    let processingURL = sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: processingURL,
        withIntermediateDirectories: true
    )
    let checkpoint = AudioCheckpoint(
        committedFrames: 48_000,
        sampleRate: 48_000,
        channelCount: 1,
        chunkFiles: ["chunk-000000.f32le"]
    )
    try JSONEncoder().encode(checkpoint).write(
        to: processingURL.appending(path: DurableAudioWriter.checkpointFilename),
        options: .atomic
    )

    let candidates = try SessionRecoveryScanner(
        sessionsRoot: root
    ).pendingSessions()