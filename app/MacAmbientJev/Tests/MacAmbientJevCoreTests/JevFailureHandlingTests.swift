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

private let fiveSegments = (0..<5).map { "公開鍵の説明その\($0)。続き" }

@Test(arguments: [429, 500, 503])
func unavailableHTTPBatchStopsRequestingAndKeepsTextUnsplitAndPending(status: Int) async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(fiveSegments, root: root, sessionID: sessionID))
    let transport = CountingStatusTransport(status: status, body: "{\"error\":\"unavailable\"}")
    let counter = DecisionUsageCounter()

    let result = try await buildAndPublish(
        root: root, sessionID: sessionID,
        provider: JevClient(apiKey: "sk-secret-123", transport: transport), scope: .all, counter: counter
    )

    #expect(await transport.calls == 1)
    #expect(await transport.lastRequest?.timeoutInterval == 15)
    #expect(result.stopReason == .providerUnavailable)
    #expect(result.pendingBoundarySegments.count == 5)
    #expect(result.materializedSegments.allSatisfy { $0.clauseState == .boundaryPending && $0.clauseSlices.isEmpty })
    let snapshot = await counter.snapshot()
    #expect(snapshot.sendCount == 1)
    #expect(snapshot.successCount == 0)
    #expect(snapshot.failureCount == 1)
    #expect(snapshot.reportedInputTokens == 0)
    #expect(snapshot.boundaryRequests.failureCount == 1)
    #expect(snapshot.priorityRequests.sendCount == 0)
    #expect(snapshot.pendingBoundarySegmentCount == 5)
}

@Test(arguments: [401, 403])
func rejectedAPIKeyStopsTheBatchAndKeepsEverySegmentPending(status: Int) async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(fiveSegments, root: root, sessionID: sessionID))
    let transport = CountingStatusTransport(status: status, body: "{}")

    let result = try await buildAndPublish(
        root: root, sessionID: sessionID,
        provider: JevClient(apiKey: "sk-secret-123", transport: transport), scope: .all
    )

    #expect(await transport.calls == 1)
    #expect(result.stopReason == .authorizationRejected)
    #expect(result.pendingBoundarySegments.count == 5)
    let reasons = try eventObjects(root).filter { $0["event_type"] as? String == "clause_boundaries.pending" }
        .compactMap { ($0["payload"] as? [String: Any])?["reason"] as? String }
    #expect(reasons == Array(repeating: "authorization_rejected", count: 5))
}

@Test
func requestSpecificFailureKeepsSendingTheRemainingSegments() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(fiveSegments, root: root, sessionID: sessionID))
    let transport = CountingStatusTransport(status: 400, body: "{}")

    let result = try await buildAndPublish(
        root: root, sessionID: sessionID,
        provider: JevClient(apiKey: "sk-secret-123", transport: transport), scope: .all
    )

    #expect(await transport.calls == 5)
    #expect(result.stopReason == nil)
    #expect(result.pendingBoundarySegments.count == 5)
}

@Test
func jevErrorsDoNotExposeAPIKeyOrProviderText() async throws {
    let key = "sk-secret-LEAKCHECK"
    for (status, body) in [(401, "{\"error\":\"bad key \(key)\"}"), (200, "not json \(key)"),
                           (200, "{\"model\":\"jev-test\",\"usage\":{},\"answers\":{\"p0001\":{\"type\":\"choice\",\"choice\":\"\(key)\",\"confidence\":1,\"probabilities\":{\"PRIMARY\":1,\"LOW_PRIORITY\":0}}}}")] {
        let transport = CountingStatusTransport(status: status, body: body)
        let client = JevClient(apiKey: key, transport: transport)
        do {
            _ = try await client.classifyPriorities([PriorityTextTarget(key: "u0001", text: "えー")])
            Issue.record("expected failure for status \(status)")
        } catch {
            let rendered = "\(error) \(error.localizedDescription) \(String(reflecting: error))"
            let url = await transport.lastRequest?.url?.absoluteString ?? ""
            #expect(!url.contains(key))
            #expect(!rendered.contains(key), "error leaks provider-echoed text: \(rendered)")
        }
    }
}
