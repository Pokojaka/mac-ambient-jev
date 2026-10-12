import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private struct NativeLiveFixtureWaitError: Error {
    let message: String
}

private actor LiveUpdateRecorder {
    private var segments: [MaterializedTranscriptSegment] = []
    private(set) var history: [[MaterializedTranscriptSegment]] = []

    func record(_ value: [MaterializedTranscriptSegment]) {
        segments = value
        history.append(value)
    }

    func snapshot() -> [MaterializedTranscriptSegment] {
        segments
    }

    func waitFor(_ condition: @escaping @Sendable ([MaterializedTranscriptSegment]) -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(segments) {
            guard ContinuousClock.now < deadline else {
                throw NativeLiveFixtureWaitError(message: "Timed out waiting for live rows: \(segments)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor StubLiveProcessorASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var prepareCount = 0
    private var transcribeCount = 0

    func prepare() async throws {
        prepareCount += 1
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        transcribeCount += 1
        return ASRResult(
            text: "ライブ文字起こし\(transcribeCount)",
            detectedLanguage: "ja"
        )
    }

    func unload() async {}

    func counts() -> (prepare: Int, transcribe: Int) {
        (prepareCount, transcribeCount)
    }
}

@Test
func nativeSessionProcessorStreamsLiveSegmentsWithoutRealModel() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = AppPaths(
        applicationSupportURL: root.appending(
            path: "support",
            directoryHint: .isDirectory
        ),
        cacheURL: root.appending(
            path: "cache",
            directoryHint: .isDirectory
        ),
        sessionsRootOverride: nil
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths,
        sessionID: sessionID,
        source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let processingDirectory = sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory)

    let audioWriter = try DurableAudioWriter(directory: processingDirectory, chunkDurationSeconds: 1, sessionURL: sessionURL)
    try await audioWriter.append(
        samples: Array(repeating: Float(0.1), count: 16_000)
    )
    let checkpoint = await audioWriter.committedSnapshot()

    let asr = StubLiveProcessorASR()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            diarization: FluidOfflineDiarizationEngine(paths: paths),
            finalTranscriptVAD: FluidFinalTranscriptVADSegmenter()
        ),
        contentPriority: .disabled
    )
    let segmentationRunID = "seg_live_test"

    _ = try await processor.startLiveTranscription(
        sessionID: sessionID,
        segmentationRunID: segmentationRunID,
        sampleRate: checkpoint.sampleRate
    )

    let segments = [
        SegmentReference(
            segmentationRunID: segmentationRunID,
            segmentID: "seg_000001",
            startFrame: 0,
            endFrame: 4_000
        ),
        SegmentReference(
            segmentationRunID: segmentationRunID,
            segmentID: "seg_000002",
            startFrame: 4_000,
            endFrame: 8_000
        )
    ]

    _ = try await processor.registerLiveSegments(
        sessionID: sessionID,
        segments: segments
    )

    let recorder = LiveUpdateRecorder()
    let progress = try await processor.processLiveSegments(
        sessionID: sessionID,
        segments: segments,
        checkpoint: checkpoint,
        onStatus: nil,
        onUpdate: { segments, _ in
            await recorder.record(segments)
        }
    )

    #expect(progress.completedCount == 2)
    #expect(progress.failedCount == 0)
    #expect(progress.pendingCount == 0)
    #expect(progress.materializedSegments.map(\.text) == [
        "ライブ文字起こし1",
        "ライブ文字起こし2"
    ])
    #expect(
        await recorder.snapshot() == progress.materializedSegments
    )

    let counts = await asr.counts()
    #expect(counts.prepare == 1)
    #expect(counts.transcribe == 2)
}

private actor GatedLiveProcessorASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var release: CheckedContinuation<Void, Never>?
    private var waitingForStart: CheckedContinuation<Void, Never>?

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        waitingForStart?.resume()
        waitingForStart = nil
        await withCheckedContinuation { continuation in
            release = continuation
        }
        return ASRResult(text: "取り消し後の結果", detectedLanguage: nil)
    }

    func waitUntilTranscribing() async {
        if release != nil { return }
        await withCheckedContinuation { continuation in
            waitingForStart = continuation
        }
    }

    func resume() {
        release?.resume()
        release = nil
    }

    func unload() async {}
}

