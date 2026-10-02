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
        originalFilename: sourceKind == .importedFile ? "fixture.wav" : nil,
        captureSource: .microphone
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(
        to: sessionURL.appending(path: "session.json"),
        options: .atomic
    )
    if sourceKind == .importedFile {
        let audioURL = sessionURL.appending(path: "audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: audioURL.appending(path: "original.wav"))
    }
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
func completedEmptyScopeDoesNotQueueSilentImportForReprocessing() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let url = root.appending(path: id.uuidString)
    try writeRecoveryManifest(sessionID: id, sourceKind: .importedFile, to: url)
    try writeRecoveryCheckpoint(AudioCheckpoint(
        committedFrames: 100,
        sampleRate: 100,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [100],
        gapEvents: []
    ), to: url)
    let scanner = SessionRecoveryScanner(sessionsRoot: root)
    #expect(try scanner.inspect(sessionID: id)?.action == .reprocess)

    let scopeID = "scope_empty_test"
    _ = try await SessionWriter(sessionURL: url).append(EventDraft(
        eventType: "processing.run.completed",
        sessionID: id,
        processingRunID: scopeID,
        payload: ProcessingRunCompletedPayload(
            stage: .scope, succeeded: true, completedCount: 0, failedCount: 0
        )
    ))
    try ProcessingMetadataStore(sessionURL: url).save(ProcessingMetadata(
        timelineVersion: 1, vadVersion: "vad", vadConfigHash: "hash",
        asrEngine: "qwen", asrModel: "model", asrVersion: "version",
        diarizationVersion: "diar", sceneAnalyzerVersion: 1, jevSchemaVersion: 1,
        policyVersion: 1, materializerSchemaVersion: 1,
        activeRuns: ActiveRuns(scope: scopeID)
    ))
    #expect(try scanner.inspect(sessionID: id) == nil)
    #expect(try scanner.pendingSessions().isEmpty)
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

    let candidates = try SessionRecoveryScanner(
        sessionsRoot: root
    ).pendingSessions()

    #expect(candidates.first?.source == .recordedTimeline(AudioCheckpoint(
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
func recoveryScannerSkipsSessionWithSelectedASRRun() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let sessionURL = root.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(
        sessionID: sessionID,
        sourceKind: .live,
        to: sessionURL
    )

    let metadata = ProcessingMetadata(
        timelineVersion: 1,
        vadVersion: "vad",
        vadConfigHash: "hash",
        asrEngine: "qwen",
        asrModel: "model",
        asrVersion: "version",
        diarizationVersion: "diar",
        sceneAnalyzerVersion: 1,
        jevSchemaVersion: 1,
        policyVersion: 1,
        materializerSchemaVersion: 1,
        activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
    )
    try ProcessingMetadataStore(sessionURL: sessionURL).save(metadata)

    let candidates = try SessionRecoveryScanner(
        sessionsRoot: root
    ).pendingSessions()

    #expect(candidates.isEmpty)
}


private func writeRecoveryCheckpoint(
    _ checkpoint: AudioCheckpoint,
    to sessionURL: URL
) throws {
    let processingURL = sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: processingURL,
        withIntermediateDirectories: true
    )
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

private func importedOriginalURL(in sessionURL: URL) -> URL {
    sessionURL.appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "original.wav")
}

private func isImportedOriginal(_ source: SessionAudioSource?, in sessionURL: URL) -> Bool {
    guard case .importedOriginal(let url) = source else { return false }
    return url.resolvingSymlinksInPath() == importedOriginalURL(in: sessionURL).resolvingSymlinksInPath()
}

@Test
func inspectSessionReadsOnlyRequestedSessionAndDoesNotRepairItsTail() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let sessionURL = root.appending(path: sessionID.uuidString)
    try writeRecoveryManifest(sessionID: sessionID, sourceKind: .importedFile, to: sessionURL)
    let checkpoint = AudioCheckpoint(
        committedFrames: 100,
        sampleRate: 100,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [100],
        gapEvents: []
    )
    try writeRecoveryCheckpoint(checkpoint, to: sessionURL)
    let eventsURL = sessionURL.appending(path: "events.jsonl")
    let original = Data("{\"event_seq\":1,\"event_type\":\"unused\"}\n{\"unfinished\"".utf8)
    try original.write(to: eventsURL)

    let otherID = UUID()
    let otherURL = root.appending(path: otherID.uuidString)
    try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
    try Data("invalid manifest".utf8).write(to: otherURL.appending(path: "session.json"))

    let result = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: sessionID)
    #expect(result?.manifest.sessionID == sessionID)
    #expect(isImportedOriginal(result?.source, in: sessionURL))
    #expect(try Data(contentsOf: eventsURL) == original)
}

