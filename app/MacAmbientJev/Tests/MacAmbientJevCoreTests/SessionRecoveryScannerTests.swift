import Foundation
import Testing
@testable import MacAmbientJevCore

private let recoveryCheckpoint = AudioCheckpoint(
    committedFrames: 100,
    sampleRate: 100,
    channelCount: 1,
    sampleFormat: .float32LE,
    chunkFiles: ["chunk-000000.f32le"],
    chunkFrameCounts: [100],
    gapEvents: []
)

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
}

private func writeRecoveryManifest(
    sessionID: UUID,
    source: SessionSource,
    to sessionURL: URL
) throws {
    try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
    let manifest = SessionManifest(
        sessionID: sessionID,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: source
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(
        to: sessionURL.appending(path: "session.json"),
        options: .atomic
    )
    if case .imported = source {
        let audioURL = sessionURL.appending(path: "audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: audioURL.appending(path: "original.wav"))
    }
}

private func writeRecoveryCheckpoint(_ checkpoint: AudioCheckpoint, to sessionURL: URL) throws {
    let processingURL = sessionURL.appending(path: "audio/processing", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: processingURL, withIntermediateDirectories: true)
    try JSONEncoder().encode(checkpoint).write(
        to: processingURL.appending(path: DurableAudioWriter.checkpointFilename),
        options: .atomic
    )
    try Data().write(to: processingURL.appending(path: DurableAudioWriter.chunkIndexFilename))
    try Data().write(to: processingURL.appending(path: DurableAudioWriter.gapEventsFilename))
    for (filename, frames) in zip(checkpoint.chunkFiles, checkpoint.chunkFrameCounts) {
        try Data(count: frames * checkpoint.channelCount * MemoryLayout<Float>.size)
            .write(to: processingURL.appending(path: filename))
    }
}

/// A recording session with captured audio.
private func writeRecording(id: UUID, root: URL) throws -> URL {
    let url = root.appending(path: id.uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(sessionID: id, source: .recording(.microphone), to: url)
    try writeRecoveryCheckpoint(recoveryCheckpoint, to: url)
    return url
}

private func saveMetadata(
    _ sessionURL: URL,
    attempt: FinalizationAttempt.State?,
    activeRuns: ActiveRuns?,
    pending: [String]
) throws {
    try ProcessingMetadataStore(sessionURL: sessionURL).save(ProcessingMetadata(
        finalizationAttempt: attempt.map {
            FinalizationAttempt(attemptID: "attempt", state: $0, failureReason: $0 == .failed ? "failed" : nil)
        },
        activeRuns: activeRuns,
        pendingContentPrioritySegmentIDs: pending
    ))
}

private let publishedRuns = ActiveRuns(
    segmentation: "seg_active",
    asr: "asr_active",
    diarization: "diar_active",
    scene: "scene_active",
    scope: "scope_active",
    contentPriority: "priority_active"
)

private func appendPublishedSegments(_ ids: [String], sessionID: UUID, writer: SessionWriter) async throws {
    for (index, id) in ids.enumerated() {
        try await writer.append(EventDraft(
            eventType: "segment.created",
            sessionID: sessionID,
            segmentationRunID: "seg_active",
            segmentID: id,
            sourceStartFrame: Int64(index * 10),
            sourceEndFrame: Int64(index * 10 + 10),
            payload: EmptyPayload()
        ))
        try await writer.append(EventDraft(
            eventType: "asr.completed",
            sessionID: sessionID,
            processingRunID: "asr_active",
            segmentationRunID: "seg_active",
            segmentID: id,
            sourceStartFrame: Int64(index * 10),
            sourceEndFrame: Int64(index * 10 + 10),
            payload: ASRCompletedEventPayload(text: "本文", detectedLanguage: "ja", engine: "test", model: "test")
        ))
    }
}

private func appendPriority(runID: String, segmentID: String, sessionID: UUID, writer: SessionWriter) async throws {
    try await writer.append(EventDraft(
        eventType: "content_priority.assigned",
        sessionID: sessionID,
        processingRunID: runID,
        segmentID: segmentID,
        payload: ContentPriorityEventPayload(
            priority: .primary,
            decision: .retryPending
        )
    ))
}

@Test
func recordingThatCrashedBeforeStopIsFinalizedFromItsTimeline() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try writeRecording(id: id, root: root)
    // Only the provisional live run reached the log.
    let writer = try SessionWriter(sessionURL: url)
    try await writer.append(EventDraft(
        eventType: "asr.pending",
        sessionID: id,
        processingRunID: "asr_live_run",
        segmentationRunID: "seg_live",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: EmptyPayload()
    ))

    let scan = try SessionRecoveryScanner(sessionsRoot: root).pendingSessions()

    #expect(scan.failures.isEmpty)
    #expect(scan.candidates.count == 1)
    #expect(scan.candidates.first?.action == .finalize)
    #expect(scan.candidates.first?.source == .recordedTimeline(recoveryCheckpoint))
}

@Test
func unprocessedImportIsFinalizedFromItsOriginal() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = root.appending(path: id.uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(sessionID: id, source: .imported(originalFilename: "fixture.wav"), to: url)

    let candidate = try #require(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id))

    #expect(candidate.action == .finalize)
    guard case .importedOriginal(let original) = candidate.source else {
        Issue.record("an import recovers from its original")
        return
    }
    #expect(original.resolvingSymlinksInPath()
        == url.appending(path: "audio/original.wav").resolvingSymlinksInPath())
}

@Test
func recordingWithoutCapturedAudioHasNothingToRecover() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    try writeRecoveryManifest(sessionID: id, source: .recording(.microphone), to: root.appending(path: id.uuidString))

    #expect(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id) == nil)
}

