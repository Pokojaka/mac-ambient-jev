import Combine
import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCore
@testable import MacAmbientJevPipeline
@testable import MacAmbientJevRuntime

private let testDecisionIdentity = try! DecisionModelIdentity(backend: "test-backend", model: "test-tagger", modelRevision: String(repeating: "0", count: 64))

private actor RecordingASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "recording-test", model: nil, version: "test", configuration: [:])
    private var count = 0
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        count += 1
        return ASRResult(text: "録音の発話\(count)", detectedLanguage: "ja")
    }
}

private struct RecordingFinalVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "recording-test-vad", model: nil, version: "test", configuration: [:])
    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] { [] }
}

private actor RecordingVAD: LiveVADProcessing {
    nonisolated let segmentationRunID = "recording-vad"
    private var emitted = false
    func processAvailable(checkpoint: AudioCheckpoint) -> LiveVADProgress {
        let segments = emitted ? [] : [
            SegmentReference(segmentationRunID: segmentationRunID, segmentID: "row_1", startFrame: 0, endFrame: 4_000),
            SegmentReference(segmentationRunID: segmentationRunID, segmentID: "row_2", startFrame: 4_000, endFrame: 8_000),
        ]
        emitted = true
        return LiveVADProgress(emittedSegments: segments, totalSegmentCount: 2,
                               committedFrames: checkpoint.committedFrames, micSpeechLevels: [])
    }
    func finish(checkpoint: AudioCheckpoint) -> LiveVADProgress {
        LiveVADProgress(emittedSegments: [], totalSegmentCount: 2,
                        committedFrames: checkpoint.committedFrames, micSpeechLevels: [])
    }
}

private actor RecordingTagger: DecisionProvider {
    private(set) var texts: [String] = []
    private var priorityRequestCount = 0
    private var priorityRequestWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, any Error>)] = [:]
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var boundaryTexts: [String] = []
    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        boundaryTexts.append(request.text)
        return ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.9) }),
            continuationProbability: request.next.map { _ in 0.1 },
            fillerRanges: [],
            inputTokens: 5
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        priorityRequestCount += 1
        resumePriorityRequestWaiters()
        texts.append(contentsOf: targets.map(\.text))
        if !released { await withCheckedContinuation { waiters.append($0) } }
        let decision = try ContentPriorityDecision(
            priority: .lowPriority, confidence: 0.95,
            probabilities: ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, decision) }),
            inputTokens: 7
        )
    }

    func waitForPriorityRequests(_ count: Int) async throws {
        guard count > 0 else {
            throw LivePollWaitFailure(message: "Priority request count must be greater than zero; received \(count).")
        }
        guard !Task.isCancelled else {
            throw LivePollWaitFailure(message: "Waiting for \(count) priority requests was cancelled before registration.")
        }
        guard priorityRequestCount < count else { return }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(
                        throwing: LivePollWaitFailure(message: "Waiting for \(count) priority requests was cancelled before registration.")
                    )
                    return
                }
                guard priorityRequestCount < count else {
                    continuation.resume()
                    return
                }
                priorityRequestWaiters[id] = (count: count, continuation: continuation)
            }
        } onCancel: { [weak self] in
            Task {
                await self?.cancelPriorityRequestWaiter(id: id)
            }
        }
    }

    private func resumePriorityRequestWaiters() {
        let matchingIDs = priorityRequestWaiters.compactMap { id, waiter in
            waiter.count <= priorityRequestCount ? id : nil
        }
        let matchingWaiters = matchingIDs.compactMap { priorityRequestWaiters.removeValue(forKey: $0) }
        for waiter in matchingWaiters {
            waiter.continuation.resume()
        }
    }

    private func cancelPriorityRequestWaiter(id: UUID) {
        guard let waiter = priorityRequestWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(
            throwing: LivePollWaitFailure(message: "Waiting for \(waiter.count) priority requests was cancelled.")
        )
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
private func withLiveDecisionRecording(
    makeDecisions: @escaping @Sendable (DecisionUsageCounter) -> NativeSessionProcessor.DecisionCoordinatorFactory,
    beforeStop: () async -> Void,
    body: (AppState) async throws -> Void
) async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let capture = FakeAppCaptureEngine()
    let poll = LivePollSleep()
    capture.onStart = { sessionID in
        let sessionURL = try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: paths.sessionsRoot, sessionID: sessionID)
        let writer = try DurableAudioWriter(directory: SessionLayout(sessionURL: sessionURL).processingDirectory, chunkDurationSeconds: 0.5, sessionURL: sessionURL)
        try await writer.append(samples: Array(repeating: 0.125, count: 16_000))
        capture.stopResult = cleanStopResult(try await writer.finish())
    }
    let state = AppState(
        paths: paths, captureEngine: capture, microphoneAccess: { true }, pausesProcessing: false,
        userDefaults: defaults,
        engines: SessionProcessingEngines(asr: RecordingASR(),
            diarization: FluidOfflineDiarizationEngine(paths: paths),
            finalTranscriptVAD: RecordingFinalVAD()),
        makeLiveVADSession: { _, _, _, _ in RecordingVAD() },
        thermalMonitor: TestThermalMonitor(.nominal),
        liveTranscriptionSleep: poll.sleep,
        makeDecisions: { _, counter in makeDecisions(counter) }
    )
    let maintenance = try #require(state.startupMaintenanceTask, "Launch maintenance task was not started")
    await maintenance.value
    try #require(!state.processingQueue.isMaintainingStorage, "Startup maintenance task completed while storage maintenance is still active")
    await state.startRecording()
    do {
        try #require(state.recordingPhase == .recording)
        try await poll.advance()
        try await poll.waitUntilSuspended()
        try await body(state)
    } catch {
        await beforeStop()
        await state.stopRecording()
        await state.processingCoordinator.waitUntilIdle()
        await state.modelPreparationTask?.value
        await state.idleReleaseTask?.value
        throw error
    }
    await beforeStop()
    await state.stopRecording()
    await state.processingCoordinator.waitUntilIdle()
    await state.modelPreparationTask?.value
    await state.idleReleaseTask?.value
}

