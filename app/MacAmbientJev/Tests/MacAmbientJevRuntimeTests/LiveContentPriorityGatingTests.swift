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
            metadata: try JevResponseMetadata(model: "jev-live", inputTokens: 5, outputTokens: nil)
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
        return PriorityBatchResponse(decisions: decisions, metadata: try JevResponseMetadata(model: "jev-live", inputTokens: 7, outputTokens: nil))
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

private struct LiveJevFixture {
    let root: URL
    let checkpoint: AudioCheckpoint
    let asr: LiveASRSession
    let jev: LiveContentPrioritySession
    let segments: [SegmentReference]
    let counter: JevUsageCounter
    let recorder = LiveRecorder()

    init(texts: [String?], makeDecisions: @escaping LiveContentPrioritySession.DecisionFactory, counter: JevUsageCounter) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1)
        let durableFrames = max(16_000, ((texts.count + 3) / 4) * 16_000)
        try await audio.append(samples: Array(repeating: Float(0.1), count: durableFrames))
        checkpoint = await audio.committedSnapshot()
        let writer = try SessionWriter(sessionURL: root)
        let sessionID = UUID()
        asr = LiveASRSession(
            sessionID: sessionID, segmentationRunID: "live_seg", asrRunID: "live_asr",
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
        try SessionRecovery.recoverJSONL(Data(contentsOf: root.appending(path: "events.jsonl"))).lines.map {
            try JSONSerialization.jsonObject(with: $0) as! [String: Any]
        }
    }
}

@Test
func liveRowsShowAtOnceAndAClauseSpanningSegmentsClosesOnlyAfterItsBoundaries() async throws {
    let provider = LiveProvider(continuing: ["seg_1", "seg_2"])
    let counter = JevUsageCounter()
    let decisions = JevDecisionCoordinator(provider: provider, usageCounter: counter)
    let fixture = try await LiveJevFixture(
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

@Test(.timeLimit(.minutes(1)))
func stoppedLiveQueueDropsALateResponseAndKeepsSavedResults() async throws {
    let provider = LiveProvider(continuing: [], holdBoundaryNumber: 2)
    let counter = JevUsageCounter()
    let decisions = JevDecisionCoordinator(provider: provider, usageCounter: counter)
    let fixture = try await LiveJevFixture(texts: ["うん。", "二つ目。", "三つ目。"], makeDecisions: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try await fixture.recognize(0)
    try await fixture.recognize(1)
    try await fixture.recognize(2)
    try await provider.waitForBoundaries(2)
    try await fixture.recorder.wait { $0.first?.clauseState == .classified }
    let updatesBeforeStop = await fixture.recorder.updates.count
    let eventsBeforeStop = try Data(contentsOf: fixture.root.appending(path: "events.jsonl"))

    await fixture.jev.stop()
    await provider.release()
    try await Task.sleep(for: .milliseconds(100))

    #expect(await fixture.recorder.updates.count == updatesBeforeStop)
    #expect(try Data(contentsOf: fixture.root.appending(path: "events.jsonl")) == eventsBeforeStop)
    #expect(await provider.priorityRequests == [["うん。"]])
    #expect(try LiveTranscriptProjection().rows(for: await fixture.recorder.latest).map(\.shouldCollapseRow) == [true, false, false])
    #expect(await fixture.recorder.latest.map(\.clauseState) == [.classified, .awaitingNextSegment, .awaitingNextSegment])
}

@Test
func unavailableJevKeepsLiveRowsUnsplitAndPendingWithoutRequests() async throws {
    let counter = JevUsageCounter()
    let fixture = try await LiveJevFixture(texts: ["一つ目。二つ目", "三つ目"], makeDecisions: { nil }, counter: counter)
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
}

@Test
func failedASRLeavesThePrecedingSegmentPendingAndTheNextHeadUnresolved() async throws {
    let provider = LiveProvider(continuing: [])
    let counter = JevUsageCounter()
    let decisions = JevDecisionCoordinator(provider: provider, usageCounter: counter)
    let fixture = try await LiveJevFixture(texts: ["前の区間", nil, "後の頭。独立"], makeDecisions: { decisions }, counter: counter)
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
    let counter = JevUsageCounter()
    let fixture = try await LiveJevFixture(texts: ["一つ目"], makeDecisions: { throw InitializationFailure() }, counter: counter)
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
    let counter = JevUsageCounter()
    let decisions = JevDecisionCoordinator(provider: provider, usageCounter: counter)
    let fixture = try await LiveJevFixture(texts: ["前の本文", "", "後の本文"], makeDecisions: { decisions }, counter: counter)
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
    let counter = JevUsageCounter()
    let decisions = JevDecisionCoordinator(provider: provider, usageCounter: counter)
    let texts: [String?] = missingAfterSeparator
        ? ["欠落の前", nil, "", nil, "独立した後"]
        : ["欠落の前", nil, "", "独立した後"]
    let fixture = try await LiveJevFixture(texts: texts, makeDecisions: { decisions }, counter: counter)
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
func explicitJevStopPreservesNormalRowsAndRecordsStoppedRatherThanUnconfigured() async throws {
    let counter = JevUsageCounter()
    let fixture = try await LiveJevFixture(
        texts: ["停止中の本文。次の節"], makeDecisions: { throw JevAvailabilityError.stopped }, counter: counter
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
    let counter = JevUsageCounter()
    let decisions = JevDecisionCoordinator(provider: provider, usageCounter: counter)
    let fixture = try await LiveJevFixture(
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
    let counter = JevUsageCounter()
    let decisions = JevDecisionCoordinator(provider: provider, usageCounter: counter)
    let fixture = try await LiveJevFixture(texts: [nil, "欠落後の頭。独立"], makeDecisions: { decisions }, counter: counter)
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
    var stopped: Bool {
        get { lock.withLock { suspended } }
        set { lock.withLock { suspended = newValue } }
    }
}

@Test(.timeLimit(.minutes(1)))
func stoppingJevBetweenBoundaryAndPriorityKeepsTheSavedBoundaryWithoutSendingChoice() async throws {
    let provider = LiveProvider(continuing: [], holdBoundaryNumber: 1)
    let counter = JevUsageCounter()
    let decisions = JevDecisionCoordinator(provider: provider, usageCounter: counter)
    let availability = LiveAvailability()
    let fixture = try await LiveJevFixture(
        texts: ["うん。", "次の本文"],
        makeDecisions: {
            if availability.stopped { throw JevAvailabilityError.stopped }
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
    let counter = JevUsageCounter()
    let decisions = JevDecisionCoordinator(provider: provider, usageCounter: counter)
    let fixture = try await LiveJevFixture(
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
