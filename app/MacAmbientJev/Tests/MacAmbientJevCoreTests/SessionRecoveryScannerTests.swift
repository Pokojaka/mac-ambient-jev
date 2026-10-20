import Foundation
import Testing
@testable import MacAmbientJevCore

private let recoveryCheckpoint = AudioCheckpoint(
    committedFrames: 100,
    sampleRate: CanonicalAudio.sampleRate,
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
    try encoder.encode(manifest).write(to: sessionURL.appending(path: "session.json"))
    if case .imported = source {
        let audioURL = sessionURL.appending(path: "audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: audioURL.appending(path: "original.wav"))
    }
    try SessionAudioStorageStore(layout: SessionLayout(sessionURL: sessionURL)).save(.initial(for: source))
}

private func writeRecoveryCheckpoint(_ checkpoint: AudioCheckpoint, to sessionURL: URL) throws {
    let processingURL = sessionURL.appending(path: "audio/processing", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: processingURL, withIntermediateDirectories: true)
    try JSONEncoder().encode(checkpoint).write(to: processingURL.appending(path: DurableAudioWriter.checkpointFilename))
    try Data().write(to: processingURL.appending(path: DurableAudioWriter.chunkIndexFilename))
    try Data().write(to: processingURL.appending(path: DurableAudioWriter.gapEventsFilename))
    for (filename, frames) in zip(checkpoint.chunkFiles, checkpoint.chunkFrameCounts) {
        try Data(count: frames * checkpoint.channelCount * MemoryLayout<Float>.size)
            .write(to: processingURL.appending(path: filename))
    }
}

private func recoveryURL(id: UUID, source: SessionSource, root: URL) throws -> URL {
    root.appending(path: try SessionFolderName.make(
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), sessionID: id,
        source: source, timeZone: TimeZone(secondsFromGMT: 0)!
    ), directoryHint: .isDirectory)
}

/// A recording session with captured audio.
private func writeRecording(id: UUID, root: URL) throws -> URL {
    let url = try recoveryURL(id: id, source: .recording(.microphone), root: root)
    try writeRecoveryManifest(sessionID: id, source: .recording(.microphone), to: url)
    try writeRecoveryCheckpoint(recoveryCheckpoint, to: url)
    return url
}

private func saveMetadata(
    _ sessionURL: URL,
    attempt: FinalizationAttempt.State?,
    activeRuns: ActiveRuns?
) throws {
    try ProcessingMetadataStore(sessionURL: sessionURL).save(ProcessingMetadata(
        finalizationAttempt: attempt.map {
            FinalizationAttempt(attemptID: "attempt", state: $0, failureReason: $0 == .failed ? "failed" : nil)
        },
        activeRuns: activeRuns,
        pendingClauseBoundarySegments: [],
        pendingContentPriorityClauses: []
    ))
}

private let publishedRuns = ActiveRuns(
    segmentation: "seg_active",
    asr: "asr_active",
    diarization: "diar_active"
)

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
    let first = try #require(scan.candidates.first)
    #expect(try SessionLayout(sessionURL: first.sessionURL).audioSource(for: first.manifest)
        == .recordedPCM(recoveryCheckpoint))
}

@Test
func unprocessedImportIsFinalizedFromItsOriginal() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try recoveryURL(id: id, source: .imported(originalFilename: "fixture.wav"), root: root)
    try writeRecoveryManifest(sessionID: id, source: .imported(originalFilename: "fixture.wav"), to: url)

    let candidate = try #require(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery)

    #expect(candidate.action == .finalize)
    guard case .importedOriginal(let original, _) = try SessionLayout(sessionURL: url)
        .audioSource(for: candidate.manifest) else {
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
    try writeRecoveryManifest(sessionID: id, source: .recording(.microphone),
        to: recoveryURL(id: id, source: .recording(.microphone), root: root))

    #expect(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery == nil)
}

@Test(arguments: [FinalizationAttempt.State.running, .paused])
func interruptedOrPausedFinalizationIsFinalizedAgain(state: FinalizationAttempt.State) throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try writeRecording(id: id, root: root)
    try saveMetadata(url, attempt: state, activeRuns: publishedRuns)

    let candidate = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery

    #expect(candidate?.action == .finalize)
}