@MainActor
@Test("AppState recording shows live rows at once and applies only saved decisions", .timeLimit(.minutes(10)))
func appRecordingShowsLiveRowsWhileDecisionsWait() async throws {
    let provider = RecordingTagger()
    try await withLiveDecisionRecording(makeDecisions: { counter in
        { DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter) }
    }, beforeStop: { await provider.release() }) { state in
        try await provider.waitForPriorityRequests(1)
        // The first row's boundary needed the second row; the second still waits for a successor.
        #expect(await provider.boundaryTexts == ["録音の発話1"])
        #expect(await provider.texts == ["録音の発話1"])
        let sessionID = try #require(state.recordingSessionID)
        await state.waitForLiveASRDrain(sessionID: sessionID)
        #expect(state.liveTranscription.failure(sessionID: sessionID) == nil)
        // Rows never wait for decisions: both are shown as normal text while priority is in flight.
        #expect(state.transcriptViewModel.rows.map(\.text) == ["録音の発話1", "録音の発話2"])
        #expect(state.transcriptViewModel.rows.map(\.clauseState) == [.priorityPending, .awaitingNextSegment])

        await provider.release()
        try await waitForPublishedValue(
            state.transcriptViewModel.$rows,
            description: "saved low-priority row to leave the live transcript",
            matching: { $0.count == 1 }
        )
        // The saved LOW sentence leaves the screen; the waiting row keeps its text.
        #expect(state.transcriptViewModel.rows.map(\.text) == ["録音の発話2"])
        #expect(state.transcriptViewModel.rows.map(\.clauseState) == [.awaitingNextSegment])
        // Resuming the suspended classifier completes row 1; row 2 is assessed only when input ends.
        #expect(await provider.boundaryTexts == ["録音の発話1"])
        #expect(await provider.texts == ["録音の発話1"])
        // These are pre-finish counts; the terminal row is assessed when recording input ends.
        let usage = await state.decisionUsageCounter.snapshot()
        #expect(usage.boundaryRequests.sendCount == 1)
        #expect(usage.priorityRequests.sendCount == 1)
        #expect(usage.inputTokens == 12)
    }
}

@MainActor
@Test("AppState keeps the classifier factory error visible while live ASR continues", .timeLimit(.minutes(10)))
func appRecordingShowsDecisionFactoryFailureReason() async throws {
    let description = "Synthetic model load failure"
    try await withLiveDecisionRecording(makeDecisions: { _ in
        { throw NSError(domain: "LiveDecisionRecordingTests", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: description]) }
    }, beforeStop: {}) { state in
        // ASR drain does not wait for decisions; wait for each independently published effect.
        try await waitForPublishedValue(
            state.transcriptViewModel.$rows,
            description: "two live rows with a pending first clause after the factory error",
            matching: { rows in rows.count == 2 && rows.first?.clauseState == .boundaryPending }
        )
        try await waitForPublishedValue(
            state.$processingStatusText,
            description: "classifier factory failure status",
            matching: { $0?.contains(description) == true }
        )
        let sessionID = try #require(state.recordingSessionID)
        await state.waitForLiveASRDrain(sessionID: sessionID)
        #expect(state.isRecording)
        #expect(state.liveTranscription.failure(sessionID: sessionID) == nil)
        #expect(state.transcriptViewModel.rows.map(\.text) == ["録音の発話1", "録音の発話2"])
        #expect(state.transcriptViewModel.rows.first?.clauseState == .boundaryPending)
        #expect(state.processingStatusText?.contains(description) == true)
        #expect(state.transcriptViewModel.statusText.contains(description))
        #expect(state.liveTranscription.contentPriorityStatus[sessionID]?.contains(description) == true)
    }
}
