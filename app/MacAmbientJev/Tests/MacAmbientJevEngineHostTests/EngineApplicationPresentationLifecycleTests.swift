import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
@testable import MacAmbientJevPipeline
import MacAmbientJevTestSupport

private struct LifecycleScanFailure: Error, LocalizedError {
    let reason: String

    var errorDescription: String? { reason }
}

@MainActor
@Suite(.timeLimit(.minutes(10))) struct EngineApplicationPresentationLifecycleTests {
    private func makeFixture(
        validatingGate: LifecycleContinuationGate?,
        preparationGate: LifecycleContinuationGate?,
        preparationFailure: EngineAdapterError?,
        captureStartGate: LifecycleContinuationGate?,
        captureStopGate: LifecycleContinuationGate?,
        captureStartFailure: EngineAdapterError?,
        liveVADFactoryFailure: EngineAdapterError?
    ) throws -> EngineApplicationPresentationLifecycleFixture {
        let root = try EngineApplicationPresentationLifecycleFixture.makeRoot()
        return try EngineApplicationPresentationLifecycleFixture(
            root: root,
            validatingGate: validatingGate,
            preparationGate: preparationGate,
            preparationFailure: preparationFailure,
            captureStartGate: captureStartGate,
            captureStopGate: captureStopGate,
            captureStartFailure: captureStartFailure,
            liveVADFactoryFailure: liveVADFactoryFailure
        )
    }

    @Test
    func idleResourceReleaseResetsPreparationStatus() async throws {
        let fixture = try makeFixture(
            validatingGate: nil,
            preparationGate: nil,
            preparationFailure: nil,
            captureStartGate: nil,
            captureStopGate: nil,
            captureStartFailure: nil,
            liveVADFactoryFailure: nil
        )
        defer {
            fixture.closeTransport()
            fixture.removeRoot()
        }

        try await fixture.start()
        try await fixture.replaceSettings()
        try await fixture.app.handlers.models.prepare(context: fixture.context)
        #expect(fixture.app.core.setupStatus == .ready)
        #expect(fixture.app.core.presentation.preparationPhase == .ready)
        #expect(fixture.app.core.presentation.preparationStatusText == nil)

        await fixture.app.core.processingCoordinator.waitUntilIdle()
        if let pendingRelease = fixture.app.core.idleReleaseTask {
            await pendingRelease.value
        }
        fixture.app.core.releaseIdleResourcesIfIdle()
        let idleReleaseTask = try #require(fixture.app.core.idleReleaseTask)
        await idleReleaseTask.value

        #expect(fixture.app.core.presentation.preparationStatusText == nil)
        let current = try await fixture.currentState()
        #expect(current.presentation.preparationPhase == .idle)
        #expect(current.presentation.preparationStatusText == nil)
        try await fixture.shutdown()
    }

    @Test
    func pendingIdleReleaseDoesNotOverrideModelPreparation() async throws {
        let preparationGate = LifecycleContinuationGate()
        let fixture = try makeFixture(
            validatingGate: nil,
            preparationGate: preparationGate,
            preparationFailure: nil,
            captureStartGate: nil,
            captureStopGate: nil,
            captureStartFailure: nil,
            liveVADFactoryFailure: nil
        )
        defer {
            fixture.closeTransport()
            fixture.removeRoot()
        }

        try await fixture.start()
        try await fixture.replaceSettings()
        let beforePreparation = try await fixture.currentState()
        var idleReleaseTask: Task<Void, Never>?
        let preparationTask = Task { @MainActor in
            fixture.app.core.processingDidChange(.drained)
            idleReleaseTask = try #require(fixture.app.core.idleReleaseTask)
            try await fixture.app.core.prepare(context: fixture.context)
        }
        defer { preparationTask.cancel() }

        try await preparationGate.waitUntilEntered()
        let scheduledIdleReleaseTask = try #require(idleReleaseTask)
        await scheduledIdleReleaseTask.value

        #expect(fixture.app.core.isPreparingModels)
        let preparing = try await fixture.currentState()
        #expect(preparing.presentation.preparationPhase == .preparing)
        #expect(preparing.presentation.preparationStatusText != nil)

        await fixture.transport.drain()
        let statesWhilePreparing = try fixture.stateEvents()
        let firstPreparingIndex = try #require(statesWhilePreparing.firstIndex { state in
            state.revision.value > beforePreparation.revision.value
                && state.presentation.preparationPhase == .preparing
        })
        for state in statesWhilePreparing[firstPreparingIndex...] {
            #expect(state.presentation.preparationPhase == .preparing)
            #expect(state.presentation.preparationStatusText?.isEmpty == false)
        }

        let phaseBeforeRepeatedRelease = fixture.app.core.presentation.preparationPhase
        fixture.app.core.releaseIdleResourcesIfIdle()
        #expect(fixture.app.core.idleReleaseTask == nil)
        #expect(fixture.app.core.presentation.preparationPhase == phaseBeforeRepeatedRelease)
        #expect(phaseBeforeRepeatedRelease == .preparing)

        await preparationGate.release()
        try await preparationTask.value
        let ready = try await fixture.waitForState(after: preparing.revision.value) { state in
            state.presentation.preparationPhase == .ready
                && state.presentation.preparationStatusText == nil
        }
        #expect(ready.presentation.preparationPhase == .ready)
        #expect(ready.presentation.preparationStatusText == nil)

        await fixture.transport.drain()
        let statesThroughReady = try fixture.stateEvents()
        let firstPreparingThroughReadyIndex = try #require(statesThroughReady.firstIndex { state in
            state.revision.value > beforePreparation.revision.value
                && state.presentation.preparationPhase == .preparing
        })
        let readyIndex = try #require(statesThroughReady[firstPreparingThroughReadyIndex...].firstIndex { state in
            state.presentation.preparationPhase == .ready
                && state.presentation.preparationStatusText == nil
        })
        for index in firstPreparingThroughReadyIndex...readyIndex {
            let state = statesThroughReady[index]
            if index == readyIndex {
                #expect(state.presentation.preparationPhase == .ready)
                #expect(state.presentation.preparationStatusText == nil)
            } else {
                #expect(state.presentation.preparationPhase == .preparing)
                #expect(state.presentation.preparationStatusText?.isEmpty == false)
            }
        }
        try await fixture.shutdown()
    }

    @Test(arguments: [false, true])
    func modelPreparationPublishesProgressBeforeTheActualHandlerReturns(failsAfterLoading: Bool) async throws {
        let validatingGate = LifecycleContinuationGate()
        let preparationGate = LifecycleContinuationGate()
        let reason = "認識モデルを検証できません"
        let preparationFailure = failsAfterLoading
            ? EngineAdapterError(
                code: .modelFailure,
                message: reason,
                recoveryAction: .prepareModels,
                details: []
            )
            : nil
        let fixture = try makeFixture(
            validatingGate: validatingGate,
            preparationGate: preparationGate,
            preparationFailure: preparationFailure,
            captureStartGate: nil,
            captureStopGate: nil,
            captureStartFailure: nil,
            liveVADFactoryFailure: nil
        )
        defer {
            fixture.closeTransport()
            fixture.removeRoot()
        }

        try await fixture.start()
        try await fixture.replaceSettings()
        let initial = try await fixture.currentState()
        #expect(initial.setup == .modelsRequired)
        #expect(initial.presentation.recordingStatusText == UserFacingStatus.idle.text)
        #expect(initial.presentation.preparationPhase == .idle)
        #expect(initial.presentation.preparationStatusText == nil)
        #expect(fixture.app.core.presentation.preparationStatusText == nil)
        #expect(try fixture.stateEvents().contains { state in
            state.presentation.recordingStatusText == UserFacingStatus.idle.text
        })

        let preparationTask = Task { @MainActor in
            try await fixture.prepareModels()
        }
        defer { preparationTask.cancel() }
        try await validatingGate.waitUntilEntered()
        let validating = try await fixture.waitForState(after: initial.revision.value) { state in
            state.presentation.preparationPhase == .preparing
                && state.presentation.preparationStatusText == UserFacingStatus.preparingASR.text
        }
        #expect(validating.setup == .modelsRequired)
        #expect(validating.presentation.preparationPhase == .preparing)
        #expect(validating.presentation.preparationStatusText == UserFacingStatus.preparingASR.text)
        #expect(validating.presentation.recordingStatusText == UserFacingStatus.idle.text)

        await validatingGate.release()
        try await preparationGate.waitUntilEntered()
        let loading = try await fixture.waitForState(after: validating.revision.value) { state in
            state.presentation.preparationPhase == .preparing
                && state.presentation.preparationStatusText == "音声認識モデルを読み込み中（100%）"
        }
        #expect(loading.setup == .modelsRequired)
        #expect(loading.presentation.preparationPhase == .preparing)
        #expect(loading.presentation.preparationStatusText == "音声認識モデルを読み込み中（100%）")

        await preparationGate.release()
        let preparationResult = await preparationTask.result
        let finished = try await fixture.waitForState(after: loading.revision.value) { state in
            if failsAfterLoading {
                return state.presentation.preparationPhase == .failed
                    && state.presentation.preparationStatusText == "準備できませんでした: \(reason)"
            }
            return state.presentation.preparationPhase == .ready
                && state.presentation.preparationStatusText == nil
        }
        if failsAfterLoading {
            guard case let .failure(error) = preparationResult else {
                Issue.record("model preparation succeeded after its configured adapter failure")
                return
            }
            let commandError = try #require(error as? EngineCommandError)
            #expect(commandError.message == reason)
            #expect(finished.setup == .modelsRequired)
            #expect(finished.presentation.preparationPhase == .failed)
            #expect(finished.presentation.preparationStatusText != nil)
        } else {
            guard case .success = preparationResult else {
                Issue.record("model preparation failed without a configured adapter failure")
                return
            }
            #expect(finished.setup == .ready)
            #expect(finished.presentation.preparationPhase == .ready)
            #expect(finished.presentation.preparationStatusText == nil)
        }
        try await fixture.shutdown()
    }

    @Test(arguments: [EngineSource.microphone, .systemAudio])
    func recordingPresentationFollowsGatedCaptureStartAndStop(source: EngineSource) async throws {
        let captureStartGate = LifecycleContinuationGate()
        let captureStopGate = LifecycleContinuationGate()
        let fixture = try makeFixture(
            validatingGate: nil,
            preparationGate: nil,
            preparationFailure: nil,
            captureStartGate: captureStartGate,
            captureStopGate: captureStopGate,
            captureStartFailure: nil,
            liveVADFactoryFailure: nil
        )
        defer {
            fixture.closeTransport()
            fixture.removeRoot()
        }

        try await fixture.start()
        try await fixture.replaceSettings()
        try await fixture.prepareModels()
        let beforeStart = try await fixture.currentState()
        let startTask = Task { @MainActor in
            try await fixture.startRecording(source: source)
        }
        defer { startTask.cancel() }
        try await captureStartGate.waitUntilEntered()
        let starting = try await fixture.waitForState(after: beforeStart.revision.value) { state in
            state.recording?.phase == .starting
                && state.presentation.recordingStatusText == UserFacingStatus.startingRecording.text
                && state.presentation.recordingTone == .neutral
        }
        #expect(starting.presentation.recordingTone == .neutral)
        await captureStartGate.release()
        let started = try await startTask.value
        let recordingText = source == .microphone ? "マイクを録音中" : "システム音声を録音中"
        let recording = try await fixture.waitForState(after: starting.revision.value) { state in
            state.recording?.sessionID == started.sessionID
                && state.recording?.phase == .recording
                && state.presentation.recordingStatusText == recordingText
                && state.presentation.recordingTone == .recording
        }
        #expect(recording.presentation.recordingTone == .recording)
        try await fixture.livePollingSleep.waitUntilEntered()

        let captureSession = try #require(fixture.capture.fake.session)
        try await captureSession.appendSpeech(seconds: 2)
        let stopTask = Task { @MainActor in
            try await fixture.stopRecording(sessionID: started.sessionID)
        }
        defer { stopTask.cancel() }
        try await captureStopGate.waitUntilEntered()
        let stopping = try await fixture.waitForState(after: recording.revision.value) { state in
            state.recording?.phase == .stopping
                && state.presentation.recordingStatusText == "録音を保存しています"
                && state.presentation.recordingTone == .neutral
        }
        #expect(stopping.presentation.recordingTone == .neutral)
        await captureStopGate.release()
        try await stopTask.value
        let saved = try await fixture.waitForState(after: stopping.revision.value) { state in
            state.recording == nil
                && state.presentation.recordingStatusText == "録音を保存しました（00:02・発話 1区間）"
                && state.presentation.recordingTone == .neutral
        }
        #expect(saved.presentation.recordingStatusText == "録音を保存しました（00:02・発話 1区間）")
        #expect(saved.presentation.recordingTone == .neutral)
        try await fixture.shutdown()
    }

    @Test
    func failedCaptureStartKeepsTheAdapterJapaneseFailureText() async throws {
        let failureText = "選択した録音デバイスを利用できません"
        let fixture = try makeFixture(
            validatingGate: nil,
            preparationGate: nil,
            preparationFailure: nil,
            captureStartGate: nil,
            captureStopGate: nil,
            captureStartFailure: EngineAdapterError(
                code: .deviceNotFound,
                message: failureText,
                recoveryAction: .selectDevice,
                details: []
            ),
            liveVADFactoryFailure: nil
        )
        defer {
            fixture.closeTransport()
            fixture.removeRoot()
        }

        try await fixture.start()
        try await fixture.replaceSettings()
        try await fixture.prepareModels()
        let beforeStart = try await fixture.currentState()
        var startError: EngineCommandError?
        do {
            _ = try await fixture.startRecording(source: .microphone)
        } catch let error as EngineCommandError {
            startError = error
        }
        let failure = try #require(startError)
        #expect(failure.message == failureText)
        let failed = try await fixture.waitForState(after: beforeStart.revision.value) { state in
            state.recording == nil
                && state.presentation.recordingStatusText == failureText
                && state.presentation.recordingTone == .error
        }
        #expect(failed.presentation.recordingStatusText == failureText)
        #expect(failed.presentation.recordingTone == .error)
        try await fixture.shutdown()
    }

    @Test
    func liveVADFactoryFailureIsReportedByARealRecordingStart() async throws {
        let reason = "発話検出器を作成できません"
        let fixture = try makeFixture(
            validatingGate: nil,
            preparationGate: nil,
            preparationFailure: nil,
            captureStartGate: nil,
            captureStopGate: nil,
            captureStartFailure: nil,
            liveVADFactoryFailure: EngineAdapterError(
                code: .modelFailure,
                message: reason,
                recoveryAction: .reprocess,
                details: []
            )
        )
        defer {
            fixture.closeTransport()
            fixture.removeRoot()
        }

        try await fixture.start()
        try await fixture.replaceSettings()
        try await fixture.prepareModels()
        let started = try await fixture.startRecording(source: .microphone)
        let expectedNotice = "録音は継続しています。発話検出を開始できませんでした: \(reason)"
        let active = try await fixture.waitForState(after: 0) { state in
            state.recording?.sessionID == started.sessionID
                && state.recording?.phase == .recording
                && state.presentation.liveFailureNotices.contains(expectedNotice)
        }
        #expect(active.presentation.liveFailureNotices == [expectedNotice])
        #expect(active.presentation.recordingStatusText == "マイクを録音中")
        let captureSession = try #require(fixture.capture.fake.session)
        try await captureSession.appendSpeech(seconds: 2)
        try await fixture.stopRecording(sessionID: started.sessionID)
        try await fixture.shutdown()
    }

    @Test
    func interruptedRecordingWaitsForModelsThenCompletesThroughStartupRecovery() async throws {
        let root = try EngineApplicationPresentationLifecycleFixture.makeRoot()
        let first = try EngineApplicationPresentationLifecycleFixture(
            root: root,
            validatingGate: nil,
            preparationGate: nil,
            preparationFailure: nil,
            captureStartGate: nil,
            captureStopGate: nil,
            captureStartFailure: nil,
            liveVADFactoryFailure: nil
        )
        defer {
            first.closeTransport()
            first.removeRoot()
        }

        try await first.start()
        try await first.replaceSettings()
        try await first.prepareModels()
        let started = try await first.startRecording(source: .microphone)
        let captureSession = try #require(first.capture.fake.session)
        try await captureSession.appendSpeech(seconds: 2)
        try await first.livePollingSleep.waitUntilEntered()
        try await first.shutdown()
        let stopped = try await first.currentState()
        #expect(stopped.presentation.processingStatusText != UserFacingStatus.finalizationPausedForHeat.text)

        let second = try EngineApplicationPresentationLifecycleFixture(
            root: root,
            validatingGate: nil,
            preparationGate: nil,
            preparationFailure: nil,
            captureStartGate: nil,
            captureStopGate: nil,
            captureStartFailure: nil,
            liveVADFactoryFailure: nil
        )
        defer { second.closeTransport() }

        try await second.start()
        let recoveryText = "未完了の文字起こしを復旧しています（1件）"
        let pending = try await second.waitForState(after: 0) { state in
            state.setup == .modelsRequired
                && state.recovery == .pending
                && state.presentation.recoveryStatusText == recoveryText
        }
        #expect(pending.presentation.recoveryStatusText == recoveryText)
        try await second.prepareModels()
        let completedText = "文字起こしと話者分離が完了しました（1区間）"
        let completed = try await second.waitForState(after: pending.revision.value) { state in
            state.setup == .ready
                && state.recovery == .completed
                && state.queue.isEmpty
                && state.presentation.recoveryStatusText == nil
                && state.presentation.processingIndicator == .complete
                && state.presentation.processingStatusText == completedText
        }
        #expect(completed.presentation.processingStatusText == completedText)
        #expect(completed.presentation.recoveryStatusText == nil)
        #expect(completed.queue.isEmpty)
        #expect(completed.recovery == .completed)
        try await second.shutdown()
        #expect(UUID(uuidString: started.sessionID) != nil)
    }

    @Test
    func windowsRejectsRecoveryRetryEmpty() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run {
                let root = FileManager.default.temporaryDirectory.appending(path: "engine-forbidden-recovery-\(UUID().uuidString)")
                let h = ApplicationHarness(root: root)
                h.app.core.recoveryDidChange(.retryEmpty)
            }
        }
    }

    @Test
    func windowsRejectsRecoveryRetryFailed() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run {
                let root = FileManager.default.temporaryDirectory.appending(path: "engine-forbidden-recovery-\(UUID().uuidString)")
                let h = ApplicationHarness(root: root)
                h.app.core.recoveryDidChange(.retryFailed("判定を読み込めません"))
            }
        }
    }

    @Test
    func recoveryCoordinatorPublishesMaintenanceFailureWording() async throws {
        let fixture = try makeFixture(
            validatingGate: nil,
            preparationGate: nil,
            preparationFailure: nil,
            captureStartGate: nil,
            captureStopGate: nil,
            captureStartFailure: nil,
            liveVADFactoryFailure: nil
        )
        defer {
            fixture.closeTransport()
            fixture.removeRoot()
        }

        try await fixture.start()
        let maintenanceGate = LifecycleContinuationGate()
        let maintenanceID = UUID()
        let maintenanceCandidate = SessionMaintenanceCandidate(
            sessionID: maintenanceID,
            sessionURL: fixture.root.appending(path: "maintenance-session", directoryHint: .isDirectory),
            maintenance: .removeTransients
        )
        let maintenanceScan = SessionRecoveryScan(candidates: [], maintenance: [maintenanceCandidate], failures: [])
        let beforeMaintenance = try await fixture.currentState()
        let maintenanceTask = Task { @MainActor in
            await fixture.app.core.processingCoordinator.recoverPendingSessions(
                effects: fixture.app.core,
                scan: { maintenanceScan },
                maintain: { items, willMaintain in
                    await willMaintain(items.count)
                    do {
                        try await maintenanceGate.suspend()
                    } catch {
                        preconditionFailure("maintenance test gate was cancelled: \(error)")
                    }
                    return [:]
                }
            )
        }
        try await maintenanceGate.waitUntilEntered()
        let maintaining = try await fixture.waitForState(after: beforeMaintenance.revision.value) { state in
            state.presentation.recoveryStatusText == "保存済み録音の音声を整理しています（1件）"
        }
        await maintenanceGate.release()
        await maintenanceTask.value
        let maintenanceFinished = try await fixture.waitForState(after: maintaining.revision.value) { state in
            state.presentation.recoveryStatusText == nil
        }
        #expect(maintenanceFinished.presentation.recoveryStatusText == nil)

        let failedOne = UUID()
        let failedTwo = UUID()
        let interruptedOne = UUID()
        let interruptedTwo = UUID()
        let maintenanceCandidates = [failedOne, failedTwo, interruptedOne, interruptedTwo].map { sessionID in
            SessionMaintenanceCandidate(
                sessionID: sessionID,
                sessionURL: fixture.root.appending(path: sessionID.uuidString, directoryHint: .isDirectory),
                maintenance: .removeTransients
            )
        }
        let scanFailures = [
            SessionRecoveryFailure(
                sessionURL: fixture.root.appending(path: "broken-one", directoryHint: .isDirectory),
                message: "manifest one is unreadable"
            ),
            SessionRecoveryFailure(
                sessionURL: fixture.root.appending(path: "broken-two", directoryHint: .isDirectory),
                message: "manifest two is unreadable"
            )
        ]
        let failureScan = SessionRecoveryScan(
            candidates: [],
            maintenance: maintenanceCandidates,
            failures: scanFailures
        )
        let maintenanceIssues: [UUID: SessionMaintenanceIssue] = [
            failedOne: .failed("zeta maintenance failure"),
            failedTwo: .failed("alpha maintenance failure"),
            interruptedOne: .interruptedByShutdown("zeta shutdown interruption"),
            interruptedTwo: .interruptedByShutdown("alpha shutdown interruption")
        ]
        let beforeFailures = try await fixture.currentState()
        let failureTask = Task { @MainActor in
            await fixture.app.core.processingCoordinator.recoverPendingSessions(
                effects: fixture.app.core,
                scan: { failureScan },
                maintain: { _, _ in maintenanceIssues }
            )
        }
        await failureTask.value
        let expectedFailures = "復旧できないセッションが2件あります。詳細は「保存済み録音」で確認できます。保存済み録音の音声を整理できなかったセッションが2件あります: alpha maintenance failure / zeta maintenance failure。終了処理のため保存済み録音の音声整理が中断されたセッションが2件あります。次回起動時に再実行します: alpha shutdown interruption / zeta shutdown interruption"
        let reported = try await fixture.waitForState(after: beforeFailures.revision.value) { state in
            state.presentation.recoveryStatusText == expectedFailures
        }
        #expect(reported.presentation.recoveryStatusText == expectedFailures)
        #expect(reported.presentation.processingIndicator == .partialFailure)
        if case let .partialFailure(message) = fixture.app.core.presentation.processingState {
            #expect(message == expectedFailures)
        } else {
            Issue.record("reported recovery failures did not set partialFailure")
        }

        let beforeScanFailure = try await fixture.currentState()
        let scanFailureTask = Task { @MainActor in
            await fixture.app.core.processingCoordinator.recoverPendingSessions(
                effects: fixture.app.core,
                scan: { throw LifecycleScanFailure(reason: "復旧スキャンで読み取りに失敗しました") },
                maintain: { _, _ in [:] }
            )
        }
        await scanFailureTask.value
        let failedScan = try await fixture.waitForState(after: beforeScanFailure.revision.value) { state in
            state.presentation.recoveryStatusText == "未完了セッションを復旧できませんでした: 復旧スキャンで読み取りに失敗しました"
        }
        #expect(failedScan.presentation.recoveryStatusText == "未完了セッションを復旧できませんでした: 復旧スキャンで読み取りに失敗しました")

        try await fixture.shutdown()
    }

    @Test
    func portableProcessingStatusesAndCleanupFailureRemainVisible() async throws {
        let fixture = try makeFixture(
            validatingGate: nil,
            preparationGate: nil,
            preparationFailure: nil,
            captureStartGate: nil,
            captureStopGate: nil,
            captureStartFailure: nil,
            liveVADFactoryFailure: nil
        )
        defer {
            fixture.closeTransport()
            fixture.removeRoot()
        }

        try await fixture.start()
        let sessionID = UUID()
        let statusHandler = fixture.app.core.processingStatusHandler(sessionID: sessionID)
        let portableStatuses: [UserFacingStatus] = [
            .convertingTimeline,
            .detectingSpeech,
            .preparingASR,
            .loadingASR,
            .preparingDiarization,
            .diarizing,
            .classifyingContent,
            .decisionDeferred
        ]
        for status in portableStatuses {
            let before = try await fixture.currentState()
            await statusHandler(.activity(status))
            let changed = try await fixture.waitForState(after: before.revision.value) { state in
                state.presentation.processingStatusText == status.text
            }
            #expect(changed.presentation.processingStatusText == status.text)
        }

        let beforeBacklogged = try await fixture.currentState()
        fixture.app.core.processingDidChange(.backlogged)
        let backlogged = try await fixture.waitForState(after: beforeBacklogged.revision.value) { state in
            state.presentation.processingStatusText == "文字起こし処理が待機中です"
                && state.presentation.processingIndicator == .backlogged
        }
        #expect(backlogged.presentation.processingStatusText == "文字起こし処理が待機中です")

        let beforeNext = try await fixture.currentState()
        fixture.app.core.processingDidChange(.next)
        let next = try await fixture.waitForState(after: beforeNext.revision.value) { state in
            state.presentation.processingStatusText == "次の文字起こし処理を開始します"
                && state.presentation.processingIndicator == .backlogged
        }
        #expect(next.presentation.processingStatusText == "次の文字起こし処理を開始します")

        let heldRequest = PendingProcessing.finalize(sessionID: sessionID, metadataPolicy: .reject)
        let beforeHeld = try await fixture.currentState()
        fixture.app.core.processingDidChange(.held(heldRequest))
        let heldText = "処理は中断されました。次回の起動時に再開できます"
        let held = try await fixture.waitForState(after: beforeHeld.revision.value) { _ in true }
        #expect(held.presentation.processingStatusText == heldText)
        #expect(held.presentation.processingIndicator == .idle)

        let updateHandler = fixture.app.core.processingUpdateHandler(sessionID: sessionID)
        let updateCases: [(ProcessingState, EngineProcessingIndicator)] = [
            (.idle, .idle),
            (.running, .running),
            (.backlogged, .backlogged),
            (.complete, .complete),
            (.partialFailure("更新に失敗しました"), .partialFailure)
        ]
        for (processingState, expectedIndicator) in updateCases {
            let before = try await fixture.currentState()
            await updateHandler([], processingState)
            if before.presentation.processingIndicator == expectedIndicator {
                let unchanged = try await fixture.currentState()
                #expect(unchanged.presentation.processingIndicator == expectedIndicator)
            } else {
                let changed = try await fixture.waitForState(after: before.revision.value) { state in
                    state.presentation.processingIndicator == expectedIndicator
                }
                #expect(changed.presentation.processingIndicator == expectedIndicator)
            }
        }

        let beforeCompletedUpdate = try await fixture.currentState()
        await updateHandler([], .complete)
        let complete = try await fixture.waitForState(after: beforeCompletedUpdate.revision.value) { state in
            state.presentation.processingIndicator == .complete
        }
        let cleanupFailure = "文字起こしは完了しましたが、後処理に失敗しました"
        let request = PendingProcessing.finalize(sessionID: sessionID, metadataPolicy: .reject)
        let beforeFinished = try await fixture.currentState()
        fixture.app.core.processingDidChange(.finished(
            request,
            .failed(message: cleanupFailure, metrics: nil, retained: .finalized)
        ))
        let partialFailure = try await fixture.waitForState(after: beforeFinished.revision.value) { state in
            state.presentation.processingIndicator == .partialFailure
                && state.presentation.processingStatusText == cleanupFailure
        }
        #expect(partialFailure.revision.value > complete.revision.value)
        #expect(partialFailure.presentation.processingStatusText == cleanupFailure)
        #expect(partialFailure.presentation.processingStatusText != "文字起こしと話者分離が完了しました")

        try await fixture.shutdown()
        let shutdownState = try await fixture.currentState()
        #expect(shutdownState.presentation.processingStatusText != UserFacingStatus.finalizationPausedForHeat.text)
        #expect(shutdownState.presentation.processingStatusText?.contains("発熱") == false)
    }
}
