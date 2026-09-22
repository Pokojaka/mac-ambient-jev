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

    #expect(candidates.first?.source == .processingTimeline(checkpoint))
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
        chunkFiles: ["chunk-000000.f32le"]
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
        chunkFiles: ["chunk-000000.f32le"]
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
        chunkFiles: ["chunk-000000.f32le"]
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