import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevPipeline

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
    private struct RowsWaiter {
        let condition: @Sendable ([MaterializedTranscriptSegment]) -> Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct StatusWaiter {
        let condition: @Sendable (String) -> Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    private(set) var updates: [[MaterializedTranscriptSegment]] = []
    private(set) var statuses: [String] = []
    private var failure: String?
    private var rowWaiters: [UUID: RowsWaiter] = [:]
    private var statusWaiters: [UUID: StatusWaiter] = [:]

    func record(_ rows: [MaterializedTranscriptSegment]) {
        updates.append(rows)
        resolveRowWaiters()
    }

    func record(status: String) {
        statuses.append(status)
        resolveStatusWaiters()
        if status.contains("判定を保存できませんでした") {
            record(failure: status)
        }
    }

    func record(failure message: String) {
        failure = message
        let pendingRows = Array(rowWaiters.values)
        let pendingStatuses = Array(statusWaiters.values)
        rowWaiters.removeAll()
        statusWaiters.removeAll()
        for waiter in pendingRows {
            waiter.continuation.resume(throwing: LiveFixtureWaitError(message: message))
        }
        for waiter in pendingStatuses {
            waiter.continuation.resume(throwing: LiveFixtureWaitError(message: message))
        }
    }

    var latest: [MaterializedTranscriptSegment] { updates.last ?? [] }

    func wait(until condition: @escaping @Sendable ([MaterializedTranscriptSegment]) -> Bool) async throws {
        if condition(latest) { return }
        if let failure { throw LiveFixtureWaitError(message: failure) }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                rowWaiters[id] = RowsWaiter(condition: condition, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelRowsWaiter(id) }
        }
    }

    func waitForStatus(_ condition: @escaping @Sendable (String) -> Bool) async throws {
        if statuses.contains(where: condition) { return }
        if let failure { throw LiveFixtureWaitError(message: failure) }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                statusWaiters[id] = StatusWaiter(condition: condition, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelStatusWaiter(id) }
        }
    }

    private func cancelRowsWaiter(_ id: UUID) {
        guard let waiter = rowWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelStatusWaiter(_ id: UUID) {
        guard let waiter = statusWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    func throwIfFailed() throws {
        if let failure { throw LiveFixtureWaitError(message: failure) }
    }

    private func resolveRowWaiters() {
        let resolved = rowWaiters.filter { $0.value.condition(latest) }
        for (id, waiter) in resolved {
            rowWaiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: ())
        }
    }

    private func resolveStatusWaiters() {
        let resolved = statusWaiters.filter { waiter in
            statuses.contains(where: waiter.value.condition)
        }
        for (id, waiter) in resolved {
            statusWaiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: ())
        }
    }
}

/// Live injected answers: boundaries after `。`, continuation for the listed segments, LOW for `うん`.
private actor LiveProvider: DecisionProvider {
    private struct RequestWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let continuing: Set<String>
    private let fillerRanges: [TextUTF16Range]
    private var gate: CheckedContinuation<Void, Never>?
    private var holdBoundaryNumber: Int?
    private var holdPriorityNumber: Int?
    private var boundaryWaiters: [UUID: RequestWaiter] = [:]
    private var priorityWaiters: [UUID: RequestWaiter] = [:]
    private(set) var boundaryRequests: [ClauseBoundaryRequest] = []
    private(set) var priorityRequests: [[String]] = []

    init(
        continuing: Set<String>, fillerRanges: [TextUTF16Range],
        holdBoundaryNumber: Int? = nil, holdPriorityNumber: Int? = nil
    ) {
        self.continuing = continuing
        self.fillerRanges = fillerRanges
        self.holdBoundaryNumber = holdBoundaryNumber
        self.holdPriorityNumber = holdPriorityNumber
    }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        boundaryRequests.append(request)
        resolveBoundaryWaiters()
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
            fillerRanges: fillerRanges,
            inputTokens: 5
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        priorityRequests.append(targets.map(\.text))
        resolvePriorityWaiters()
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
        return PriorityBatchResponse(decisions: decisions, inputTokens: 7)
    }

    func release() {
        holdBoundaryNumber = nil
        holdPriorityNumber = nil
        gate?.resume()
        gate = nil
    }

    func boundaryCount() -> Int { boundaryRequests.count }

    func waitForBoundaries(_ count: Int) async throws {
        if boundaryRequests.count >= count { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                boundaryWaiters[id] = RequestWaiter(count: count, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelBoundaryWaiter(id) }
        }
    }

    func waitForPriorities(_ count: Int) async throws {
        if priorityRequests.count >= count { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                priorityWaiters[id] = RequestWaiter(count: count, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelPriorityWaiter(id) }
        }
    }

    private func cancelBoundaryWaiter(_ id: UUID) {
        guard let waiter = boundaryWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelPriorityWaiter(_ id: UUID) {
        guard let waiter = priorityWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resolveBoundaryWaiters() {
        let resolved = boundaryWaiters.filter { boundaryRequests.count >= $0.value.count }
        for (id, waiter) in resolved {
            boundaryWaiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: ())
        }
    }

    private func resolvePriorityWaiters() {
        let resolved = priorityWaiters.filter { priorityRequests.count >= $0.value.count }
        for (id, waiter) in resolved {
            priorityWaiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: ())
        }
    }
}

private struct LiveDecisionFixture {
    let root: URL
    let sessionID: UUID
    let checkpoint: AudioCheckpoint
    let asr: LiveASRSession
    let priority: LiveContentPrioritySession
    let segments: [SegmentReference]
    let counter: DecisionUsageCounter
    let recorder: LiveRecorder

