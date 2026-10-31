import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private enum UnexpectedLiveTestFinalization: Error {
    case called
}

private struct UnusedLiveTestDiarizer: DiarizationEngine {
    let provenance = RunProvenance(engine: "unused-live-test-diarizer", model: nil, version: "test", configuration: [:])

    func prepare() async throws {
        throw UnexpectedLiveTestFinalization.called
    }

    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] {
        throw UnexpectedLiveTestFinalization.called
    }

    func unload() async {}
}

private struct UnusedLiveTestVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "unused-live-test-vad", model: nil, version: "test", configuration: [:])

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        throw UnexpectedLiveTestFinalization.called
    }
}

private actor LiveUpdateRecorder {
    private struct RowsWaiter {
        let condition: @Sendable ([MaterializedTranscriptSegment]) -> Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var segments: [MaterializedTranscriptSegment] = []
    private(set) var history: [[MaterializedTranscriptSegment]] = []
    private var waiters: [UUID: RowsWaiter] = [:]

    func record(_ value: [MaterializedTranscriptSegment]) {
        segments = value
        history.append(value)
        resolveWaiters()
    }

    func snapshot() -> [MaterializedTranscriptSegment] {
        segments
    }

    func waitFor(_ condition: @escaping @Sendable ([MaterializedTranscriptSegment]) -> Bool) async throws {
        if condition(segments) { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard !condition(segments) else {
                    continuation.resume(returning: ())
                    return
                }
                waiters[id] = RowsWaiter(condition: condition, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resolveWaiters() {
        let resolved = waiters.filter { $0.value.condition(segments) }
        for (id, waiter) in resolved {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: ())
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
            diarization: UnusedLiveTestDiarizer(),
            finalTranscriptVAD: UnusedLiveTestVAD()
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .disabled,
        sleep: { _ in }
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

private actor ProcessingStateRecorder {
    private(set) var states: [ProcessingState] = []

    func record(_ state: ProcessingState) {
        states.append(state)
    }

    func snapshot() -> [ProcessingState] { states }
}

private actor ProcessingStatusRecorder {
    private(set) var statuses: [NativeSessionProcessor.Status] = []

    func record(_ status: NativeSessionProcessor.Status) {
        statuses.append(status)
    }

    func reset() {
        statuses = []
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
            diarization: UnusedLiveTestDiarizer(),
            finalTranscriptVAD: UnusedLiveTestVAD()
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .disabled,
        sleep: { _ in }
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
    private struct HeldWaiter {
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let holdPriorityNumber: Int?
    private let failedPriorityNumbers: Set<Int>
    private let primaryPriorityNumbers: Set<Int>
    private var gate: CheckedContinuation<Void, Never>?
    private var heldWaiters: [UUID: HeldWaiter] = [:]
    private var beforePriority: (@Sendable (Int) throws -> Void)?
    private(set) var requests: [[String]] = []
    private(set) var boundaryRequests: [ClauseBoundaryRequest] = []

    init(holdPriorityNumber: Int?, failedPriorityNumbers: Set<Int>, primaryPriorityNumbers: Set<Int> = []) {
        self.holdPriorityNumber = holdPriorityNumber
        self.failedPriorityNumbers = failedPriorityNumbers
        self.primaryPriorityNumbers = primaryPriorityNumbers
    }

    func setBeforePriority(_ action: @escaping @Sendable (Int) throws -> Void) { beforePriority = action }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        boundaryRequests.append(request)
        return ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.95) }),
            continuationProbability: request.next.map { _ in 0.05 },
            fillerRanges: [],
            inputTokens: 5
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        requests.append(targets.map(\.text))
        let number = requests.count
        if number == holdPriorityNumber {
            await withCheckedContinuation { continuation in
                gate = continuation
                resolveHeldWaiters()
            }
        }
        try beforePriority?(number)
        if failedPriorityNumbers.contains(number) { throw DecisionResponseError.missingAnswer }
        // A late live LOW answer must not replace the final fresh PRIMARY answer.
        let low = !primaryPriorityNumbers.contains(number) && (holdPriorityNumber == nil || number <= 2)
        let decision = try ContentPriorityDecision(
            priority: low ? .lowPriority : .primary, confidence: 0.95,
            probabilities: low ? ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975] : ["PRIMARY": 0.975, "LOW_PRIORITY": 0.025]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, decision) }),
            inputTokens: 7
        )
    }

    func waitUntilHeld() async throws {
        if gate != nil { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard gate == nil else {
                    continuation.resume(returning: ())
                    return
                }
                heldWaiters[id] = HeldWaiter(continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelHeldWaiter(id) }
        }
    }

    private func cancelHeldWaiter(_ id: UUID) {
        guard let waiter = heldWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resolveHeldWaiters() {
        let waiters = Array(heldWaiters.values)
        heldWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: ())
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
            audioHandling: RecordingTestAudioHandling(),
            contentPriority: .localTagger(factory, usageCounter: counter),
            sleep: { _ in }
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

@Test(.timeLimit(.minutes(10)))
func nativeTakeoverFinishesWithoutWaitingForLiveDecisionsAndReusesOnlyFrozenDurableAnswers() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: 2, failedPriorityNumbers: [])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
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
    let livePriority = try #require(await fixture.processor.liveContentPrioritySessions[fixture.sessionID])
    let liveWorker = try #require(await livePriority.worker)
    let frozen = try EventLogTranscriptReader().liveContentPriorityDecisions(
        from: SessionWriter.readDurableLog(eventsURL: SessionLayout(sessionURL: fixture.sessionURL).eventsURL),
        modelRevision: testDecisionIdentity.modelRevision
    )
    #expect(Set(frozen.keys) == [ExactClauseTextKey(text: "保存済み。")])
    let waitingRows = try LiveTranscriptProjection().rows(for: await liveUpdates.snapshot())
    #expect(waitingRows.map(\.text) == ["遅い結果。"])

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
    await liveWorker.value
    #expect(await liveUpdates.history.count == liveCount)
    #expect(try fixture.rows() == rows)
    #expect(await finalUpdates.snapshot() == rows)
    #expect(await counter.snapshot().pendingBoundarySegmentCount == 0)
    #expect(await counter.snapshot().pendingPriorityClauseCount == 0)
}

