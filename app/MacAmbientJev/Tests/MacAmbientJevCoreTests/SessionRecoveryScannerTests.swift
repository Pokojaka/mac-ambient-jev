import Foundation
import Testing
@testable import MacAmbientJevCore

private let recoveryCheckpoint = AudioCheckpoint(
    committedFrames: 4_000,
    sampleRate: CanonicalAudio.sampleRate,
    channelCount: 1,
    sampleFormat: .float32LE,
    chunkFiles: ["chunk-000000.f32le"],
    chunkFrameCounts: [4_000],
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
    _ = try SessionWriter(sessionURL: sessionURL)
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

private func saveStatus(
    _ sessionURL: URL,
    sessionID: UUID,
    state: ProcessingMetadata.State
) async throws {
    let eventsURL = sessionURL.appending(path: "events.jsonl")
    let current = try EventLogTranscriptReader().read(eventsURL: eventsURL, sessionID: sessionID)
    let generationID: UUID
    if let current {
        generationID = current.state.generation.id
    } else {
        let provenance = RunProvenance(engine: "test", model: nil, version: "1", configuration: [:])
        let generation = PipelineGeneration(
            id: UUID(), runs: ActiveRuns(segmentation: "seg_status", asr: "asr_status"),
            sampleRate: recoveryCheckpoint.sampleRate,
            segmentationProvenance: provenance, asrProvenance: provenance
        )
        try await SessionWriter(sessionURL: sessionURL).append(generation.startEvent(sessionID: sessionID))
        generationID = generation.id
    }
    try ProcessingMetadataStore(sessionURL: sessionURL).save(ProcessingMetadata(
        generationID: generationID, state: state, failureReason: state == .failed ? "failed" : nil
    ))
}

@Test
func recordingThatCrashedBeforeStopIsFinalizedFromItsTimeline() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try writeRecording(id: id, root: root)
    // The generation marker records the interrupted processing snapshot.
    try await saveStatus(url, sessionID: id, state: .running)

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
func aRecordingWithoutItsCheckpointIsMissingAudioAndAnEmptyOneIsFinalized() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try recoveryURL(id: id, source: .recording(.microphone), root: root)
    try writeRecoveryManifest(sessionID: id, source: .recording(.microphone), to: url)

    #expect(throws: SessionRecoveryScannerError.missingAudio) {
        _ = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id)
    }

    // A crash after the writer's initial zero-frame checkpoint, before the first generation.
    let layout = SessionLayout(sessionURL: url)
    _ = try await DurableAudioWriter(
        directory: layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: url
    ).finish()
    let candidate = try #require(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery)
    #expect(candidate.action == .finalize)
}

@Test(arguments: [ProcessingMetadata.State.running, .paused])
func interruptedOrPausedFinalizationIsFinalizedAgain(state: ProcessingMetadata.State) async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try writeRecording(id: id, root: root)
    try await saveStatus(url, sessionID: id, state: state)

    let candidate = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery

    #expect(candidate?.action == .finalize)
}

@Test
func interruptedFinalizationWithoutAudioIsReportedAsMissingAudio() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try recoveryURL(id: id, source: .recording(.microphone), root: root)
    try writeRecoveryManifest(sessionID: id, source: .recording(.microphone), to: url)
    try await saveStatus(url, sessionID: id, state: .running)

    #expect(throws: SessionRecoveryScannerError.missingAudio) {
        _ = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id)
    }
}

@Test
func failedAndCompletedFinalizationsWaitForTheUser() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let failedID = UUID()
    let failedURL = try writeRecording(id: failedID, root: root)
    try await saveStatus(failedURL, sessionID: failedID, state: .failed)
    let completeID = UUID()
    let completeURL = try writeRecording(id: completeID, root: root)
    _ = try await writeTranscript(
        [], root: completeURL, sessionID: completeID,
        sampleRate: recoveryCheckpoint.sampleRate, frameCount: recoveryCheckpoint.committedFrames
    )
    try saveCompletedStatus(root: completeURL, sessionID: completeID)

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
    _ = try await writeTranscript(
        ["一。二", "三"], root: url, sessionID: id,
        sampleRate: recoveryCheckpoint.sampleRate, frameCount: recoveryCheckpoint.committedFrames
    )
    try saveCompletedStatus(root: url, sessionID: id)
    let pending = try readStored(root: url, sessionID: id).pendingDecisions
    let localOnly = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery
    #expect(localOnly?.action == .retryContentPriority(
        boundarySegments: pending.boundarySegments, clauses: pending.clauses
    ))

    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: { _ in
        throw DecisionResponseError.missingAnswer
    })
    let counter = DecisionUsageCounter()
    let result = try await buildAndPublish(root: url, sessionID: id, provider: provider, counter: counter)
    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["s01", "s02"])
    let boundaryUsage = await counter.snapshot().boundaryRequests
    #expect(boundaryUsage.sendCount == 2)
    #expect(boundaryUsage.successCount == 2)
    #expect(boundaryUsage.inputTokens == 2 * testInputTokens)
    #expect(result.pendingBoundarySegments.isEmpty)
    // An interrupted retry run that was never published is not adopted; launch recovery requests the published pendings again.
    _ = try await SessionWriter(sessionURL: url).append(EventDraft(
        eventType: "processing.run.started", sessionID: id, processingRunID: "priority_unpublished",
        payload: ProcessingRunStartedPayload(stage: .contentPriority, provenance: DecisionRunProvenance.priority(identity: testDecisionIdentity))
    ))

    let candidate = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery
    #expect(candidate?.action == .recoverDecisionRun(boundarySegments: [], clauses: result.pendingPriorityClauses))
}