    init(
        texts: [String?], makeDecisions: @escaping NativeSessionProcessor.DecisionCoordinatorFactory,
        counter: DecisionUsageCounter
    ) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try DurableAudioWriter(
            directory: SessionLayout(sessionURL: root).processingDirectory, chunkDurationSeconds: 1, sessionURL: root
        )
        let durableFrames = max(16_000, ((texts.count + 3) / 4) * 16_000)
        try await audio.append(samples: Array(repeating: Float(0.1), count: durableFrames))
        checkpoint = await audio.committedSnapshot()
        let writer = try SessionWriter(sessionURL: root)
        sessionID = UUID()
        segments = texts.indices.map {
            SegmentReference(segmentationRunID: "live_seg", segmentID: "seg_\($0 + 1)",
                             speechRanges: [Int64($0 * 4_000)..<Int64($0 * 4_000 + 3_000)])
        }
        let scripted = ScriptedASR(texts)
        try await seedLivePipeline(
            writer: writer, sessionID: sessionID, segmentationRunID: "live_seg", asrRunID: "live_asr",
            sampleRate: checkpoint.sampleRate, asrProvenance: scripted.provenance,
            decisionRuns: ("boundary_live", "priority_live")
        )
        asr = try await LiveASRSession.open(sessionID: sessionID, sessionURL: root, writer: writer, asr: scripted)
        let recorder = LiveRecorder()
        self.recorder = recorder
        priority = try await LiveContentPrioritySession.open(
            sessionID: sessionID, writer: writer, liveASR: asr, makeDecisions: makeDecisions, usageCounter: counter,
            onStatus: { await recorder.record(status: $0) },
            onUpdate: { await recorder.record($0.progress.materializedSegments) }
        )
        self.counter = counter
    }

    /// Recognizes one segment the way the processor does: rows are shown, then the decision queue is told.
    func recognize(_ index: Int) async throws {
        let priority = self.priority, recorder = self.recorder
        _ = try await asr.process(segments: [segments[index]], checkpoint: checkpoint, onSegmentFinished: { status, snapshot in
            await recorder.record(snapshot.progress.materializedSegments)
            switch status.outcome {
            case .recognized(let source, _):
                do {
                    try await priority.enqueue(
                        source: source, snapshot: snapshot,
                        onStatus: { await recorder.record(status: $0) },
                        onUpdate: { await recorder.record($0.progress.materializedSegments) }
                    )
                } catch {
                    await recorder.record(failure: "ライブ判定の登録に失敗しました: \(error.localizedDescription)")
                }
            case .failed, .pending:
                do {
                    try await priority.observe(snapshot: snapshot)
                } catch {
                    await recorder.record(failure: "ライブ判定の状態記録に失敗しました: \(error.localizedDescription)")
                }
            }
        }, shouldPause: { _ in nil })
    }

    func eventLog() async throws -> Data {
        let worker = await priority.worker
        await worker?.value
        return try SessionWriter.readDurableLog(eventsURL: root.appending(path: "events.jsonl"))
    }

    func eventObjects(from log: Data) throws -> [[String: Any]] {
        try SessionRecovery.recoverJSONL(log).lines.map {
            try JSONSerialization.jsonObject(with: $0) as! [String: Any]
        }
    }

    func waitForDecisionCompletion() async throws -> Data {
        let worker = await priority.worker
        await worker?.value
        try await recorder.throwIfFailed()
        let log = try SessionWriter.readDurableLog(eventsURL: root.appending(path: "events.jsonl"))
        guard try eventObjects(from: log).contains(where: {
            $0["event_type"] as? String == "processing.run.completed"
                && ($0["payload"] as? [String: Any])?["stage"] as? String == "contentPriority"
        }) else {
            throw LiveFixtureWaitError(message: "ライブ優先度判定の完了イベントが保存されていません")
        }
        return log
    }
}

@Test(.timeLimit(.minutes(10)))
func liveRowsShowAtOnceAndAClauseSpanningSegmentsClosesOnlyAfterItsBoundaries() async throws {
    let provider = LiveProvider(continuing: ["seg_1", "seg_2"], fillerRanges: [])
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(
        texts: ["これは", "コピーと", "いうか。うん、うん。"], makeDecisions: { decisions }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try await fixture.recognize(0)
    // Saved ASR is visible as normal text before any decision request: the boundary needs the next segment.
    #expect(await fixture.recorder.updates.first?.map(\.clauseState) == [.awaitingNextSegment])
    #expect(await provider.boundaryCount() == 0)
    let first = try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)
    #expect(first.map(\.text) == ["これは"])

    try await fixture.recognize(1)
    try await fixture.recognize(2)
    try await provider.waitForBoundaries(2)
    // The last segment waits for a successor; the clause running through it is not closed.
    try await fixture.recorder.wait { $0.map(\.clauseState) == [.awaitingNextSegment, .awaitingNextSegment, .awaitingNextSegment] }

    try await fixture.priority.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.recorder.wait { $0.map(\.clauseState) == [.classified, .classified, .classified] }
    _ = try await fixture.waitForDecisionCompletion()

    let requests = await provider.boundaryRequests
    #expect(requests.map(\.source.segmentID) == ["seg_1", "seg_2", "seg_3"])
    #expect(requests.map { $0.next?.text } == ["コピーと", "いうか。うん、うん。", nil])
    #expect(await provider.priorityRequests == [["これはコピーというか。", "うん、うん。"]])
    let rows = try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)
    #expect(rows.map(\.text) == ["これは", "コピーと", "いうか。"])
    let snapshot = await counter.snapshot()
    #expect(snapshot.boundaryRequests.sendCount == 3)
    #expect(snapshot.priorityRequests.sendCount == 1)
    await fixture.priority.worker?.value
}

@Test(.timeLimit(.minutes(10)), arguments: [false, true])
func stoppedLiveQueueDropsALateResponseAndKeepsSavedResults(holdingPriority: Bool) async throws {
    let provider = LiveProvider(
        continuing: [], fillerRanges: [], holdBoundaryNumber: holdingPriority ? nil : 2,
        holdPriorityNumber: holdingPriority ? 2 : nil
    )
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
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
    let eventsBeforeStop = try SessionWriter.readDurableLog(eventsURL: fixture.root.appending(path: "events.jsonl"))
    let worker = try #require(await fixture.priority.worker)

    await fixture.priority.stop()
    await provider.release()
    await worker.value

    #expect(await fixture.recorder.updates.count == updatesBeforeStop)
    let eventsAfterStop = try SessionWriter.readDurableLog(eventsURL: fixture.root.appending(path: "events.jsonl"))
    #expect(eventsAfterStop == eventsBeforeStop)
    let expectedRequests = holdingPriority
        ? [["うん。"], (1...40).map { "本文\($0)。" }]
        : [["うん。"]]
    #expect(await provider.priorityRequests == expectedRequests)
    #expect(try LiveTranscriptProjection().rows(for: await fixture.recorder.latest).map(\.text)
        == [holdingPriority ? second : "2つ目。", "3つ目。"])
    #expect(await fixture.recorder.latest.map(\.text) == ["うん。", second, "三つ目。"])
    #expect(await fixture.recorder.latest.map(\.clauseState) == [
        .classified, holdingPriority ? .priorityPending : .awaitingNextSegment, .awaitingNextSegment
    ])
}

