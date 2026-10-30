import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private enum ServiceTestFailure: Error {
    case expected
    case missingDecisionResources
}

private struct ServiceDecisionProviderFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class ServiceTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private actor EngineCallCounter {
    private(set) var asrTranscriptions = 0
    private(set) var vadRuns = 0
    private(set) var diarizationRuns = 0

    func recordASR() { asrTranscriptions += 1 }
    func recordVAD() { vadRuns += 1 }
    func recordDiarization() { diarizationRuns += 1 }

    func snapshot() -> (asr: Int, vad: Int, diarization: Int) {
        (asrTranscriptions, vadRuns, diarizationRuns)
    }
}

private struct FakeServiceTimelineBuilder: ImportedAudioTimelineBuilding {
    let samples: [Float]

    func build(from sourceURL: URL, into processingDirectory: URL, sessionURL: URL) async throws -> AudioCheckpoint {
        let writer = try DurableAudioWriter(
            directory: processingDirectory,
            chunkDurationSeconds: 0.5,
            sessionURL: sessionURL
        )
        try await writer.append(samples: samples)
        return try await writer.finish()
    }
}

private actor FakeServiceASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "service-test-asr", model: nil, version: "test", configuration: [:])
    private let calls: EngineCallCounter
    private let shouldFail: Bool
    private let text: String

    init(calls: EngineCallCounter, shouldFail: Bool = false, text: String = "日本語のテストです。") {
        self.calls = calls
        self.shouldFail = shouldFail
        self.text = text
    }

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        await calls.recordASR()
        if shouldFail { throw ServiceTestFailure.expected }
        return ASRResult(text: text, detectedLanguage: "ja")
    }

    func unload() async {}
}

private struct FakeServiceDiarizer: DiarizationEngine {
    let provenance = RunProvenance(engine: "service-test-diarizer", model: nil, version: "test", configuration: [:])
    let calls: EngineCallCounter

    func prepare() async throws {}
    func unload() async {}

    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] {
        await calls.recordDiarization()
        return [SpeakerSpan(speakerID: "Speaker 1", startFrame: 0, endFrame: 16_000, confidence: 0.95)]
    }
}

private struct FakeServiceVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "service-test-vad", model: nil, version: "test", configuration: [:])
    let calls: EngineCallCounter
    let producesSpeech: Bool

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        await calls.recordVAD()
        guard producesSpeech else { return [] }
        return [SegmentReference(
            segmentationRunID: runID,
            segmentID: "service_test_segment",
            startFrame: 0,
            endFrame: reader.info.committedFrames
        )]
    }
}

private actor FakeServiceDecisionProvider: DecisionProvider {
    private var failRequests: Bool
    private var retryFailureMessage: String?
    private var boundaryRequestCount = 0
    private var priorityRequestCount = 0

    init(failRequests: Bool = false) {
        self.failRequests = failRequests
    }

    func configureRetryFailure(_ message: String) {
        failRequests = false
        retryFailureMessage = message
    }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        boundaryRequestCount += 1
        if failRequests { throw ServiceTestFailure.expected }
        if let retryFailureMessage { throw ServiceDecisionProviderFailure(message: retryFailureMessage) }
        return ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.95) }),
            continuationProbability: request.next == nil ? nil : 0.05,
            fillerRanges: [],
            inputTokens: 4
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        priorityRequestCount += 1
        if failRequests { throw ServiceTestFailure.expected }
        if let retryFailureMessage { throw ServiceDecisionProviderFailure(message: retryFailureMessage) }
        let decision = try ContentPriorityDecision(
            priority: .primary,
            confidence: 0.95,
            probabilities: ["PRIMARY": 0.975, "LOW_PRIORITY": 0.025]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, decision) }),
            inputTokens: 6
        )
    }

    func requestCounts() -> (boundary: Int, priority: Int) {
        (boundaryRequestCount, priorityRequestCount)
    }
}

private struct ServiceDecisionHarness: Sendable {
    let provider: FakeServiceDecisionProvider
    let providerFactory: DecisionProviderFactory
    let usageCounter: DecisionUsageCounter
    let providerLoadCount: ServiceTestCounter
    let contentPriority: ContentPriorityAccess

