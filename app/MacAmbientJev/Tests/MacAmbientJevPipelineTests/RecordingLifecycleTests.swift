import Foundation
import Testing
import MacAmbientJevPipeline

@Test
func recordingLifecycleTransitionsThroughPermissionAndRecording() {
    var lifecycle = RecordingLifecycle()
    let sessionID = UUID()

    #expect(lifecycle.phase == .idle)
    #expect(lifecycle.sessionID == nil)

    lifecycle.requestPermission()
    #expect(lifecycle.phase == .requestingPermission)
    #expect(lifecycle.sessionID == nil)

    lifecycle.start(sessionID: sessionID)
    #expect(lifecycle.phase == .starting)
    #expect(lifecycle.sessionID == sessionID)

    lifecycle.didStart(sessionID: sessionID)
    #expect(lifecycle.phase == .recording)
    #expect(lifecycle.sessionID == sessionID)

    let didBeginStoppingCurrentSession = lifecycle.beginStopping(sessionID: sessionID)
    #expect(didBeginStoppingCurrentSession)
    #expect(lifecycle.phase == .stopping)
    #expect(lifecycle.sessionID == sessionID)

    lifecycle.finish()
    #expect(lifecycle.phase == .idle)
    #expect(lifecycle.sessionID == nil)
}

@Test
func recordingLifecycleStartsSystemRecordingWithoutPermission() {
    var lifecycle = RecordingLifecycle()
    let sessionID = UUID()

    lifecycle.start(sessionID: sessionID)
    #expect(lifecycle.phase == .starting)
    #expect(lifecycle.sessionID == sessionID)

    lifecycle.didStart(sessionID: sessionID)
    #expect(lifecycle.phase == .recording)
    #expect(lifecycle.isCurrentRecording(sessionID))
}

@Test
func recordingLifecycleRejectsForeignStaleAndRepeatedStops() {
    var lifecycle = RecordingLifecycle()
    let sessionID = UUID()
    let foreignSessionID = UUID()
    let nextSessionID = UUID()

    lifecycle.start(sessionID: sessionID)
    lifecycle.didStart(sessionID: sessionID)

    let didBeginStoppingForeignSession = lifecycle.beginStopping(sessionID: foreignSessionID)
    #expect(!didBeginStoppingForeignSession)
    #expect(lifecycle.phase == .recording)
    let didBeginStoppingSession = lifecycle.beginStopping(sessionID: sessionID)
    #expect(didBeginStoppingSession)
    let didBeginStoppingRepeatedSession = lifecycle.beginStopping(sessionID: sessionID)
    #expect(!didBeginStoppingRepeatedSession)

    lifecycle.finish()
    lifecycle.start(sessionID: nextSessionID)
    lifecycle.didStart(sessionID: nextSessionID)
    let didBeginStoppingStaleSession = lifecycle.beginStopping(sessionID: sessionID)
    #expect(!didBeginStoppingStaleSession)
    #expect(lifecycle.phase == .recording)
}

@Test
func recordingLifecycleDefersStartingFailureOnlyForMatchingSessionOnce() {
    var lifecycle = RecordingLifecycle()
    let sessionID = UUID()
    let foreignSessionID = UUID()

    lifecycle.start(sessionID: sessionID)

    let didDeferForeignFailure = lifecycle.deferFailureWhileStarting(sessionID: foreignSessionID, message: "foreign")
    #expect(!didDeferForeignFailure)
    let pendingFailureBeforeMatchingDeferral = lifecycle.takePendingFailure(sessionID: sessionID)
    #expect(pendingFailureBeforeMatchingDeferral == nil)

    let didDeferMatchingFailure = lifecycle.deferFailureWhileStarting(sessionID: sessionID, message: "start failed")
    #expect(didDeferMatchingFailure)
    let pendingFailureForForeignSession = lifecycle.takePendingFailure(sessionID: foreignSessionID)
    #expect(pendingFailureForForeignSession == nil)
    let pendingFailureForMatchingSession = lifecycle.takePendingFailure(sessionID: sessionID)
    #expect(pendingFailureForMatchingSession == "start failed")
    let pendingFailureAfterConsumption = lifecycle.takePendingFailure(sessionID: sessionID)
    #expect(pendingFailureAfterConsumption == nil)

    let didDeferFailureBeforeFinish = lifecycle.deferFailureWhileStarting(sessionID: sessionID, message: "cleared by finish")
    #expect(didDeferFailureBeforeFinish)
    lifecycle.finish()
    let pendingFailureAfterFinish = lifecycle.takePendingFailure(sessionID: sessionID)
    #expect(pendingFailureAfterFinish == nil)
}

@Test
func recordingLifecycleFinishesImportIntoIdle() {
    var lifecycle = RecordingLifecycle()

    lifecycle.beginImport()
    #expect(lifecycle.phase == .importing)
    #expect(lifecycle.sessionID == nil)

    lifecycle.finish()
    #expect(lifecycle.phase == .idle)
    #expect(lifecycle.sessionID == nil)
}