private struct TaggerLoadFailure: Error {}

private struct NativeDecisionRetryInitializationFailure: LocalizedError, Sendable {
    var errorDescription: String? { "テスト初期化エラー" }
}

@Test(.timeLimit(.minutes(10)))
func cancellingLiveDecisionsAfterAFailedTaggerLoadClearsItsPendingKeys() async throws {
    let counter = DecisionUsageCounter()
    let fixture = try await NativeDecisionFixture(
        texts: ["前の本文", "次の本文"], factory: { throw TaggerLoadFailure() }, counter: counter
    )
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

@Test
func failedAtomicDecisionPublicationLeavesTheDurableLocalDisplayAndPendingKeys() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
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
    _ = await fixture.processor.retryContentPrioritySession(
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

private enum PublishedRetryLatePause: CaseIterable {
    case cancellation
    case processingPause
    case both
}

private final class PublishedRetryThermalObservation: ThermalStateObservation {}

private struct PublishedRetryNoThermalMonitor: ThermalMonitoring {
    var isCritical: Bool { false }
    var liveASRDecision: LiveASRThermalDecision { .processNow }

    @MainActor
    func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any ThermalStateObservation {
        PublishedRetryThermalObservation()
    }
}

private struct PublishedRetryFinishedEvent {
    let sessionID: UUID
    let disposition: BatchDisposition?
    let message: String?
}

@MainActor
private final class PublishedRetryEffects: SessionProcessingEffects {
    var processingQueue = SessionProcessingQueue()
    var pausesProcessing = false
    var onComplete: (@MainActor () -> Void)?

    private(set) var statusTexts: [String] = []
    private(set) var updateStates: [ProcessingState] = []
    private(set) var updatedSegments: [MaterializedTranscriptSegment] = []
    private(set) var finishedEvents: [PublishedRetryFinishedEvent] = []
    private(set) var heldCount = 0
    private(set) var exportCount = 0

    var modelsReady: Bool { true }
    func prepareModels() {}

    func awaitIdleRelease() async {}

    func processingStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler {
        { status in await self.record(status) }
    }

    func processingUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        { segments, state in await self.record(segments: segments, state: state) }
    }

    func waitForLiveASRDrain(sessionID: UUID) async {
        preconditionFailure("published retry test does not finish live transcription")
    }

    func liveASRFailure(sessionID: UUID) -> String? {
        preconditionFailure("published retry test does not inspect live ASR failures")
    }

    func cleanupLiveASRState(sessionID: UUID) {
        preconditionFailure("published retry test does not clean up live ASR state")
    }

    func refreshSavedSessions() {}

    func autoExportIfEnabled(sessionID: UUID) async {
        exportCount += 1
    }

    func processingDidChange(_ event: SessionProcessingEvent) {
        switch event {
        case .held:
            heldCount += 1
        case .finished(let request, let result):
            finishedEvents.append(PublishedRetryFinishedEvent(
                sessionID: request.sessionID,
                disposition: result?.disposition,
                message: result?.message
            ))
        case .backlogged, .heldForModels, .began, .liveFailed, .next, .willFinishDrain, .drained:
            break
        }
    }

    private func record(_ status: NativeSessionProcessor.Status) {
        statusTexts.append(status.text)
    }

    private func record(segments: [MaterializedTranscriptSegment], state: ProcessingState) {
        updatedSegments = segments
        updateStates.append(state)
        if state == .complete {
            onComplete?()
        }
    }
}

@MainActor
@Test(.timeLimit(.minutes(10)), arguments: PublishedRetryLatePause.allCases)
private func publishedRetryRemainsCompletedAfterLatePause(_ latePause: PublishedRetryLatePause) async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(
        texts: ["再試行後に公開する本文。"], factory: { decisions }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let initialResult = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { false }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(initialResult.disposition == .completed)

    let store = ProcessingMetadataStore(sessionURL: fixture.sessionURL)
    let initialMetadata = try #require(try store.load())
    let initialRuns = try #require(initialMetadata.activeRuns)
    let initialContentPriorityRun = try #require(initialRuns.contentPriority)
    let pendingClauses = initialMetadata.pendingContentPriorityClauses
    #expect(pendingClauses.count == 1)
    let pendingClause = try #require(pendingClauses.first)

    let effects = PublishedRetryEffects()
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: fixture.processor,
        thermalMonitor: PublishedRetryNoThermalMonitor()
    )
    var completionMetadata: ProcessingMetadata?
    var completionMetadataLoadError: String?
    var completionCallbackCount = 0
    effects.onComplete = {
        completionCallbackCount += 1
        do {
            if let loaded = try store.load() {
                completionMetadata = loaded
            } else {
                completionMetadataLoadError = "processing metadata was absent at complete callback"
            }
        } catch {
            completionMetadataLoadError = error.localizedDescription
        }

        switch latePause {
        case .cancellation:
            coordinator.requestPause()
        case .processingPause:
            effects.pausesProcessing = true
        case .both:
            coordinator.requestPause()
            effects.pausesProcessing = true
        }
    }

    coordinator.enqueue(.retryContentPriority(
        sessionID: fixture.sessionID,
        boundarySegments: [],
        clauses: [pendingClause]
    ))
    await coordinator.waitUntilIdle()

    #expect(completionCallbackCount == 1)
    #expect(completionMetadataLoadError == nil)
    let metadataAtCompletion = try #require(completionMetadata)
    let runsAtCompletion = try #require(metadataAtCompletion.activeRuns)
    #expect(runsAtCompletion.contentPriority != initialContentPriorityRun)
    #expect(metadataAtCompletion.pendingContentPriorityClauses.isEmpty)
    #expect(metadataAtCompletion.pendingDecisionTargets.isEmpty)
    #expect(effects.updateStates.contains(.complete))
    #expect(effects.updatedSegments.map(\.text) == ["再試行後に公開する本文。"])

    #expect(effects.finishedEvents.count == 1)
    let finishedAtCompletion = try #require(effects.finishedEvents.first)
    #expect(finishedAtCompletion.sessionID == fixture.sessionID)
    // A successful retry is reported as .finished(request, nil), not as a completed result.
    #expect(finishedAtCompletion.disposition == nil)
    #expect(effects.heldCount == 0)
    #expect(effects.processingQueue.thermallyHeld.isEmpty)
    #expect(effects.processingQueue.pending.isEmpty)
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(effects.exportCount == 0)
    #expect(!effects.statusTexts.contains("処理は中断されました。次回の起動時に再開できます"))

    let metadataURL = fixture.sessionURL.appending(path: "processing_metadata.json")
    let eventsURL = SessionLayout(sessionURL: fixture.sessionURL).eventsURL
    let metadataBytesAfterCompletion = try Data(contentsOf: metadataURL)
    let eventBytesAfterCompletion = try Data(contentsOf: eventsURL)
    let providerRequestsAfterCompletion = await provider.requests
    #expect(providerRequestsAfterCompletion.count == 2)
    #expect(providerRequestsAfterCompletion == [
        ["再試行後に公開する本文。"],
        ["再試行後に公開する本文。"]
    ])
    let completionRecovery = try SessionRecoveryScanner(sessionsRoot: fixture.paths.sessionsRoot)
        .inspect(sessionID: fixture.sessionID).recovery
    #expect(SessionRecoveryPlan(completionRecovery?.action).launchRecoveryRequest(sessionID: fixture.sessionID) == nil)

    // If a regression leaves a stale held retry here, resuming it is finite and must not
    // re-send a provider request or overwrite the already published snapshot.
    effects.pausesProcessing = false
    coordinator.resumeThermallyHeldProcessing()
    await coordinator.waitUntilIdle()

    #expect(effects.heldCount == 0)
    #expect(effects.processingQueue.thermallyHeld.isEmpty)
    #expect(effects.processingQueue.pending.isEmpty)
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(effects.finishedEvents.count == 1)
    #expect(effects.finishedEvents.first?.disposition == nil)
    #expect(effects.exportCount == 0)
    #expect(!effects.statusTexts.contains("処理は中断されました。次回の起動時に再開できます"))
    let retryFailureMessages = effects.finishedEvents.compactMap(\.message).filter { $0.contains("再試行") }
    #expect(retryFailureMessages.isEmpty)
    #expect(await provider.requests == providerRequestsAfterCompletion)
    #expect(try Data(contentsOf: metadataURL) == metadataBytesAfterCompletion)
    #expect(try Data(contentsOf: eventsURL) == eventBytesAfterCompletion)
}

