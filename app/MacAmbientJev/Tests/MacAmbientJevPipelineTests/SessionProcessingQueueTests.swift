import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private func request(_ sessionID: UUID) -> PendingProcessing {
    .finalize(sessionID: sessionID, metadataPolicy: .reject)
}

@Test
func sessionProcessingQueueProcessesEnqueuedRequestsInFIFOOrder() throws {
    var queue = SessionProcessingQueue()
    let firstSessionID = UUID()
    let secondSessionID = UUID()
    try queue.enqueue(request(firstSessionID))
    try queue.enqueue(request(secondSessionID))

    let firstRequestValue = queue.dequeue()
    let firstRequest = try #require(firstRequestValue)
    #expect(firstRequest.sessionID == firstSessionID)
    queue.begin(firstRequest)
    #expect(queue.currentSessionID == firstSessionID)
    queue.completeCurrent()

    let secondRequestValue = queue.dequeue()
    let secondRequest = try #require(secondRequestValue)
    #expect(secondRequest.sessionID == secondSessionID)
    queue.begin(secondRequest)
    #expect(queue.currentSessionID == secondSessionID)
    queue.completeCurrent()
    let noMoreRequests = queue.dequeue()
    #expect(noMoreRequests == nil)
}

@Test
func terminalRequestIdentityCannotBeAdmittedAgain() throws {
    var queue = SessionProcessingQueue()
    let terminalRequest = request(UUID())
    try queue.enqueue(terminalRequest)
    let dequeuedValue = queue.dequeue()
    let dequeued = try #require(dequeuedValue)
    queue.begin(dequeued)
    queue.completeCurrent(terminal: true)

    #expect(throws: SessionProcessingQueueError.terminalRequestAlreadyCompleted) {
        try queue.enqueue(terminalRequest)
    }
    #expect(queue.pending.isEmpty)
}

@Test
func sessionIDsIncludeCurrentAndPendingRequests() throws {
    var queue = SessionProcessingQueue()
    let currentSessionID = UUID()
    let pendingSessionID = UUID()
    try queue.enqueue(request(currentSessionID))

    let currentRequestValue = queue.dequeue()
    let currentRequest = try #require(currentRequestValue)
    queue.begin(currentRequest)
    try queue.enqueue(request(pendingSessionID))

    #expect(queue.sessionIDs == [currentSessionID, pendingSessionID])
}

@Test
func reprocessingClaimRejectsDuplicatesUntilReleased() {
    var queue = SessionProcessingQueue()
    let sessionID = UUID()

    let firstClaim = queue.claimReprocessing(sessionID)
    #expect(firstClaim)
    let duplicateClaim = queue.claimReprocessing(sessionID)
    #expect(!duplicateClaim)
    #expect(queue.claimedSessionIDs == [sessionID])

    queue.releaseReprocessing(sessionID)
    #expect(queue.claimedSessionIDs.isEmpty)
    let claimAfterRelease = queue.claimReprocessing(sessionID)
    #expect(claimAfterRelease)
}

@Test
func heldRequestsResumeAtTheFrontInOriginalOrder() throws {
    var queue = SessionProcessingQueue()
    let pendingSessionID = UUID()
    let firstHeldSessionID = UUID()
    let secondHeldSessionID = UUID()
    try queue.enqueue(request(pendingSessionID))
    queue.hold(request(firstHeldSessionID), reason: .inference(.resourcePressure))
    queue.hold(request(secondHeldSessionID), reason: .inference(.resourcePressure))

    let resumed = queue.resumeHeld(activeInferenceHold: nil, releasesPauses: false, pausesProcessing: false)
    #expect(resumed)
    #expect(queue.pending.map(\.sessionID) == [
        firstHeldSessionID,
        secondHeldSessionID,
        pendingSessionID
    ])
    #expect(queue.held.isEmpty)
}