@Test(arguments: [FinalizationAttempt.State.running, .paused])
func interruptedOrPausedFinalizationIsFinalizedAgain(state: FinalizationAttempt.State) throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try writeRecording(id: id, root: root)
    try saveMetadata(url, attempt: state, activeRuns: publishedRuns, pending: [])

    let candidate = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id)

    #expect(candidate?.action == .finalize)
}

@Test
func interruptedFinalizationWithoutAudioIsReportedAsMissingAudio() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = root.appending(path: id.uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(sessionID: id, source: .recording(.microphone), to: url)
    try saveMetadata(url, attempt: .running, activeRuns: nil, pending: [])

    #expect(throws: SessionRecoveryScannerError.missingAudio) {
        _ = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id)
    }
}

@Test
func failedAndCompletedFinalizationsWaitForTheUser() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let failedID = UUID()
    try saveMetadata(try writeRecording(id: failedID, root: root), attempt: .failed, activeRuns: nil, pending: [])
    let completeID = UUID()
    try saveMetadata(try writeRecording(id: completeID, root: root), attempt: .complete, activeRuns: publishedRuns, pending: [])

    let scan = try SessionRecoveryScanner(sessionsRoot: root).pendingSessions()

    #expect(scan == SessionRecoveryScan(candidates: [], failures: []))
}

@Test
func completedFinalizationRetriesOnlyItsPendingClassifications() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try writeRecording(id: id, root: root)
    let writer = try SessionWriter(sessionURL: url)
    try await appendPublishedSegments(["seg_000001", "seg_000002"], sessionID: id, writer: writer)
    try await appendPriority(runID: "priority_active", segmentID: "seg_000002", sessionID: id, writer: writer)
    try saveMetadata(url, attempt: .complete, activeRuns: publishedRuns, pending: ["seg_000002"])

    let candidate = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id)

    #expect(candidate?.action == .retryContentPriority(segmentIDs: ["seg_000002"]))
}