@Test
func targetedRetryAfterSaveFailureUsesANewWorkerAndRetainsThePublishedSnapshotUntilSuccess() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1], primaryPriorityNumbers: [2])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
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
    _ = await fixture.processor.retryContentPrioritySession(
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

    _ = await fixture.processor.retryContentPrioritySession(
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

@Test(arguments: [false, true])
func nativeRetryRejectsMetadataMismatchOrIncompleteLogBeforeSending(incompleteTail: Bool) async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
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
    _ = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: metadata.pendingContentPriorityClauses,
        onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(await provider.requests == [["保留本文。"]])
    #expect(await counter.snapshot().priorityRequests.sendCount == 1)
    #expect(try Data(contentsOf: eventsURL) == corruptedLog)
    #expect(try store.load()?.activeRuns == metadata.activeRuns)
}

@Test
func corruptedDurableLiveDecisionFailsExplicitlyWithoutReplacingThePublishedLocalText() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["ローカル本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let writer = try SessionWriter(sessionURL: fixture.sessionURL)
    _ = try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: fixture.sessionID, processingRunID: "priority_live_corrupt",
        payload: ProcessingRunStartedPayload(stage: .contentPriority, provenance: DecisionRunProvenance.priority(mode: "live", identity: testDecisionIdentity))
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

@Test
func unpublishedRetryRebuildsACompleteSnapshotEvenWithoutPendingTargetsAndNeverUsesUnpublishedAnswers() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
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
    let usageBeforeRetry = await counter.snapshot()
    let writer = try SessionWriter(sessionURL: fixture.sessionURL)
    _ = try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: fixture.sessionID, processingRunID: "boundary_retry_unpublished",
        payload: ProcessingRunStartedPayload(stage: .clauseBoundary, provenance: DecisionRunProvenance.boundary(mode: "retry", identity: testDecisionIdentity))
    ))
    // A well-shaped assessment of a nonexistent source must not enter the rebuilt snapshot.
    _ = try await writer.append(EventDraft(
        eventType: ClauseEventType.boundaryAssessed, sessionID: fixture.sessionID, processingRunID: "boundary_retry_unpublished",
        payload: try ClauseBoundaryAssessment(
            source: SegmentTextReference(
                segmentationRunID: "missing", segmentID: "missing", asrRunID: "missing", asrEventSeq: 999
            ),
            candidates: [], probabilities: [:], nextHead: nil, continuationProbability: nil,
            fillerRanges: [], request: try DecisionRequestRecord(requestID: "decisionreq_unpublished", inputTokens: 1),
            sourceDecision: .assessed
        )
    ))
    _ = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: [],
        onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let after = try #require(try store.load())
    #expect(after.activeRuns?.clauseBoundary != before.activeRuns?.clauseBoundary)
    #expect(after.activeRuns?.contentPriority != before.activeRuns?.contentPriority)
    #expect(after.pendingDecisionTargets == [])
    #expect(try fixture.rows()[0].clauseSlices.map(\.priority) == [.lowPriority])
    #expect(await provider.requests == [["保存済み本文。"]])
    let boundaryRequests = await provider.boundaryRequests
    #expect(boundaryRequests.count == 1)
    let boundaryRequest = try #require(boundaryRequests.first)
    #expect(boundaryRequest.text == "保存済み本文。")
    #expect(boundaryRequest.candidates == [])
    #expect(boundaryRequest.next == nil)
    #expect(boundaryRequest.source.segmentID == "final")
    #expect(boundaryRequest.source.segmentationRunID == before.activeRuns?.segmentation)
    #expect(boundaryRequest.source.asrRunID == before.activeRuns?.asr)
    // Terminal boundary F inference and priority run once; retry carries results without sending.
    let usage = await counter.snapshot()
    #expect(usage.sendCount == 2)
    #expect(usage.boundaryRequests.sendCount == 1)
    #expect(usage.priorityRequests.sendCount == 1)
    #expect(usage == usageBeforeRetry)
    #expect(await fixture.asr.callCount == 1)
}

