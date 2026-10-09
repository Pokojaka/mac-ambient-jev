import Foundation
import Synchronization
import Testing
@testable import MacAmbientJevAppleSupport
@testable import MacAmbientJevCore

private let publishedRuns = ActiveRuns(
    segmentation: "seg_previous", asr: "asr_previous", diarization: "diar_previous",
    scene: "scene_previous", scope: "scope_previous"
)

private func makeSession(_ paths: AppPaths, source: SessionSource, second: Int) throws -> SessionLayout {
    SessionLayout(sessionURL: try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: UUID(), source: source,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(second)), timeZone: TimeZone(secondsFromGMT: 0)!
    ))
}

private func publish(_ layout: SessionLayout, attempt: FinalizationAttempt.State) async throws {
    let sessionID = try layout.loadManifest().sessionID
    let writer = try SessionWriter(sessionURL: layout.sessionURL)
    let localRuns: [(ProcessingStage, String)] = [
        (.segmentation, "seg_previous"), (.asr, "asr_previous"),
        (.diarization, "diar_previous"), (.scene, "scene_previous"), (.scope, "scope_previous")
    ]
    for (stage, runID) in localRuns {
        try await writer.append(EventDraft(
            eventType: "processing.run.started", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunStartedPayload(
                stage: stage,
                provenance: RunProvenance(engine: "test", model: nil, version: "test", configuration: [:])
            )
        ))
        try await writer.append(EventDraft(
            eventType: "processing.run.completed", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunCompletedPayload(stage: stage, succeeded: true, completedCount: 0, failedCount: 0)
        ))
    }
    try ProcessingMetadataStore(sessionURL: layout.sessionURL).save(ProcessingMetadata(
        finalizationAttempt: FinalizationAttempt(attemptID: "finalize_previous", state: attempt, failureReason: nil),
        activeRuns: publishedRuns,
        pendingClauseBoundarySegments: [],
        pendingContentPriorityClauses: []
    ))
}

private func publishedRecording(_ paths: AppPaths, second: Int, attempt: FinalizationAttempt.State) async throws -> SessionLayout {
    let layout = try makeSession(paths, source: .recording(.microphone), second: second)
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: layout.sessionURL)
    try await writer.append(samples: Array(repeating: 0.3, count: 16_000))
    _ = try await writer.finish()
    try await publish(layout, attempt: attempt)
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
    try await publish(recordingNow, attempt: .complete)
    let compactOnly = try await publishedRecording(paths, second: 0, attempt: .complete)
    let reprocessing = try await publishedRecording(paths, second: 1, attempt: .paused)
    let staleInput = try await publishedRecording(paths, second: 2, attempt: .complete)
    _ = try RecordingAudioCompactor(interrupt: nil).compact(layout: staleInput)
    try FileManager.default.createDirectory(at: staleInput.derivedDirectory, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: staleInput.diarizationInputURL)
    let finishedImport = try makeSession(paths, source: .imported(originalFilename: "fixture.caf"), second: 3)
    try Data("original".utf8).write(to: finishedImport.audioDirectory.appending(path: "original.caf"))
    try FileManager.default.createDirectory(at: finishedImport.processingDirectory, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: finishedImport.processingDirectory.appending(path: "stale"))
    try await publish(finishedImport, attempt: .complete)
    let unwritable = try await publishedRecording(paths, second: 4, attempt: .paused)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: unwritable.audioDirectory.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unwritable.audioDirectory.path)
        try? FileManager.default.removeItem(at: root)
    }

    let scan = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
    #expect(scan.failures.isEmpty)
    let recordingNowID = try recordingNow.loadManifest().sessionID
    #expect(Set(scan.maintenance.map(\.sessionURL)).contains(recordingNow.sessionURL))

    let announced = Mutex(0)
    let failures = await SessionStorageMaintainer.maintain(
        scan.maintenance.filter { $0.sessionID != recordingNowID },
        willMaintain: { count in announced.withLock { $0 = count } }
    )

    #expect(announced.withLock { $0 } == 5)
    for layout in [compactOnly, reprocessing, staleInput] {
        guard case .recordingFLAC = try SessionAudioStorageStore(layout: layout).load() else {
            Issue.record("\(layout.sessionURL.lastPathComponent) is stored as FLAC")
            continue
        }
        #expect(!exists(layout.processingDirectory))
        #expect(exists(layout.recordingFLACURL))
        #expect(!exists(layout.derivedDirectory))
    }
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
    #expect(failure.hasPrefix(unwritable.sessionURL.lastPathComponent + ": "))
}