@Test
func retryAnalyzerDistinguishesFailedCompletedRunFromUnendedAndSuccessfulUnpublishedRun() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try writeRecording(id: id, root: root)
    _ = try await writeTranscript(
        ["本文。"], root: url, sessionID: id,
        sampleRate: recoveryCheckpoint.sampleRate, frameCount: recoveryCheckpoint.committedFrames
    )
    try saveCompletedStatus(root: url, sessionID: id)
    _ = try await buildAndPublish(
        root: url, sessionID: id,
        provider: ScriptedDecisionProvider(
            boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
            priority: lowForBackchannel
        )
    )
    let writer = try SessionWriter(sessionURL: url)
    let analyzer = DecisionRetryAnalyzer()
    let failedRunID = "failed_unpublished_retry"
    try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: id, processingRunID: failedRunID,
        payload: ProcessingRunStartedPayload(
            stage: .contentPriority,
            provenance: DecisionRunProvenance.priority(identity: testDecisionIdentity)
        )
    ))
    #expect(try analyzer.hasUnpublishedDecisionRun(lines: eventLines(url), sessionID: id))
    try await writer.append(EventDraft(
        eventType: "processing.run.completed", sessionID: id, processingRunID: failedRunID,
        payload: ProcessingRunCompletedPayload(
            stage: .contentPriority, succeeded: false, completedCount: 0, failedCount: 1
        )
    ))
    #expect(try !analyzer.hasUnpublishedDecisionRun(lines: eventLines(url), sessionID: id))
    #expect(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery == nil)

    let successfulRunID = "successful_unpublished_retry"
    try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: id, processingRunID: successfulRunID,
        payload: ProcessingRunStartedPayload(
            stage: .contentPriority,
            provenance: DecisionRunProvenance.priority(identity: testDecisionIdentity)
        )
    ))
    try await writer.append(EventDraft(
        eventType: "processing.run.completed", sessionID: id, processingRunID: successfulRunID,
        payload: ProcessingRunCompletedPayload(
            stage: .contentPriority, succeeded: true, completedCount: 1, failedCount: 0
        )
    ))
    #expect(try analyzer.hasUnpublishedDecisionRun(lines: eventLines(url), sessionID: id))
    #expect(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery?.action
        == .recoverDecisionRun(boundarySegments: [], clauses: []))
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
func inspectReadsOnlyRequestedSessionAndLeavesItsLogUntouched() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let sessionURL = try recoveryURL(id: sessionID, source: .imported(originalFilename: "fixture.wav"), root: root)
    try writeRecoveryManifest(sessionID: sessionID, source: .imported(originalFilename: "fixture.wav"), to: sessionURL)
    let eventsURL = sessionURL.appending(path: "events.jsonl")
    let writer = try SessionWriter(sessionURL: sessionURL)
    try await writer.append(EventDraft(eventType: "unused", sessionID: sessionID, payload: EmptyPayload()))
    var original = try Data(contentsOf: eventsURL)
    original.append(Data("{\"unfinished\"".utf8))
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
func recoveryRebuildsAnUnpublishedRetryEvenWhenPublishedPendingIsEmpty() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try writeRecording(id: id, root: root)
    _ = try await writeTranscript(
        ["本文"], root: url, sessionID: id,
        sampleRate: recoveryCheckpoint.sampleRate, frameCount: recoveryCheckpoint.committedFrames
    )
    try saveCompletedStatus(root: url, sessionID: id)
    let provider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
        priority: lowForBackchannel
    )
    let counter = DecisionUsageCounter()
    _ = try await buildAndPublish(root: url, sessionID: id, provider: provider, counter: counter)
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
    let writer = try SessionWriter(sessionURL: url)
    #expect(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery == nil)
    try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: id, processingRunID: "unpublished_retry",
        payload: ProcessingRunStartedPayload(stage: .contentPriority, provenance: DecisionRunProvenance.priority(identity: testDecisionIdentity))
    ))
    #expect(try DecisionRetryAnalyzer().hasUnpublishedDecisionRun(lines: eventLines(url), sessionID: id))
    #expect(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery?.action
        == .recoverDecisionRun(boundarySegments: [], clauses: []))
    // Selecting a complete pair after the unpublished run ends the recovery.
    _ = try await buildAndPublish(
        root: url, sessionID: id,
        provider: ScriptedDecisionProvider(
            boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
            priority: lowForBackchannel
        )
    )
    #expect(try !DecisionRetryAnalyzer().hasUnpublishedDecisionRun(lines: eventLines(url), sessionID: id))
    #expect(try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id).recovery == nil)
}

@Test
func recoveryRejectsCorruptionInCurrentEventLog() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = try writeRecording(id: id, root: root)
    _ = try await writeTranscript(
        ["本文"], root: url, sessionID: id,
        sampleRate: recoveryCheckpoint.sampleRate, frameCount: recoveryCheckpoint.committedFrames
    )
    try saveCompletedStatus(root: url, sessionID: id)
    _ = try await buildAndPublish(root: url, sessionID: id,
                                  provider: ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
                                                                     priority: lowForBackchannel))
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