@Test
func recoveryScannerChoosesPendingOnlyASRResume() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let sessionURL = root.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(
        sessionID: sessionID,
        sourceKind: .live,
        to: sessionURL
    )
    let checkpoint = AudioCheckpoint(
        committedFrames: 200,
        sampleRate: 100,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [200],
        gapEvents: []
    )
    try writeRecoveryCheckpoint(checkpoint, to: sessionURL)

    let writer = try SessionWriter(sessionURL: sessionURL)
    for index in 0..<2 {
        let segmentID = String(format: "seg_%06d", index + 1)
        let start = Int64(index * 100)
        let end = start + 100
        _ = try await writer.append(EventDraft(
            eventType: "segment.created",
            sessionID: sessionID,
            segmentationRunID: "seg_resume",
            segmentID: segmentID,
            sourceStartFrame: start,
            sourceEndFrame: end,
            payload: EmptyPayload()
        ))
        _ = try await writer.append(EventDraft(
            eventType: "asr.pending",
            sessionID: sessionID,
            processingRunID: "asr_resume",
            segmentationRunID: "seg_resume",
            segmentID: segmentID,
            sourceStartFrame: start,
            sourceEndFrame: end,
            payload: EmptyPayload()
        ))
    }
    _ = try await writer.append(EventDraft(
        eventType: "asr.completed",
        sessionID: sessionID,
        processingRunID: "asr_resume",
        segmentationRunID: "seg_resume",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: ASRCompletedEventPayload(
            text: "完了済み",
            detectedLanguage: "ja",
            engine: "qwen3-asr",
            model: "test"
        )
    ))

    let candidates = try SessionRecoveryScanner(
        sessionsRoot: root
    ).pendingSessions()

    guard case .resumeASR(let plan) = candidates.first?.action else {
        Issue.record("pending ASR should be resumed")
        return
    }
    #expect(plan.pendingSegments.map(\.segmentID) == ["seg_000002"])
}

@Test
func brokenSessionDoesNotBlockOtherPendingSessions() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let validID = UUID()
    let valid = root.appending(path: validID.uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(sessionID: validID, sourceKind: .live, to: valid)
    try writeRecoveryCheckpoint(AudioCheckpoint(
        committedFrames: 100,
        sampleRate: 100,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [100],
        gapEvents: []
    ), to: valid)
    let brokenID = UUID()
    let broken = root.appending(path: brokenID.uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("{broken".utf8).write(to: broken.appending(path: "session.json"))

    let candidates = try SessionRecoveryScanner(sessionsRoot: root).pendingSessions()
    #expect(candidates.map(\.manifest.sessionID) == [validID])
}

@Test
func crashAfterLastASRCompletionFinishesTheRunWithoutRerunningASR() async throws {
    for (asrRunID, resumes) in [("asr", true), ("asr_live_run", false)] {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let sessionURL = root.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        try writeRecoveryManifest(sessionID: sessionID, sourceKind: .live, to: sessionURL)
        try writeRecoveryCheckpoint(AudioCheckpoint(
            committedFrames: 100,
            sampleRate: 100,
            channelCount: 1,
            sampleFormat: .float32LE,
            chunkFiles: ["chunk-000000.f32le"],
            chunkFrameCounts: [100],
            gapEvents: []
        ), to: sessionURL)
        let writer = try SessionWriter(sessionURL: sessionURL)
        _ = try await writer.append(EventDraft(
            eventType: "segment.created", sessionID: sessionID,
            segmentationRunID: "seg", segmentID: "seg_000001",
            sourceStartFrame: 0, sourceEndFrame: 100, payload: EmptyPayload()
        ))
        _ = try await writer.append(EventDraft(
            eventType: "asr.pending", sessionID: sessionID, processingRunID: asrRunID,
            segmentationRunID: "seg", segmentID: "seg_000001",
            sourceStartFrame: 0, sourceEndFrame: 100, payload: EmptyPayload()
        ))
        _ = try await writer.append(EventDraft(
            eventType: "asr.completed", sessionID: sessionID, processingRunID: asrRunID,
            segmentationRunID: "seg", segmentID: "seg_000001",
            sourceStartFrame: 0, sourceEndFrame: 100,
            payload: ASRCompletedEventPayload(
                text: "already completed", detectedLanguage: "en",
                engine: "qwen3-asr", model: "test"
            )
        ))

        let action = try SessionRecoveryScanner(sessionsRoot: root)
            .pendingSessions().first?.action
        if resumes {
            guard case .resumeASR(let plan) = action else {
                Issue.record("completed ASR must be resumed without pending work: \(String(describing: action))")
                continue
            }
            #expect(plan.pendingSegments.isEmpty)
            #expect(plan.transcriptEvents.count == 2)
        } else {
            #expect(action == .reprocess)
        }
    }
}

@Test
func bulkDiscoverySkipsFolderWhoseManifestNamesAnotherSession() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(sessionID: UUID(), sourceKind: .live, to: folder)
    try writeRecoveryCheckpoint(AudioCheckpoint(
        committedFrames: 100,
        sampleRate: 100,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [100],
        gapEvents: []
    ), to: folder)

    #expect(try SessionRecoveryScanner(sessionsRoot: root).pendingSessions().isEmpty)
}