private actor UpdateCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@Test
func cancelledLiveTranscriptionDoesNotPublishInFlightResult() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let audioWriter = try DurableAudioWriter(directory: sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory), chunkDurationSeconds: 1, sessionURL: sessionURL)
    try await audioWriter.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audioWriter.committedSnapshot()
    let asr = GatedLiveProcessorASR()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            diarization: FluidOfflineDiarizationEngine(paths: paths),
            finalTranscriptVAD: FluidFinalTranscriptVADSegmenter()
        ),
        contentPriority: .disabled
    )
    _ = try await processor.startLiveTranscription(
        sessionID: sessionID, segmentationRunID: "seg_live_test",
        sampleRate: checkpoint.sampleRate
    )
    let segment = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000001",
        startFrame: 0, endFrame: 4_000
    )
    let updates = UpdateCounter()

    let processing = Task {
        try await processor.processLiveSegments(
            sessionID: sessionID, segments: [segment], checkpoint: checkpoint,
            onStatus: nil,
            onUpdate: { _, _ in await updates.increment() }
        )
    }
    await asr.waitUntilTranscribing()
    await processor.cancelLiveTranscription(sessionID: sessionID)
    await asr.resume()
    _ = try await processing.value

    #expect(await updates.count == 0)
}

private actor ScriptedLiveProcessorASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "scripted-asr", model: nil, version: "test", configuration: [:])
    private var texts: [String]
    private(set) var callCount = 0
    init(texts: [String]) { self.texts = texts }
    func prepare() async throws {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        callCount += 1
        return ASRResult(text: texts.removeFirst(), detectedLanguage: "ja")
    }
    func unload() async {}
}

private struct LiveProcessorFinalVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "fixture-vad", model: nil, version: "test", configuration: [:])
    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        [SegmentReference(segmentationRunID: runID, segmentID: "final", startFrame: 0, endFrame: 16_000)]
    }
}

private struct LiveProcessorFinalDiarizer: DiarizationEngine {
    let provenance = RunProvenance(engine: "fixture-diarizer", model: nil, version: "test", configuration: [:])
    func prepare() async throws {}
    func unload() async {}
    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] {
        [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 16_000, confidence: 0.95)]
    }
}