@Test(.timeLimit(.minutes(10)))
func localSelectedLiveDecisionProvenanceIsDurableForBoundaryAndPriority() async throws {
    let modelID = "Pokojaka/modernbert-ja-30m-utterance-tagger"
    let revision = String(repeating: "a", count: 64)
    let counter = DecisionUsageCounter()
    let provider = FixedResponseProvider()
    let decisions = DecisionCoordinator(
        provider: provider, identity: try DecisionModelIdentity(backend: "test-backend", model: modelID, modelRevision: revision), usageCounter: counter
    )
    let fixture = try await LiveDecisionFixture(
        texts: ["最初。後続", "独立"], makeDecisions: { decisions }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    for index in fixture.segments.indices { try await fixture.recognize(index) }
    try await fixture.priority.finishInput(snapshot: await fixture.asr.snapshot())
    let log = try await fixture.waitForDecisionCompletion()
    try await fixture.recorder.wait { $0.filter(\.hasRecognizedText).map(\.clauseState) == [.classified, .classified] }

    let objects = try fixture.eventObjects(from: log)
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
        #expect(provenance["engine"] as? String == "test-backend")
        #expect(provenance["model"] as? String == modelID)
        #expect(provenance["version"] as? String == revision)
        let configuration = try #require(provenance["configuration"] as? [String: String])
        #expect(configuration["model_id"] == modelID)
        #expect(configuration["model_revision"] == revision)
        #expect(configuration["unit_policy"] == "btsj-utterance-sentence")
    }

    let boundaryPayloads = objects.filter { $0["event_type"] as? String == ClauseEventType.boundaryAssessed }
        .compactMap { $0["payload"] as? [String: Any] }
    #expect(boundaryPayloads.count == 2)
    #expect(boundaryPayloads.compactMap { $0["request"] as? [String: Any] }.count == 2)
    #expect(boundaryPayloads.map {
        ($0["candidates"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    } == [["b0001"], []])
    #expect(boundaryPayloads.allSatisfy {
        ($0["source_decision"] as? [String: Any])?["kind"] as? String == "assessed"
    })
    let priorityPayloads = objects.filter { $0["event_type"] as? String == ClauseEventType.priorityAssigned }
        .compactMap { $0["payload"] as? [String: Any] }
    #expect(priorityPayloads.count == 2)
    #expect(priorityPayloads.compactMap { ($0["assignments"] as? [Any])?.count } == [2, 1])

    let requestRecords = boundaryPayloads.compactMap { $0["request"] as? [String: Any] }
        + priorityPayloads.compactMap { $0["request"] as? [String: Any] }
    #expect(requestRecords.count == 4)
    #expect(requestRecords.allSatisfy { ($0["request_id"] as? String)?.hasPrefix("decisionreq_") == true })
    #expect(requestRecords.allSatisfy { Set($0.keys) == ["request_id", "input_tokens"] })
    #expect(requestRecords.compactMap { $0["input_tokens"] as? Int } == [11, 11, 17, 17])

    let usage = await counter.snapshot()
    #expect(usage.boundaryRequests.sendCount == 2)
    #expect(usage.priorityRequests.sendCount == 2)
    #expect(usage.inputTokens == 56)
    await fixture.priority.worker?.value
}

@Test(.timeLimit(.minutes(10)), arguments: [false, true])
func liveTranscriptRemovesOnlySavedFillerRanges(hasSavedFiller: Bool) async throws {
    let fillerRange = try TextUTF16Range(start: 0, end: 2)
    let provider = LiveProvider(
        continuing: [], fillerRanges: hasSavedFiller ? [fillerRange] : []
    )
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(texts: ["まあ、本文。"], makeDecisions: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try await fixture.recognize(0)
    try await fixture.priority.finishInput(snapshot: await fixture.asr.snapshot())
    let log = try await fixture.waitForDecisionCompletion()
    try await fixture.recorder.wait { $0.first?.clauseState == .classified }

    let objects = try fixture.eventObjects(from: log)
    let raw = try #require(objects.first { $0["event_type"] as? String == "asr.completed" }?["payload"] as? [String: Any])
    #expect(raw["text"] as? String == "まあ、本文。")
    let boundary = try #require(objects.first { $0["event_type"] as? String == ClauseEventType.boundaryAssessed }?["payload"] as? [String: Any])
    let savedRanges = try #require(boundary["filler_ranges"] as? [[String: Any]])
    #expect(savedRanges.compactMap { $0["start"] as? Int } == (hasSavedFiller ? [0] : []))
    #expect(savedRanges.compactMap { $0["end"] as? Int } == (hasSavedFiller ? [2] : []))
    let rows = try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)
    #expect(rows.map(\.text) == [hasSavedFiller ? "本文。" : "まあ、本文。"])
    let usage = await counter.snapshot()
    #expect(usage.boundaryRequests.sendCount == 1)
    #expect(usage.priorityRequests.sendCount == 1)
    await fixture.priority.worker?.value
}

@Test(.timeLimit(.minutes(10)))
func failedTaggerLoadKeepsLiveRowsUnsplitAndPendingWithoutRequests() async throws {
    let counter = DecisionUsageCounter()
    let fixture = try await LiveDecisionFixture(
        texts: ["一つ目。二つ目", "三つ目"], makeDecisions: { throw InitializationFailure() }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try await fixture.recognize(0)
    try await fixture.recognize(1)
    try await fixture.priority.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.recorder.wait { $0.map(\.clauseState) == [.boundaryPending, .boundaryPending] }

    #expect(try LiveTranscriptProjection().rows(for: await fixture.recorder.latest).map(\.text) == ["1つ目。2つ目", "3つ目"])
    #expect(await fixture.recorder.latest.map(\.text) == ["一つ目。二つ目", "三つ目"])
    let snapshot = await counter.snapshot()
    #expect(snapshot.sendCount == 0)
    #expect(snapshot.pendingBoundarySegmentCount == 2)
    let log = try await fixture.eventLog()
    let objects = try fixture.eventObjects(from: log)
    let firstRun = try #require(objects.first {
        $0["event_type"] as? String == "processing.run.started"
            && ($0["payload"] as? [String: Any])?["stage"] as? String == ProcessingStage.clauseBoundary.rawValue
    })
    #expect((firstRun["payload"] as? [String: Any])?["stage"] as? String
        == ProcessingStage.clauseBoundary.rawValue)
    let provenance = try #require((firstRun["payload"] as? [String: Any])?["provenance"] as? [String: Any])
    #expect(provenance["engine"] as? String == "unavailable")
    await fixture.priority.worker?.value
}

@Test(.timeLimit(.minutes(10)), arguments: [false, true])
func failedASRStopsBeforeLaterDecisionRequests(leadingFailure: Bool) async throws {
    let provider = LiveProvider(continuing: [], fillerRanges: [])
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let texts: [String?] = leadingFailure ? [nil, "後の本文"] : ["前の本文", nil, "後の本文"]
    let fixture = try await LiveDecisionFixture(texts: texts, makeDecisions: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    for index in fixture.segments.indices { try await fixture.recognize(index) }
    await #expect(throws: LiveContentPriorityError.self) {
        try await fixture.priority.finishInput(snapshot: await fixture.asr.snapshot())
    }
    let log = try await fixture.eventLog()
    let snapshot = await fixture.asr.snapshot()
    let objects = try fixture.eventObjects(from: log)

    #expect(snapshot.progress.materializedSegments.map(\.text) == (leadingFailure ? [] : ["前の本文"]))
    #expect(snapshot.progress.materializedSegments.map(\.clauseState) == (leadingFailure ? [] : [.awaitingNextSegment]))
    #expect(snapshot.progress.completedCount == (leadingFailure ? 0 : 1))
    #expect(snapshot.progress.failedCount == 1)
    #expect(snapshot.progress.pendingCount == 2)
    #expect(await provider.boundaryRequests.isEmpty)
    #expect(await provider.priorityRequests.isEmpty)

    let failedIDs = objects.filter { $0["event_type"] as? String == "asr.failed" }
        .compactMap { $0["segment_id"] as? String }
    #expect(failedIDs == [leadingFailure ? "seg_1" : "seg_2"])
    let completedIDs = objects.filter { $0["event_type"] as? String == "asr.completed" }
        .compactMap { $0["segment_id"] as? String }
    #expect(completedIDs == (leadingFailure ? [] : ["seg_1"]))
    let pendingBoundaries = objects.filter { $0["event_type"] as? String == ClauseEventType.boundaryPending }
    #expect(pendingBoundaries.isEmpty)
    let completedDecisionRuns = objects.filter { $0["event_type"] as? String == "processing.run.completed" }
        .filter {
            let stage = ($0["payload"] as? [String: Any])?["stage"] as? String
            return stage == ProcessingStage.clauseBoundary.rawValue || stage == ProcessingStage.contentPriority.rawValue
        }
    #expect(completedDecisionRuns.isEmpty)
}