@Test
func interruptedFinalizationWithoutAudioIsReportedAsMissingAudio() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try recoveryURL(id: id, source: .recording(.microphone), root: root)
    try writeRecoveryManifest(sessionID: id, source: .recording(.microphone), to: url)
    try saveMetadata(url, attempt: .running, activeRuns: nil)

    #expect(throws: SessionRecoveryScannerError.missingAudio) {
        _ = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id)
    }
}

@Test
func failedAndCompletedFinalizationsWaitForTheUser() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let failedID = UUID()
    try saveMetadata(try writeRecording(id: failedID, root: root), attempt: .failed, activeRuns: nil)
    let completeID = UUID()
    let completeURL = try writeRecording(id: completeID, root: root)
    _ = try await writeTranscript([], root: completeURL, sessionID: completeID)
    try saveMetadata(completeURL, attempt: .complete, activeRuns: transcriptRuns)

    let scan = try SessionRecoveryScanner(sessionsRoot: root).pendingSessions()

    #expect(scan == SessionRecoveryScan(
        candidates: [],
        maintenance: [SessionMaintenanceCandidate(
            sessionID: completeID, sessionURL: completeURL, maintenance: .compactRecording
        )],
        failures: []
    ))
}

@Test
func completedFinalizationRetriesOnlyItsPublishedPendingDecisionResults() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try writeRecording(id: id, root: root)
    let events = try await writeTranscript(["一。二", "三"], root: url, sessionID: id)
    _ = try publishLocal(root: url, events: events)
    let localOnly = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery
    #expect(localOnly?.action == .retryContentPriority(
        boundarySegments: [try source("s01", in: events), try source("s02", in: events)], clauses: []
    ))

    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: { _ in
        throw DecisionResponseError.missingAnswer
    })
    let counter = DecisionUsageCounter()
    let result = try await buildAndPublish(root: url, sessionID: id, provider: provider, scope: .all, counter: counter)
    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["s01", "s02"])
    let boundaryUsage = await counter.snapshot().boundaryRequests
    #expect(boundaryUsage.sendCount == 2)
    #expect(boundaryUsage.successCount == 2)
    #expect(boundaryUsage.inputTokens == 2 * testInputTokens)
    #expect(result.pendingBoundarySegments.isEmpty)
    // An interrupted retry run that was never published is not adopted; launch recovery requests the published pendings again.
    _ = try await SessionWriter(sessionURL: url).append(EventDraft(
        eventType: "processing.run.started", sessionID: id, processingRunID: "priority_unpublished",
        payload: ProcessingRunStartedPayload(stage: .contentPriority, provenance: DecisionRunProvenance.priority(mode: "retry", identity: testDecisionIdentity))
    ))

    let candidate = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery
    #expect(candidate?.action == .recoverDecisionRun(boundarySegments: [], clauses: result.pendingPriorityClauses))
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
}

@Test
func recoveryScannerPrefersExistingProcessingCheckpoint() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let sessionURL = try recoveryURL(id: sessionID, source: .recording(.microphone), root: root)
    try writeRecoveryManifest(sessionID: sessionID, source: .recording(.microphone), to: sessionURL)
    let processingURL = sessionURL.appending(path: "audio/processing", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: processingURL, withIntermediateDirectories: true)
    let checkpoint = AudioCheckpoint(
        committedFrames: 48_000,
        sampleRate: CanonicalAudio.sampleRate,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [48_000],
        gapEvents: []
    )
    try JSONEncoder().encode(checkpoint).write(to: processingURL.appending(path: DurableAudioWriter.checkpointFilename))
    try Data().write(to: processingURL.appending(path: DurableAudioWriter.chunkIndexFilename))
    try Data().write(to: processingURL.appending(path: DurableAudioWriter.gapEventsFilename))
    try Data(count: 48_000 * MemoryLayout<Float>.size)
        .write(to: processingURL.appending(path: "chunk-000000.f32le"))
    // Crash before finish(): the new chunk is durable despite stale JSON.
    try Data(count: 48_000 * MemoryLayout<Float>.size)
        .write(to: processingURL.appending(path: "chunk-000001.f32le"))

    let scan = try SessionRecoveryScanner(sessionsRoot: root).pendingSessions()

    let recovered = try #require(scan.candidates.first)
    #expect(try SessionLayout(sessionURL: recovered.sessionURL).audioSource(for: recovered.manifest) == .recordedPCM(AudioCheckpoint(
        committedFrames: 96_000,
        sampleRate: CanonicalAudio.sampleRate,
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
    let sessionURL = try recoveryURL(id: sessionID, source: .imported(originalFilename: "fixture.wav"), root: root)
    try writeRecoveryManifest(sessionID: sessionID, source: .imported(originalFilename: "fixture.wav"), to: sessionURL)
    let eventsURL = sessionURL.appending(path: "events.jsonl")
    let original = Data("{\"event_seq\":1,\"event_type\":\"unused\",\"schema_version\":3}\n{\"unfinished\"".utf8)
    try original.write(to: eventsURL)

    let otherURL = root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
    try Data("invalid manifest".utf8).write(to: otherURL.appending(path: "session.json"))

    let result = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: sessionID).recovery
    #expect(result?.manifest.sessionID == sessionID)
    #expect(try Data(contentsOf: eventsURL) == original)
}

