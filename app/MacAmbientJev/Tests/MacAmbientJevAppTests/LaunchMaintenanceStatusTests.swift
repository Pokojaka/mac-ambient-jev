import Combine
import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevRuntime

private func launchMaintenanceRecording(
    paths: AppPaths, attempt: FinalizationAttempt.State = .complete
) async throws -> SessionLayout {
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: UUID(), source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let layout = SessionLayout(sessionURL: sessionURL)
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 1)
    try await writer.append(samples: Array(repeating: 0.125, count: 16_000))
    _ = try await writer.finish()
    try ProcessingMetadataStore(sessionURL: sessionURL).save(ProcessingMetadata(
        finalizationAttempt: FinalizationAttempt(
            attemptID: "finalize_saved", state: attempt, failureReason: nil
        ),
        activeRuns: ActiveRuns(
            segmentation: "seg_saved", asr: "asr_saved", diarization: "diar_saved",
            scene: "scene_saved", scope: "scope_saved"
        ),
        pendingContentPrioritySegmentIDs: []
    ))
    return layout
}

@MainActor
private func launchMaintenanceState(paths: AppPaths, defaults: UserDefaults) -> AppState {
    AppState(
        paths: paths, captureEngine: FakeAppCaptureEngine(), microphoneAccess: { false },
        pausesProcessing: true, userDefaults: defaults, engines: .production(paths: paths),
        makeLiveVADSession: idleLiveVADFactory()
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

    await state.recoverPendingSessions()

    #expect(!state.isMaintainingStorage)
    #expect(state.processingStatusText == nil)
    #expect(state.transcriptViewModel.statusText == UserFacingStatus.idle.text)
    #expect(state.pendingProcessing.isEmpty)
    #expect(state.processingTask == nil)
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
    let ongoingStatus = UserFacingStatus.classifyingWithJev.text
    let previousTranscriptStatus = "表示済みの文字起こし"
    state.transcriptViewModel.setStatus(previousTranscriptStatus)
    let observation = state.transcriptViewModel.$statusText.dropFirst().sink { _ in
        guard state.isMaintainingStorage else { return }
        state.processingState = .running
        state.processingStatusText = ongoingStatus
    }
    defer { observation.cancel() }

    await state.recoverPendingSessions()

    #expect(!state.isMaintainingStorage)
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
    let layout = try await launchMaintenanceRecording(paths: paths, attempt: .paused)
    _ = try RecordingAudioCompactor(interrupt: nil).compact(layout: layout)
    try FileManager.default.createDirectory(at: layout.processingDirectory, withIntermediateDirectories: true)
    try Data("invalid FLAC".utf8).write(to: layout.recordingFLACURL)
    let scan = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
    try #require(scan.maintenance.count == 1)
    try #require(scan.candidates.count == 1)
    let state = launchMaintenanceState(paths: paths, defaults: defaults)

    await state.recoverPendingSessions()

    #expect(!state.isMaintainingStorage)
    guard case .partialFailure(let message) = state.processingState else {
        Issue.record("corrupt saved FLAC must be reported as a maintenance failure")
        return
    }
    #expect(message.contains(layout.sessionURL.lastPathComponent + ": "))
    #expect(state.processingStatusText == message)
    #expect(state.transcriptViewModel.statusText == UserFacingStatus.idle.text)
    #expect(state.pendingProcessing.isEmpty)
    #expect(state.processingTask == nil)
    #expect(FileManager.default.fileExists(atPath: layout.processingDirectory.path))
}
