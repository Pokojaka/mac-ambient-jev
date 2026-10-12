import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private actor ScriptedASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var texts: [String?]
    init(_ texts: [String?]) { self.texts = texts }
    func prepare() async throws {}
    /// A nil text fails the segment.
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        let text = texts.removeFirst()
        guard let text else { throw URLError(.cannotDecodeContentData) }
        return ASRResult(text: text, detectedLanguage: "ja")
    }
    func unload() async {}
}

private struct LiveFixtureWaitError: Error {
    let message: String
}

private actor LiveRecorder {
    private(set) var updates: [[MaterializedTranscriptSegment]] = []
    private(set) var statuses: [String] = []

    func record(_ rows: [MaterializedTranscriptSegment]) {
        updates.append(rows)
    }

    func record(status: String) {
        statuses.append(status)
    }
    var latest: [MaterializedTranscriptSegment] { updates.last ?? [] }

    func wait(until condition: @escaping @Sendable ([MaterializedTranscriptSegment]) -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(latest) {
            if let failure = statuses.last(where: { $0.contains("判定を保存できませんでした") }) {
                throw LiveFixtureWaitError(message: failure)
            }
            guard ContinuousClock.now < deadline else {
                throw LiveFixtureWaitError(message: "Timed out waiting for live rows: \(latest); statuses: \(statuses)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForStatus(_ condition: @escaping @Sendable (String) -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !statuses.contains(where: condition) {
            guard ContinuousClock.now < deadline else {
                throw LiveFixtureWaitError(message: "Timed out waiting for live status: \(statuses)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Live injected answers: boundaries after `。`, continuation for the listed segments, LOW for `うん`.
private actor LiveProvider: DecisionProvider {
    private let continuing: Set<String>
    private var gate: CheckedContinuation<Void, Never>?
    private var holdBoundaryNumber: Int?
    private var holdPriorityNumber: Int?
    private(set) var boundaryRequests: [ClauseBoundaryRequest] = []
    private(set) var priorityRequests: [[String]] = []

    init(continuing: Set<String>, holdBoundaryNumber: Int? = nil, holdPriorityNumber: Int? = nil) {
        self.continuing = continuing
        self.holdBoundaryNumber = holdBoundaryNumber
        self.holdPriorityNumber = holdPriorityNumber
    }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        boundaryRequests.append(request)
        if boundaryRequests.count == holdBoundaryNumber {
            await withCheckedContinuation { gate = $0 }
        }
        var probabilities: [String: Double] = [:]
        let utf16 = Array(request.text.utf16)
        for candidate in request.candidates {
            probabilities[candidate.id] = utf16[candidate.offsetUTF16 - 1] == "、".utf16.first! ? 0.1 : 0.9
        }
        return ClauseBoundaryResponse(
            probabilities: probabilities,
            continuationProbability: request.next.map { _ in continuing.contains(request.source.segmentID) ? 0.9 : 0.1 },
            metadata: try DecisionResponseMetadata(model: "jev-live", inputTokens: 5, outputTokens: nil)
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        priorityRequests.append(targets.map(\.text))
        if priorityRequests.count == holdPriorityNumber {
            await withCheckedContinuation { gate = $0 }
        }
        var decisions: [String: ContentPriorityDecision] = [:]
        for target in targets {
            let low = target.text.contains("うん")
            decisions[target.key] = try ContentPriorityDecision(
                priority: low ? .lowPriority : .primary, confidence: 0.95,
                probabilities: low ? ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975] : ["PRIMARY": 0.975, "LOW_PRIORITY": 0.025]
            )
        }
        return PriorityBatchResponse(decisions: decisions, metadata: try DecisionResponseMetadata(model: "jev-live", inputTokens: 7, outputTokens: nil))
    }

    func release() {
        holdBoundaryNumber = nil
        holdPriorityNumber = nil
        gate?.resume()
        gate = nil
    }

    func boundaryCount() -> Int { boundaryRequests.count }

    func waitForBoundaries(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while boundaryRequests.count < count {
            guard ContinuousClock.now < deadline else {
                throw LiveFixtureWaitError(message: "Expected \(count) boundary requests, received \(boundaryRequests)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForPriorities(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while priorityRequests.count < count {
            guard ContinuousClock.now < deadline else {
                throw LiveFixtureWaitError(message: "Expected \(count) priority requests, received \(priorityRequests)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct LiveDecisionFixture {
    let root: URL
    let checkpoint: AudioCheckpoint
    let asr: LiveASRSession
    let jev: LiveContentPrioritySession
    let segments: [SegmentReference]
    let counter: DecisionUsageCounter
    let recorder = LiveRecorder()

    init(texts: [String?], makeDecisions: @escaping NativeSessionProcessor.DecisionCoordinatorFactory, counter: DecisionUsageCounter) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1, sessionURL: root)
        let durableFrames = max(16_000, ((texts.count + 3) / 4) * 16_000)
        try await audio.append(samples: Array(repeating: Float(0.1), count: durableFrames))
        checkpoint = await audio.committedSnapshot()
        let writer = try SessionWriter(sessionURL: root)
        let sessionID = UUID()
        asr = LiveASRSession(
            sessionID: sessionID, sessionURL: root, segmentationRunID: "live_seg", asrRunID: "live_asr",
            processingDirectory: root, writer: writer, asr: ScriptedASR(texts), sampleRate: checkpoint.sampleRate,
            clauseBoundaryRunID: "boundary_live", contentPriorityRunID: "priority_live"
        )
        jev = LiveContentPrioritySession(
            sessionID: sessionID, boundaryRunID: "boundary_live", priorityRunID: "priority_live",
            writer: writer, liveASR: asr, makeDecisions: makeDecisions, usageCounter: counter
        )
        segments = texts.indices.map {
            SegmentReference(segmentationRunID: "live_seg", segmentID: "seg_\($0 + 1)",
                             startFrame: Int64($0 * 4_000), endFrame: Int64($0 * 4_000 + 3_000))
        }
        self.counter = counter
    }

    /// Recognizes one segment the way the processor does: rows are shown, then the Jev queue is told.
    func recognize(_ index: Int) async throws {
        let jev = self.jev, recorder = self.recorder
        _ = try await asr.process(segments: [segments[index]], checkpoint: checkpoint) { status, snapshot in
            await recorder.record(snapshot.progress.materializedSegments)
            switch status.outcome {
            case .recognized(let source, _):
                try? await jev.enqueue(
                    source: source, snapshot: snapshot,
                    onStatus: { await recorder.record(status: $0) },
                    onUpdate: { await recorder.record($0.progress.materializedSegments) }
                )
            case .failed, .pending:
                try? await jev.observe(snapshot: snapshot)
            }
        }
    }

    func eventObjects() throws -> [[String: Any]] {
        try SessionRecovery.recoverJSONL(SessionWriter.readDurableLog(eventsURL: root.appending(path: "events.jsonl"))).lines.map {
            try JSONSerialization.jsonObject(with: $0) as! [String: Any]
        }
    }

    func waitForDecisionCompletion() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            if try eventObjects().contains(where: {
                $0["event_type"] as? String == "processing.run.completed"
                    && ($0["payload"] as? [String: Any])?["stage"] as? String == "contentPriority"
            }) { return }
            if let failure = await recorder.statuses.last(where: { $0.contains("判定を保存できませんでした") }) {
                throw LiveFixtureWaitError(message: failure)
            }
            guard ContinuousClock.now < deadline else {
                throw LiveFixtureWaitError(message: "Timed out waiting for live Jev completion")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Test
func liveRowsShowAtOnceAndAClauseSpanningSegmentsClosesOnlyAfterItsBoundaries() async throws {
    let provider = LiveProvider(continuing: ["seg_1", "seg_2"])
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(
        texts: ["これは", "コピーと", "いうか。うん、うん。"], makeDecisions: { decisions }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try await fixture.recognize(0)
    // Saved ASR is visible as normal text before any Jev request: the boundary needs the next segment.
    #expect(await fixture.recorder.updates.first?.map(\.clauseState) == [.awaitingNextSegment])
    #expect(await provider.boundaryCount() == 0)
    let first = try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)
    #expect(first.map(\.textFragments) == [[TranscriptTextFragment(text: "これは", style: .normal)]])

    try await fixture.recognize(1)
    try await fixture.recognize(2)
    try await provider.waitForBoundaries(2)
    // The last segment waits for a successor; the clause running through it is not closed.
    try await fixture.recorder.wait { $0.map(\.clauseState) == [.awaitingNextSegment, .awaitingNextSegment, .awaitingNextSegment] }

    try await fixture.jev.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.recorder.wait { $0.map(\.clauseState) == [.classified, .classified, .classified] }

    let requests = await provider.boundaryRequests
    #expect(requests.map(\.source.segmentID) == ["seg_1", "seg_2", "seg_3"])
    #expect(requests.map { $0.next?.text } == ["コピーと", "いうか。うん、うん。", nil])
    #expect(await provider.priorityRequests == [["これはコピーというか。", "うん、うん。"]])
    let rows = try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)
    #expect(rows.map(\.shouldCollapseRow) == [false, false, false])
    #expect(rows[2].textFragments == [
        TranscriptTextFragment(text: "いうか。", style: .normal),
        TranscriptTextFragment(text: "うん、うん。", style: .lowPriority)
    ])
    // The durable live results are what finalization may reuse.
    let reused = try EventLogTranscriptReader().liveContentPriorityDecisions(
        from: Data(contentsOf: fixture.root.appending(path: "events.jsonl"))
    )
    #expect(Set(reused.keys) == [ExactClauseTextKey(text: "これはコピーというか。"), ExactClauseTextKey(text: "うん、うん。")])
    let snapshot = await counter.snapshot()
    #expect(snapshot.boundaryRequests.sendCount == 3)
    #expect(snapshot.priorityRequests.sendCount == 1)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func stoppedLiveQueueDropsALateResponseAndKeepsSavedResults(holdingPriority: Bool) async throws {
    let provider = LiveProvider(
        continuing: [], holdBoundaryNumber: holdingPriority ? nil : 2,
        holdPriorityNumber: holdingPriority ? 2 : nil
    )
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let second = holdingPriority ? (1...81).map { "本文\($0)。" }.joined() : "二つ目。"
    let fixture = try await LiveDecisionFixture(texts: ["うん。", second, "三つ目。"], makeDecisions: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try await fixture.recognize(0)
    try await fixture.recognize(1)
    try await fixture.recognize(2)
    if holdingPriority {
        try await provider.waitForPriorities(2)
    } else {
        try await provider.waitForBoundaries(2)
    }
    try await fixture.recorder.wait { $0.first?.clauseState == .classified }
    let updatesBeforeStop = await fixture.recorder.updates.count
    let eventsBeforeStop = try Data(contentsOf: fixture.root.appending(path: "events.jsonl"))

    await fixture.jev.stop()
    await provider.release()
    try await Task.sleep(for: .milliseconds(100))

    #expect(await fixture.recorder.updates.count == updatesBeforeStop)
    #expect(try Data(contentsOf: fixture.root.appending(path: "events.jsonl")) == eventsBeforeStop)
    let expectedRequests = holdingPriority
        ? [["うん。"], (1...40).map { "本文\($0)。" }]
        : [["うん。"]]
    #expect(await provider.priorityRequests == expectedRequests)
    #expect(try LiveTranscriptProjection().rows(for: await fixture.recorder.latest).map(\.shouldCollapseRow) == [true, false, false])
    #expect(await fixture.recorder.latest.map(\.clauseState) == [
        .classified, holdingPriority ? .priorityPending : .awaitingNextSegment, .awaitingNextSegment
    ])
}

@Test(.timeLimit(.minutes(1)))
func localSelectedLiveDecisionProvenanceIsDurableForBoundaryAndPriority() async throws {
    let modelID = "sbintuitions/modernbert-ja-30m-multitagger"
    let revision = String(repeating: "a", count: 64)
    let counter = DecisionUsageCounter()
    let provider = LocalSelectedDecisionProvider(modelID: modelID, revision: revision)
    let decisions = DecisionCoordinator(
        provider: provider, identity: try DecisionModelIdentity(provider: .localModel, model: modelID, modelRevision: revision), usageCounter: counter
    )
    let fixture = try await LiveDecisionFixture(
        texts: ["最初。後続", "独立"], makeDecisions: { decisions }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    for index in fixture.segments.indices { try await fixture.recognize(index) }
    try await fixture.jev.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.waitForDecisionCompletion()
    try await fixture.recorder.wait { $0.filter(\.hasRecognizedText).map(\.clauseState) == [.classified, .classified] }

    let objects = try fixture.eventObjects()
    let starts = objects.filter { $0["event_type"] as? String == "processing.run.started" }
        .filter {
            let stage = ($0["payload"] as? [String: Any])?["stage"] as? String
            return stage == ProcessingStage.clauseBoundary.rawValue
                || stage == ProcessingStage.contentPriority.rawValue
        }
    #expect(starts.compactMap { ($0["payload"] as? [String: Any])?["stage"] as? String }
        == [ProcessingStage.clauseBoundary.rawValue, ProcessingStage.contentPriority.rawValue])
    for start in starts {
        let provenance = try #require((start["payload"] as? [String: Any])?["provenance"] as? [String: Any])
        #expect(provenance["engine"] as? String == "local-coreml")
        #expect(provenance["model"] as? String == modelID)
        #expect(provenance["version"] as? String == revision)
        let configuration = try #require(provenance["configuration"] as? [String: String])
        #expect(configuration["provider"] == "local-coreml")
        #expect(configuration["model_id"] == modelID)
        #expect(configuration["model_revision"] == revision)
        #expect(configuration["unit_policy"] == "btsj-utterance-sentence")
    }

    let boundaryPayloads = objects.filter { $0["event_type"] as? String == ClauseEventType.boundaryAssessed }
        .compactMap { $0["payload"] as? [String: Any] }
    #expect(boundaryPayloads.count == 2)
    #expect(boundaryPayloads.compactMap { $0["request"] as? [String: Any] }.count == 1)
    #expect(boundaryPayloads.map {
        ($0["candidates"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    } == [["b0001"], []])
    #expect((boundaryPayloads.last?["request"] as? NSNull) != nil)
    #expect((boundaryPayloads.last?["source_decision"] as? [String: Any])?["kind"] as? String
        == "terminal_without_questions")
    let priorityPayloads = objects.filter { $0["event_type"] as? String == ClauseEventType.priorityAssigned }
        .compactMap { $0["payload"] as? [String: Any] }
    #expect(priorityPayloads.count == 2)
    #expect(priorityPayloads.compactMap { ($0["assignments"] as? [Any])?.count } == [2, 1])

    let requestRecords = boundaryPayloads.compactMap { $0["request"] as? [String: Any] }
        + priorityPayloads.compactMap { $0["request"] as? [String: Any] }
    #expect(requestRecords.count == 3)
    #expect(requestRecords.allSatisfy { ($0["request_id"] as? String)?.hasPrefix("decisionreq_") == true })
    let requestMetadata = requestRecords.compactMap { $0["metadata"] as? [String: Any] }
    #expect(requestMetadata.count == 3)
    #expect(requestMetadata.allSatisfy {
        ($0["provider"] as? String) == "local-coreml"
            && ($0["model"] as? String) == modelID
            && ($0["model_revision"] as? String) == revision
    })
    #expect(requestMetadata.compactMap { $0["input_tokens"] as? Int } == [11, 17, 17])

    let usage = await counter.snapshot()
    #expect(usage.boundaryRequests.sendCount == 1)
    #expect(usage.priorityRequests.sendCount == 2)
    #expect(usage.reportedInputTokens == 45)
}

@Test(.timeLimit(.minutes(1)))
func localTerminalWithoutQuestionsKeepsSelectedProvenanceAndCallsPriority() async throws {
    let modelID = "sbintuitions/modernbert-ja-30m-multitagger"
    let revision = String(repeating: "a", count: 64)
    let counter = DecisionUsageCounter()
    let provider = LocalSelectedDecisionProvider(modelID: modelID, revision: revision)
    let decisions = DecisionCoordinator(
        provider: provider, identity: try DecisionModelIdentity(provider: .localModel, model: modelID, modelRevision: revision), usageCounter: counter
    )
    let fixture = try await LiveDecisionFixture(
        texts: ["終端本文"], makeDecisions: { decisions }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try await fixture.recognize(0)
    try await fixture.jev.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.waitForDecisionCompletion()
    try await fixture.recorder.wait { $0.first?.clauseState == .classified }

    let objects = try fixture.eventObjects()
    let starts = objects.filter { $0["event_type"] as? String == "processing.run.started" }
        .filter {
            let stage = ($0["payload"] as? [String: Any])?["stage"] as? String
            return stage == ProcessingStage.clauseBoundary.rawValue
                || stage == ProcessingStage.contentPriority.rawValue
        }
    #expect(starts.compactMap { ($0["payload"] as? [String: Any])?["stage"] as? String }
        == [ProcessingStage.clauseBoundary.rawValue, ProcessingStage.contentPriority.rawValue])
    #expect(starts.allSatisfy { start in
        guard let provenance = (start["payload"] as? [String: Any])?["provenance"] as? [String: Any],
              let configuration = provenance["configuration"] as? [String: String] else { return false }
        return provenance["engine"] as? String == "local-coreml"
            && provenance["model"] as? String == modelID
            && provenance["version"] as? String == revision
            && configuration["provider"] == "local-coreml"
            && configuration["model_id"] == modelID
            && configuration["model_revision"] == revision
            && configuration["unit_policy"] == "btsj-utterance-sentence"
    })
    let boundary = try #require(objects.first { $0["event_type"] as? String == ClauseEventType.boundaryAssessed }?["payload"] as? [String: Any])
    #expect((boundary["request"] as? NSNull) != nil)
    #expect((boundary["candidates"] as? [Any])?.isEmpty == true)
    #expect((boundary["source_decision"] as? [String: Any])?["kind"] as? String
        == "terminal_without_questions")
    let priority = try #require(objects.first { $0["event_type"] as? String == ClauseEventType.priorityAssigned }?["payload"] as? [String: Any])
    let request = try #require(priority["request"] as? [String: Any])
    #expect((request["request_id"] as? String)?.hasPrefix("decisionreq_") == true)
    let metadata = try #require(request["metadata"] as? [String: Any])
    #expect(metadata["provider"] as? String == "local-coreml")
    #expect(metadata["model"] as? String == modelID)
    #expect(metadata["model_revision"] as? String == revision)
    #expect(metadata["input_tokens"] as? Int == 17)
    let usage = await counter.snapshot()
    #expect(usage.boundaryRequests.sendCount == 0)
    #expect(usage.priorityRequests.sendCount == 1)
    #expect(usage.reportedInputTokens == 17)
}

@Test
func unavailableDecisionEngineKeepsLiveRowsUnsplitAndPendingWithoutRequests() async throws {
    let counter = DecisionUsageCounter()
    let fixture = try await LiveDecisionFixture(texts: ["一つ目。二つ目", "三つ目"], makeDecisions: { nil }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try await fixture.recognize(0)
    try await fixture.recognize(1)
    try await fixture.jev.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.recorder.wait { $0.map(\.clauseState) == [.boundaryPending, .boundaryPending] }

    #expect(try LiveTranscriptProjection().rows(for: await fixture.recorder.latest).map(\.textFragments) == [
        [TranscriptTextFragment(text: "一つ目。二つ目", style: .normal)],
        [TranscriptTextFragment(text: "三つ目", style: .normal)]
    ])
    let snapshot = await counter.snapshot()
    #expect(snapshot.sendCount == 0)
    #expect(snapshot.pendingBoundarySegmentCount == 2)
    let firstRun = try #require(try fixture.eventObjects().first {
        $0["event_type"] as? String == "processing.run.started"
            && ($0["payload"] as? [String: Any])?["stage"] as? String == ProcessingStage.clauseBoundary.rawValue
    })
    #expect((firstRun["payload"] as? [String: Any])?["stage"] as? String
        == ProcessingStage.clauseBoundary.rawValue)
    let provenance = try #require((firstRun["payload"] as? [String: Any])?["provenance"] as? [String: Any])
    #expect(provenance["engine"] as? String == "unavailable")
    #expect((provenance["configuration"] as? [String: String])?["provider"] == "unavailable")
}