@Test
func recoveryUsesIntactOriginalWhenImportCheckpointIsUnusable() throws {
    let checkpoints = [
        AudioCheckpoint(committedFrames: 100, sampleRate: CanonicalAudio.sampleRate, channelCount: 1, sampleFormat: .float32LE, chunkFiles: ["missing.f32le"], chunkFrameCounts: [100], gapEvents: []),
        AudioCheckpoint(committedFrames: 1, sampleRate: CanonicalAudio.sampleRate, channelCount: 1, sampleFormat: .float32LE, chunkFiles: ["../../../secret"], chunkFrameCounts: [1], gapEvents: []),
    ]
    for checkpoint in checkpoints {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let url = try recoveryURL(id: id, source: .imported(originalFilename: "fixture.wav"), root: root)
        try writeRecoveryManifest(sessionID: id, source: .imported(originalFilename: "fixture.wav"), to: url)
        let processing = url.appending(path: "audio/processing", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: processing.appending(path: DurableAudioWriter.checkpointFilename))
        try Data(count: 4).write(to: root.appending(path: "secret"))

        let candidate = try #require(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery)
        let source = try SessionLayout(sessionURL: url).audioSource(for: candidate.manifest)
        guard case .importedOriginal(let original, _) = source else {
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
    let oldRuns = ActiveRuns(segmentation: "seg_old", asr: "asr_old",
                             clauseBoundary: "boundary_old", contentPriority: "priority_old")
    let oldSource = try SegmentTextReference(segmentationRunID: "seg_old", segmentID: "s", asrRunID: "asr_old", asrEventSeq: 1)
    try store.save(ProcessingMetadata(
        finalizationAttempt: nil,
        activeRuns: oldRuns,
        pendingClauseBoundarySegments: [oldSource],
        pendingContentPriorityClauses: []
    ))

    try store.beginFinalization(attemptID: "attempt_1", policy: .reject)
    try store.pauseFinalization(attemptID: "attempt_1")
    #expect(try store.load() == ProcessingMetadata(
        finalizationAttempt: FinalizationAttempt(attemptID: "attempt_1", state: .paused, failureReason: nil),
        activeRuns: oldRuns,
        pendingClauseBoundarySegments: [oldSource],
        pendingContentPriorityClauses: []
    ))
    try store.failFinalization(attemptID: "attempt_1", reason: "diarization failed")
    #expect(try store.load()?.activeRuns == oldRuns)

    #expect(throws: ProcessingMetadataStoreError.finalizationAttemptMismatch) {
        try store.completeFinalization(attemptID: "attempt_other", activeRuns: ActiveRuns(asr: "x"), pendingClauseBoundarySegments: [])
    }

    let newRuns = ActiveRuns(segmentation: "seg_new", asr: "asr_new", diarization: "diar_new")
    try store.beginFinalization(attemptID: "attempt_2", policy: .reject)
    let newSource = try SegmentTextReference(segmentationRunID: "seg_new", segmentID: "s", asrRunID: "asr_new", asrEventSeq: 9)
    try store.completeFinalization(attemptID: "attempt_2", activeRuns: newRuns, pendingClauseBoundarySegments: [newSource])
    // The local runs and the boundary-pending list of their segments are one write; old decision runs are gone.
    #expect(try store.load() == ProcessingMetadata(
        finalizationAttempt: FinalizationAttempt(attemptID: "attempt_2", state: .complete, failureReason: nil),
        activeRuns: newRuns,
        pendingClauseBoundarySegments: [newSource],
        pendingContentPriorityClauses: []
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
        pendingClauseBoundarySegments: [],
        pendingContentPriorityClauses: []
    ))
}