@Test
func inspectReportsPendingSessionWithoutAudioAsMissingAudio() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    try writeRecoveryManifest(sessionID: id, sourceKind: .live, to: root.appending(path: id.uuidString))

    #expect(throws: SessionRecoveryScannerError.missingAudio) {
        _ = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id)
    }
}

@Test
func recoveryUsesIntactOriginalWhenCheckpointIsUnusable() throws {
    let checkpoints = [
        AudioCheckpoint(committedFrames: 100, sampleRate: 100, channelCount: 1, sampleFormat: .float32LE, chunkFiles: ["missing.f32le"], chunkFrameCounts: [100], gapEvents: []),
        AudioCheckpoint(committedFrames: 1, sampleRate: 100, channelCount: 1, sampleFormat: .float32LE, chunkFiles: ["../../../secret"], chunkFrameCounts: [1], gapEvents: []),
    ]
    for checkpoint in checkpoints {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let url = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        try writeRecoveryManifest(sessionID: id, sourceKind: .importedFile, to: url)
        let processing = url.appending(path: "audio/processing", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: processing.appending(path: DurableAudioWriter.checkpointFilename))
        try Data(count: 4).write(to: root.appending(path: "secret"))
        let original = url.appending(path: "audio/original.wav")
        try Data([1, 2, 3]).write(to: original)

        let source = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: id)?.source
        guard case .importedOriginal(let url) = source else {
            Issue.record("intact original must be chosen: \(String(describing: source))")
            continue
        }
        #expect(url.resolvingSymlinksInPath() == original.resolvingSymlinksInPath())
    }
}

@Test
func recoveryScannerPromotesCompletedUnselectedASRRun() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let sessionURL = root.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(
        sessionID: sessionID,
        sourceKind: .live,
        to: sessionURL
    )
    let checkpoint = AudioCheckpoint(
        committedFrames: 100,
        sampleRate: 100,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [100],
        gapEvents: []
    )
    try writeRecoveryCheckpoint(checkpoint, to: sessionURL)

    let writer = try SessionWriter(sessionURL: sessionURL)
    _ = try await writer.append(EventDraft(
        eventType: "segment.created",
        sessionID: sessionID,
        segmentationRunID: "seg_complete",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.pending",
        sessionID: sessionID,
        processingRunID: "asr_complete",
        segmentationRunID: "seg_complete",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.completed",
        sessionID: sessionID,
        processingRunID: "asr_complete",
        segmentationRunID: "seg_complete",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: ASRCompletedEventPayload(
            text: "復旧対象",
            detectedLanguage: "ja",
            engine: "qwen3-asr",
            model: "test"
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "processing.run.completed",
        sessionID: sessionID,
        processingRunID: "asr_complete",
        payload: ProcessingRunCompletedPayload(
            stage: .asr,
            succeeded: true,
            completedCount: 1,
            failedCount: 0
        )
    ))

    let candidates = try SessionRecoveryScanner(
        sessionsRoot: root
    ).pendingSessions()

    guard case .selectCompletedASR(let plan) = candidates.first?.action else {
        Issue.record("completed unselected ASR run should be promoted")
        return
    }
    #expect(plan.asrRunID == "asr_complete")
    #expect(plan.pendingSegments.isEmpty)
}


