import Combine
import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevPipeline
import MacAmbientJevRuntime

private func launchMaintenanceRecording(
    paths: AppPaths, state: ProcessingMetadata.State = .complete
) async throws -> SessionLayout {
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let layout = SessionLayout(sessionURL: sessionURL)
    let audioWriter = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: layout.sessionURL)
    try await audioWriter.append(samples: Array(repeating: 0.125, count: 16_000))
    _ = try await audioWriter.finish()
    let provenance = RunProvenance(engine: "launch-maintenance-test", model: nil, version: "test", configuration: [:])
    let runs = ActiveRuns(segmentation: "local_segmentation", asr: "local_asr")
    let generation = PipelineGeneration(
        id: UUID(), runs: runs, sampleRate: 16_000,
        segmentationProvenance: provenance, asrProvenance: provenance
    )
    let eventWriter = try SessionWriter(sessionURL: sessionURL)
    try await eventWriter.append(generation.startEvent(sessionID: sessionID))
    for (stage, runID) in [(ProcessingStage.segmentation, "local_segmentation"), (.asr, "local_asr")] {
        try await eventWriter.append(EventDraft(
            eventType: "processing.run.started", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunStartedPayload(stage: stage, provenance: provenance)
        ))
    }
    try await eventWriter.append(EventDraft(
        eventType: "segmentation.input.sealed", sessionID: sessionID, segmentationRunID: "local_segmentation",
        payload: SegmentationInputSealedPayload(frameCount: 16_000)
    ))
    try await eventWriter.append(EventDraft(
        eventType: "segmentation.completed", sessionID: sessionID, segmentationRunID: "local_segmentation",
        payload: SegmentationCompletedPayload(consumedFrames: 16_000, segmentCount: 0)
    ))
    for (stage, runID) in [(ProcessingStage.segmentation, "local_segmentation"), (.asr, "local_asr")] {
        try await eventWriter.append(EventDraft(
            eventType: "processing.run.completed", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunCompletedPayload(
                stage: stage, succeeded: true, completedCount: 0, failedCount: 0
            )
        ))
    }
    try ProcessingMetadataStore(sessionURL: sessionURL).save(ProcessingMetadata(
        generationID: generation.id, state: state, failureReason: nil
    ))
    return layout
}

@MainActor
private func launchMaintenanceState(paths: AppPaths, defaults: UserDefaults) -> AppState {
    AppState(
        paths: paths, captureEngine: FakeAppCaptureEngine(), microphoneAccess: { false },
        pausesProcessing: true, userDefaults: defaults, engines: productionEngines(paths: paths),
        modelProvisioning: ReadyModelProvisioning(),
        makeLiveVADSession: idleLiveVADFactory(),
        thermalMonitor: TestThermalMonitor(.nominal),
        liveTranscriptionSleep: { try await Task.sleep(for: $0) }
    )
}

@MainActor
@Test("completed launch maintenance clears the processing indicator and live header when no recovery is needed")
func completedLaunchMaintenanceClearsItsStatus() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let layout = try await launchMaintenanceRecording(paths: paths)
    let scan = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
    try #require(scan.maintenance.count == 1)
    try #require(scan.candidates.isEmpty)
    let state = launchMaintenanceState(paths: paths, defaults: defaults)

    await state.processingCoordinator.recoverPendingSessions(
        effects: state,
        scan: {
            try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
        },
        maintain: { items, callback in
            await SessionStorageMaintainer.maintain(items, willMaintain: callback)
        }
    )

    #expect(!state.processingQueue.isMaintainingStorage)
    #expect(state.processingStatusText == nil)
    #expect(state.transcriptViewModel.statusText == UserFacingStatus.idle.text)
    #expect(state.processingQueue.pending.isEmpty)
    #expect(!state.processingCoordinator.isDraining)
    guard case .recordingFLAC(let timeline) = try SessionAudioStorageStore(layout: layout).load() else {
        Issue.record("launch recovery did not compact the saved recording")
        return
    }
    #expect(timeline.committedFrames == 16_000)
    #expect(FileManager.default.fileExists(atPath: layout.recordingFLACURL.path))
    #expect(!FileManager.default.fileExists(atPath: layout.processingDirectory.path))
}

@MainActor
@Test("maintenance completion preserves processing status replaced while its storage work was awaited")
func completedLaunchMaintenancePreservesNewProcessingStatus() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    _ = try await launchMaintenanceRecording(paths: paths)
    let state = launchMaintenanceState(paths: paths, defaults: defaults)
    let ongoingStatus = UserFacingStatus.classifyingContent.text
    let previousTranscriptStatus = "表示済みの文字起こし"
    state.transcriptViewModel.setStatus(previousTranscriptStatus)
    let observation = state.transcriptViewModel.$statusText.dropFirst().sink { _ in
        guard state.processingQueue.isMaintainingStorage else { return }
        state.processingState = .running
        state.processingStatusText = ongoingStatus
    }
    defer { observation.cancel() }

    await state.processingCoordinator.recoverPendingSessions(
        effects: state,
        scan: {
            try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
        },
        maintain: { items, callback in
            await SessionStorageMaintainer.maintain(items, willMaintain: callback)
        }
    )

    #expect(!state.processingQueue.isMaintainingStorage)
    #expect(state.processingState == .running)
    #expect(state.processingStatusText == ongoingStatus)
    #expect(state.transcriptViewModel.statusText == previousTranscriptStatus)
}