@Test
func recoveryRebuildsAnUnpublishedRetryEvenWhenPublishedPendingIsEmpty() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try writeRecording(id: id, root: root)
    _ = try publishLocal(root: url, events: try await writeTranscript(["本文"], root: url, sessionID: id))
    let provider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
        priority: lowForBackchannel
    )
    let counter = DecisionUsageCounter()
    _ = try await buildAndPublish(root: url, sessionID: id, provider: provider, scope: .all, counter: counter)
    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["s01"])
    let boundaryUsage = await counter.snapshot().boundaryRequests
    #expect(boundaryUsage.sendCount == 1)
    #expect(boundaryUsage.successCount == 1)
    #expect(boundaryUsage.inputTokens == testInputTokens)
    let assessment = try #require(try eventObjects(url).first {
        $0["event_type"] as? String == ClauseEventType.boundaryAssessed
    })
    let assessmentPayload = try #require(assessment["payload"] as? [String: Any])
    #expect(assessmentPayload["filler_ranges"] as? [Any] != nil)
    #expect(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery == nil)
    let metadata = try #require(try ProcessingMetadataStore(sessionURL: url).load())
    let active = try #require(metadata.activeRuns)
    let writer = try SessionWriter(sessionURL: url)
    try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: id, processingRunID: "unfinished_live",
        payload: ProcessingRunStartedPayload(stage: .contentPriority, provenance: DecisionRunProvenance.priority(mode: "live", identity: testDecisionIdentity))
    ))
    #expect(try !DecisionRetryAnalyzer().hasUnpublishedDecisionRun(lines: eventLines(url), activeRuns: active))
    #expect(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery == nil)
    try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: id, processingRunID: "unpublished_retry",
        payload: ProcessingRunStartedPayload(stage: .contentPriority, provenance: DecisionRunProvenance.priority(mode: "retry", identity: testDecisionIdentity))
    ))
    #expect(try DecisionRetryAnalyzer().hasUnpublishedDecisionRun(lines: eventLines(url), activeRuns: active))
    #expect(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery?.action
        == .recoverDecisionRun(boundarySegments: [], clauses: []))
    let retryProvider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
        priority: lowForBackchannel
    )
    let retryCounter = DecisionUsageCounter()
    _ = try await buildAndPublish(
        root: url, sessionID: id, provider: retryProvider,
        scope: .retry(boundarySegments: [], clauses: []), counter: retryCounter
    )
    #expect(await retryProvider.boundaryRequests.isEmpty)
    let retryBoundaryUsage = await retryCounter.snapshot().boundaryRequests
    #expect(retryBoundaryUsage.sendCount == 0)
    #expect(retryBoundaryUsage.inputTokens == 0)
    let replaced = try #require(try ProcessingMetadataStore(sessionURL: url).load()?.activeRuns)
    #expect(try !DecisionRetryAnalyzer().hasUnpublishedDecisionRun(lines: eventLines(url), activeRuns: replaced))
    #expect(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery == nil)
}

@Test
func recoveryRejectsCorruptionEvenWhenMetadataHasNoPendingTargets() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try writeRecording(id: id, root: root)
    _ = try publishLocal(root: url, events: try await writeTranscript(["本文"], root: url, sessionID: id))
    _ = try await buildAndPublish(root: url, sessionID: id,
                                  provider: ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
                                                                     priority: lowForBackchannel), scope: .all)
    let eventsURL = url.appending(path: "events.jsonl")
    var objects = try eventObjects(url)
    let index = try #require(objects.firstIndex { $0["event_type"] as? String == ClauseEventType.priorityAssigned })
    var payload = try #require(objects[index]["payload"] as? [String: Any])
    payload.removeValue(forKey: "assignments")
    objects[index]["payload"] = payload
    let lines = try objects.map { try JSONSerialization.data(withJSONObject: $0) }
    let original = lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
    try original.write(to: eventsURL)
    #expect(throws: EventLogTranscriptReaderError.self) {
        _ = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id)
    }
    let scan = try SessionRecoveryScanner(sessionsRoot: root).pendingSessions()
    #expect(scan.candidates.isEmpty)
    #expect(scan.failures.map(\.sessionURL) == [url])
    #expect(try Data(contentsOf: eventsURL) == original)
}