@Test(.timeLimit(.minutes(10)))
func decisionRecoveryWaitsForTheMissingSuccessorWithoutRepeatingSavedRequests() async throws {
    let provider = LiveProvider(continuing: ["seg_1", "seg_2"], fillerRanges: [])
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(
        texts: ["うん。続く", "本文", "です。", ""],
        makeDecisions: { decisions }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try await fixture.recognize(0)
    try await fixture.recognize(1)
    try await fixture.recorder.wait { $0.first?.clauseSlices.first?.priority == .lowPriority }
    #expect(await provider.priorityRequests == [["うん。"]])
    let firstObjects = try fixture.eventObjects(from: await fixture.eventLog())
    #expect(firstObjects.filter { $0["event_type"] as? String == ClauseEventType.boundaryAssessed }.count == 1
        && firstObjects.filter { $0["event_type"] as? String == ClauseEventType.priorityAssigned }.count == 1)

    _ = try await fixture.asr.register(segments: [fixture.segments[2]])
    try await fixture.priority.observe(snapshot: await fixture.asr.snapshot())
    await fixture.priority.worker?.value
    await fixture.priority.stop()
    let eventsURL = fixture.root.appending(path: "events.jsonl")
    let logBeforeRecovery = try SessionWriter.readDurableLog(eventsURL: eventsURL)

    let writer = try SessionWriter(sessionURL: fixture.root)
    let reopenedASR = try await LiveASRSession.open(
        sessionID: fixture.sessionID, sessionURL: fixture.root, writer: writer, asr: ScriptedASR(["です。", ""])
    )
    let recorder = fixture.recorder
    let onStatus: LiveContentPrioritySession.StatusHandler = { await recorder.record(status: $0) }
    let onUpdate: LiveContentPrioritySession.UpdateHandler = { await recorder.record($0.progress.materializedSegments) }
    let reopened = try await LiveContentPrioritySession.open(
        sessionID: fixture.sessionID,
        writer: writer, liveASR: reopenedASR, makeDecisions: { decisions }, usageCounter: counter,
        onStatus: onStatus, onUpdate: onUpdate
    )
    await reopened.worker?.value
    let recoveredSnapshot = await reopenedASR.snapshot()
    #expect(recoveredSnapshot.segments.last?.outcome == LiveASRSegmentStatus.Outcome.pending)
    let recoveredRows = try LiveTranscriptProjection().rows(for: recoveredSnapshot.progress.materializedSegments)
    #expect(recoveredRows.first?.text == "続く")
    #expect(recoveredSnapshot.progress.materializedSegments.first?.clauseSlices.first?.priority == .lowPriority)
    await #expect(throws: LiveContentPriorityError.self) {
        try await reopened.finishInput(snapshot: recoveredSnapshot)
    }
    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["seg_1"])
    #expect(await provider.priorityRequests == [["うん。"]])
    #expect(try SessionWriter.readDurableLog(eventsURL: eventsURL) == logBeforeRecovery)

    let notify: @Sendable (LiveASRSegmentStatus, LiveASRSnapshot) async -> Void = { status, snapshot in
        await recorder.record(snapshot.progress.materializedSegments)
        do {
            switch status.outcome {
            case .recognized(let source, _):
                try await reopened.enqueue(source: source, snapshot: snapshot, onStatus: onStatus, onUpdate: onUpdate)
            case .pending, .failed:
                try await reopened.observe(snapshot: snapshot)
            }
        } catch {
            await recorder.record(failure: "ライブ判定の状態記録に失敗しました: \(error.localizedDescription)")
        }
    }

    _ = try await reopenedASR.process(segments: [], checkpoint: fixture.checkpoint, onSegmentFinished: notify,
                                       shouldPause: { _ in nil })
    await reopened.worker?.value
    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["seg_1", "seg_2"])
    #expect(await provider.boundaryRequests.map { $0.next?.text } == ["本文", "です。"])
    #expect(await provider.priorityRequests == [["うん。"]])
    let afterThird = try fixture.eventObjects(from: SessionWriter.readDurableLog(eventsURL: eventsURL))
    #expect(afterThird.allSatisfy { $0["event_type"] as? String != "processing.run.completed" })

    _ = try await reopenedASR.register(segments: [fixture.segments[3]])
    try await reopened.observe(snapshot: await reopenedASR.snapshot())
    await reopened.worker?.value
    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["seg_1", "seg_2"])
    #expect(await provider.priorityRequests == [["うん。"]])
    _ = try await reopenedASR.process(segments: [], checkpoint: fixture.checkpoint, onSegmentFinished: notify,
                                       shouldPause: { _ in nil })
    await reopened.worker?.value
    try await recorder.throwIfFailed()
    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["seg_1", "seg_2", "seg_3"])
    #expect(await provider.boundaryRequests.map { $0.next?.text } == ["本文", "です。", nil])
    #expect(await provider.priorityRequests == [["うん。"], ["続く本文です。"]])

    let beforeFinishObjects = try fixture.eventObjects(from: SessionWriter.readDurableLog(eventsURL: eventsURL))
    #expect(beforeFinishObjects.allSatisfy { $0["event_type"] as? String != "processing.run.completed" })

    try await reopened.finishInput(snapshot: await reopenedASR.snapshot())
    await reopened.worker?.value
    let finalLog = try SessionWriter.readDurableLog(eventsURL: fixture.root.appending(path: "events.jsonl"))
    let finalObjects = try fixture.eventObjects(from: finalLog)
    let decisionRunIDs: Set<String> = ["boundary_live", "priority_live"]
    let decisionRuns: (String) -> [[String: Any]] = { eventType in
        finalObjects.filter { object in
            guard let runID = object["processing_run_id"] as? String else { return false }
            return object["event_type"] as? String == eventType && decisionRunIDs.contains(runID)
        }
    }
    let starts = decisionRuns("processing.run.started")
    let completions = decisionRuns("processing.run.completed")
    #expect(starts.count == 2 && completions.count == 2)
    #expect(Set(starts.compactMap { $0["processing_run_id"] as? String }) == decisionRunIDs
        && Set(completions.compactMap { $0["processing_run_id"] as? String }) == decisionRunIDs)
}

private struct InitializationFailure: LocalizedError {
    var errorDescription: String? { "モデルを読み込めません" }
}