@Test
func failedASRLeavesThePrecedingSegmentPendingAndTheNextHeadUnresolved() async throws {
    let provider = LiveProvider(continuing: [])
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(texts: ["前の区間", nil, "後の頭。独立"], makeDecisions: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try await fixture.recognize(0)
    try await fixture.recognize(1)
    try await fixture.recognize(2)
    try await fixture.jev.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.recorder.wait { $0.map(\.clauseState) == [.boundaryPending, .boundaryPending] }

    // The gap is not bridged: no request carries text across it.
    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["seg_3"])
    let reasons = try fixture.eventObjects().filter { $0["event_type"] as? String == "clause_boundaries.pending" }
        .compactMap { ($0["payload"] as? [String: Any])?["reason"] as? String }
    #expect(reasons == ["asr_gap"])
    #expect(await provider.priorityRequests == [["独立"]])
}

private struct InitializationFailure: LocalizedError {
    var errorDescription: String? { "Keychain を読めません" }
}

@Test
func initializationErrorIsShownAndRecordingRowsStayVisible() async throws {
    let counter = DecisionUsageCounter()
    let fixture = try await LiveDecisionFixture(texts: ["一つ目"], makeDecisions: { throw InitializationFailure() }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try await fixture.recognize(0)
    try await fixture.jev.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.recorder.wait { $0.map(\.clauseState) == [.boundaryPending] }

    #expect(await fixture.recorder.statuses.last?.contains("Keychain を読めません") == true)
    let reasons = try fixture.eventObjects().filter { $0["event_type"] as? String == "clause_boundaries.pending" }
        .compactMap { ($0["payload"] as? [String: Any])?["reason"] as? String }
    #expect(reasons == ["initialization_failed"])
}

@Test(.timeLimit(.minutes(1)))
func emptySuccessfulASREndsTheTextStreamWithoutSkippingToAFutureHead() async throws {
    let provider = LiveProvider(continuing: [])
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(texts: ["前の本文", "", "後の本文"], makeDecisions: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    for index in fixture.segments.indices { try await fixture.recognize(index) }
    try await fixture.jev.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.recorder.wait { $0.filter(\.hasRecognizedText).map(\.clauseState) == [.classified, .classified] }

    #expect(await provider.boundaryRequests == [])
    #expect(await provider.priorityRequests == [["前の本文"], ["後の本文"]])
    let objects = try fixture.eventObjects()
    let raw = objects.filter { $0["event_type"] as? String == "asr.completed" }
        .compactMap { ($0["payload"] as? [String: Any])?["text"] as? String }
    #expect(raw == ["前の本文", "", "後の本文"])
    let clauses = objects.filter { $0["event_type"] as? String == "clauses.closed" }
    #expect(clauses.allSatisfy { object in
        let payload = object["payload"] as? [String: Any]
        return (payload?["termination"] as? [String: Any])?["kind"] as? String == "stream_end"
    })
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func emptySuccessfulASRSeparatesAnUnresolvedGapFromLaterText(missingAfterSeparator: Bool) async throws {
    let provider = LiveProvider(continuing: [])
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let texts: [String?] = missingAfterSeparator
        ? ["欠落の前", nil, "", nil, "独立した後"]
        : ["欠落の前", nil, "", "独立した後"]
    let fixture = try await LiveDecisionFixture(texts: texts, makeDecisions: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    for index in fixture.segments.indices { try await fixture.recognize(index) }
    try await fixture.jev.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.recorder.wait {
        $0.filter(\.hasRecognizedText).map(\.clauseState)
            == [.boundaryPending, missingAfterSeparator ? .boundaryPending : .classified]
    }

    #expect(await provider.priorityRequests == (missingAfterSeparator ? [] : [["独立した後"]]))
    #expect(await provider.boundaryRequests == [])
    let rows = await fixture.recorder.latest.filter(\.hasRecognizedText)
    #expect(rows.map(\.text) == ["欠落の前", "独立した後"])
    #expect(rows.first?.clauseSlices == [])
    #expect(rows.last?.clauseSlices.map(\.priority) == (missingAfterSeparator ? [] : [.primary]))
    let reusable = try EventLogTranscriptReader().liveContentPriorityDecisions(
        from: SessionWriter.readDurableLog(eventsURL: fixture.root.appending(path: "events.jsonl"))
    )
    #expect(Set(reusable.keys) == (missingAfterSeparator ? [] : [ExactClauseTextKey(text: "独立した後")]))
    #expect(await counter.snapshot().pendingBoundarySegmentCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func explicitDecisionStopPreservesNormalRowsAndRecordsStoppedRatherThanUnconfigured() async throws {
    let counter = DecisionUsageCounter()
    let fixture = try await LiveDecisionFixture(
        texts: ["停止中の本文。次の節"], makeDecisions: { throw DecisionAvailabilityError.stopped }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try await fixture.recognize(0)
    try await fixture.jev.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.recorder.wait { $0.map(\.clauseState) == [.boundaryPending] }
    let objects = try fixture.eventObjects()
    let reasons = objects.filter { $0["event_type"] as? String == "clause_boundaries.pending" }
        .compactMap { ($0["payload"] as? [String: Any])?["reason"] as? String }
    #expect(reasons == ["stopped"])
    #expect(await fixture.recorder.latest.first?.clauseSlices == [])
    #expect(await counter.snapshot().sendCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func livePrioritySaveFailureKeepsPreviouslyDurableClassificationAndNewTextVisible() async throws {
    let provider = LiveProvider(continuing: [], holdPriorityNumber: 2)
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(
        texts: ["うん。", "新しい本文。", "続き"], makeDecisions: { decisions }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    for index in fixture.segments.indices { try await fixture.recognize(index) }
    try await provider.waitForPriorities(2)
    try await fixture.recorder.wait { $0.map(\.clauseState) == [.classified, .priorityPending, .awaitingNextSegment] }

    let eventsURL = fixture.root.appending(path: "events.jsonl")
    let savedURL = fixture.root.appending(path: "saved-events.jsonl")
    try FileManager.default.moveItem(at: eventsURL, to: savedURL)
    try FileManager.default.createDirectory(at: eventsURL, withIntermediateDirectories: false)
    await provider.release()
    try await fixture.recorder.waitForStatus { $0.contains("判定を保存できませんでした") }
    try FileManager.default.removeItem(at: eventsURL)
    try FileManager.default.moveItem(at: savedURL, to: eventsURL)

    let rows = try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)
    #expect(rows.map(\.text) == ["うん。", "新しい本文。", "続き"])
    #expect(rows.map(\.shouldCollapseRow) == [true, false, false])
    #expect(rows[1].textFragments == [TranscriptTextFragment(text: "新しい本文。", style: .normal)])
    let assignments = try fixture.eventObjects().filter { $0["event_type"] as? String == "content_priority.assigned" }
    #expect(assignments.count == 1)
    #expect(await counter.snapshot().priorityRequests.successCount == 2)
    #expect(await counter.snapshot().priorityRequests.failureCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func leadingASRFailureDoesNotInventTheNextHeadAsAnIndependentClause() async throws {
    let provider = LiveProvider(continuing: [])
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(texts: [nil, "欠落後の頭。独立"], makeDecisions: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    for index in fixture.segments.indices { try await fixture.recognize(index) }
    try await fixture.jev.finishInput(snapshot: await fixture.asr.snapshot())
    try await provider.waitForPriorities(1)
    try await fixture.recorder.wait { rows in
        rows.first?.clauseState == .boundaryPending && rows.first?.clauseSlices.first?.priority == .primary
    }
    #expect(await provider.priorityRequests == [["独立"]])
    let slices = await fixture.recorder.latest.first?.clauseSlices
    #expect(slices?.map(\.sourceRange.start) == ["欠落後の頭。".utf16.count])
    #expect(slices?.map(\.sourceRange.end) == ["欠落後の頭。独立".utf16.count])
}

private final class LiveAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var suspended = false
    private var acquisitionCount = 0
    var stopped: Bool {
        get { lock.withLock { suspended } }
        set { lock.withLock { suspended = newValue } }
    }

    func stoppedForRequest() -> Bool {
        lock.withLock {
            acquisitionCount += 1
            return suspended
        }
    }

    var acquisitions: Int { lock.withLock { acquisitionCount } }
}

@Test(.timeLimit(.minutes(1)))
func stoppingDecisionsBetweenBoundaryAndPriorityKeepsTheSavedBoundaryWithoutSendingChoice() async throws {
    let provider = LiveProvider(continuing: [], holdBoundaryNumber: 1)
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let availability = LiveAvailability()
    let fixture = try await LiveDecisionFixture(
        texts: ["うん。", "次の本文"],
        makeDecisions: {
            if availability.stopped { throw DecisionAvailabilityError.stopped }
            return decisions
        },
        counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.recognize(0)
    try await fixture.recognize(1)
    try await provider.waitForBoundaries(1)
    availability.stopped = true
    await provider.release()
    try await fixture.recorder.wait {
        $0.first?.clauseState == .priorityPending && $0.first?.clauseSlices.first?.needsRetry == true
    }
    #expect(await provider.priorityRequests == [])
    #expect(await fixture.recorder.latest.first?.clauseSlices.map(\.priority) == [nil])
    let projection = try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)
    #expect(projection.first?.shouldCollapseRow == false)
    #expect(projection.first?.textFragments == [TranscriptTextFragment(text: "うん。", style: .normal)])
    let objects = try fixture.eventObjects()
    let payload = try #require(objects.first { $0["event_type"] as? String == "content_priority.assigned" }?["payload"] as? [String: Any])
    let decision = try #require((payload["assignments"] as? [[String: Any]])?.first?["decision"] as? [String: Any])
    #expect(decision["reason"] as? String == "stopped")
    #expect(payload["request"] is NSNull)
    #expect(await counter.snapshot().boundaryRequests.sendCount == 1)
    #expect(await counter.snapshot().priorityRequests.sendCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func savedLowSliceDoesNotFlickerWhileItsContinuationWaitsForPriority() async throws {
    let provider = LiveProvider(continuing: ["seg_1"], holdPriorityNumber: 2)
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(
        texts: ["うん。続く", "本文。", "次"],
        makeDecisions: { decisions }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.recognize(0)
    try await fixture.recognize(1)
    try await fixture.recorder.wait { $0.first?.clauseSlices.first?.priority == .lowPriority }
    let awaiting = try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)
    #expect(awaiting[0].clauseState == .awaitingNextSegment)
    let expected = [
        TranscriptTextFragment(text: "うん。", style: .lowPriority),
        TranscriptTextFragment(text: "続く", style: .normal)
    ]
    #expect(awaiting[0].textFragments == expected)
    #expect(!awaiting[0].shouldCollapseRow)

    try await fixture.recognize(2)
    try await provider.waitForPriorities(2)
    try await fixture.recorder.wait { $0.first?.clauseState == .priorityPending }
    let pending = try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)
    #expect(pending[0].textFragments == expected)
    #expect(!pending[0].shouldCollapseRow)
    await provider.release()
    try await fixture.recorder.wait { $0.first?.clauseState == .classified }
    #expect(try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)[0].textFragments == expected)
    await fixture.jev.stop()
}

private actor StoppingPriorityProvider: DecisionProvider {
    private(set) var prioritySizes: [Int] = []
    private let status: Int
    private(set) var boundaryCount = 0

    init(status: Int) { self.status = status }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        boundaryCount += 1
        return ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.9) }),
            continuationProbability: request.next.map { _ in 0.1 },
            metadata: try DecisionResponseMetadata(model: "injected", inputTokens: 1, outputTokens: nil)
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        prioritySizes.append(targets.count)
        throw JevClientError.httpStatus(status)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [401, 429])
