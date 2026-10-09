import Combine
import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCore
@testable import MacAmbientJevRuntime

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

private actor RecordingJev: DecisionProvider {
    private(set) var texts: [String] = []
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var boundaryTexts: [String] = []
    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        boundaryTexts.append(request.text)
        return ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.9) }),
            continuationProbability: request.next.map { _ in 0.1 },
            metadata: try JevResponseMetadata(model: "recording-test", inputTokens: 5, outputTokens: nil)
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        texts.append(contentsOf: targets.map(\.text))
        if !released { await withCheckedContinuation { waiters.append($0) } }
        let decision = try ContentPriorityDecision(
            priority: .lowPriority, confidence: 0.95,
            probabilities: ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, decision) }),
            metadata: try JevResponseMetadata(model: "recording-test", inputTokens: 7, outputTokens: nil)
        )
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
private func withLiveJevRecording(
    makeDecisions: @escaping @Sendable (JevUsageCounter) -> NativeSessionProcessor.JevDecisionCoordinatorFactory,
    body: (AppState) async throws -> Void
) async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let capture = FakeAppCaptureEngine()
    capture.onStart = { sessionID in
        let sessionURL = try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: paths.sessionsRoot, sessionID: sessionID)
        let writer = try DurableAudioWriter(directory: SessionLayout(sessionURL: sessionURL).processingDirectory,
                                            chunkDurationSeconds: 0.5)
        try await writer.append(samples: Array(repeating: 0.125, count: 16_000))
        capture.stopResult = cleanStopResult(try await writer.finish())
    }
    let state = AppState(
        paths: paths, captureEngine: capture, microphoneAccess: { true }, pausesProcessing: false,
        userDefaults: defaults,
        engines: SessionProcessingEngines(asr: RecordingASR(),
            diarization: FluidOfflineDiarizationEngine(paths: paths),
            finalTranscriptVAD: RecordingFinalVAD()),
        makeLiveVADSession: { _, _, _ in RecordingVAD() }, makeJevDecisions: makeDecisions
    )
    state.readLiveThermalPressure = { .nominal }
    let maintenanceDeadline = ContinuousClock.now + .seconds(5)
    while state.isMaintainingStorage, ContinuousClock.now < maintenanceDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!state.isMaintainingStorage)
    await state.startRecording()
    do {
        try #require(state.recordingPhase == .recording)
        try await body(state)
    } catch {
        await state.stopRecording()
        await state.processingTask?.value
        await state.modelPreparationTask?.value
        await state.idleReleaseTask?.value
        throw error
    }
    await state.stopRecording()
    await state.processingTask?.value
    await state.modelPreparationTask?.value
    await state.idleReleaseTask?.value
}

@MainActor
@Test("AppState recording shows live rows at once and applies only saved Jev results")
func appRecordingShowsLiveRowsWhileJevWaits() async throws {
    let provider = RecordingJev()
    try await withLiveJevRecording(makeDecisions: { counter in
        { JevDecisionCoordinator(provider: provider, usageCounter: counter) }
    }) { state in
        let deadline = ContinuousClock.now + .seconds(5)
        while await provider.texts.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The first row's boundary needed the second row; the second still waits for a successor.
        #expect(await provider.boundaryTexts == ["録音の発話1"])
        #expect(await provider.texts == ["録音の発話1"])
        let sessionID = try #require(state.recordingSessionID)
        await state.waitForLiveASRDrain(sessionID: sessionID)
        #expect(state.liveASRFailures[sessionID] == nil)
        // Rows never wait for Jev: both are shown as normal text while the Choice is in flight.
        #expect(state.transcriptViewModel.rows.map(\.text) == ["録音の発話1", "録音の発話2"])
        #expect(state.transcriptViewModel.rows.map(\.clauseState) == [.priorityPending, .awaitingNextSegment])
        #expect(state.transcriptViewModel.rows.map(\.shouldCollapseRow) == [false, false])

        await provider.release()
        let decisionDeadline = ContinuousClock.now + .seconds(5)
        while state.transcriptViewModel.rows.first?.clauseState != .classified, ContinuousClock.now < decisionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.transcriptViewModel.rows.map(\.clauseState) == [.classified, .awaitingNextSegment])
        #expect(state.transcriptViewModel.rows.map(\.shouldCollapseRow) == [true, false])
        let usage = await state.jevUsageCounter.snapshot()
        #expect(usage.boundaryRequests.sendCount == 1)
        #expect(usage.priorityRequests.sendCount == 1)
        #expect(usage.reportedInputTokens == 12)
    }
}

@MainActor
@Test("AppState keeps the classifier factory error visible while live ASR continues")
func appRecordingShowsJevFactoryFailureReason() async throws {
    let description = "Synthetic credential read denied (no Keychain access)"
    try await withLiveJevRecording(makeDecisions: { _ in
        { throw NSError(domain: "LiveJevRecordingTest", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: description]) }
    }) { state in
        let deadline = ContinuousClock.now + .seconds(5)
        // ASR drain does not wait for Jev. The pending row is published after the factory error status.
        while (state.transcriptViewModel.rows.count != 2
               || state.transcriptViewModel.rows.first?.clauseState != .boundaryPending),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let sessionID = try #require(state.recordingSessionID)
        await state.waitForLiveASRDrain(sessionID: sessionID)
        #expect(state.isRecording)
        #expect(state.liveASRFailures[sessionID] == nil)
        #expect(state.transcriptViewModel.rows.map(\.text) == ["録音の発話1", "録音の発話2"])
        #expect(state.transcriptViewModel.rows.allSatisfy { !$0.shouldCollapseRow })
        #expect(state.transcriptViewModel.rows.first?.clauseState == .boundaryPending)
        #expect(state.processingStatusText?.contains(description) == true)
        #expect(state.transcriptViewModel.statusText.contains(description))
        #expect(state.liveContentPriorityStatus[sessionID]?.contains(description) == true)
    }
}