@Test(.timeLimit(.minutes(10)))
func initializationErrorIsShownAndRecordingRowsStayVisible() async throws {
    let counter = DecisionUsageCounter()
    let fixture = try await LiveDecisionFixture(texts: ["一つ目"], makeDecisions: { throw InitializationFailure() }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try await fixture.recognize(0)
    try await fixture.priority.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.recorder.wait { $0.map(\.clauseState) == [.boundaryPending] }

    #expect(await fixture.recorder.statuses.last?.contains("モデルを読み込めません") == true)
    let log = try await fixture.eventLog()
    let objects = try fixture.eventObjects(from: log)
    let reasons = objects.filter { $0["event_type"] as? String == "clause_boundaries.pending" }
        .compactMap { ($0["payload"] as? [String: Any])?["reason"] as? String }
    #expect(reasons == ["initialization_failed"])
    await fixture.priority.worker?.value
}

@Test(.timeLimit(.minutes(10)))
func emptySuccessfulASREndsTheTextStreamWithoutSkippingToAFutureHead() async throws {
    let provider = LiveProvider(continuing: [], fillerRanges: [])
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(texts: ["前の本文", "", "後の本文"], makeDecisions: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    for index in fixture.segments.indices { try await fixture.recognize(index) }
    try await fixture.priority.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.recorder.wait { $0.filter(\.hasRecognizedText).map(\.clauseState) == [.classified, .classified] }

    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["seg_1", "seg_3"])
    #expect(await provider.priorityRequests == [["前の本文"], ["後の本文"]])
    let log = try await fixture.eventLog()
    let objects = try fixture.eventObjects(from: log)
    let raw = objects.filter { $0["event_type"] as? String == "asr.completed" }
        .compactMap { ($0["payload"] as? [String: Any])?["text"] as? String }
    #expect(raw == ["前の本文", "", "後の本文"])
    let clauses = objects.filter { $0["event_type"] as? String == "clauses.closed" }
    #expect(clauses.allSatisfy { object in
        let payload = object["payload"] as? [String: Any]
        return (payload?["termination"] as? [String: Any])?["kind"] as? String == "stream_end"
    })
    let usage = await counter.snapshot()
    #expect(usage.boundaryRequests.sendCount == 2)
    #expect(usage.priorityRequests.sendCount == 2)
    await fixture.priority.worker?.value
}

@Test(.timeLimit(.minutes(10)))
func livePrioritySaveFailureKeepsPreviouslyDurableClassificationAndNewTextVisible() async throws {
    let provider = LiveProvider(continuing: [], fillerRanges: [], holdPriorityNumber: 2)
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(
        texts: ["うん。", "新しい本文。", "続き"], makeDecisions: { decisions }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    for index in fixture.segments.indices { try await fixture.recognize(index) }
    try await provider.waitForPriorities(2)
    try await fixture.recorder.wait { $0.map(\.clauseState) == [.classified, .priorityPending, .awaitingNextSegment] }

    let eventsURL = fixture.root.appending(path: "events.jsonl")
    let savedURL = fixture.root.appending(path: "saved-events.jsonl")
    let worker = try #require(await fixture.priority.worker)
    try FileManager.default.moveItem(at: eventsURL, to: savedURL)
    try FileManager.default.createDirectory(at: eventsURL, withIntermediateDirectories: false)
    await provider.release()
    try await fixture.recorder.waitForStatus { $0.contains("判定を保存できませんでした") }
    await worker.value
    try FileManager.default.removeItem(at: eventsURL)
    try FileManager.default.moveItem(at: savedURL, to: eventsURL)

    let rows = try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)
    #expect(rows.map(\.text) == ["新しい本文。", "続き"])
    let log = try await fixture.eventLog()
    let objects = try fixture.eventObjects(from: log)
    let assignments = objects.filter { $0["event_type"] as? String == "content_priority.assigned" }
    #expect(assignments.count == 1)
    #expect(await counter.snapshot().priorityRequests.successCount == 2)
    #expect(await counter.snapshot().priorityRequests.failureCount == 0)
}

@Test(.timeLimit(.minutes(10)))
func savedLowSliceStaysRemovedWhileItsContinuationWaitsForPriority() async throws {
    let provider = LiveProvider(continuing: ["seg_1"], fillerRanges: [], holdPriorityNumber: 2)
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(
        texts: ["うん。続く", "本文。", "次"],
        makeDecisions: { decisions }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.recognize(0)
    let saved = try #require(await fixture.recorder.updates.first)
    #expect(try LiveTranscriptProjection().rows(for: saved).map(\.text) == ["うん。続く"])
    try await fixture.recognize(1)
    try await fixture.recorder.wait { $0.first?.clauseSlices.first?.priority == .lowPriority }
    let awaiting = try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)
    #expect(awaiting[0].clauseState == .awaitingNextSegment)
    #expect(awaiting[0].text == "続く")

    try await fixture.recognize(2)
    try await provider.waitForPriorities(2)
    try await fixture.recorder.wait { $0.first?.clauseState == .priorityPending }
    let pending = try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)
    #expect(pending[0].text == "続く")
    await provider.release()
    try await fixture.recorder.wait { $0.first?.clauseState == .classified }
    #expect(try LiveTranscriptProjection().rows(for: await fixture.recorder.latest)[0].text == "続く")
    await fixture.priority.worker?.value
    await fixture.priority.stop()
}

private actor FailingPriorityProvider: DecisionProvider {
    private(set) var prioritySizes: [Int] = []
    private(set) var boundaryCount = 0

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        boundaryCount += 1
        return ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.9) }),
            continuationProbability: request.next.map { _ in 0.1 },
            fillerRanges: [],
            inputTokens: 1
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        prioritySizes.append(targets.count)
        throw DecisionResponseError.missingAnswer
    }
}

@Test(.timeLimit(.minutes(10)))
func everyFailedLivePriorityBatchIsPendingOnItsOwn() async throws {
    let provider = FailingPriorityProvider()
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let raw = (1...81).map { "本文\($0)。" }.joined()
    let fixture = try await LiveDecisionFixture(texts: [raw, "後続"], makeDecisions: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.recognize(0)
    try await fixture.recognize(1)
    try await fixture.priority.finishInput(snapshot: await fixture.asr.snapshot())
    let log = try await fixture.waitForDecisionCompletion()
    let objects = try fixture.eventObjects(from: log)
    let assigned = objects.filter { $0["event_type"] as? String == ClauseEventType.priorityAssigned }
    let payloads = try assigned.map { try #require($0["payload"] as? [String: Any]) }
    #expect(payloads.map { ($0["assignments"] as? [Any])?.count } == [40, 40, 1, 1])
    #expect(payloads.allSatisfy { $0["request"] is NSNull })
    #expect(await provider.prioritySizes == [40, 40, 1, 1])
    #expect(await provider.boundaryCount == 2)
    #expect(await counter.snapshot().boundaryRequests.sendCount == 2)
    #expect(await counter.snapshot().boundaryRequests.successCount == 2)
    let assignments = try payloads.flatMap { try #require($0["assignments"] as? [[String: Any]]) }
    #expect(assignments.allSatisfy {
        ($0["decision"] as? [String: Any])?["reason"] as? String
            == "request_failed"
    })
    #expect(objects.filter { $0["event_type"] as? String == ClauseEventType.boundaryPending }.isEmpty)
    #expect(await counter.snapshot().priorityRequests.sendCount == 4)
    #expect(await counter.snapshot().priorityRequests.failureCount == 4)
    #expect(await counter.snapshot().pendingPriorityClauseCount == 82)
    #expect(await counter.snapshot().pendingBoundarySegmentCount == 0)
    let row = try #require(try LiveTranscriptProjection().rows(for: await fixture.recorder.latest).first)
    #expect(row.text == raw)
    #expect(row.clauseState == .priorityPending)
    await fixture.priority.worker?.value
    await fixture.priority.stop()
}

private struct FixedResponseProvider: DecisionProvider {
    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.99) }),
            continuationProbability: request.next.map { _ in 0.01 },
            fillerRanges: [],
            inputTokens: 11
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        let decisions = try Dictionary(uniqueKeysWithValues: targets.map { target in
            (target.key, try ContentPriorityDecision(
                priority: .primary, confidence: 0.98,
                probabilities: ["PRIMARY": 0.99, "LOW_PRIORITY": 0.01]
            ))
        })
        return PriorityBatchResponse(decisions: decisions, inputTokens: 17)
    }
}