@Test
func nativeRetryWithoutTargetsOrUnpublishedRunFailsAndRetainsPublishedSnapshot() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["再試行対象のない本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let finalized = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { false }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(finalized.disposition == .completed)
    let store = ProcessingMetadataStore(sessionURL: fixture.sessionURL)
    let before = try #require(try store.load())
    #expect(before.pendingDecisionTargets.isEmpty)
    let lines = try SessionRecovery.recoverJSONL(
        Data(contentsOf: SessionLayout(sessionURL: fixture.sessionURL).eventsURL)
    ).lines
    let activeRuns = try #require(before.activeRuns)
    let hasUnpublishedRun = try DecisionRetryAnalyzer().hasUnpublishedDecisionRun(lines: lines, activeRuns: activeRuns)
    #expect(!hasUnpublishedRun)
    let publishedRows = try fixture.rows()

    let updates = LiveUpdateRecorder()
    let updateStates = ProcessingStateRecorder()
    let result = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: [], onStatus: { _ in },
        onUpdate: { rows, state in
            await updates.record(rows)
            await updateStates.record(state)
        }
    )

    let expectedMessage = "発話文の判定を再試行できませんでした: 判定の再試行対象がありません"
    #expect(result.disposition == .failed)
    #expect(result.message == expectedMessage)
    #expect(result.retainedTranscript == .finalized)
    #expect(try store.load() == before)
    #expect(try fixture.rows() == publishedRows)
    #expect(await updates.snapshot().isEmpty)
    let retryUpdateStates = await updateStates.snapshot()
    #expect(retryUpdateStates.isEmpty)
    #expect(!retryUpdateStates.contains(.complete))
}