private actor NativeClauseProvider: DecisionProvider {
    private let holdPriorityNumber: Int?
    private let failedPriorityNumbers: Set<Int>
    private let primaryPriorityNumbers: Set<Int>
    private var gate: CheckedContinuation<Void, Never>?
    private var beforePriority: (@Sendable (Int) throws -> Void)?
    private(set) var requests: [[String]] = []

    init(holdPriorityNumber: Int?, failedPriorityNumbers: Set<Int>, primaryPriorityNumbers: Set<Int> = []) {
        self.holdPriorityNumber = holdPriorityNumber
        self.failedPriorityNumbers = failedPriorityNumbers
        self.primaryPriorityNumbers = primaryPriorityNumbers
    }

    func setBeforePriority(_ action: @escaping @Sendable (Int) throws -> Void) { beforePriority = action }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.95) }),
            continuationProbability: request.next.map { _ in 0.05 },
            metadata: try DecisionResponseMetadata(model: "native-fixture", inputTokens: 5, outputTokens: nil)
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        requests.append(targets.map(\.text))
        let number = requests.count
        if number == holdPriorityNumber {
            await withCheckedContinuation { continuation in
                gate = continuation
            }
        }
        try beforePriority?(number)
        if failedPriorityNumbers.contains(number) { throw JevClientError.httpStatus(503) }
        // A late live LOW answer must not replace the final fresh PRIMARY answer.
        let low = !primaryPriorityNumbers.contains(number) && (holdPriorityNumber == nil || number <= 2)
        let decision = try ContentPriorityDecision(
            priority: low ? .lowPriority : .primary, confidence: 0.95,
            probabilities: low ? ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975] : ["PRIMARY": 0.975, "LOW_PRIORITY": 0.025]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, decision) }),
            metadata: try DecisionResponseMetadata(model: "native-fixture", inputTokens: 7, outputTokens: nil)
        )
    }

    func waitUntilHeld() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while gate == nil {
            guard ContinuousClock.now < deadline else {
                throw NativeLiveFixtureWaitError(message: "Timed out waiting for held live priority request: \(requests)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

private struct NativeDecisionFixture {
    let root: URL
    let paths: AppPaths
    let sessionID: UUID
    let sessionURL: URL
    let checkpoint: AudioCheckpoint
    let asr: ScriptedLiveProcessorASR
    let processor: NativeSessionProcessor

    init(texts: [String], factory: @escaping NativeSessionProcessor.DecisionCoordinatorFactory, counter: DecisionUsageCounter) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        paths = AppPaths(
            applicationSupportURL: root.appending(path: "support"), cacheURL: root.appending(path: "cache"),
            sessionsRootOverride: nil
        )
        sessionID = UUID()
        sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
            paths: paths, sessionID: sessionID, source: .recording(.microphone),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let audio = try DurableAudioWriter(directory: SessionLayout(sessionURL: sessionURL).processingDirectory, chunkDurationSeconds: 1, sessionURL: sessionURL)
        try await audio.append(samples: Array(repeating: 0.1, count: 16_000))
        checkpoint = await audio.committedSnapshot()
        asr = ScriptedLiveProcessorASR(texts: texts)
        processor = NativeSessionProcessor(
            paths: paths,
            engines: SessionProcessingEngines(asr: asr, diarization: LiveProcessorFinalDiarizer(), finalTranscriptVAD: LiveProcessorFinalVAD()),
            contentPriority: .selectedEngine(factory, usageCounter: counter)
        )
    }

    func rows() throws -> [MaterializedTranscriptSegment] {
        let runs = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.activeRuns)
        let lines = try SessionRecovery.recoverJSONL(Data(contentsOf: SessionLayout(sessionURL: sessionURL).eventsURL)).lines
        return try TranscriptMaterializer(sampleRate: 16_000).materialize(
            events: try EventLogTranscriptReader().events(lines: lines, activeRuns: runs), activeRuns: runs
        )
    }
}

@Test(.timeLimit(.minutes(1)))
func nativeTakeoverFinishesWithoutWaitingForLiveNetworkAndReusesOnlyFrozenDurableAnswers() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: 2, failedPriorityNumbers: [])
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(
        texts: ["保存済み。", "遅い結果。", "", "保存済み。遅い結果。"], factory: { decisions }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.processor.startLiveTranscription(
        sessionID: fixture.sessionID, segmentationRunID: "live", sampleRate: 16_000
    )
    let liveUpdates = LiveUpdateRecorder()
    let progress = try await fixture.processor.processLiveSegments(
        sessionID: fixture.sessionID,
        segments: (0..<3).map {
            SegmentReference(segmentationRunID: "live", segmentID: "live_\($0)", startFrame: Int64($0 * 4_000), endFrame: Int64($0 * 4_000 + 3_000))
        },
        checkpoint: fixture.checkpoint, onStatus: nil,
        onUpdate: { rows, _ in await liveUpdates.record(rows) }
    )
    #expect(progress.completedCount == 3)
    try await provider.waitUntilHeld()
    try await liveUpdates.waitFor { $0.filter(\.hasRecognizedText).map(\.clauseState) == [.classified, .priorityPending] }
    let frozen = try EventLogTranscriptReader().liveContentPriorityDecisions(
        from: SessionWriter.readDurableLog(eventsURL: SessionLayout(sessionURL: fixture.sessionURL).eventsURL)
    )
    #expect(Set(frozen.keys) == [ExactClauseTextKey(text: "保存済み。")])
    let waitingRows = try LiveTranscriptProjection().rows(for: await liveUpdates.snapshot())
    #expect(waitingRows.map(\.shouldCollapseRow) == [true, false])
    #expect(waitingRows[1].textFragments == [TranscriptTextFragment(text: "遅い結果。", style: .normal)])

    let finalUpdates = LiveUpdateRecorder()
    let result = await fixture.processor.finishLiveTranscription(
        sessionID: fixture.sessionID, checkpoint: fixture.checkpoint, finalSegments: [], pacingMode: .normal,
        shouldPause: { false }, onPhase: { _ in }, onStatus: { _ in },
        onUpdate: { rows, _ in await finalUpdates.record(rows) }
    )
    // The provider is still suspended here: finalization did not drain its HTTP request.
    #expect(result.disposition == .completed)
    #expect(await provider.requests == [["保存済み。"], ["遅い結果。"], ["遅い結果。"]])
    let rows = try fixture.rows()
    #expect(rows.map(\.text) == ["保存済み。遅い結果。"])
    #expect(rows[0].clauseSlices.map(\.priority) == [.lowPriority, .primary])
    let liveCount = await liveUpdates.history.count
    await provider.release()
    try await Task.sleep(for: .milliseconds(100))
    #expect(await liveUpdates.history.count == liveCount)
    #expect(try fixture.rows() == rows)
    #expect(await finalUpdates.snapshot() == rows)
    #expect(await counter.snapshot().pendingBoundarySegmentCount == 0)
    #expect(await counter.snapshot().pendingPriorityClauseCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func cancellingUnavailableLiveDecisionsClearsItsPendingKeysWithoutAProvider() async throws {
    let counter = DecisionUsageCounter()
    let fixture = try await NativeDecisionFixture(texts: ["前の本文", "次の本文"], factory: { nil }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.processor.startLiveTranscription(
        sessionID: fixture.sessionID, segmentationRunID: "live", sampleRate: 16_000
    )
    let updates = LiveUpdateRecorder()
    _ = try await fixture.processor.processLiveSegments(
        sessionID: fixture.sessionID,
        segments: [
            SegmentReference(segmentationRunID: "live", segmentID: "a", startFrame: 0, endFrame: 4_000),
            SegmentReference(segmentationRunID: "live", segmentID: "b", startFrame: 4_000, endFrame: 8_000)
        ],
        checkpoint: fixture.checkpoint, onStatus: nil, onUpdate: { rows, _ in await updates.record(rows) }
    )
    try await updates.waitFor { $0.first?.clauseState == .boundaryPending }
    #expect(await counter.snapshot().pendingBoundarySegmentCount == 1)
    await fixture.processor.cancelLiveTranscription(sessionID: fixture.sessionID)
    #expect(await counter.snapshot().pendingBoundarySegmentCount == 0)
    #expect(await counter.snapshot().sendCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func failedAtomicDecisionPublicationLeavesTheDurableLocalDisplayAndPendingKeys() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [])
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["保存する本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let metadataURL = fixture.sessionURL.appending(path: "processing_metadata.json")
    let savedURL = fixture.sessionURL.appending(path: "saved-metadata.json")
    await provider.setBeforePriority { number in
        guard number == 1 else { return }
        try FileManager.default.moveItem(at: metadataURL, to: savedURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: false)
    }
    let updates = LiveUpdateRecorder()
    let result = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { false }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { rows, _ in await updates.record(rows) }
    )
    #expect(result.disposition == .failed)
    #expect(result.retainedTranscript == .finalized)
    try FileManager.default.removeItem(at: metadataURL)
    try FileManager.default.moveItem(at: savedURL, to: metadataURL)
    let metadata = try #require(try ProcessingMetadataStore(sessionURL: fixture.sessionURL).load())
    #expect(metadata.activeRuns?.clauseBoundary == nil)
    #expect(metadata.activeRuns?.contentPriority == nil)
    #expect(metadata.pendingClauseBoundarySegments.map(\.segmentID) == ["final"])
    let rows = try fixture.rows()
    #expect(rows.map(\.clauseState) == [.boundaryPending])
    #expect(rows[0].clauseSlices == [])
    #expect(await updates.snapshot() == rows)
    #expect(await counter.snapshot().pendingBoundarySegmentCount == 1)
    #expect(await counter.snapshot().priorityRequests.successCount == 1)
    #expect(await counter.snapshot().priorityRequests.failureCount == 0)

    // A failed optional publication left no boundary run; explicit retry still targets the
    // published local source, with a fresh worker rather than that unpublished response.
    await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: metadata.pendingClauseBoundarySegments, clauses: [],
        onStatus: { _ in }, onUpdate: { rows, _ in await updates.record(rows) }
    )
    let retried = try #require(try ProcessingMetadataStore(sessionURL: fixture.sessionURL).load())
    #expect(retried.activeRuns?.clauseBoundary != nil)
    #expect(retried.pendingDecisionTargets == [])
    #expect(try fixture.rows().first?.clauseSlices.map(\.priority) == [.lowPriority])
    #expect(await fixture.asr.callCount == 1)
    #expect(await counter.snapshot().pendingBoundarySegmentCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func targetedRetryAfterSaveFailureUsesANewWorkerAndRetainsThePublishedSnapshotUntilSuccess() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1], primaryPriorityNumbers: [2])
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["再試行する本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { false }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let store = ProcessingMetadataStore(sessionURL: fixture.sessionURL)
    let before = try #require(try store.load())
    let pending = before.pendingContentPriorityClauses
    #expect(pending.count == 1)
    let previousRows = try fixture.rows()
    let metadataURL = fixture.sessionURL.appending(path: "processing_metadata.json")
    let savedURL = fixture.sessionURL.appending(path: "saved-metadata.json")
    await provider.setBeforePriority { number in
        guard number == 2 else { return }
        try FileManager.default.moveItem(at: metadataURL, to: savedURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: false)
    }
    let updates = LiveUpdateRecorder()
    await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: pending,
        onStatus: { _ in }, onUpdate: { rows, _ in await updates.record(rows) }
    )
    try FileManager.default.removeItem(at: metadataURL)
    try FileManager.default.moveItem(at: savedURL, to: metadataURL)
    #expect(try store.load() == before)
    #expect(await updates.snapshot() == previousRows)
    struct PriorityEvent: Decodable {
        let payload: ContentPriorityAssignedPayload
    }
    let failedRetryLog = try SessionRecovery.recoverJSONL(Data(contentsOf: SessionLayout(sessionURL: fixture.sessionURL).eventsURL)).lines
    let unpublishedAssignment = try #require(try EventLogLine.decode(failedRetryLog).last {
        $0.header.eventType == ClauseEventType.priorityAssigned
    })
    let unpublishedRunID = try unpublishedAssignment.requiredRunID()
    #expect(unpublishedRunID != before.activeRuns?.contentPriority)
    let unpublishedPayload = try unpublishedAssignment.body(PriorityEvent.self).payload
    #expect(unpublishedPayload.assignments.map(\.priority) == [.primary])
    #expect(await counter.snapshot().pendingPriorityClauseCount == 1)

    await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: pending,
        onStatus: { _ in }, onUpdate: { rows, _ in await updates.record(rows) }
    )
    let after = try #require(try store.load())
    let beforeRuns = try #require(before.activeRuns)
    let afterRuns = try #require(after.activeRuns)
    #expect(afterRuns.clauseBoundary != beforeRuns.clauseBoundary)
    #expect(afterRuns.contentPriority != beforeRuns.contentPriority)
    #expect(afterRuns.contentPriority != unpublishedRunID)
    #expect(afterRuns.segmentation == beforeRuns.segmentation)
    #expect(afterRuns.asr == beforeRuns.asr)
    #expect(after.pendingDecisionTargets == [])
    let finalRows = try fixture.rows()
    #expect(finalRows.first?.clauseSlices.map(\.priority) == [.lowPriority])
    #expect(await updates.snapshot() == finalRows)
    let lines = try SessionRecovery.recoverJSONL(Data(contentsOf: SessionLayout(sessionURL: fixture.sessionURL).eventsURL)).lines
    let events = try EventLogTranscriptReader().events(lines: lines, activeRuns: afterRuns)
    let rebuiltAssessment = try #require(events.compactMap { event -> ClauseBoundaryAssessment? in
        guard case .clauseBoundaryAssessed(let assessment) = event.kind else { return nil }
        return assessment
    }.first)
    guard case .carriedOver(let sourceRunID, _) = rebuiltAssessment.sourceDecision else {
        Issue.record("The reconstructed boundary must reuse only the published boundary assessment")
        return
    }
    #expect(sourceRunID == beforeRuns.clauseBoundary)
    let finalAssignment = try #require(events.compactMap { event -> ClausePriorityAssignment? in
        guard case .contentPriorityAssigned(let payload) = event.kind else { return nil }
        return payload.assignments.first
    }.first)
    #expect(finalAssignment.reference.boundaryRunID == afterRuns.clauseBoundary)
    guard case .classified = finalAssignment.decision else {
        Issue.record("An unpublished PRIMARY response must not be carried into the rebuilt snapshot")
        return
    }
    #expect(await fixture.asr.callCount == 1)
    #expect(await provider.requests == Array(repeating: ["再試行する本文。"], count: 3))
    #expect(await counter.snapshot().pendingPriorityClauseCount == 0)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func nativeRetryRejectsMetadataMismatchOrIncompleteLogBeforeSending(incompleteTail: Bool) async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1])
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["保留本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { false }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let store = ProcessingMetadataStore(sessionURL: fixture.sessionURL)
    let metadata = try #require(try store.load())
    #expect(metadata.pendingContentPriorityClauses.count == 1)
    let eventsURL = SessionLayout(sessionURL: fixture.sessionURL).eventsURL
    if incompleteTail {
        let handle = try FileHandle(forWritingTo: eventsURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"event_seq\":".utf8))
        try handle.synchronize()
    } else {
        try store.save(ProcessingMetadata(
            finalizationAttempt: metadata.finalizationAttempt,
            activeRuns: metadata.activeRuns,
            pendingClauseBoundarySegments: metadata.pendingClauseBoundarySegments,
            pendingContentPriorityClauses: []
        ))
    }
    let corruptedLog = try Data(contentsOf: eventsURL)
    await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: metadata.pendingContentPriorityClauses,
        onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(await provider.requests == [["保留本文。"]])
    #expect(await counter.snapshot().priorityRequests.sendCount == 1)
    #expect(try Data(contentsOf: eventsURL) == corruptedLog)
    #expect(try store.load()?.activeRuns == metadata.activeRuns)
}