/// Boundaries after `。`, continuation for the listed segments, PRIMARY for every clause; named results
/// can be made to fail, and failures can be switched off to model a later retry.
private actor RetryProvider: DecisionProvider {
    private let continuing: Set<String>
    private var failingBoundarySegments: Set<String>
    private var failsPriority: Bool
    private(set) var boundarySegmentIDs: [String] = []
    private(set) var priorityTexts: [[String]] = []

    init(continuing: Set<String> = [], failingBoundarySegments: Set<String> = [], failsPriority: Bool = false) {
        self.continuing = continuing
        self.failingBoundarySegments = failingBoundarySegments
        self.failsPriority = failsPriority
    }

    private var answersNaN = false

    func recover() {
        failingBoundarySegments = []
        failsPriority = false
    }

    /// Replaces the error answers with a response whose probabilities are NaN.
    func answerWithNaN() {
        failingBoundarySegments = []
        answersNaN = true
    }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        boundarySegmentIDs.append(request.source.segmentID)
        if failingBoundarySegments.contains(request.source.segmentID) { throw DecisionResponseError.missingAnswer }
        return ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, answersNaN ? Double.nan : 0.9) }),
            continuationProbability: request.next.map { _ in continuing.contains(request.source.segmentID) ? 0.9 : 0.1 },
            fillerRanges: [], inputTokens: 3
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        priorityTexts.append(targets.map(\.text))
        if failsPriority { throw DecisionResponseError.missingAnswer }
        let decision = try ContentPriorityDecision(
            priority: .primary, confidence: 0.95, probabilities: ["PRIMARY": 0.975, "LOW_PRIORITY": 0.025]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, decision) }), inputTokens: 7
        )
    }
}

/// A finished live decision pair for `texts`, and the saved log a retry reads.
private func finishedDecisions(
    texts: [String], provider: RetryProvider
) async throws -> (fixture: LiveDecisionFixture, stored: StoredTranscriptEvents) {
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(texts: texts, makeDecisions: { decisions }, counter: counter)
    for index in texts.indices { try await fixture.recognize(index) }
    try await fixture.priority.finishInput(snapshot: await fixture.asr.snapshot())
    try await fixture.priority.waitForDrain()
    return (fixture, try savedDecisions(fixture))
}

private func savedDecisions(_ fixture: LiveDecisionFixture) throws -> StoredTranscriptEvents {
    try #require(try EventLogTranscriptReader().read(
        eventsURL: fixture.root.appending(path: "events.jsonl"), sessionID: fixture.sessionID
    ))
}

/// What a retry does: a replacement pair over the saved ASR results, then the event selecting it.
private func replaceDecisions(
    _ fixture: LiveDecisionFixture, stored: StoredTranscriptEvents, provider: RetryProvider,
    boundaryTargets: Set<SegmentTextReference>, clauseTargets: Set<ClauseReference>, select: Bool = true
) async throws -> (session: LiveContentPrioritySession, boundaryRunID: String, priorityRunID: String) {
    let suffix = UUID().uuidString.lowercased()
    let keepsBoundaryRun = boundaryTargets.isEmpty
    let boundaryRunID = keepsBoundaryRun ? try #require(stored.state.runs.clauseBoundary) : "boundary_\(suffix)"
    let priorityRunID = "priority_\(suffix)"
    let source = try StoredTranscriptSource(state: stored.state, boundaryRunID: boundaryRunID, priorityRunID: priorityRunID)
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let writer = try SessionWriter(sessionURL: fixture.root)
    let session = try await LiveContentPrioritySession.openReplacement(
        sessionID: fixture.sessionID, writer: writer, source: source,
        plan: ReplacementPlan(
            boundaryRunID: boundaryRunID, priorityRunID: priorityRunID,
            boundaryTargets: boundaryTargets, clauseTargets: clauseTargets,
            carry: ReplacementCarry(events: stored.events, runs: stored.state.runs),
            keepsBoundaryRun: keepsBoundaryRun
        ),
        makeDecisions: { decisions }, usageCounter: counter, onStatus: { _ in }, onUpdate: { _ in }
    )
    try await session.replace(snapshot: await source.snapshot())
    if select {
        try await writer.append(DecisionRunReplacement(
            generationID: stored.state.generation.id,
            previous: DecisionRunIDs(
                boundary: try #require(stored.state.runs.clauseBoundary),
                priority: try #require(stored.state.runs.contentPriority)
            ),
            replacement: DecisionRunIDs(boundary: boundaryRunID, priority: priorityRunID)
        ).selectionEvent(sessionID: fixture.sessionID))
    }
    return (session, boundaryRunID, priorityRunID)
}

private func runEvents(_ fixture: LiveDecisionFixture, _ runID: String) throws -> [[String: Any]] {
    try SessionRecovery.recoverJSONL(Data(contentsOf: fixture.root.appending(path: "events.jsonl"))).lines
        .map { try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        .filter { $0["processing_run_id"] as? String == runID }
}

@Test(.timeLimit(.minutes(10)))
func stopRetainsSavedDecisionsAndProcessesOnlyRemainingTargets() async throws {
    let provider = LiveProvider(continuing: [], fillerRanges: [])
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await LiveDecisionFixture(texts: ["一。二。", "三。"], makeDecisions: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.recognize(0)
    try await fixture.recognize(1)
    // Recording stopped here: the first segment's decisions are saved, the last one still waits for its successor.
    let firstWorker = await fixture.priority.worker
    await firstWorker?.value
    await fixture.priority.stop()
    let savedBeforeStop = try fixture.eventObjects(from: await fixture.eventLog())
    #expect(savedBeforeStop.filter { $0["event_type"] as? String == ClauseEventType.priorityAssigned }.count == 1)
    #expect(await provider.priorityRequests == [["一。", "二。"]])

    let writer = try SessionWriter(sessionURL: fixture.root)
    let reopenedASR = try await LiveASRSession.open(
        sessionID: fixture.sessionID, sessionURL: fixture.root, writer: writer, asr: ScriptedASR([])
    )
    let reopened = try await LiveContentPrioritySession.open(
        sessionID: fixture.sessionID, writer: writer, liveASR: reopenedASR,
        makeDecisions: { decisions }, usageCounter: counter, onStatus: { _ in }, onUpdate: { _ in }
    )
    try await reopened.finishInput(snapshot: await reopenedASR.snapshot())
    try await reopened.waitForDrain()

    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["seg_1", "seg_2"])
    #expect(await provider.priorityRequests == [["一。", "二。"], ["三。"]])
    let stored = try savedDecisions(fixture)
    #expect(stored.pendingDecisions.pendingTargets.isEmpty)
    let objects = try fixture.eventObjects(from: await fixture.eventLog())
    #expect(objects.filter { $0["event_type"] as? String == ClauseEventType.priorityAssigned }.count == 2)
    #expect(objects.filter {
        $0["event_type"] as? String == "processing.run.completed"
            && ($0["payload"] as? [String: Any])?["stage"] as? String == "contentPriority"
    }.count == 1)
}