@Test
func nativeRetryWithoutContentPriorityFailsAndRetainsPublishedSnapshot() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["判定保留中の本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    _ = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { false }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let store = ProcessingMetadataStore(sessionURL: fixture.sessionURL)
    let before = try #require(try store.load())
    let pending = before.pendingContentPriorityClauses
    #expect(pending.count == 1)
    let publishedRows = try fixture.rows()
    let disabledProcessor = NativeSessionProcessor(
        paths: fixture.paths,
        engines: SessionProcessingEngines(
            asr: fixture.asr, diarization: LiveProcessorFinalDiarizer(), finalTranscriptVAD: LiveProcessorFinalVAD()
        ),
        audioHandling: RecordingTestAudioHandling(), contentPriority: .disabled, sleep: { _ in }
    )
    let updates = LiveUpdateRecorder()
    let updateStates = ProcessingStateRecorder()

    let result = await disabledProcessor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: pending, onStatus: { _ in },
        onUpdate: { rows, state in
            await updates.record(rows)
            await updateStates.record(state)
        }
    )

    let expectedMessage = "発話文の判定を再試行できませんでした: 判定エンジンが利用できません"
    #expect(result.disposition == .failed)
    #expect(result.message == expectedMessage)
    #expect(result.retainedTranscript == .finalized)
    #expect(try store.load() == before)
    #expect(try fixture.rows() == publishedRows)
    #expect(await updates.snapshot().isEmpty)
    let retryUpdateStates = await updateStates.snapshot()
    #expect(retryUpdateStates.isEmpty)
    #expect(!retryUpdateStates.contains(.complete))
}

