import Foundation
import MacAmbientJevPipeline
import Synchronization
import Testing
@testable import MacAmbientJevAppleSupport
@testable import MacAmbientJevCore

private func makeSession(_ paths: AppPaths, source: SessionSource, second: Int) throws -> SessionLayout {
    SessionLayout(sessionURL: try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: UUID(), source: source,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(second)), timeZone: TimeZone(secondsFromGMT: 0)!
    ))
}

private func publish(_ layout: SessionLayout, frameCount: Int64 = 16_000, state: ProcessingMetadata.State) async throws {
    let sessionID = try layout.loadManifest().sessionID
    let writer = try SessionWriter(sessionURL: layout.sessionURL)
    let provenance = RunProvenance(engine: "launch-maintenance-test", model: nil, version: "test", configuration: [:])
    let runs = ActiveRuns(segmentation: "local_segmentation", asr: "local_asr")
    let generation = PipelineGeneration(
        id: UUID(), runs: runs, sampleRate: 16_000,
        segmentationProvenance: provenance, asrProvenance: provenance
    )
    try await writer.append(generation.startEvent(sessionID: sessionID))
    for (stage, runID) in [(ProcessingStage.segmentation, "local_segmentation"), (.asr, "local_asr")] {
        try await writer.append(EventDraft(
            eventType: "processing.run.started", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunStartedPayload(stage: stage, provenance: provenance)
        ))
    }
    try await writer.append(EventDraft(
        eventType: "segmentation.input.sealed", sessionID: sessionID, segmentationRunID: "local_segmentation",
        payload: SegmentationInputSealedPayload(frameCount: frameCount)
    ))
    try await writer.append(EventDraft(
        eventType: "segmentation.completed", sessionID: sessionID, segmentationRunID: "local_segmentation",
        payload: SegmentationCompletedPayload(consumedFrames: frameCount, segmentCount: 0)
    ))
    for (stage, runID) in [(ProcessingStage.segmentation, "local_segmentation"), (.asr, "local_asr")] {
        try await writer.append(EventDraft(
            eventType: "processing.run.completed", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunCompletedPayload(stage: stage, succeeded: true, completedCount: 0, failedCount: 0)
        ))
    }
    try ProcessingMetadataStore(sessionURL: layout.sessionURL).save(ProcessingMetadata(
        generationID: generation.id, state: state, failureReason: nil
    ))
}

private func publishedRecording(_ paths: AppPaths, second: Int, state: ProcessingMetadata.State) async throws -> SessionLayout {
    let layout = try makeSession(paths, source: .recording(.microphone), second: second)
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: layout.sessionURL)
    try await writer.append(samples: Array(repeating: 0.3, count: 16_000))
    _ = try await writer.finish()
    try await publish(layout, state: state)
    return layout
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@Test
func launchMaintenanceConvergesEverySessionAndNamesTheOneItCouldNotMaintain() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root.appending(path: "sessions"))
    let recordingNow = try makeSession(paths, source: .recording(.microphone), second: 9)
    let recordingNowWriter = try DurableAudioWriter(directory: recordingNow.processingDirectory, chunkDurationSeconds: 1, sessionURL: recordingNow.sessionURL)
    try await recordingNowWriter.append(samples: Array(repeating: 0.3, count: 16_000))
    _ = try await recordingNowWriter.finish()
    try await publish(recordingNow, state: .complete)
    let compactOnly = try await publishedRecording(paths, second: 0, state: .complete)
    let reprocessing = try await publishedRecording(paths, second: 1, state: .paused)
    let finishedImport = try makeSession(paths, source: .imported(originalFilename: "fixture.caf"), second: 3)
    try Data("original".utf8).write(to: finishedImport.audioDirectory.appending(path: "original.caf"))
    try FileManager.default.createDirectory(at: finishedImport.processingDirectory, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: finishedImport.processingDirectory.appending(path: "stale"))
    try await publish(finishedImport, frameCount: 0, state: .complete)
    let unwritable = try await publishedRecording(paths, second: 4, state: .complete)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: unwritable.audioDirectory.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unwritable.audioDirectory.path)
        try? FileManager.default.removeItem(at: root)
    }

    let scan = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
    #expect(scan.failures.isEmpty)
    let recordingNowID = try recordingNow.loadManifest().sessionID
    #expect(Set(scan.maintenance.map(\.sessionURL)).contains(recordingNow.sessionURL))
    let reprocessingID = try reprocessing.loadManifest().sessionID
    #expect(scan.candidates.contains { $0.manifest.sessionID == reprocessingID })
    #expect(!scan.maintenance.contains { $0.sessionID == reprocessingID })
    #expect(scan.maintenance.filter { $0.sessionID != recordingNowID }.count == 3)

    let announced = Mutex(0)
    let failures = await SessionStorageMaintainer.maintain(
        scan.maintenance.filter { $0.sessionID != recordingNowID },
        willMaintain: { count in announced.withLock { $0 = count } }
    )

    #expect(announced.withLock { $0 } == 3)
    guard case .recordingFLAC = try SessionAudioStorageStore(layout: compactOnly).load() else {
        Issue.record("a completed recording is stored as FLAC")
        return
    }
    #expect(!exists(compactOnly.processingDirectory))
    #expect(exists(compactOnly.recordingFLACURL))
    guard case .recordingPCM = try SessionAudioStorageStore(layout: reprocessing).load() else {
        Issue.record("a paused session remains stored as PCM")
        return
    }
    #expect(exists(reprocessing.processingDirectory))
    #expect(!exists(reprocessing.recordingFLACURL))
    #expect(!exists(finishedImport.processingDirectory))
    #expect(exists(finishedImport.audioDirectory.appending(path: "original.caf")))
    #expect(exists(recordingNow.processingDirectory))
    guard case .recordingPCM = try SessionAudioStorageStore(layout: unwritable).load() else {
        Issue.record("a session whose compaction failed stays PCM")
        return
    }
    #expect(exists(unwritable.processingDirectory))
    #expect(Array(failures.keys) == [try unwritable.loadManifest().sessionID])
    let failure = try #require(failures.values.first)
    guard case .failed(let message) = failure else {
        Issue.record("unexpected shutdown interruption while maintaining the unwritable session")
        return
    }
    #expect(message.hasPrefix(unwritable.sessionURL.lastPathComponent + ": "))
}