@Test(.timeLimit(.minutes(10)))
func aPriorityRetryRequestsOnlyItsTargetsKeepsTheBoundaryRunAndCarriesTheRest() async throws {
    let provider = RetryProvider(failsPriority: true)
    let (fixture, stored) = try await finishedDecisions(texts: ["一。二。三"], provider: provider)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = stored.pendingDecisions.clauses
    #expect(pending.count == 3)
    let boundaryRunID = try #require(stored.state.runs.clauseBoundary)
    let boundaryEventCount = try runEvents(fixture, boundaryRunID).count
    await provider.recover()
    let requestsBefore = await provider.priorityTexts.count

    let retry = try await replaceDecisions(
        fixture, stored: stored, provider: provider, boundaryTargets: [], clauseTargets: [pending[1]]
    )

    #expect(await provider.boundarySegmentIDs == ["seg_1"])
    #expect(await provider.priorityTexts.dropFirst(requestsBefore).map { $0 } == [["二。"]])
    #expect(retry.boundaryRunID == boundaryRunID)
    #expect(try runEvents(fixture, boundaryRunID).count == boundaryEventCount)
    let after = try savedDecisions(fixture)
    #expect(after.state.runs.contentPriority == retry.priorityRunID)
    // Pending results that were not requested stay pending; they are never turned into results.
    #expect(after.pendingDecisions.clauses == [pending[0], pending[2]])
    let rows = try TranscriptMaterializer(sampleRate: after.state.generation.sampleRate)
        .materialize(events: after.events, activeRuns: after.state.runs)
    #expect(rows.first?.clauseSlices.map(\.needsRetry) == [true, false, true])
    // A reopened decision session would resume the generation's first pair, not the selected one.
    #expect(throws: (any Error).self) {
        try DecisionSessionRecovery(eventsURL: fixture.root.appending(path: "events.jsonl"), sessionID: fixture.sessionID)
    }
}

@Test(.timeLimit(.minutes(10)))
func aBoundaryRetryCarriesSavedAssessmentsAndRequestsOnlyThePendingSource() async throws {
    let provider = RetryProvider(continuing: ["seg_1", "seg_2"], failingBoundarySegments: ["seg_2"])
    let (fixture, stored) = try await finishedDecisions(texts: ["前。続く", "途中", "終わり。後"], provider: provider)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = stored.pendingDecisions.boundarySegments
    #expect(pending.map(\.segmentID) == ["seg_2"])
    await provider.recover()
    let boundaryRequestsBefore = await provider.boundarySegmentIDs.count
    let priorityRequestsBefore = await provider.priorityTexts.count

    let retry = try await replaceDecisions(
        fixture, stored: stored, provider: provider, boundaryTargets: Set(pending), clauseTargets: []
    )

    #expect(await provider.boundarySegmentIDs.dropFirst(boundaryRequestsBefore).map { $0 } == ["seg_2"])
    // Clauses that do not touch the re-requested source keep their saved priority.
    let requested = await provider.priorityTexts.dropFirst(priorityRequestsBefore).flatMap { $0 }
    #expect(requested.allSatisfy { $0.contains("途中") })
    #expect(!requested.isEmpty)
    let kinds = try runEvents(fixture, retry.boundaryRunID)
        .filter { $0["event_type"] as? String == ClauseEventType.boundaryAssessed }
        .compactMap { (($0["payload"] as? [String: Any])?["source_decision"] as? [String: Any])?["kind"] as? String }
    #expect(kinds == ["carried_over", "assessed", "carried_over"])
    let after = try savedDecisions(fixture)
    #expect(after.pendingDecisions.pendingTargets.isEmpty)
    #expect(after.state.runs.clauseBoundary == retry.boundaryRunID)
}

@Test(.timeLimit(.minutes(10)))
func aFailedRetryEndsItsStartedRunsAndSelectsNothing() async throws {
    let provider = RetryProvider(failsPriority: true)
    let (fixture, stored) = try await finishedDecisions(texts: ["一。二。三"], provider: provider)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = stored.pendingDecisions.clauses
    let writer = try SessionWriter(sessionURL: fixture.root)
    let source = try StoredTranscriptSource(
        state: stored.state, boundaryRunID: try #require(stored.state.runs.clauseBoundary), priorityRunID: "priority_x"
    )
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let session = try await LiveContentPrioritySession.openReplacement(
        sessionID: fixture.sessionID, writer: writer, source: source,
        plan: ReplacementPlan(
            boundaryRunID: try #require(stored.state.runs.clauseBoundary), priorityRunID: "priority_x",
            boundaryTargets: [], clauseTargets: Set(pending),
            carry: ReplacementCarry(events: stored.events, runs: stored.state.runs), keepsBoundaryRun: true
        ),
        makeDecisions: { decisions }, usageCounter: counter, onStatus: { _ in }, onUpdate: { _ in }
    )
    do {
        try await session.replace(snapshot: await source.snapshot())
        Issue.record("a retry whose request fails must not complete")
    } catch {
        #expect(try await session.recordFailure(originalError: error))
    }

    let events = try runEvents(fixture, "priority_x")
    #expect(events.filter { $0["event_type"] as? String == "processing.run.started" }.count == 1)
    #expect(!events.contains { $0["event_type"] as? String == ClauseEventType.priorityAssigned })
    let completion = try #require(events.first { $0["event_type"] as? String == "processing.run.completed" }?["payload"] as? [String: Any])
    #expect(completion["succeeded"] as? Bool == false)
    // The three clauses of the failed request count as failed.
    #expect(completion["completed_count"] as? Int == 0)
    #expect(completion["failed_count"] as? Int == 3)
    #expect(try !DecisionRetryAnalyzer().hasUnpublishedDecisionRun(
        lines: SessionRecovery.recoverJSONL(Data(contentsOf: fixture.root.appending(path: "events.jsonl"))).lines,
        sessionID: fixture.sessionID
    ))
    #expect(try savedDecisions(fixture).state.runs == stored.state.runs)
}

@Test(.timeLimit(.minutes(10)), arguments: [false, true])
func aFailedBoundaryRequestCountsAsFailedAndSelectsNothing(malformedProbability: Bool) async throws {
    let provider = RetryProvider(failingBoundarySegments: ["seg_1"])
    let (fixture, stored) = try await finishedDecisions(texts: ["前。後"], provider: provider)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = stored.pendingDecisions.boundarySegments
    #expect(pending.count == 1)
    // The retry's answer is either an error or a response with a NaN probability.
    if malformedProbability { await provider.answerWithNaN() }
    let source = try StoredTranscriptSource(state: stored.state, boundaryRunID: "boundary_x", priorityRunID: "priority_x")
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let session = try await LiveContentPrioritySession.openReplacement(
        sessionID: fixture.sessionID, writer: try SessionWriter(sessionURL: fixture.root), source: source,
        plan: ReplacementPlan(
            boundaryRunID: "boundary_x", priorityRunID: "priority_x", boundaryTargets: Set(pending), clauseTargets: [],
            carry: ReplacementCarry(events: stored.events, runs: stored.state.runs), keepsBoundaryRun: false
        ),
        makeDecisions: { decisions }, usageCounter: counter, onStatus: { _ in }, onUpdate: { _ in }
    )

    do {
        try await session.replace(snapshot: await source.snapshot())
        Issue.record("a retry whose request fails must not complete")
    } catch {
        #expect(try await session.recordFailure(originalError: error))
    }

    let completions = try runEvents(fixture, "boundary_x").filter { $0["event_type"] as? String == "processing.run.completed" }
    let payload = try #require(completions.first?["payload"] as? [String: Any])
    #expect(completions.count == 1 && payload["succeeded"] as? Bool == false)
    #expect(payload["failed_count"] as? Int == 1)
}