@Test
func nativeRetryCoordinatorInitializationFailurePreservesDeferredEngineStatusAndSnapshot() async throws {
    let counter = DecisionUsageCounter()
    let fixture = try await NativeDecisionFixture(
        texts: ["判定エンジン初期化待ちの本文."], factory: { throw NativeDecisionRetryInitializationFailure() },
        counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let statuses = ProcessingStatusRecorder()

    _ = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { false }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { await statuses.record($0) }, onUpdate: { _, _ in }
    )
    let store = ProcessingMetadataStore(sessionURL: fixture.sessionURL)
    let before = try #require(try store.load())
    #expect(!before.pendingClauseBoundarySegments.isEmpty)
    let publishedRows = try fixture.rows()
    await statuses.reset()
    let updates = LiveUpdateRecorder()
    let updateStates = ProcessingStateRecorder()

    let result = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: before.pendingClauseBoundarySegments, clauses: [],
        onStatus: { await statuses.record($0) },
        onUpdate: { rows, state in
            await updates.record(rows)
            await updateStates.record(state)
        }
    )

    let engineFailure = "判定エンジンを初期化できませんでした: テスト初期化エラー"
    let expectedMessage = "発話文の判定を再試行できませんでした: \(engineFailure)"
    let expectedDeferredStatus = "\(UserFacingStatus.decisionDeferred.text)。\(engineFailure)"
    #expect(result.disposition == .failed)
    #expect(result.message == expectedMessage)
    #expect(result.retainedTranscript == .finalized)
    #expect(await statuses.statuses == [.message(expectedDeferredStatus)])
    #expect(try store.load() == before)
    #expect(try fixture.rows() == publishedRows)
    #expect(await updates.snapshot().isEmpty)
    let retryUpdateStates = await updateStates.snapshot()
    #expect(retryUpdateStates.isEmpty)
    #expect(!retryUpdateStates.contains(.complete))
}