@Test(.timeLimit(.minutes(1)))
func corruptedDurableLiveDecisionFailsExplicitlyWithoutReplacingThePublishedLocalText() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [])
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["ローカル本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let writer = try SessionWriter(sessionURL: fixture.sessionURL)
    _ = try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: fixture.sessionID, processingRunID: "priority_live_corrupt",
        payload: ProcessingRunStartedPayload(stage: .contentPriority, provenance: DecisionRunProvenance.priority(mode: "live"))
    ))
    _ = try await writer.append(EventDraft(
        eventType: ClauseEventType.priorityAssigned, sessionID: fixture.sessionID, processingRunID: "priority_live_corrupt",
        payload: try ClausePriorityBatch.pending(
            references: [ClauseReference(boundaryRunID: "boundary_live_missing", clauseID: "c999_0")],
            reason: .requestFailed, message: "a durable decision refers to a nonexistent clause"
        )
    ))
    let updates = LiveUpdateRecorder()
    let result = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { false }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { rows, _ in await updates.record(rows) }
    )
    #expect(result.disposition == .failed)
    #expect(result.retainedTranscript == .finalized)
    let rows = try fixture.rows()
    #expect(rows.map(\.text) == ["ローカル本文。"])
    #expect(rows.map(\.clauseState) == [.boundaryPending])
    #expect(rows[0].clauseSlices == [])
    #expect(await updates.snapshot() == rows)
    #expect(await counter.snapshot().sendCount == 0)
    #expect(await provider.requests == [])
}