@Test
func recoveryScannerRunsDiarizationWhenSelectedASRHasNoDiarizationRun() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let sessionURL = root.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(
        sessionID: sessionID,
        sourceKind: .live,
        to: sessionURL
    )
    let checkpoint = AudioCheckpoint(
        committedFrames: 100,
        sampleRate: 100,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [100],
        gapEvents: []
    )
    try writeRecoveryCheckpoint(checkpoint, to: sessionURL)

    let writer = try SessionWriter(sessionURL: sessionURL)
    _ = try await writer.append(EventDraft(
        eventType: "segment.created",
        sessionID: sessionID,
        segmentationRunID: "seg_active",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.pending",
        sessionID: sessionID,
        processingRunID: "asr_active",
        segmentationRunID: "seg_active",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.completed",
        sessionID: sessionID,
        processingRunID: "asr_active",
        segmentationRunID: "seg_active",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: ASRCompletedEventPayload(
            text: "話者分離待ち",
            detectedLanguage: "ja",
            engine: "qwen3-asr",
            model: "test"
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "processing.run.completed",
        sessionID: sessionID,
        processingRunID: "asr_active",
        payload: ProcessingRunCompletedPayload(
            stage: .asr,
            succeeded: true,
            completedCount: 1,
            failedCount: 0
        )
    ))

    let metadata = ProcessingMetadata(
        timelineVersion: 1,
        vadVersion: "vad",
        vadConfigHash: "hash",
        asrEngine: "qwen",
        asrModel: "model",
        asrVersion: "version",
        diarizationVersion: "diar",
        sceneAnalyzerVersion: 1,
        jevSchemaVersion: 1,
        policyVersion: 1,
        materializerSchemaVersion: 1,
        activeRuns: ActiveRuns(
            segmentation: "seg_active",
            asr: "asr_active"
        )
    )
    try ProcessingMetadataStore(sessionURL: sessionURL).save(metadata)

    let candidates = try SessionRecoveryScanner(
        sessionsRoot: root
    ).pendingSessions()

    guard case .runDiarization(let plan) = candidates.first?.action else {
        Issue.record("selected ASR without diarization should resume diarization")
        return
    }
    #expect(plan.asrRunID == "asr_active")
}

private func appendCompletedRecoveryASRRun(
    writer: SessionWriter,
    sessionID: UUID,
    segmentationRunID: String,
    asrRunID: String,
    text: String
) async throws {
    let segmentID = "seg_000001"
    _ = try await writer.append(EventDraft(
        eventType: "segment.created",
        sessionID: sessionID,
        segmentationRunID: segmentationRunID,
        segmentID: segmentID,
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.pending",
        sessionID: sessionID,
        processingRunID: asrRunID,
        segmentationRunID: segmentationRunID,
        segmentID: segmentID,
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.completed",
        sessionID: sessionID,
        processingRunID: asrRunID,
        segmentationRunID: segmentationRunID,
        segmentID: segmentID,
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: ASRCompletedEventPayload(
            text: text,
            detectedLanguage: "ja",
            engine: "qwen3-asr",
            model: "test"
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "processing.run.completed",
        sessionID: sessionID,
        processingRunID: asrRunID,
        payload: ProcessingRunCompletedPayload(
            stage: .asr,
            succeeded: true,
            completedCount: 1,
            failedCount: 0
        )
    ))
}

@Test
func recoveryScannerRerunsPostASRStagesWhenScopeWasNotSelected() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let sessionURL = root.appending(
        path: sessionID.uuidString,
        directoryHint: .isDirectory
    )
    try writeRecoveryManifest(
        sessionID: sessionID,
        sourceKind: .live,
        to: sessionURL
    )

    let checkpoint = AudioCheckpoint(
        committedFrames: 100,
        sampleRate: 100,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [100],
        gapEvents: []
    )
    try writeRecoveryCheckpoint(checkpoint, to: sessionURL)

    let writer = try SessionWriter(sessionURL: sessionURL)
    try await appendCompletedRecoveryASRRun(
        writer: writer,
        sessionID: sessionID,
        segmentationRunID: "seg_active",
        asrRunID: "asr_active",
        text: "後処理を復旧する"
    )

    let metadata = ProcessingMetadata(
        timelineVersion: 1,
        vadVersion: "vad",
        vadConfigHash: "hash",
        asrEngine: "qwen",
        asrModel: "model",
        asrVersion: "version",
        diarizationVersion: "diar",
        sceneAnalyzerVersion: 1,
        jevSchemaVersion: 1,
        policyVersion: 1,
        materializerSchemaVersion: 1,
        activeRuns: ActiveRuns(
            segmentation: "seg_active",
            asr: "asr_active",
            diarization: "diar_old",
            scene: "scene_old"
        )
    )
    try ProcessingMetadataStore(
        sessionURL: sessionURL
    ).save(metadata)

    let candidates = try SessionRecoveryScanner(
        sessionsRoot: root
    ).pendingSessions()

    guard case .runDiarization(let plan)
            = candidates.first?.action else {
        Issue.record(
            "scope未完了なら話者分離以降を安全に再実行する必要がある"
        )
        return
    }
    #expect(plan.asrRunID == "asr_active")
    #expect(plan.runSucceeded)
}

