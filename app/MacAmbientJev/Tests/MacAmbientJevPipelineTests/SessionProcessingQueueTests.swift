import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevPipeline

private func request(_ sessionID: UUID) -> PendingProcessing {
    .finalize(sessionID: sessionID, metadataPolicy: .reject)
}

@Test
func sessionProcessingQueueProcessesEnqueuedRequestsInFIFOOrder() throws {
    var queue = SessionProcessingQueue()
    let firstSessionID = UUID()
    let secondSessionID = UUID()
    queue.enqueue(request(firstSessionID))
    queue.enqueue(request(secondSessionID))

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
func sessionIDsIncludeCurrentAndPendingRequests() throws {
    var queue = SessionProcessingQueue()
    let currentSessionID = UUID()
    let pendingSessionID = UUID()
    queue.enqueue(request(currentSessionID))

    let currentRequestValue = queue.dequeue()
    let currentRequest = try #require(currentRequestValue)
    queue.begin(currentRequest)
    queue.enqueue(request(pendingSessionID))

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
func heldRequestsResumeAtTheFrontInOriginalOrder() {
    var queue = SessionProcessingQueue()
    let pendingSessionID = UUID()
    let firstHeldSessionID = UUID()
    let secondHeldSessionID = UUID()
    queue.enqueue(request(pendingSessionID))
    queue.holdForHeat(request(firstHeldSessionID))
    queue.holdForHeat(request(secondHeldSessionID))

    let resumed = queue.resumeHeld(
        isCritical: false,
        pausesProcessing: false
    )
    #expect(resumed)
    #expect(queue.pending.map(\.sessionID) == [
        firstHeldSessionID,
        secondHeldSessionID,
        pendingSessionID
    ])
    #expect(queue.thermallyHeld.isEmpty)
}

@Test
func criticalThermalPressureOrProcessingPauseKeepsRequestsHeld() {
    var queue = SessionProcessingQueue()
    let heldSessionID = UUID()
    queue.holdForHeat(request(heldSessionID))

    let blockedByCriticalPressure = queue.resumeHeld(
        isCritical: true,
        pausesProcessing: false
    )
    #expect(!blockedByCriticalPressure)
    let blockedByPause = queue.resumeHeld(
        isCritical: false,
        pausesProcessing: true
    )
    #expect(!blockedByPause)
    #expect(queue.pending.isEmpty)
    #expect(queue.thermallyHeld.map(\.sessionID) == [heldSessionID])
}

@Test
func windowsThermalMonitoringResumesHeldRequestsWithoutPressure() {
    var queue = SessionProcessingQueue()
    let heldSessionID = UUID()
    let monitor = WindowsNoThermalMonitoring()
    queue.holdForHeat(request(heldSessionID))

    #expect(!monitor.isCritical)
    #expect(monitor.liveASRDecision == .processNow)
    let resumed = queue.resumeHeld(isCritical: monitor.isCritical, pausesProcessing: false)
    #expect(resumed)
    #expect(queue.pending.map(\.sessionID) == [heldSessionID])
    #expect(queue.thermallyHeld.isEmpty)
}