@MainActor
@Test("failed maintenance remains visible, leaves no maintaining header and excludes the failed session from recovery")
func failedLaunchMaintenanceReportsFailureWithoutStaleStatus() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let layout = try await launchMaintenanceRecording(paths: paths, state: .paused)
    _ = try RecordingAudioCompactor(interrupt: nil).compact(layout: layout)
    try FileManager.default.createDirectory(at: layout.processingDirectory, withIntermediateDirectories: true)
    try Data("invalid FLAC".utf8).write(to: layout.recordingFLACURL)
    let scan = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
    try #require(scan.maintenance.count == 1)
    try #require(scan.candidates.count == 1)
    let state = launchMaintenanceState(paths: paths, defaults: defaults)

    await state.processingCoordinator.recoverPendingSessions(
        effects: state,
        scan: {
            try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
        },
        maintain: { items, callback in
            await SessionStorageMaintainer.maintain(items, willMaintain: callback)
        }
    )

    #expect(!state.processingQueue.isMaintainingStorage)
    guard case .partialFailure(let message) = state.processingState else {
        Issue.record("corrupt saved FLAC must be reported as a maintenance failure")
        return
    }
    #expect(message.contains(layout.sessionURL.lastPathComponent + ": "))
    #expect(state.processingStatusText == message)
    #expect(state.transcriptViewModel.statusText == UserFacingStatus.idle.text)
    #expect(state.processingQueue.pending.isEmpty)
    #expect(!state.processingCoordinator.isDraining)
    #expect(FileManager.default.fileExists(atPath: layout.processingDirectory.path))
}

@MainActor
@Test("interrupted launch maintenance remains retryable when shutdown cancels before the first item")
func interruptedLaunchMaintenanceRemainsRetryableAfterCancellation() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let layout = try await launchMaintenanceRecording(paths: paths, state: .complete)
    let manifest = try layout.loadManifest()
    let state = launchMaintenanceState(paths: paths, defaults: defaults)
    let previousProcessingState = state.processingState
    let previousTranscriptStatus = "既存の文字起こし表示"
    state.transcriptViewModel.setStatus(previousTranscriptStatus)

    let recoveryTask = Task { @MainActor in
        await state.processingCoordinator.recoverPendingSessions(
            effects: state,
            scan: {
                try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
            },
            maintain: { items, callback in
                await SessionStorageMaintainer.maintain(items, willMaintain: { count in
                    await callback(count)
                    withUnsafeCurrentTask { $0?.cancel() }
                })
            }
        )
    }
    await recoveryTask.value

    #expect(!state.processingQueue.isMaintainingStorage)
    #expect(state.processingQueue.pending.isEmpty)
    #expect(!state.processingQueue.containsForReprocessing(manifest.sessionID))
    #expect(!state.processingCoordinator.isDraining)
    #expect(state.processingState == previousProcessingState)
    guard let status = state.processingStatusText else {
        Issue.record("shutdown interruption must remain visible for the next launch")
        return
    }
    #expect(status.contains("終了処理"))
    #expect(status.contains("次回起動時に再実行"))
    #expect(state.transcriptViewModel.statusText == previousTranscriptStatus)

    guard case .recordingPCM = try SessionAudioStorageStore(layout: layout).load() else {
        Issue.record("interrupted maintenance must retain PCM as the authoritative recording")
        return
    }
    guard case .recordedPCM(let checkpoint)? = try layout.audioSource(for: manifest) else {
        Issue.record("interrupted maintenance must retain its readable PCM checkpoint")
        return
    }
    #expect(checkpoint.committedFrames == 16_000)
    #expect(FileManager.default.fileExists(atPath: layout.processingDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: layout.recordingFLACURL.path))
    let pcmFiles = try FileManager.default.contentsOfDirectory(
        at: layout.processingDirectory, includingPropertiesForKeys: nil
    )
    #expect(!pcmFiles.isEmpty)

    let retryScan = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
    #expect(retryScan.maintenance.count == 1)
    #expect(retryScan.candidates.isEmpty)
    #expect(retryScan.maintenance[0].sessionURL == layout.sessionURL)
}

@MainActor
@Test("mixed maintenance failures preserve actual errors and report shutdown interruption")
func mixedMaintenanceFailuresKeepActualErrorsVisible() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let state = launchMaintenanceState(paths: paths, defaults: defaults)
    let failureReason = "permission denied"
    let interruptionReason = "終了処理のため保存整理を中断しました。次回起動時に再実行します"

    state.recoveryDidChange(.reportedFailures(
        scanFailures: [],
        maintenanceFailures: [
            UUID(): .failed(failureReason),
            UUID(): .interruptedByShutdown(interruptionReason)
        ],
        hasRecoveries: false
    ))

    guard case .partialFailure(let message) = state.processingState else {
        Issue.record("a real maintenance error must remain a partial failure")
        return
    }
    #expect(message.contains(failureReason))
    #expect(message.contains(interruptionReason))
    #expect(state.processingStatusText == message)
}