@Test
func recoveryScannerTreatsSelectedScopeAsMandatoryLocalCompletion() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let sessionURL = root.appending(
        path: sessionID.uuidString,
        directoryHint: .isDirectory
    )
    try writeRecoveryManifest(
        sessionID: sessionID,
        sourceKind: .live,
        to: sessionURL
    )

    let checkpoint = AudioCheckpoint(
        committedFrames: 100,
        sampleRate: 100,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [100],
        gapEvents: []
    )
    try writeRecoveryCheckpoint(checkpoint, to: sessionURL)

    let writer = try SessionWriter(sessionURL: sessionURL)
    try await appendCompletedRecoveryASRRun(
        writer: writer,
        sessionID: sessionID,
        segmentationRunID: "seg_active",
        asrRunID: "asr_active",
        text: "ローカル処理完了"
    )

    let metadata = ProcessingMetadata(
        timelineVersion: 1,
        vadVersion: "vad",
        vadConfigHash: "hash",
        asrEngine: "qwen",
        asrModel: "model",
        asrVersion: "version",
        diarizationVersion: "diar",
        sceneAnalyzerVersion: 1,
        jevSchemaVersion: 1,
        policyVersion: 1,
        materializerSchemaVersion: 1,
        activeRuns: ActiveRuns(
            segmentation: "seg_active",
            asr: "asr_active",
            diarization: "diar_active",
            scene: "scene_active",
            scope: "scope_active"
        )
    )
    try ProcessingMetadataStore(
        sessionURL: sessionURL
    ).save(metadata)

    let candidates = try SessionRecoveryScanner(
        sessionsRoot: root
    ).pendingSessions()

    #expect(candidates.isEmpty)
}

@Test
func recoveryScannerUsesActiveGoodASREvenWhenNewerRunFailed() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let sessionURL = root.appending(
        path: sessionID.uuidString,
        directoryHint: .isDirectory
    )
    try writeRecoveryManifest(
        sessionID: sessionID,
        sourceKind: .live,
        to: sessionURL
    )

    let checkpoint = AudioCheckpoint(
        committedFrames: 100,
        sampleRate: 100,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [100],
        gapEvents: []
    )
    try writeRecoveryCheckpoint(checkpoint, to: sessionURL)

    let writer = try SessionWriter(sessionURL: sessionURL)
    try await appendCompletedRecoveryASRRun(
        writer: writer,
        sessionID: sessionID,
        segmentationRunID: "seg_active",
        asrRunID: "asr_active",
        text: "正常run"
    )

    _ = try await writer.append(EventDraft(
        eventType: "segment.created",
        sessionID: sessionID,
        segmentationRunID: "seg_failed",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.pending",
        sessionID: sessionID,
        processingRunID: "asr_failed_newer",
        segmentationRunID: "seg_failed",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.failed",
        sessionID: sessionID,
        processingRunID: "asr_failed_newer",
        segmentationRunID: "seg_failed",
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: ASRFailedEventPayload(
            kind: .transcriptionFailed,
            message: "forced failure"
        )
    ))

    let metadata = ProcessingMetadata(
        timelineVersion: 1,
        vadVersion: "vad",
        vadConfigHash: "hash",
        asrEngine: "qwen",
        asrModel: "model",
        asrVersion: "version",
        diarizationVersion: "diar",
        sceneAnalyzerVersion: 1,
        jevSchemaVersion: 1,
        policyVersion: 1,
        materializerSchemaVersion: 1,
        activeRuns: ActiveRuns(
            segmentation: "seg_active",
            asr: "asr_active"
        )
    )
    try ProcessingMetadataStore(
        sessionURL: sessionURL
    ).save(metadata)

    let candidates = try SessionRecoveryScanner(
        sessionsRoot: root
    ).pendingSessions()

    guard case .runDiarization(let plan)
            = candidates.first?.action else {
        Issue.record(
            "最新失敗runではなくactive正常runから復旧する必要がある"
        )
        return
    }
    #expect(plan.asrRunID == "asr_active")
    #expect(plan.hasFailures == false)
}


