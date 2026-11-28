import Foundation
import Synchronization
import Testing
import MacAmbientJevEngineProtocol
@testable import MacAmbientJevPipeline
@testable import MacAmbientJevEngineHost

@MainActor
@Test
func completionRegistryRoutesSameSessionAndKindByRequestUUID() async throws {
    let registry = EngineCompletionRegistry()
    let sessionID = UUID()
    let firstRequestID = UUID()
    let secondRequestID = UUID()
    let terminalClaims = Mutex<[UUID]>([])
    registry.register(requestID: firstRequestID) {
        terminalClaims.withLock { $0.append(firstRequestID) }
    }
    registry.register(requestID: secondRequestID) {
        terminalClaims.withLock { $0.append(secondRequestID) }
    }
    let result = SessionProcessingResult.completed(
        metrics: nil, noSpeech: false, replacementGeneration: .notOpened
    )

    registry.finished(
        ProcessingQueueItemSummary(
            requestID: secondRequestID, sessionID: sessionID, kind: .finalization, holdReason: nil
        ),
        result: result,
        isShutdownCancellation: false
    )
    #expect(terminalClaims.withLock { $0 } == [secondRequestID])
    if case .completed = try await registry.wait(requestID: secondRequestID) {} else {
        Issue.record("the second request did not receive its own completion")
    }

    registry.finished(
        ProcessingQueueItemSummary(
            requestID: firstRequestID, sessionID: sessionID, kind: .finalization, holdReason: nil
        ),
        result: result,
        isShutdownCancellation: false
    )
    #expect(terminalClaims.withLock { $0 } == [secondRequestID, firstRequestID])
    if case .completed = try await registry.wait(requestID: firstRequestID) {} else {
        Issue.record("the first request did not receive its own completion")
    }
}