    init(failRequests: Bool = false) {
        let provider = FakeServiceDecisionProvider(failRequests: failRequests)
        let usageCounter = DecisionUsageCounter()
        let providerLoadCount = ServiceTestCounter()
        let identity = try! ClauseTaggerModelIdentity(
            backend: testDecisionIdentity.backend,
            modelID: testDecisionIdentity.model,
            revision: testDecisionIdentity.modelRevision,
            tokenizerSHA256: String(repeating: "a", count: 64)
        )
        let providerFactory = DecisionProviderFactory(usageCounter: usageCounter) {
            providerLoadCount.increment()
            return LoadedDecisionProvider(provider: provider, identity: identity)
        }
        self.provider = provider
        self.providerFactory = providerFactory
        self.usageCounter = usageCounter
        self.providerLoadCount = providerLoadCount
        self.contentPriority = .localTagger({ try providerFactory.makeCoordinator() }, usageCounter: usageCounter)
    }
}

private struct ServiceEnvironment {
    let root: URL
    let paths: AppPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "session-file-processing-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        paths = AppPaths(
            applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
            cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
            sessionsRootOverride: root.appending(path: "sessions", directoryHint: .isDirectory)
        )
    }

    func makeInput(bytes: Data = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x73, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65])) throws -> URL {
        let url = root.appending(path: "source-\(UUID().uuidString).wav")
        try bytes.write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct CreatedServiceSession: Sendable {
    let id: UUID
    let url: URL
}

private actor ServiceEventRecorder {
    private var created: [CreatedServiceSession] = []
    private var exports: [URL] = []
    private var cleanupFailures: [String] = []

    func record(_ event: SessionFileProcessingService.Event) {
        switch event {
        case .sessionCreated(let sessionID, let sessionURL):
            created.append(CreatedServiceSession(id: sessionID, url: sessionURL))
        case .exported(let url):
            exports.append(url)
        case .cleanupFailed(let message):
            cleanupFailures.append(message)
        }
    }

    func createdSessions() -> [CreatedServiceSession] { created }
    func exportCount() -> Int { exports.count }
    func cleanupFailureCount() -> Int { cleanupFailures.count }
}

private actor ServiceCallbackRecorder {
    private var recordedStatuses: [String] = []
    private var recordedUpdateStates: [ProcessingState] = []

    func recordStatus(_ status: String) {
        recordedStatuses.append(status)
    }

    func recordUpdateState(_ state: ProcessingState) {
        recordedUpdateStates.append(state)
    }

    func statuses() -> [String] { recordedStatuses }

    func partialFailureUpdateCount() -> Int {
        recordedUpdateStates.reduce(into: 0) { count, state in
            if case .partialFailure = state { count += 1 }
        }
    }
}

private struct ServiceTestHarness {
    let service: SessionFileProcessingService
    let engineCalls: EngineCallCounter
    let resourceFactoryCalls: ServiceTestCounter
    let decisions: ServiceDecisionHarness?

    init(
        environment: ServiceEnvironment,
        producesSpeech: Bool = true,
        asrFails: Bool = false
    ) {
        let engineCalls = EngineCallCounter()
        let resourceFactoryCalls = ServiceTestCounter()
        let decisions: ServiceDecisionHarness? = nil
        let asr = FakeServiceASR(calls: engineCalls, shouldFail: asrFails)
        let engines = SessionProcessingEngines(
            asr: asr,
            diarization: FakeServiceDiarizer(calls: engineCalls),
            finalTranscriptVAD: FakeServiceVAD(calls: engineCalls, producesSpeech: producesSpeech)
        )
        let timelineBuilder = FakeServiceTimelineBuilder(samples: Array(repeating: 0.1, count: 16_000))
        self.engineCalls = engineCalls
        self.resourceFactoryCalls = resourceFactoryCalls
        self.decisions = decisions
        self.service = SessionFileProcessingService(
            paths: environment.paths,
            protectedRoots: [],
            timelineBuilder: timelineBuilder,
            makeResources: { withDecisions in
                resourceFactoryCalls.increment()
                if withDecisions {
                    guard let decisions else { throw ServiceTestFailure.missingDecisionResources }
                    return SessionFileProcessingResources(
                        engines: engines,
                        contentPriority: decisions.contentPriority,
                        decisionProviderFactory: decisions.providerFactory
                    )
                }
                return SessionFileProcessingResources(
                    engines: engines,
                    contentPriority: .disabled,
                    decisionProviderFactory: nil
                )
            },
            sleep: { _ in }
        )
    }

    init(
        environment: ServiceEnvironment,
        producesSpeech: Bool = true,
        asrFails: Bool = false,
        decisions: ServiceDecisionHarness
    ) {
        let engineCalls = EngineCallCounter()
        let resourceFactoryCalls = ServiceTestCounter()
        let asr = FakeServiceASR(calls: engineCalls, shouldFail: asrFails)
        let engines = SessionProcessingEngines(
            asr: asr,
            diarization: FakeServiceDiarizer(calls: engineCalls),
            finalTranscriptVAD: FakeServiceVAD(calls: engineCalls, producesSpeech: producesSpeech)
        )
        let timelineBuilder = FakeServiceTimelineBuilder(samples: Array(repeating: 0.1, count: 16_000))
        self.engineCalls = engineCalls
        self.resourceFactoryCalls = resourceFactoryCalls
        self.decisions = decisions
        self.service = SessionFileProcessingService(
            paths: environment.paths,
            protectedRoots: [],
            timelineBuilder: timelineBuilder,
            makeResources: { withDecisions in
                resourceFactoryCalls.increment()
                if withDecisions {
                    return SessionFileProcessingResources(
                        engines: engines,
                        contentPriority: decisions.contentPriority,
                        decisionProviderFactory: decisions.providerFactory
                    )
                }
                return SessionFileProcessingResources(
                    engines: engines,
                    contentPriority: .disabled,
                    decisionProviderFactory: nil
                )
            },
            sleep: { _ in }
        )
    }
}

private func serviceCallbacks(_ recorder: ServiceEventRecorder) -> SessionFileProcessingService.Callbacks {
    SessionFileProcessingService.Callbacks(
        onEvent: { await recorder.record($0) },
        onStatus: { _ in },
        onUpdate: { _, _ in },
        shouldPause: { nil },
        onPhase: { _ in }
    )
}

private func importedSession(
    using harness: ServiceTestHarness,
    audioURL: URL,
    outputURL: URL,
    keepSession: Bool = true,
    withDecisions: Bool = false,
    recorder: ServiceEventRecorder
) async throws -> SessionProcessingResult {
    try await harness.service.importFile(
        SessionFileProcessingService.ImportRequest(
            audioURL: audioURL,
            outputURL: outputURL,
            keepSession: keepSession,
            pacingMode: .normal,
            withDecisions: withDecisions
        ),
        callbacks: serviceCallbacks(recorder)
    )
}

private func materializedRows(sessionURL: URL) throws -> [MaterializedTranscriptSegment] {
    guard let metadata = try ProcessingMetadataStore(sessionURL: sessionURL).load(),
          let activeRuns = metadata.activeRuns else {
        throw ServiceTestFailure.expected
    }
    let lines = try SessionRecovery.recoverJSONL(Data(contentsOf: SessionLayout(sessionURL: sessionURL).eventsURL)).lines
    let events = try EventLogTranscriptReader().events(lines: lines, activeRuns: activeRuns)
    return try TranscriptMaterializer(sampleRate: CanonicalAudio.sampleRate)
        .materialize(events: events, activeRuns: activeRuns)
}

private func canonicalJSON(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func assertExportMatchesMaterialization(
    outputURL: URL,
    rows: [MaterializedTranscriptSegment]
) throws {
    let expected = try JSONEncoder().encode(rows)
    #expect(try canonicalJSON(Data(contentsOf: outputURL)) == canonicalJSON(expected))
}

@Suite("SessionFileProcessingServiceTests")
struct SessionFileProcessingServiceTests {
    @Test
    func importKeepsCanonicalSessionAndPublishesTranscriptWithoutStdoutDependency() async throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let bytes = Data([0x52, 0x49, 0x46, 0x46, 0x10, 0x20, 0x30, 0x40, 0x80, 0xff])
        let audioURL = try environment.makeInput(bytes: bytes)
        let outputURL = environment.root.appending(path: "export/transcript.json")
        let harness = ServiceTestHarness(environment: environment)
        let recorder = ServiceEventRecorder()

        let result = try await importedSession(
            using: harness,
            audioURL: audioURL,
            outputURL: outputURL,
            recorder: recorder
        )

        #expect(result.disposition == .completed)
        #expect(result.noSpeech == false)
        #expect(await recorder.createdSessions().count == 1)
        let created = try #require(await recorder.createdSessions().first)
        #expect(await recorder.exportCount() == 1)
        let originalURL = SessionLayout(sessionURL: created.url).audioDirectory.appending(path: "original.wav")
        #expect(try Data(contentsOf: originalURL) == bytes)

        let metadata = try #require(try ProcessingMetadataStore(sessionURL: created.url).load())
        let runs = try #require(metadata.activeRuns)
        #expect(runs.segmentation != nil)
        #expect(runs.asr != nil)
        #expect(runs.diarization != nil)
        let rows = try materializedRows(sessionURL: created.url)
        #expect(rows.map(\.text) == ["日本語のテストです。"])
        try assertExportMatchesMaterialization(outputURL: outputURL, rows: rows)
        #expect(harness.resourceFactoryCalls.snapshot() == 1)
    }

    @Test
    func inspectReportsDecisionRetryWithExactJSONAndDoesNotTouchEventsOrCreateResources() async throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let audioURL = try environment.makeInput()
        let outputURL = environment.root.appending(path: "transcript.json")
        let harness = ServiceTestHarness(environment: environment)
        let recorder = ServiceEventRecorder()
        let result = try await importedSession(using: harness, audioURL: audioURL, outputURL: outputURL, recorder: recorder)
        #expect(result.disposition == .completed)
        let created = try #require(await recorder.createdSessions().first)
        let layout = SessionLayout(sessionURL: created.url)
        let before = try Data(contentsOf: layout.eventsURL)
        let resourceCalls = harness.resourceFactoryCalls.snapshot()

        let inspection = try harness.service.inspect(sessionID: created.id)
        let inspectionJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(inspection)) as? [String: Any]
        #expect(inspection.action == "retryContentPriority")
        #expect(inspection.maintenance == nil)
        #expect(Set(try #require(inspectionJSON).keys) == Set(["session_id", "action", "maintenance"]))
        #expect(inspectionJSON?["session_id"] as? String == created.id.uuidString)
        #expect(inspectionJSON?["action"] as? String == "retryContentPriority")
        #expect(inspectionJSON?["maintenance"] is NSNull)
        #expect(try Data(contentsOf: layout.eventsURL) == before)
        #expect(harness.resourceFactoryCalls.snapshot() == resourceCalls)
    }

    @Test(arguments: [false, true])
    func resumeOfDisabledOrSatisfiedTranscriptExportsWithoutResources(
        withDecisions: Bool
    ) async throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let audioURL = try environment.makeInput()
        let outputURL = environment.root.appending(path: "transcript.json")
        let decisions = ServiceDecisionHarness()
        let harness = withDecisions
            ? ServiceTestHarness(environment: environment, decisions: decisions)
            : ServiceTestHarness(environment: environment)
        let recorder = ServiceEventRecorder()
        let importResult = try await importedSession(
            using: harness,
            audioURL: audioURL,
            outputURL: outputURL,
            withDecisions: withDecisions,
            recorder: recorder
        )
        #expect(importResult.disposition == .completed)
        let created = try #require(await recorder.createdSessions().first)
        let layout = SessionLayout(sessionURL: created.url)
        let beforeEvents = try Data(contentsOf: layout.eventsURL)
        let beforeExport = try Data(contentsOf: outputURL)
        let rows = try materializedRows(sessionURL: created.url)
        try assertExportMatchesMaterialization(outputURL: outputURL, rows: rows)
        let resourceCallsBeforeResume = harness.resourceFactoryCalls.snapshot()

        let resumed = try await harness.service.resume(
            SessionFileProcessingService.ResumeRequest(
                sessionID: created.id,
                outputURL: outputURL,
                pacingMode: .normal,
                withDecisions: withDecisions
            ),
            callbacks: serviceCallbacks(recorder)
        )

        #expect(resumed.disposition == .completed)
        #expect(harness.resourceFactoryCalls.snapshot() == resourceCallsBeforeResume)
        #expect(try Data(contentsOf: layout.eventsURL) == beforeEvents)
        #expect(try canonicalJSON(Data(contentsOf: outputURL)) == canonicalJSON(beforeExport))
        try assertExportMatchesMaterialization(outputURL: outputURL, rows: rows)
        if withDecisions {
            let metadata = try #require(try ProcessingMetadataStore(sessionURL: created.url).load())
            #expect(metadata.pendingDecisionTargets.isEmpty)
            #expect(metadata.activeRuns?.clauseBoundary != nil)
            #expect(metadata.activeRuns?.contentPriority != nil)
        }
    }

    @Test
    func interruptedImportedFinalizationResumesFromRunningMetadata() async throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let audioURL = try environment.makeInput()
        let sessionID = UUID()
        let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
            paths: environment.paths,
            sessionID: sessionID,
            source: .imported(originalFilename: audioURL.lastPathComponent),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let imported = try AudioImporter().importFile(audioURL, into: sessionURL)
        #expect(try Data(contentsOf: imported.originalURL) == Data(contentsOf: audioURL))
        try ProcessingMetadataStore(sessionURL: sessionURL).beginFinalization(
            attemptID: "finalize_interrupted_fixture",
            policy: .reject
        )
        let harness = ServiceTestHarness(environment: environment)
        let recorder = ServiceEventRecorder()
        let outputURL = environment.root.appending(path: "resumed.json")

        let before = try harness.service.inspect(sessionID: sessionID)
        #expect(before.action == "finalize")
        #expect(harness.resourceFactoryCalls.snapshot() == 0)
        let result = try await harness.service.resume(
            SessionFileProcessingService.ResumeRequest(
                sessionID: sessionID,
                outputURL: outputURL,
                pacingMode: .normal,
                withDecisions: false
            ),
            callbacks: serviceCallbacks(recorder)
        )

        #expect(result.disposition == .completed)
        #expect(harness.resourceFactoryCalls.snapshot() == 1)
        let metadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
        #expect(metadata.finalizationAttempt?.state == .complete)
        #expect(metadata.activeRuns?.segmentation != nil)
        #expect(metadata.activeRuns?.asr != nil)
        #expect(metadata.activeRuns?.diarization != nil)
        #expect(try Data(contentsOf: imported.originalURL) == Data(contentsOf: audioURL))
        try assertExportMatchesMaterialization(outputURL: outputURL, rows: try materializedRows(sessionURL: sessionURL))
        #expect(await recorder.exportCount() == 1)
    }

    @Test(arguments: [false, true])
    func decisionOnlyResumeRetriesPublishedTargetsAndRecoversUnpublishedRuns(
        recoverUnpublishedRun: Bool
    ) async throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let audioURL = try environment.makeInput()
        let outputURL = environment.root.appending(path: "decision-resume.json")
        let decisions = ServiceDecisionHarness()
        let harness = ServiceTestHarness(environment: environment, decisions: decisions)
        let recorder = ServiceEventRecorder()
        let imported = try await importedSession(using: harness, audioURL: audioURL, outputURL: outputURL, recorder: recorder)
        #expect(imported.disposition == .completed)
        let created = try #require(await recorder.createdSessions().first)
        let beforeMetadata = try #require(try ProcessingMetadataStore(sessionURL: created.url).load())
        #expect(!beforeMetadata.pendingDecisionTargets.isEmpty)
        let engineCallsBefore = await harness.engineCalls.snapshot()

        if recoverUnpublishedRun {
            let writer = try SessionWriter(sessionURL: created.url)
            _ = try await writer.append(EventDraft(
                eventType: "processing.run.started",
                sessionID: created.id,
                processingRunID: "priority_unpublished_fixture",
                payload: ProcessingRunStartedPayload(
                    stage: .contentPriority,
                    provenance: DecisionRunProvenance.priority(mode: "retry", identity: testDecisionIdentity)
                )
            ))
        }
        let inspection = try harness.service.inspect(sessionID: created.id)
        #expect(inspection.action == (recoverUnpublishedRun ? "recoverDecisionRun" : "retryContentPriority"))
        let eventsBeforeResume = try Data(contentsOf: SessionLayout(sessionURL: created.url).eventsURL)
        let resourceCallsBeforeResume = harness.resourceFactoryCalls.snapshot()

        let result = try await harness.service.resume(
            SessionFileProcessingService.ResumeRequest(
                sessionID: created.id,
                outputURL: outputURL,
                pacingMode: .normal,
                withDecisions: true
            ),
            callbacks: serviceCallbacks(recorder)
        )

        #expect(result.disposition == .completed)
        #expect(harness.resourceFactoryCalls.snapshot() == resourceCallsBeforeResume + 1)
        #expect(await harness.engineCalls.snapshot().asr == engineCallsBefore.asr)
        #expect(await harness.engineCalls.snapshot().vad == engineCallsBefore.vad)
        #expect(await harness.engineCalls.snapshot().diarization == engineCallsBefore.diarization)
        let metadata = try #require(try ProcessingMetadataStore(sessionURL: created.url).load())
        #expect(metadata.pendingDecisionTargets.isEmpty)
        #expect(metadata.activeRuns?.clauseBoundary != nil)
        #expect(metadata.activeRuns?.contentPriority != nil)
        #expect(try materializedRows(sessionURL: created.url).map(\.text) == ["日本語のテストです。"])
        try assertExportMatchesMaterialization(outputURL: outputURL, rows: try materializedRows(sessionURL: created.url))
        let requestCounts = await decisions.provider.requestCounts()
        #expect(requestCounts.boundary > 0)
        #expect(requestCounts.priority > 0)
        #expect(decisions.providerLoadCount.snapshot() == 1)
        let usage = await decisions.usageCounter.snapshot()
        #expect(usage.pendingBoundarySegmentCount == 0)
        #expect(usage.pendingPriorityClauseCount == 0)
        #expect(try Data(contentsOf: SessionLayout(sessionURL: created.url).eventsURL) != eventsBeforeResume)
    }

    @Test
    func failedDecisionRequestRejectsDecisionExportButKeepsPublishedLocalTranscript() async throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let audioURL = try environment.makeInput()
        let outputURL = environment.root.appending(path: "must-not-export.json")
        let decisions = ServiceDecisionHarness(failRequests: true)
        let harness = ServiceTestHarness(environment: environment, decisions: decisions)
        let recorder = ServiceEventRecorder()

        await #expect(throws: SessionFileProcessingError.self) {
            _ = try await importedSession(
                using: harness,
                audioURL: audioURL,
                outputURL: outputURL,
                withDecisions: true,
                recorder: recorder
            )
        }

        let created = try #require(await recorder.createdSessions().first)
        let metadata = try #require(try ProcessingMetadataStore(sessionURL: created.url).load())
        #expect(metadata.finalizationAttempt?.state == .complete)
        #expect(metadata.activeRuns?.segmentation != nil)
        #expect(metadata.activeRuns?.asr != nil)
        #expect(metadata.activeRuns?.diarization != nil)
        #expect(!metadata.pendingDecisionTargets.isEmpty)
        #expect(try materializedRows(sessionURL: created.url).map(\.text) == ["日本語のテストです。"])
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        #expect(await recorder.exportCount() == 0)
        #expect(decisions.providerLoadCount.snapshot() == 1)
        #expect(await decisions.provider.requestCounts().boundary == 1)
    }

    @Test
    func failedDecisionRetryKeepsPublishedSnapshotAndDoesNotExport() async throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let audioURL = try environment.makeInput()
        let outputURL = environment.root.appending(path: "retry-must-not-export.json")
        let decisions = ServiceDecisionHarness(failRequests: true)
        let harness = ServiceTestHarness(environment: environment, decisions: decisions)
        let recorder = ServiceEventRecorder()

        await #expect(throws: SessionFileProcessingError.self) {
            _ = try await importedSession(
                using: harness,
                audioURL: audioURL,
                outputURL: outputURL,
                withDecisions: true,
                recorder: recorder
            )
        }

        let created = try #require(await recorder.createdSessions().first)
        let metadataStore = ProcessingMetadataStore(sessionURL: created.url)
        let published = try #require(try metadataStore.load())
        let publishedRows = try materializedRows(sessionURL: created.url)
        #expect(published.finalizationAttempt?.state == .complete)
        #expect(!published.pendingDecisionTargets.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        #expect(await recorder.exportCount() == 0)

        let providerFailure = "テスト判定エンジンに失敗しました"
        let expectedMessage = "発話文の判定を再試行できませんでした: \(providerFailure)"
        await decisions.provider.configureRetryFailure(providerFailure)
        let retryCallbacks = ServiceCallbackRecorder()
        let result = try await harness.service.resume(
            SessionFileProcessingService.ResumeRequest(
                sessionID: created.id,
                outputURL: outputURL,
                pacingMode: .normal,
                withDecisions: true
            ),
            callbacks: SessionFileProcessingService.Callbacks(
                onEvent: { await recorder.record($0) },
                onStatus: { await retryCallbacks.recordStatus($0.text) },
                onUpdate: { _, state in await retryCallbacks.recordUpdateState(state) },
                shouldPause: { nil },
                onPhase: { _ in }
            )
        )

        #expect(result.disposition == .failed)
        #expect(result.message == expectedMessage)
        #expect(await retryCallbacks.statuses().filter { $0 == expectedMessage }.count == 1)
        let partialFailureUpdateCount = await retryCallbacks.partialFailureUpdateCount()
        #expect(partialFailureUpdateCount == 0)
        #expect(try metadataStore.load() == published)
        #expect(try materializedRows(sessionURL: created.url) == publishedRows)
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        #expect(await recorder.exportCount() == 0)
    }

    @Test(arguments: [false, true])
    func failedImportCleansTemporarySessionOnlyWhenNotRetained(keepSession: Bool) async throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let audioURL = try environment.makeInput()
        let outputURL = environment.root.appending(path: "failed.json")
        let harness = ServiceTestHarness(environment: environment, asrFails: true)
        let recorder = ServiceEventRecorder()

        let result = try await importedSession(
            using: harness,
            audioURL: audioURL,
            outputURL: outputURL,
            keepSession: keepSession,
            recorder: recorder
        )

        #expect(result.disposition == .failed)
        let created = try #require(await recorder.createdSessions().first)
        #expect(await recorder.createdSessions().count == 1)
        #expect(FileManager.default.fileExists(atPath: created.url.path) == keepSession)
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        if keepSession {
            let metadata = try #require(try ProcessingMetadataStore(sessionURL: created.url).load())
            #expect(metadata.finalizationAttempt?.state == .failed)
        }
        #expect(await recorder.cleanupFailureCount() == 0)
    }

    @Test
    func invalidAliasesAndMissingAudioAreRejectedBeforeResourceCreation() async throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let audioURL = try environment.makeInput()
        let harness = ServiceTestHarness(environment: environment)
        let recorder = ServiceEventRecorder()

        await #expect(throws: SessionFileProcessingError.self) {
            _ = try await importedSession(
                using: harness,
                audioURL: audioURL,
                outputURL: audioURL,
                recorder: recorder
            )
        }
        #expect(harness.resourceFactoryCalls.snapshot() == 0)

        let missingURL = environment.root.appending(path: "missing.wav")
        await #expect(throws: SessionFileProcessingError.self) {
            _ = try await importedSession(
                using: harness,
                audioURL: missingURL,
                outputURL: environment.root.appending(path: "missing-export.json"),
                recorder: recorder
            )
        }
        #expect(harness.resourceFactoryCalls.snapshot() == 0)

        let retained = try await importedSession(
            using: harness,
            audioURL: audioURL,
            outputURL: environment.root.appending(path: "retained.json"),
            recorder: recorder
        )
        #expect(retained.disposition == .completed)
        let created = try #require(await recorder.createdSessions().first)
        let callsBeforeResume = harness.resourceFactoryCalls.snapshot()
        await #expect(throws: SessionFileProcessingError.self) {
            _ = try await harness.service.resume(
                SessionFileProcessingService.ResumeRequest(
                    sessionID: created.id,
                    outputURL: created.url.appending(path: "nested/output.json"),
                    pacingMode: .normal,
                    withDecisions: false
                ),
                callbacks: serviceCallbacks(recorder)
            )
        }
        #expect(harness.resourceFactoryCalls.snapshot() == callsBeforeResume)
    }

    @Test
    func noSpeechWithDecisionsExportsEmptyArrayWithoutDecisionRuns() async throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let audioURL = try environment.makeInput()
        let outputURL = environment.root.appending(path: "empty.json")
        let decisions = ServiceDecisionHarness()
        let harness = ServiceTestHarness(environment: environment, producesSpeech: false, decisions: decisions)
        let recorder = ServiceEventRecorder()

        let result = try await importedSession(
            using: harness,
            audioURL: audioURL,
            outputURL: outputURL,
            withDecisions: true,
            recorder: recorder
        )

        #expect(result.disposition == .completed)
        #expect(result.noSpeech)
        let exported = try JSONSerialization.jsonObject(with: Data(contentsOf: outputURL)) as? [Any]
        #expect(exported?.isEmpty == true)
        let created = try #require(await recorder.createdSessions().first)
        let metadata = try #require(try ProcessingMetadataStore(sessionURL: created.url).load())
        #expect(metadata.pendingDecisionTargets.isEmpty)
        #expect(metadata.activeRuns?.clauseBoundary == nil)
        #expect(metadata.activeRuns?.contentPriority == nil)
        #expect(await decisions.provider.requestCounts().boundary == 0)
        #expect(await decisions.provider.requestCounts().priority == 0)
        let usage = await decisions.usageCounter.snapshot()
        #expect(usage.sendCount == 0)
        #expect(decisions.providerLoadCount.snapshot() == 1)
    }

    @Test
    func retainedImportKeepsOriginalAndSessionWithOneFinalizeRequestAndNoProcessingOrJSON() throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let bytes = Data([0x52, 0x49, 0x46, 0x46, 0x11, 0x22, 0x33, 0x44, 0x80, 0xfe])
        let audioURL = try environment.makeInput(bytes: bytes)

        let retained = try RetainedSessionImporter(paths: .trustedApplication(environment.paths))
            .importRetainedSession(audioURL: audioURL)

        let originalURL = SessionLayout(sessionURL: retained.sessionURL).audioDirectory.appending(path: "original.wav")
        #expect(try Data(contentsOf: originalURL) == bytes)
        #expect(try SessionLayout(sessionURL: retained.sessionURL).loadManifest().sessionID == retained.sessionID)
        #expect(retained.finalize == SessionFinalizeRequest(sessionID: retained.sessionID, metadataPolicy: .reject))
        #expect(retained.finalize.pending.sessionID == retained.sessionID)
        #expect(try ProcessingMetadataStore(sessionURL: retained.sessionURL).load()?.activeRuns == nil)
        let sessionEntries = try FileManager.default.contentsOfDirectory(
            at: environment.paths.sessionsRoot, includingPropertiesForKeys: nil
        )
        #expect(sessionEntries.map(\.lastPathComponent) == [retained.sessionURL.lastPathComponent])
        let rootEntries = try FileManager.default.contentsOfDirectory(at: environment.root, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        #expect(rootEntries.filter { $0.hasSuffix(".json") }.isEmpty)
    }

    @Test
    func retainedImportOfMissingAudioReportsCopyFailureWithTheCreatedSession() throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let missing = environment.root.appending(path: "missing.wav")

        do {
            _ = try RetainedSessionImporter(paths: .trustedApplication(environment.paths))
                .importRetainedSession(audioURL: missing)
            Issue.record("a missing audio file must fail the import")
        } catch let error as RetainedImportError {
            let created = try #require(error.createdSession)
            #expect(FileManager.default.fileExists(atPath: created.sessionURL.path))
        }
    }

    @Test
    func externalRootStillRejectsProtectedRootsWhileTrustedApplicationRootIsAdmitted() throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let protectedRoot = environment.paths.sessionsRoot

        #expect(throws: SessionsRootPolicy.Error.self) {
            _ = try ValidatedSessionPaths.externalRoot(environment.paths, protectedRoots: [protectedRoot])
        }
        let trusted = ValidatedSessionPaths.trustedApplication(environment.paths)
        #expect(trusted.paths.sessionsRoot == environment.paths.sessionsRoot)
    }

    @Test
    func cliServiceRejectsProtectedRootBeforeImportingAnything() async throws {
        let environment = try ServiceEnvironment()
        defer { environment.remove() }
        let audioURL = try environment.makeInput()
        let service = SessionFileProcessingService(
            paths: environment.paths,
            protectedRoots: [environment.paths.sessionsRoot],
            timelineBuilder: FakeServiceTimelineBuilder(samples: []),
            makeResources: { _ in throw ServiceTestFailure.expected },
            sleep: { _ in }
        )
        let recorder = ServiceEventRecorder()

        await #expect(throws: SessionsRootPolicy.Error.self) {
            _ = try await service.importFile(
                .init(
                    audioURL: audioURL,
                    outputURL: environment.root.appending(path: "out.json"),
                    keepSession: true,
                    pacingMode: .normal,
                    withDecisions: false
                ),
                callbacks: serviceCallbacks(recorder)
            )
        }
        #expect(await recorder.createdSessions().isEmpty)
    }

    @Test
    func recoveryPlanRoutesInspectionNamesInferenceAndEnqueueRequests() {
        let sessionID = UUID()
        let none = SessionRecoveryPlan(nil)
        let finalize = SessionRecoveryPlan(.finalize)
        let recover = SessionRecoveryPlan(.recoverDecisionRun(boundarySegments: [], clauses: []))
        let retry = SessionRecoveryPlan(.retryContentPriority(boundarySegments: [], clauses: []))

        #expect([none, finalize, recover, retry].map(\.inspectionName)
            == ["none", "finalize", "recoverDecisionRun", "retryContentPriority"])
        #expect(!none.requiresInference(withDecisions: true))
        #expect(finalize.requiresInference(withDecisions: false))
        #expect(recover.requiresInference(withDecisions: true) && !recover.requiresInference(withDecisions: false))
        #expect(retry.requiresInference(withDecisions: true) && !retry.requiresInference(withDecisions: false))

        #expect(finalize.launchRecoveryRequest(sessionID: sessionID)?.finalizesTranscript == true)
        #expect(recover.launchRecoveryRequest(sessionID: sessionID)?.finalizesTranscript == false)
        #expect(retry.launchRecoveryRequest(sessionID: sessionID) == nil)
        #expect(none.launchRecoveryRequest(sessionID: sessionID) == nil)
        #expect(recover.decisionRetryRequest(sessionID: sessionID) != nil)
        #expect(retry.decisionRetryRequest(sessionID: sessionID) != nil)
        #expect(finalize.decisionRetryRequest(sessionID: sessionID) == nil)
    }
}