func stoppedLivePriorityRunPersistsEveryUnsentClauseInBoundedBatches(_ status: Int) async throws {
    let provider = StoppingPriorityProvider(status: status)
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let raw = (1...81).map { "本文\($0)。" }.joined()
    let availability = LiveAvailability()
    let fixture = try await LiveDecisionFixture(
        texts: [raw, "後続"],
        makeDecisions: {
            _ = availability.stoppedForRequest()
            return decisions
        },
        counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.recognize(0)
    try await fixture.recognize(1)
    try await fixture.jev.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.waitForDecisionCompletion()
    let assigned = try fixture.eventObjects().filter { $0["event_type"] as? String == ClauseEventType.priorityAssigned }
    let payloads = try assigned.map { try #require($0["payload"] as? [String: Any]) }
    #expect(payloads.map { ($0["assignments"] as? [Any])?.count } == [40, 40, 1])
    #expect(payloads.allSatisfy { $0["request"] is NSNull })
    #expect(await provider.prioritySizes == [40])
    #expect(await provider.boundaryCount == 1)
    #expect(availability.acquisitions == 2)
    let assignments = try payloads.flatMap { try #require($0["assignments"] as? [[String: Any]]) }
    #expect(assignments.allSatisfy {
        ($0["decision"] as? [String: Any])?["reason"] as? String
            == (status == 401 ? "authorization_rejected" : "request_failed")
    })
    let pendingBoundaries = try fixture.eventObjects().filter {
        $0["event_type"] as? String == ClauseEventType.boundaryPending
    }
    #expect(pendingBoundaries.count == 1)
    #expect((pendingBoundaries[0]["payload"] as? [String: Any])?["reason"] as? String
        == (status == 401 ? "authorization_rejected" : "request_failed"))
    #expect(await counter.snapshot().priorityRequests.sendCount == 1)
    #expect(await counter.snapshot().priorityRequests.failureCount == 1)
    #expect(await counter.snapshot().pendingPriorityClauseCount == 81)
    #expect(await counter.snapshot().pendingBoundarySegmentCount == 1)
    let row = try #require(try LiveTranscriptProjection().rows(for: await fixture.recorder.latest).first)
    #expect(row.text == raw)
    #expect(row.clauseState == .priorityPending)
    #expect(row.textFragments == [TranscriptTextFragment(text: raw, style: .normal)])
    #expect(!row.shouldCollapseRow)
    await fixture.jev.stop()
}