@Test
func interruptedClassificationRetryReclassifiesEveryPublishedSegment() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try writeRecording(id: id, root: root)
    let writer = try SessionWriter(sessionURL: url)
    try await appendPublishedSegments(["seg_000001", "seg_000002"], sessionID: id, writer: writer)
    try await appendPriority(runID: "priority_active", segmentID: "seg_000002", sessionID: id, writer: writer)
    try await appendPriority(runID: "priority_unpublished", segmentID: "seg_000002", sessionID: id, writer: writer)
    try saveMetadata(url, attempt: .complete, activeRuns: publishedRuns, pending: ["seg_000002"])

    let candidate = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id)

    #expect(candidate?.action == .retryContentPriority(segmentIDs: ["seg_000001", "seg_000002"]))
}

@Test
func unreadableSessionsAreReportedWithoutBlockingOthers() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let validID = UUID()
    _ = try writeRecording(id: validID, root: root)

    let brokenManifest = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: brokenManifest, withIntermediateDirectories: true)
    try Data("{broken".utf8).write(to: brokenManifest.appending(path: "session.json"))

    let brokenMetadata = try writeRecording(id: UUID(), root: root)
    try Data("{broken".utf8).write(to: brokenMetadata.appending(path: "processing_metadata.json"))

    let mismatched = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(sessionID: UUID(), source: .recording(.microphone), to: mismatched)

    let scan = try SessionRecoveryScanner(sessionsRoot: root).pendingSessions()

    #expect(scan.candidates.map(\.manifest.sessionID) == [validID])
    #expect(Set(scan.failures.map(\.sessionURL.lastPathComponent)) == Set([
        brokenManifest.lastPathComponent,
        brokenMetadata.lastPathComponent,
        mismatched.lastPathComponent,
    ]))
    #expect(scan.failures.contains { $0.message.hasPrefix("処理状態ファイルを読めません") })
    #expect(scan.failures.contains { $0.message.hasPrefix("セッション情報を読めません") })
}

@Test
func recoveryScannerPrefersExistingProcessingCheckpoint() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let sessionURL = root.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(sessionID: sessionID, source: .recording(.microphone), to: sessionURL)
    let processingURL = sessionURL.appending(path: "audio/processing", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: processingURL, withIntermediateDirectories: true)
    let checkpoint = AudioCheckpoint(
        committedFrames: 48_000,
        sampleRate: 48_000,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [48_000],
        gapEvents: []
    )
    try JSONEncoder().encode(checkpoint).write(
        to: processingURL.appending(path: DurableAudioWriter.checkpointFilename),
        options: .atomic
    )
    try Data().write(to: processingURL.appending(path: DurableAudioWriter.chunkIndexFilename))
    try Data().write(to: processingURL.appending(path: DurableAudioWriter.gapEventsFilename))
    try Data(count: 48_000 * MemoryLayout<Float>.size)
        .write(to: processingURL.appending(path: "chunk-000000.f32le"))
    // Crash before finish(): the new chunk is durable despite stale JSON.
    try Data(count: 48_000 * MemoryLayout<Float>.size)
        .write(to: processingURL.appending(path: "chunk-000001.f32le"))

    let scan = try SessionRecoveryScanner(sessionsRoot: root).pendingSessions()

    #expect(scan.candidates.first?.source == .recordedTimeline(AudioCheckpoint(
        committedFrames: 96_000,
        sampleRate: 48_000,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le", "chunk-000001.f32le"],
        chunkFrameCounts: [48_000, 48_000],
        gapEvents: []
    )))
}

@Test
func inspectReadsOnlyRequestedSessionAndLeavesItsLogUntouched() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let sessionURL = root.appending(path: sessionID.uuidString)
    try writeRecoveryManifest(sessionID: sessionID, source: .imported(originalFilename: "fixture.wav"), to: sessionURL)
    let eventsURL = sessionURL.appending(path: "events.jsonl")
    let original = Data("{\"event_seq\":1,\"event_type\":\"unused\"}\n{\"unfinished\"".utf8)
    try original.write(to: eventsURL)

    let otherURL = root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
    try Data("invalid manifest".utf8).write(to: otherURL.appending(path: "session.json"))

    let result = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: sessionID)
    #expect(result?.manifest.sessionID == sessionID)
    #expect(try Data(contentsOf: eventsURL) == original)
}