@Test
func criticalThermalPressureOrProcessingPauseKeepsRequestsHeld() {
    var queue = SessionProcessingQueue()
    let heldSessionID = UUID()
    queue.hold(request(heldSessionID), reason: .inference(.thermal))

    let blockedByCriticalPressure = queue.resumeHeld(
        activeInferenceHold: .thermal, releasesPauses: true, pausesProcessing: false)
    #expect(!blockedByCriticalPressure)
    let blockedByPause = queue.resumeHeld(activeInferenceHold: nil, releasesPauses: true, pausesProcessing: true)
    #expect(!blockedByPause)
    #expect(queue.pending.isEmpty)
    #expect(queue.held.map { $0.request.sessionID } == [heldSessionID])
}

@Test
func pausedRequestsWaitForTheExplicitResumeWhileEndedInferenceHoldsMove() {
    var queue = SessionProcessingQueue()
    let pausedSessionID = UUID(), thermalSessionID = UUID()
    queue.hold(request(pausedSessionID), reason: .paused)
    queue.hold(request(thermalSessionID), reason: .inference(.thermal))

    let movedInference = queue.resumeHeld(activeInferenceHold: nil, releasesPauses: false, pausesProcessing: false)
    #expect(movedInference)
    #expect(queue.pending.map(\.sessionID) == [thermalSessionID])
    #expect(queue.held.map { $0.request.sessionID } == [pausedSessionID])

    let movedPause = queue.resumeHeld(activeInferenceHold: .thermal, releasesPauses: true, pausesProcessing: false)
    #expect(movedPause)
    #expect(queue.pending.map(\.sessionID) == [pausedSessionID, thermalSessionID])
    #expect(queue.held.isEmpty)
}

@Test
func windowsThermalMonitoringResumesHeldRequestsWithoutPressure() {
    var queue = SessionProcessingQueue()
    let heldSessionID = UUID()
    let monitor = WindowsNoThermalMonitoring()
    queue.hold(request(heldSessionID), reason: .inference(.thermal))

    #expect(!monitor.isCritical)
    #expect(monitor.liveASRDecision == .processNow)
    let resumed = queue.resumeHeld(
        activeInferenceHold: monitor.isCritical ? .thermal : nil, releasesPauses: false, pausesProcessing: false)
    #expect(resumed)
    #expect(queue.pending.map(\.sessionID) == [heldSessionID])
    #expect(queue.held.isEmpty)
}

@Test
func admittedReplacementCannotBeSubmittedTwice() throws {
    var queue = SessionProcessingQueue()
    let sessionID = UUID()
    let admittedRequestID = queue.enqueueAdmittedReplacement(sessionID: sessionID)
    let requestID = try #require(admittedRequestID)
    let admitted = try #require(queue.pending.first)

    #expect(throws: SessionProcessingQueueError.replacementMustEnterThroughAdmission) {
        try queue.enqueue(admitted)
    }
    #expect(queue.pending.map(\.requestID) == [requestID])
}

@Test
func replacementReservationCanRetryAfterTheWriterDefinitelyWroteNothing() throws {
    var queue = SessionProcessingQueue()
    let admittedRequestID = queue.enqueueAdmittedReplacement(sessionID: UUID())
    let requestID = try #require(admittedRequestID)
    let admitted = try #require(queue.pending.first)
    guard case .finalize(_, _, let policy) = admitted else {
        Issue.record("replacement admission did not create finalization work")
        return
    }
    #expect(admitted.requestID == requestID)

    let cancelledGeneration = UUID()
    try policy.reserveReplacementGeneration(cancelledGeneration)
    policy.replacementGenerationDidNotAppend(cancelledGeneration)
    #expect(policy.replacementGeneration == .notOpened)

    let resumedGeneration = UUID()
    try policy.reserveReplacementGeneration(resumedGeneration)
    policy.replacementGenerationDidAppend(resumedGeneration)
    #expect(policy.replacementGeneration == .opened(resumedGeneration))
}
