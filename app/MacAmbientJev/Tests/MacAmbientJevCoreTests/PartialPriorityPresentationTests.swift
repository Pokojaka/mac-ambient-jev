import Foundation
import Testing
@testable import MacAmbientJevCore

private actor PartialPriorityProvider: DecisionProvider {
    private var batches = 0
    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.9) }),
            continuationProbability: request.next.map { _ in 0.1 }, metadata: testMetadata
        )
    }
    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        batches += 1
        if batches == 2 { throw JevClientError.httpStatus(429) }
        return try lowForBackchannel(targets)
    }
}

@Test
func storedLowClausesRemainDimmedWhenAnotherPriorityBatchFails() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let raw = String(repeating: "うん。", count: 41)
    let events = try await writeTranscript([raw], root: root, sessionID: id)
    _ = try publishLocal(root: root, events: events)
    let result = try await buildAndPublish(root: root, sessionID: id, provider: PartialPriorityProvider(), scope: .all)
    let segments = try readPublished(root: root)
    let row = try #require(try LiveTranscriptProjection().rows(for: segments).first)
    #expect(segments[0].clauseSlices.filter { $0.priority == .lowPriority }.count == 40)
    #expect(result.pendingPriorityClauses.count == 1)
    #expect(row.clauseState == .priorityPending)
    #expect(row.text == raw)
    #expect(!row.shouldCollapseRow)
    #expect(row.textFragments == [
        TranscriptTextFragment(text: String(repeating: "うん。", count: 40), style: .lowPriority),
        TranscriptTextFragment(text: "うん。", style: .normal)
    ])
}