@Test(.timeLimit(.minutes(1)))
func unpublishedRetryRebuildsACompleteSnapshotEvenWithoutPendingTargetsAndNeverUsesUnpublishedAnswers() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [])
    let decisions = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["保存済み本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let result = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { false }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(result.disposition == .completed)
    let store = ProcessingMetadataStore(sessionURL: fixture.sessionURL)
    let before = try #require(try store.load())
    #expect(before.pendingDecisionTargets == [])
    let writer = try SessionWriter(sessionURL: fixture.sessionURL)
    _ = try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: fixture.sessionID, processingRunID: "boundary_retry_unpublished",
        payload: ProcessingRunStartedPayload(stage: .clauseBoundary, provenance: DecisionRunProvenance.boundary(mode: "retry"))
    ))
    // A well-shaped assessment of a nonexistent source must not enter the rebuilt snapshot.
    _ = try await writer.append(EventDraft(
        eventType: ClauseEventType.boundaryAssessed, sessionID: fixture.sessionID, processingRunID: "boundary_retry_unpublished",
        payload: try ClauseBoundaryAssessment(
            source: SegmentTextReference(
                segmentationRunID: "missing", segmentID: "missing", asrRunID: "missing", asrEventSeq: 999
            ),
            candidates: [], probabilities: [:], nextHead: nil, continuationProbability: nil, request: nil,
            sourceDecision: .terminalWithoutQuestions
        )
    ))
    await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: [],
        onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let after = try #require(try store.load())
    #expect(after.activeRuns?.clauseBoundary != before.activeRuns?.clauseBoundary)
    #expect(after.activeRuns?.contentPriority != before.activeRuns?.contentPriority)
    #expect(after.pendingDecisionTargets == [])
    #expect(try fixture.rows()[0].clauseSlices.map(\.priority) == [.lowPriority])
    #expect(await provider.requests == [["保存済み本文。"]])
    #expect(await counter.snapshot().sendCount == 1)
    #expect(await fixture.asr.callCount == 1)
}
