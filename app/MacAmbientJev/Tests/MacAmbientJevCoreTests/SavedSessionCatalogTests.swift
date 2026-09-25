import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func catalogSortsSessionsNewestFirstAndReportsMissingAudio() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let older = UUID()
    let newer = UUID()
    try writeCatalogSession(id: older, createdAt: 1_700_000_000, source: .live, root: root, includeAudio: true)
    try writeCatalogSession(id: newer, createdAt: 1_700_000_100, source: .live, root: root, includeAudio: false)

    let summaries = try SavedSessionCatalog().list(sessionsRoot: root)

    #expect(summaries.map(\.sessionID) == [newer, older])
    #expect(summaries.first?.audioAvailable == false)
    #expect(summaries.first?.canReprocess == false)
    #expect(summaries.last?.canReprocess == true)
}

@Test
func catalogKeepsCorruptSessionMetadataVisibleAsAnErrorRow() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let id = UUID()
    let session = root.appending(path: id.uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    try Data("{broken".utf8).write(to: session.appending(path: "session.json"))

    let row = try #require(SavedSessionCatalog().list(sessionsRoot: root).first)

    #expect(row.sessionID == id)
    #expect(row.errorMessage != nil)
    #expect(row.canReprocess == false)
}

@Test
func catalogUsesTheSavedImportedOriginalWhenTimelineIsAbsent() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let id = UUID()
    let session = try writeCatalogSession(
        id: id, createdAt: 1_700_000_000, source: .importedFile,
        root: root, includeAudio: false
    )
    let audio = session.appending(path: "audio", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: audio.appending(path: "original.wav"))

    let row = try #require(SavedSessionCatalog().list(sessionsRoot: root).first)

    #expect(row.sourceKind == .importedFile)
    #expect(row.audioAvailable)
    #expect(row.canReprocess)
}

@Test
func catalogReportsCorruptProcessingMetadataWithoutDroppingOtherRows() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let id = UUID()
    let session = try writeCatalogSession(id: id, createdAt: 1_700_000_000, source: .live, root: root, includeAudio: true)
    try Data("{broken".utf8).write(to: session.appending(path: "processing_metadata.json"))

    let row = try #require(SavedSessionCatalog().list(sessionsRoot: root).first)

    #expect(row.errorMessage != nil)
    #expect(row.canReprocess == false)
}

@Test
func catalogSummaryShowsFinalizationStateAndActiveTranscript() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let id = UUID()
    let session = try writeCatalogSession(id: id, createdAt: 1_700_000_000, source: .live, root: root, includeAudio: true)
    try ProcessingMetadataStore(sessionURL: session).save(ProcessingMetadata(
        timelineVersion: 1, vadVersion: "vad", vadConfigHash: "hash",
        asrEngine: "qwen", asrModel: "model", asrVersion: "version",
        diarizationVersion: "diar", sceneAnalyzerVersion: 1,
        jevSchemaVersion: 1, policyVersion: 1, materializerSchemaVersion: 1,
        activeRuns: ActiveRuns(asr: "asr"),
        finalizationAttempt: FinalizationAttempt(attemptID: "a", state: .failed, failureReason: "decode failed")
    ))

    let row = try #require(SavedSessionCatalog().list(sessionsRoot: root).first)

    #expect(row.hasActiveTranscript)
    #expect(row.processingStatus == .failed("decode failed"))
}

@Test
func reprocessGateAcceptsOnlyOneQueuedAttemptPerSession() {
    var gate = SavedSessionReprocessGate()
    let id = UUID()

    let firstClaim = gate.claim(id)
    #expect(firstClaim)
    let duplicateClaim = gate.claim(id)
    #expect(!duplicateClaim)
    #expect(gate.sessionIDs == Set([id]))
    gate.release(id)
    let claimAfterRelease = gate.claim(id)
    #expect(claimAfterRelease)
}

@Test
func savedSessionSelectionIsUnavailableDuringRecording() {
    #expect(!SavedSessionSelectionPolicy.canSelect(isRecording: true))
    #expect(SavedSessionSelectionPolicy.canSelect(isRecording: false))
}

@discardableResult
private func writeCatalogSession(
    id: UUID,
    createdAt: TimeInterval,
    source: SessionSourceKind,
    root: URL,
    includeAudio: Bool
) throws -> URL {
    let session = root.appending(path: id.uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(SessionManifest(
        sessionID: id,
        createdAt: Date(timeIntervalSince1970: createdAt),
        sourceKind: source
    )).write(to: session.appending(path: "session.json"), options: .atomic)
    if includeAudio {
        let processing = session.appending(path: "audio/processing", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
        let filename = "chunk-000000.f32le"
        try Data([0, 0, 0, 0]).write(to: processing.appending(path: filename))
        try JSONEncoder().encode(AudioCheckpoint(
            committedFrames: 1, sampleRate: 1, channelCount: 1,
            chunkFiles: [filename], chunkFrameCounts: [1]
        )).write(to: processing.appending(path: DurableAudioWriter.checkpointFilename), options: .atomic)
    }
    return session
}

@Test
func catalogReportsPendingClassificationAfterLocalFinalization() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let id = UUID()
    let session = try writeCatalogSession(
        id: id, createdAt: 1_700_000_000, source: .live, root: root, includeAudio: true
    )
    try ProcessingMetadataStore(sessionURL: session).save(ProcessingMetadata(
        timelineVersion: 1, vadVersion: "vad", vadConfigHash: "hash",
        asrEngine: "qwen", asrModel: "model", asrVersion: "version",
        diarizationVersion: "diar", sceneAnalyzerVersion: 1,
        jevSchemaVersion: 1, policyVersion: 1, materializerSchemaVersion: 1,
        activeRuns: ActiveRuns(asr: "asr", scope: "scope"),
        finalizationAttempt: FinalizationAttempt(attemptID: "a", state: .complete),
        pendingContentPrioritySegmentIDs: ["seg_000001"]
    ))

    let row = try #require(SavedSessionCatalog().list(sessionsRoot: root).first)

    #expect(row.hasActiveTranscript)
    #expect(row.processingStatus == .classificationPending)
}