@Test
func recoveryUsesIntactOriginalWhenImportCheckpointIsUnusable() throws {
    let checkpoints = [
        AudioCheckpoint(committedFrames: 100, sampleRate: 100, channelCount: 1, sampleFormat: .float32LE, chunkFiles: ["missing.f32le"], chunkFrameCounts: [100], gapEvents: []),
        AudioCheckpoint(committedFrames: 1, sampleRate: 100, channelCount: 1, sampleFormat: .float32LE, chunkFiles: ["../../../secret"], chunkFrameCounts: [1], gapEvents: []),
    ]
    for checkpoint in checkpoints {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let url = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        try writeRecoveryManifest(sessionID: id, source: .imported(originalFilename: "fixture.wav"), to: url)
        let processing = url.appending(path: "audio/processing", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: processing.appending(path: DurableAudioWriter.checkpointFilename))
        try Data(count: 4).write(to: root.appending(path: "secret"))

        let source = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id)?.source
        guard case .importedOriginal(let original) = source else {
            Issue.record("intact original must be chosen: \(String(describing: source))")
            continue
        }
        #expect(original.resolvingSymlinksInPath()
            == url.appending(path: "audio/original.wav").resolvingSymlinksInPath())
    }
}

@Test
func finalizationAttemptPublishesRunsOnlyOnCompletion() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = ProcessingMetadataStore(sessionURL: root)
    let oldRuns = ActiveRuns(segmentation: "seg_old", asr: "asr_old", scope: "scope_old", contentPriority: "priority_old")
    try store.save(ProcessingMetadata(
        finalizationAttempt: nil,
        activeRuns: oldRuns,
        pendingContentPrioritySegmentIDs: ["seg_old"]
    ))

    try store.beginFinalization(attemptID: "attempt_1", policy: .reject)
    try store.pauseFinalization(attemptID: "attempt_1")
    #expect(try store.load() == ProcessingMetadata(
        finalizationAttempt: FinalizationAttempt(attemptID: "attempt_1", state: .paused, failureReason: nil),
        activeRuns: oldRuns,
        pendingContentPrioritySegmentIDs: ["seg_old"]
    ))
    try store.failFinalization(attemptID: "attempt_1", reason: "diarization failed")
    #expect(try store.load()?.activeRuns == oldRuns)

    #expect(throws: ProcessingMetadataStoreError.finalizationAttemptMismatch) {
        try store.completeFinalization(attemptID: "attempt_other", activeRuns: ActiveRuns(asr: "x"))
    }

    let newRuns = ActiveRuns(segmentation: "seg_new", asr: "asr_new", diarization: "diar_new", scope: "scope_new")
    try store.beginFinalization(attemptID: "attempt_2", policy: .reject)
    try store.completeFinalization(attemptID: "attempt_2", activeRuns: newRuns)
    #expect(try store.load() == ProcessingMetadata(
        finalizationAttempt: FinalizationAttempt(attemptID: "attempt_2", state: .complete, failureReason: nil),
        activeRuns: newRuns,
        pendingContentPrioritySegmentIDs: []
    ))
}

@Test
func unreadableMetadataIsReplacedOnlyWhenTheCallerAllowsIt() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = ProcessingMetadataStore(sessionURL: root)
    let broken = Data("{broken".utf8)
    try broken.write(to: store.url)

    #expect {
        try store.beginFinalization(attemptID: "attempt", policy: .reject)
    } throws: { error in
        guard case .unreadable = error as? ProcessingMetadataStoreError else { return false }
        return true
    }
    #expect(try Data(contentsOf: store.url) == broken)

    let replaced = try store.beginFinalization(attemptID: "attempt", policy: .replace)
    #expect(replaced == nil)
    #expect(try store.load() == ProcessingMetadata(
        finalizationAttempt: FinalizationAttempt(attemptID: "attempt", state: .running, failureReason: nil),
        activeRuns: nil,
        pendingContentPrioritySegmentIDs: []
    ))
}