@Test(.timeLimit(.minutes(10)))
func aCarriedPriorityIsRejectedOnReloadWhenItsOriginHasOtherParts() async throws {
    let provider = RetryProvider()
    // Two clauses with identical text and different parts.
    let (fixture, stored) = try await finishedDecisions(texts: ["あ。", "あ。"], provider: provider)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let retry = try await replaceDecisions(fixture, stored: stored, provider: provider, boundaryTargets: [], clauseTargets: [])
    let eventsURL = fixture.root.appending(path: "events.jsonl")
    _ = try #require(try EventLogTranscriptReader().read(eventsURL: eventsURL, sessionID: fixture.sessionID))

    var lines = try SessionRecovery.recoverJSONL(Data(contentsOf: eventsURL)).lines
    let index = try #require(lines.firstIndex { line in
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        return object?["event_type"] as? String == ClauseEventType.priorityAssigned
            && object?["processing_run_id"] as? String == retry.priorityRunID
    })
    var object = try #require(try JSONSerialization.jsonObject(with: lines[index]) as? [String: Any])
    var payload = try #require(object["payload"] as? [String: Any])
    var assignments = try #require(payload["assignments"] as? [[String: Any]])
    try #require(assignments.count == 2)
    assignments[1]["decision"] = assignments[0]["decision"]
    payload["assignments"] = assignments
    object["payload"] = payload
    lines[index] = try JSONSerialization.data(withJSONObject: object)
    try lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }.write(to: eventsURL)

    #expect(throws: (any Error).self) {
        try EventLogTranscriptReader().read(eventsURL: eventsURL, sessionID: fixture.sessionID)
    }
}

@Test(.timeLimit(.minutes(10)))
func aSecondSelectionFromTheSamePreflightStateFailsAndWritesNothing() async throws {
    let provider = RetryProvider(failsPriority: true)
    let (fixture, stored) = try await finishedDecisions(texts: ["一。二"], provider: provider)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    await provider.recover()
    let pending = Set(stored.pendingDecisions.clauses)
    let first = try await replaceDecisions(
        fixture, stored: stored, provider: provider, boundaryTargets: [], clauseTargets: pending, select: false
    )
    let second = try await replaceDecisions(
        fixture, stored: stored, provider: provider, boundaryTargets: [], clauseTargets: pending, select: false
    )
    let previous = DecisionRunIDs(
        boundary: try #require(stored.state.runs.clauseBoundary), priority: try #require(stored.state.runs.contentPriority)
    )
    func selection(_ run: (session: LiveContentPrioritySession, boundaryRunID: String, priorityRunID: String)) -> DecisionRunReplacement {
        DecisionRunReplacement(
            generationID: stored.state.generation.id, previous: previous,
            replacement: DecisionRunIDs(boundary: run.boundaryRunID, priority: run.priorityRunID)
        )
    }
    let writer = try SessionWriter(sessionURL: fixture.root)
    try await writer.appendSelection(selection(first), sessionID: fixture.sessionID)
    let eventsURL = fixture.root.appending(path: "events.jsonl")
    let logAfterFirst = try Data(contentsOf: eventsURL)

    await #expect(throws: DecisionEnrichmentError.selectionConflict) {
        try await writer.appendSelection(selection(second), sessionID: fixture.sessionID)
    }

    #expect(try Data(contentsOf: eventsURL) == logAfterFirst)
    #expect(try savedDecisions(fixture).state.runs.contentPriority == first.priorityRunID)
}

/// Appends every event, and fails after the first `processing.run.completed` has reached the log.
private actor CompletionThrowingWriter: DecisionEventWriting {
    struct AmbiguousWrite: Error {}
    private let writer: SessionWriter
    nonisolated let eventsURL: URL
    private var thrown = false

    init(writer: SessionWriter, eventsURL: URL) {
        self.writer = writer
        self.eventsURL = eventsURL
    }

    func append<Payload: Codable & Sendable>(_ draft: EventDraft<Payload>) async throws -> EventEnvelope<Payload> {
        let envelope = try await writer.append(draft)
        if draft.eventType == "processing.run.completed", !thrown {
            thrown = true
            throw AmbiguousWrite()
        }
        return envelope
    }

    func appendSelection(_ selection: DecisionRunReplacement, sessionID: UUID) async throws {
        try await writer.appendSelection(selection, sessionID: sessionID)
    }

    func appendFailedRetryCompletion(
        _ draft: EventDraft<ProcessingRunCompletedPayload>
    ) async throws -> EventEnvelope<ProcessingRunCompletedPayload> {
        try await writer.appendFailedRetryCompletion(draft)
    }
}

@Test(.timeLimit(.minutes(10)))
func aCompletionWriteThatFailsAfterReachingTheLogIsNeverWrittenTwice() async throws {
    let provider = RetryProvider(failsPriority: true)
    let (fixture, stored) = try await finishedDecisions(texts: ["一。二"], provider: provider)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    await provider.recover()
    let writer = try SessionWriter(sessionURL: fixture.root)
    let source = try StoredTranscriptSource(
        state: stored.state, boundaryRunID: try #require(stored.state.runs.clauseBoundary), priorityRunID: "priority_x"
    )
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let session = try await LiveContentPrioritySession.openReplacement(
        sessionID: fixture.sessionID, writer: CompletionThrowingWriter(writer: writer, eventsURL: writer.eventsURL),
        source: source,
        plan: ReplacementPlan(
            boundaryRunID: try #require(stored.state.runs.clauseBoundary), priorityRunID: "priority_x",
            boundaryTargets: [], clauseTargets: Set(stored.pendingDecisions.clauses),
            carry: ReplacementCarry(events: stored.events, runs: stored.state.runs), keepsBoundaryRun: true
        ),
        makeDecisions: { decisions }, usageCounter: counter, onStatus: { _ in }, onUpdate: { _ in }
    )

    do {
        try await session.replace(snapshot: await source.snapshot())
        Issue.record("the failing completion write must surface")
    } catch {
        let wroteAnotherCompletion = try await session.recordFailure(originalError: error)
        #expect(!wroteAnotherCompletion)
    }

    let completions = try runEvents(fixture, "priority_x").filter { $0["event_type"] as? String == "processing.run.completed" }
    #expect(completions.count == 1)
    // The unselected, once-completed run is what recovery rebuilds from; a second completion would block it.
    #expect(try DecisionRetryAnalyzer().hasUnpublishedDecisionRun(
        lines: SessionRecovery.recoverJSONL(Data(contentsOf: fixture.root.appending(path: "events.jsonl"))).lines,
        sessionID: fixture.sessionID
    ))
}