@Test
func recoveryScannerSchedulesOnlyDeferredPrioritySegments() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let sessionURL = root.appending(
        path: sessionID.uuidString,
        directoryHint: .isDirectory
    )
    try writeRecoveryManifest(
        sessionID: sessionID,
        sourceKind: .live,
        to: sessionURL
    )
    let checkpoint = AudioCheckpoint(
        committedFrames: 100,
        sampleRate: 100,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [100],
        gapEvents: []
    )
    try writeRecoveryCheckpoint(checkpoint, to: sessionURL)

    let writer = try SessionWriter(sessionURL: sessionURL)
    try await appendCompletedRecoveryASRRun(
        writer: writer,
        sessionID: sessionID,
        segmentationRunID: "seg-active",
        asrRunID: "asr-active",
        text: "意味分類待ち"
    )

    _ = try await writer.append(EventDraft(
        eventType: "content_priority.assigned",
        sessionID: sessionID,
        processingRunID: "priority-active",
        segmentID: "seg_000001",
        payload: ContentPriorityEventPayload(
            priority: .primary,
            decision: .retryPending
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "content_priority.pending_retry",
        sessionID: sessionID,
        processingRunID: "priority-active",
        segmentID: "seg_000001",
        payload: EmptyPayload()
    ))

    let metadata = ProcessingMetadata(
        timelineVersion: 1,
        vadVersion: "vad",
        vadConfigHash: "hash",
        asrEngine: "qwen",
        asrModel: "model",
        asrVersion: "version",
        diarizationVersion: "diar",
        sceneAnalyzerVersion: 1,
        jevSchemaVersion: 1,
        policyVersion: 1,
        materializerSchemaVersion: 1,
        activeRuns: ActiveRuns(
            segmentation: "seg-active",
            asr: "asr-active",
            diarization: "diar-active",
            scene: "scene-active",
            scope: "scope-active",
            contentPriority: "priority-active"
        )
    )
    try ProcessingMetadataStore(
        sessionURL: sessionURL
    ).save(metadata)

    let candidates = try SessionRecoveryScanner(
        sessionsRoot: root
    ).pendingSessions()

    guard case .retryContentPriority(let segmentIDs)
            = candidates.first?.action else {
        Issue.record("保留中のJev分類だけを再試行する必要がある")
        return
    }
    #expect(segmentIDs == ["seg_000001"])
}

@Test
func recoveryScannerFindsDeferredContentPriorityWithoutJevEvents() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let sessionURL = root.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
    try writeRecoveryManifest(sessionID: sessionID, sourceKind: .live, to: sessionURL)
    try writeRecoveryCheckpoint(AudioCheckpoint(
        committedFrames: 1_600,
        sampleRate: 16_000,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["chunk-000000.f32le"],
        chunkFrameCounts: [1_600],
        gapEvents: []
    ), to: sessionURL)
    try await appendCompletedRecoveryASRRun(
        writer: SessionWriter(sessionURL: sessionURL),
        sessionID: sessionID,
        segmentationRunID: "seg-active",
        asrRunID: "asr-active",
        text: "意味分類待ち"
    )
    let metadata = ProcessingMetadata(
        timelineVersion: 1, vadVersion: "vad", vadConfigHash: "hash",
        asrEngine: "qwen", asrModel: "model", asrVersion: "version",
        diarizationVersion: "diar", sceneAnalyzerVersion: 1, jevSchemaVersion: 1,
        policyVersion: 1, materializerSchemaVersion: 1,
        activeRuns: ActiveRuns(
            segmentation: "seg-active", asr: "asr-active", diarization: "diar-active",
            scene: "scene-active", scope: "scope-active"
        )
    ).withPendingContentPrioritySegmentIDs(["seg_000001"])
    try ProcessingMetadataStore(sessionURL: sessionURL).save(metadata)

    let maybeCandidate = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: sessionID)
    let candidate = try #require(maybeCandidate)
    guard case .retryContentPriority(let segmentIDs) = candidate.action else {
        Issue.record("A deferred Jev classification should be retryable without Jev events")
        return
    }
    #expect(segmentIDs == ["seg_000001"])
}