@Test(.timeLimit(.minutes(1)))
func livePriorityBatchesReadCurrentAvailabilityAfterEachSavedBatch() async throws {
    let provider = LiveProvider(continuing: [], holdPriorityNumber: 1)
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let availability = LiveAvailability()
    let raw = (1...81).map { "本文\($0)。" }.joined()
    let fixture = try await LiveDecisionFixture(
        texts: [raw],
        makeDecisions: {
            if availability.stoppedForRequest() { throw DecisionAvailabilityError.stopped }
            return decisions
        },
        counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.recognize(0)
    try await fixture.jev.finishInput(snapshot: await fixture.asr.snapshot())
    try await provider.waitForPriorities(1)
    availability.stopped = true
    await provider.release()
    try await fixture.waitForDecisionCompletion()

    let slices = try #require(await fixture.recorder.latest.first?.clauseSlices)
    #expect(slices.prefix(40).allSatisfy { $0.priority == .primary && !$0.needsRetry })
    #expect(slices.dropFirst(40).allSatisfy { $0.priority == nil && $0.needsRetry })
    #expect(slices.count == 81)
    let assigned = try fixture.eventObjects().filter { $0["event_type"] as? String == ClauseEventType.priorityAssigned }
    let payloads = try assigned.map { try #require($0["payload"] as? [String: Any]) }
    #expect(payloads.map { ($0["assignments"] as? [Any])?.count } == [40, 40, 1])
    #expect(payloads.first?["request"] is [String: Any])
    #expect(payloads.dropFirst().allSatisfy {
        $0["request"] is NSNull && ($0["assignments"] as? [[String: Any]])?.allSatisfy {
            ($0["decision"] as? [String: Any])?["reason"] as? String == "stopped"
        } == true
    })
    #expect(await provider.priorityRequests == [(1...40).map { "本文\($0)。" }])
    #expect(availability.acquisitions == 4)
    #expect(await counter.snapshot().priorityRequests.successCount == 1)
    #expect(await counter.snapshot().priorityRequests.failureCount == 0)
    #expect(await counter.snapshot().pendingPriorityClauseCount == 41)
    await fixture.jev.stop()
}

private actor LocalSelectedDecisionProvider: DecisionProvider {
    private let modelID: String
    private let revision: String

    init(modelID: String, revision: String) {
        self.modelID = modelID
        self.revision = revision
    }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.99) }),
            continuationProbability: request.next.map { _ in 0.01 },
            metadata: try DecisionResponseMetadata(
                identity: DecisionModelIdentity(provider: .localModel, model: modelID, modelRevision: revision),
                inputTokens: 11,
                outputTokens: 0
            )
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        let decisions = try Dictionary(uniqueKeysWithValues: targets.map { target in
            (target.key, try ContentPriorityDecision(
                priority: .primary, confidence: 0.98,
                probabilities: ["PRIMARY": 0.99, "LOW_PRIORITY": 0.01]
            ))
        })
        return PriorityBatchResponse(
            decisions: decisions,
            metadata: try DecisionResponseMetadata(
                identity: DecisionModelIdentity(provider: .localModel, model: modelID, modelRevision: revision),
                inputTokens: 17,
                outputTokens: 0
            )
        )
    }
}
