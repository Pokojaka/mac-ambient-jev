import Foundation
import Testing
@testable import MacAmbientJevCore

private actor CountingStatusTransport: JevHTTPTransport {
    private(set) var calls = 0
    private(set) var lastRequest: URLRequest?
    private let status: Int?
    private let body: Data

    init(status: Int?, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        lastRequest = request
        guard let status else { throw URLError(.networkConnectionLost) }
        return (body, HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!)
    }
}

private func fiveSegmentEvents() -> [TranscriptEvent] {
    var events: [TranscriptEvent] = []
    var seq: UInt64 = 1
    for index in 0..<5 {
        events.append(.segmentCreated(
            seq: seq, segmentationRunID: "seg", segmentID: "s\(index)",
            startFrame: Int64(index) * 1_000, endFrame: Int64(index) * 1_000 + 900
        ))
        seq += 1
        events.append(.asrCompleted(
            seq: seq, runID: "asr", segmentationRunID: "seg",
            segmentID: "s\(index)",
            text: "公開鍵の説明その\(index)"
        ))
        seq += 1
    }
    return events
}

@Test
func rateLimitedBatchStopsRequestingAndKeepsTextPrimaryAndPending() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = CountingStatusTransport(status: 429, body: "{\"error\":\"rate\"}")
    let coordinator = JevEnrichmentCoordinator(
        sessionID: UUID(),
        runID: "priority-429",
        writer: try SessionWriter(sessionURL: root),
        decisions: JevDecisionCoordinator(
            provider: JevClient(apiKey: "sk-secret-123", transport: transport),
            usageCounter: JevUsageCounter()
        ),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )
    let result = try await coordinator.process(
        existingEvents: fiveSegmentEvents(),
        activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
    )
    let calls = await transport.calls
    let timeout = await transport.lastRequest?.timeoutInterval

    #expect(result.retryPendingSegmentIDs.count == 5)
    #expect(result.materializedSegments.count == 5)
    #expect(result.materializedSegments.allSatisfy { $0.contentPriority != .lowPriority })
    #expect(calls == 1)
    #expect(timeout == 15)
    #expect(result.stopReason == .providerUnavailable)
}

private func pendingRetrySegmentIDs(root: URL) throws -> [String] {
    let persisted = try SessionRecovery.recoverJSONL(
        Data(contentsOf: root.appending(path: "events.jsonl"))
    )
    return try persisted.lines.compactMap { line -> String? in
        let event = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        guard event?["event_type"] as? String == "content_priority.pending_retry" else {
            return nil
        }
        return event?["segment_id"] as? String
    }
}

@Test(arguments: [401, 403])
func rejectedAPIKeyStopsTheBatchAndKeepsEverySegmentPending(status: Int) async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = CountingStatusTransport(status: status, body: "{\"error\":\"unauthorized\"}")
    let counter = JevUsageCounter()
    let coordinator = JevEnrichmentCoordinator(
        sessionID: UUID(),
        runID: "priority-\(status)",
        writer: try SessionWriter(sessionURL: root),
        decisions: JevDecisionCoordinator(
            provider: JevClient(apiKey: "sk-secret-123", transport: transport),
            usageCounter: counter
        ),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )

    let result = try await coordinator.process(
        existingEvents: fiveSegmentEvents(),
        activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
    )

    let allSegmentIDs = Set((0..<5).map { "s\($0)" })
    #expect(await transport.calls == 1)
    #expect(result.stopReason == .authorizationRejected)
    #expect(Set(result.retryPendingSegmentIDs) == allSegmentIDs)
    #expect(Set(try pendingRetrySegmentIDs(root: root)) == allSegmentIDs)
    #expect(result.materializedSegments.allSatisfy { $0.contentPriority == .primary })
    let snapshot = await counter.snapshot()
    #expect(snapshot.sendCount == 1)
    #expect(snapshot.failureCount == 1)
    #expect(snapshot.retryPendingCount == 5)
}

@Test
func requestSpecificFailureKeepsSendingTheRemainingSegments() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = CountingStatusTransport(status: 400, body: "{\"error\":\"bad request\"}")
    let coordinator = JevEnrichmentCoordinator(
        sessionID: UUID(),
        runID: "priority-400",
        writer: try SessionWriter(sessionURL: root),
        decisions: JevDecisionCoordinator(
            provider: JevClient(apiKey: "sk-secret-123", transport: transport),
            usageCounter: JevUsageCounter()
        ),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )

    let result = try await coordinator.process(
        existingEvents: fiveSegmentEvents(),
        activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
    )

    #expect(await transport.calls == 5)
    #expect(result.stopReason == nil)
    #expect(result.retryPendingSegmentIDs.count == 5)
}

@Test
func jevErrorsDoNotExposeAPIKeyOrProviderText() async throws {
    let key = "sk-secret-LEAKCHECK"
    for (status, body) in [(401, "{\"error\":\"bad key \(key)\"}"), (200, "not json \(key)"),
                           (200, "{\"answers\":{\"content_priority\":{\"type\":\"choice\",\"choice\":\"\(key)\",\"confidence\":1}}}")] {
        let transport = CountingStatusTransport(status: status, body: body)
        let client = JevClient(apiKey: key, transport: transport)
        do {
            _ = try await client.classifyPriority(text: "えー")
            Issue.record("expected failure for status \(status)")
        } catch {
            let rendered = "\(error) \(error.localizedDescription) \(String(reflecting: error))"
            let url = await transport.lastRequest?.url?.absoluteString ?? ""
            #expect(!url.contains(key))
            #expect(!rendered.contains(key), "error leaks provider-echoed text: \(rendered)")
        }
    }
}
