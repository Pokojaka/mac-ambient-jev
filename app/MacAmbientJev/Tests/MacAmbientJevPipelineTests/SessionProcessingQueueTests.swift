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
    queue.hold(request(firstHeldSessionID), reason: .resourcePressure)
    queue.hold(request(secondHeldSessionID), reason: .resourcePressure)

    let resumed = queue.resumeHeld(
        holdReason: nil,
        pausesProcessing: false
    )
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
    queue.hold(request(heldSessionID), reason: .thermal)

    let blockedByCriticalPressure = queue.resumeHeld(
        holdReason: .thermal,
        pausesProcessing: false
    )
    #expect(!blockedByCriticalPressure)
    let blockedByPause = queue.resumeHeld(
        holdReason: nil,
        pausesProcessing: true
    )
    #expect(!blockedByPause)
    #expect(queue.pending.isEmpty)
    #expect(queue.held.map { $0.request.sessionID } == [heldSessionID])
}

@Test
func windowsThermalMonitoringResumesHeldRequestsWithoutPressure() {
    var queue = SessionProcessingQueue()
    let heldSessionID = UUID()
    let monitor = WindowsNoThermalMonitoring()
    queue.hold(request(heldSessionID), reason: .thermal)

    #expect(!monitor.isCritical)
    #expect(monitor.liveASRDecision == .processNow)
    let resumed = queue.resumeHeld(holdReason: monitor.isCritical ? .thermal : nil, pausesProcessing: false)
    #expect(resumed)
    #expect(queue.pending.map(\.sessionID) == [heldSessionID])
    #expect(queue.held.isEmpty)
}
