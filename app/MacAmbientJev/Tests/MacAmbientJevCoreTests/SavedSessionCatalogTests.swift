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
func catalogShowsJapaneseMessageForDecodingFailureButPreservesOtherErrors() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let brokenID = UUID()
    let broken = root.appending(path: brokenID.uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("{broken".utf8).write(to: broken.appending(path: "session.json"))

    let mismatchID = UUID()
    let mismatch = try writeCatalogSession(
        id: mismatchID, createdAt: 1_700_000_000, source: .live, root: root, includeAudio: false
    )
    let manifest = try Data(contentsOf: mismatch.appending(path: "session.json"))
    let other = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try manifest.write(to: other.appending(path: "session.json"))

    let rows = try SavedSessionCatalog().list(sessionsRoot: root)
    #expect(rows.first(where: { $0.sessionID == brokenID })?.errorMessage == "セッション情報が壊れています")
    #expect(rows.first(where: { $0.sessionID == UUID(uuidString: other.lastPathComponent) })?.errorMessage
        == "保存セッションの ID がフォルダー名と一致しません")
}

@Test(arguments: [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity])
func catalogRejectsInvalidCheckpointSampleRate(_ sampleRate: Double) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let id = UUID()
    let session = try writeCatalogSession(
        id: id, createdAt: 1_700_000_000, source: .live, root: root, includeAudio: true
    )
    let checkpoint = session.appending(path: "audio/processing/\(DurableAudioWriter.checkpointFilename)")
    let encoder = JSONEncoder()
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
        positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
    )
    try encoder.encode(AudioCheckpoint(
        committedFrames: 1,
        sampleRate: sampleRate,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [1],
        gapEvents: []
    )).write(to: checkpoint)

    let row = try #require(SavedSessionCatalog().list(sessionsRoot: root).first)
    #expect(row.sessionID == id)
    #expect(row.errorMessage != nil)
    #expect(!row.canReprocess)
}

@Test(arguments: [16_000.0, 48_000.0])
func catalogReportsDurationFromCheckpointSampleRate(_ sampleRate: Double) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let id = UUID()
    let session = try writeCatalogSession(
        id: id, createdAt: 1_700_000_000, source: .live, root: root, includeAudio: true
    )
    let checkpoint = session.appending(path: "audio/processing/\(DurableAudioWriter.checkpointFilename)")
    try JSONEncoder().encode(AudioCheckpoint(
        committedFrames: 1,
        sampleRate: sampleRate,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [1],
        gapEvents: []
    )).write(to: checkpoint)

    let row = try #require(SavedSessionCatalog().list(sessionsRoot: root).first)
    #expect(row.errorMessage == nil)
    #expect(row.canReprocess)
    #expect(row.durationSeconds == 1 / sampleRate)
}

@Test
func catalogIncludesChunksCommittedAfterLastJSONCheckpoint() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let id = UUID()
    let session = try writeCatalogSession(
        id: id, createdAt: 1_700_000_000, source: .live, root: root, includeAudio: true
    )
    let processing = session.appending(path: "audio/processing")
    try Data(count: MemoryLayout<Float>.size)
        .write(to: processing.appending(path: "chunk-000001.f32le"))

    let row = try #require(SavedSessionCatalog().list(sessionsRoot: root).first)
    #expect(row.errorMessage == nil)
    #expect(row.durationSeconds == 2.0 / 48_000)
}

@Test(arguments: [
    (59.5, "1:00"), (-0.2, "0:00"), (Double.nan, "不明"),
    (Double.infinity, "不明"), (-Double.infinity, "不明"),
    (Double.greatestFiniteMagnitude, "不明"), (Double(Int.max), "不明")
])
func savedSessionDurationHandlesNonfiniteAndOutOfRangeSeconds(_ seconds: Double, _ expected: String) {
    #expect(SavedSessionDisplayText.duration(seconds) == expected)
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
func importedOriginalStaysReprocessableWhenCheckpointIsCorrupt() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let session = try writeCatalogSession(
        id: id, createdAt: 1_700_000_000, source: .importedFile,
        root: root, includeAudio: false
    )
    let audio = session.appending(path: "audio", directoryHint: .isDirectory)
    let processing = audio.appending(path: "processing", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: audio.appending(path: "original.wav"))
    try Data("{broken".utf8).write(
        to: processing.appending(path: DurableAudioWriter.checkpointFilename)
    )

    let row = try #require(SavedSessionCatalog().list(sessionsRoot: root).first)
    #expect(row.audioAvailable)
    #expect(row.canReprocess)
    #expect(row.errorMessage == nil)
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
        finalizationAttempt: FinalizationAttempt(attemptID: "a", state: .failed, failureReason: "decode failed"),
        activeRuns: ActiveRuns(asr: "asr"),
        pendingContentPrioritySegmentIDs: []
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
        sourceKind: source,
        captureSource: .microphone
    )).write(to: session.appending(path: "session.json"), options: .atomic)
    if includeAudio {
        let processing = session.appending(path: "audio/processing", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
        let filename = "chunk-000000.f32le"
        try Data([0, 0, 0, 0]).write(to: processing.appending(path: filename))
        try Data().write(to: processing.appending(path: DurableAudioWriter.chunkIndexFilename))
        try Data().write(to: processing.appending(path: DurableAudioWriter.gapEventsFilename))
        try JSONEncoder().encode(AudioCheckpoint(
            committedFrames: 1,
            sampleRate: 48_000,
            channelCount: 1,
            sampleFormat: .float32LE,
            chunkFiles: [filename],
            chunkFrameCounts: [1],
            gapEvents: []
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
        finalizationAttempt: FinalizationAttempt(attemptID: "a", state: .complete, failureReason: nil),
        activeRuns: ActiveRuns(asr: "asr", scope: "scope"),
        pendingContentPrioritySegmentIDs: ["seg_000001"]
    ))

    let row = try #require(SavedSessionCatalog().list(sessionsRoot: root).first)

    #expect(row.hasActiveTranscript)
    #expect(row.processingStatus == .classificationPending)
}

@Test
func catalogReportsZeroAudioScopeOnlySessionAsComplete() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try writeCatalogSession(
        id: UUID(), createdAt: 1_700_000_000, source: .importedFile, root: root, includeAudio: true
    )
    try Data([1, 2, 3]).write(to: session.appending(path: "audio/original.wav"))
    try ProcessingMetadataStore(sessionURL: session).save(ProcessingMetadata(
        finalizationAttempt: nil,
        activeRuns: ActiveRuns(scope: "scope_empty"),
        pendingContentPrioritySegmentIDs: []
    ))

    let row = try #require(SavedSessionCatalog().list(sessionsRoot: root).first)
    #expect(row.processingStatus == .complete)
    #expect(!row.hasActiveTranscript)
}
