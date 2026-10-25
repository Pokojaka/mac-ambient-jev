import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

public struct EngineApplicationConfiguration: Sendable {
    public let paths: AppPaths
    public let logicalCPUCount: Int
    /// The pacing sleep of live transcription.
    public let sleep: @MainActor @Sendable (Duration) async throws -> Void
    /// How long shutdown waits for running finalization to stop at its next boundary before it fails.
    public let shutdownPauseTimeout: Duration

    public init(
        paths: AppPaths,
        logicalCPUCount: Int,
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void,
        shutdownPauseTimeout: Duration
    ) {
        self.paths = paths
        self.logicalCPUCount = logicalCPUCount
        self.sleep = sleep
        self.shutdownPauseTimeout = shutdownPauseTimeout
    }
}

/// The real engine: the handlers behind `EngineController`, composed from the shared recording-start coordinator,
/// the live and processing coordinators, startup recovery, the settings store and the portable exporter. Capture and
/// inference come from injected adapters, so the same composition runs on every OS under test.
@MainActor
public final class EngineApplication {
    let core: EngineApplicationCore

    public init(
        configuration: EngineApplicationConfiguration,
        capture: any EngineCaptureProviding,
        inference: any EngineInferenceProviding,
        events: EngineEventEmitter
    ) {
        core = EngineApplicationCore(configuration: configuration, capture: capture, inference: inference, events: events)
    }

    public var handlers: EngineHandlers {
        EngineHandlers(
            state: core, recording: core, sessions: core, transcript: core,
            settings: core, models: core, shutdown: core
        )
    }

    /// Starts startup recovery: storage maintenance, then the recovery of sessions a forced kill left unfinished.
    /// Recording and import are refused until maintenance ends. Call once, before the controller runs.
    public func start() {
        core.start()
    }

    /// Returns when startup recovery has scanned, maintained and queued; queued finalizations may still run.
    public func waitForStartupRecovery() async {
        await core.startupTask?.value
    }
}

@MainActor
final class EngineApplicationCore {
    static let failureLimit = 16
    static let queueLimit = 16

    let paths: AppPaths
    let logicalCPUCount: Int
    let settingsStore: EngineSettingsStore
    let capture: any EngineCaptureProviding
    let inferenceProvider: any EngineInferenceProviding
    let events: EngineEventEmitter
    let sleep: @MainActor @Sendable (Duration) async throws -> Void
    let shutdownPauseTimeout: Duration
    let gateway = EngineProcessorGateway()
    let thermalMonitor = WindowsNoThermalMonitoring()
    let completions = EngineCompletionRegistry()

    // Settings and models
    var settingsResult: EngineSettingsResult?
    var inference: EngineInference?
    var isPreparingModels = false
    var presentation = EnginePresentation()
    var isShuttingDown = false
    private(set) var mutationTasks: [UUID: Task<Void, Never>] = [:]

    // Recording
    var recording = RecordingLifecycle()
    var captureSession: (any EngineCaptureSession)?
    var startAttempt: StartAttempt?
    var startTask: Task<Void, Never>?
    var stopTask: Task<Void, Never>?
    var finishOutcomes: [UUID: RecordingFinishOutcome] = [:]
    var activeRecording: (source: EngineSource, device: EngineDevice)?

    // Processing and recovery
    var processingQueue = SessionProcessingQueue()
    let liveTranscription = LiveTranscriptionState()
    var savedSessionOperations = SavedSessionOperations()
    var savedSessionsAreStale = true
    var sessionListSnapshot: EngineSessionListSnapshot?
    var idleReleaseTask: Task<Void, Never>?
    var startupTask: Task<Void, Never>?
    var recoveryStatus: EngineRecoveryStatus = .pending
    var recoveryOutstanding: Set<UUID> = []
    var scanFailed = false
    var isImporting: Bool { recording.phase == .importing }

    // Transcript
    var watchedSessionID: UUID?
    var watchedSessionIsFinal = false
    var transcript: EngineTranscriptCache?
    var readTranscript: EngineTranscriptCache?
    var transcriptReadSnapshot: EngineTranscriptCache?
    var transcriptReadNavigation: EnginePageNavigation?
    var transcriptRowDetailsSnapshot: EngineTranscriptRowDetailsSnapshot?
    var nextTranscriptRevision: UInt64 = 0

    // State publication
    var failures: [EngineFailure] = []
    var stateRevision: UInt64 = 1
    var publishedState: EngineState?
    var eventsEnabled = false
    var pendingFailureEvents: [EngineFailure] = []
    var failureEventTask: Task<Void, Never>?
    var inFlightFailureEvent: EngineFailure?
    var eventsClosed = false
    var onBackgroundEventStateChange: (@MainActor () -> Void)?

    lazy var processingCoordinator = SessionProcessingCoordinator(
        effects: self, processor: gateway, thermalMonitor: thermalMonitor
    )
    lazy var liveCoordinator = LiveTranscriptionCoordinator(
        state: liveTranscription, effects: self, processor: gateway, thermalMonitor: thermalMonitor, sleep: sleep
    )

    struct StartAttempt {
        let source: EngineSource
        let device: EngineDevice
        var sessionURL: URL?
        var error: EngineCommandError?
    }

    init(
        configuration: EngineApplicationConfiguration,
        capture: any EngineCaptureProviding,
        inference: any EngineInferenceProviding,
        events: EngineEventEmitter
    ) {
        paths = configuration.paths
        logicalCPUCount = configuration.logicalCPUCount
        settingsStore = EngineSettingsStore(paths: configuration.paths, logicalCPUCount: configuration.logicalCPUCount)
        self.capture = capture
        inferenceProvider = inference
        self.events = events
        sleep = configuration.sleep
        shutdownPauseTimeout = configuration.shutdownPauseTimeout
        loadSettings()
    }

    func performMutation<T: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        guard !isShuttingDown else {
            throw EngineFailures.commandError(.cancelled, "終了処理中のため変更を開始できません", stage: .shutdown)
        }

        let mutationID = UUID()
        let task = Task { @MainActor in try await operation() }
        let tracker = Task { @MainActor [self] in
            _ = await task.result
            _ = mutationTasks.removeValue(forKey: mutationID)
        }
        mutationTasks[mutationID] = tracker
        return try await task.value
    }

    // MARK: Settings

    var settings: EngineSettings? { settingsResult?.settings }

    /// Reads settings.json. A missing or corrupt file leaves the engine in `settings_required`; the specific
    /// problem is reported by `settings.get`.
    func loadSettings() {
        do {
            settingsResult = try settingsStore.load()
        } catch let error as EngineSettingsError {
            settingsResult = nil
            switch error {
            case .required, .corrupt:
                break
            case .invalid, .staleRevision, .revisionExhausted, .filesystem:
                report(EngineFailures.failure(
                    code: error.errorCode, message: error.errorDescription ?? String(describing: error),
                    stage: .settings, sessionID: nil, severity: .error, recoveryAction: error.recoveryAction
                ))
            }
        } catch {
            preconditionFailure("EngineSettingsStore.load throws EngineSettingsError only: \(error)")
        }
    }

    var setupStatus: EngineSetupStatus {
        if settingsResult == nil { return .settingsRequired }
        if inference == nil { return .modelsRequired }
        return .ready
    }

    // MARK: State

    func start() {
        precondition(startupTask == nil, "startup recovery already started")
        recoveryStatus = .running
        processingQueue.beginStorageMaintenance()
        stateDidChange()
        startupTask = Task { [self] in await runStartupRecovery() }
    }

    func capabilities() throws -> EngineCapabilities {
        try EngineCapabilities(
            sources: [.microphone, .systemAudio], asrSizes: [.small, .large], executionProviders: [.cpu],
            maximumThreads: min(PortableThreadLimit.maximum, logicalCPUCount),
            automaticInputVolume: .none, thermalMonitoring: .none
        )
    }

    func currentState() -> EngineState {
        stateDidChange()
        guard let publishedState else { preconditionFailure("stateDidChange publishes a state") }
        return publishedState
    }

    /// Recomputes the state; when it differs from the published one the revision advances and, once the client
    /// has said hello, the new state is sent.
    func stateDidChange() {
        let candidate = makeState(revision: stateRevision)
        if let publishedState, publishedState == candidate { return }
        if publishedState != nil { stateRevision += 1 }
        let next = makeState(revision: stateRevision)
        publishedState = next
        guard eventsEnabled else { return }
        do {
            try events.state(next)
        } catch {
            EngineLog.write("state event not sent: \(error)")
        }
    }

    private func makeState(revision: UInt64) -> EngineState {
        do {
            return try EngineState(
                revision: try EngineID(revision),
                screen: screen,
                setup: setupStatus,
                recovery: recoveryStatus,
                recording: try recordingState(),
                queue: try queueState(),
                failures: failures,
                presentation: try presentationState()
            )
        } catch {
            preconditionFailure("engine state fields are valid by construction: \(error)")
        }
    }

    private var screen: EngineScreen {
        switch recording.phase {
        case .starting, .recording: return .live
        case .stopping: return .finalizing
        case .idle, .requestingPermission, .importing: break
        }
        if let watchedSessionID, processingQueue.sessionIDs.contains(watchedSessionID) { return .finalizing }
        if watchedSessionID != nil, watchedSessionIsFinal { return .finalized }
        return .idle
    }

    private func recordingState() throws -> EngineRecordingState? {
        guard let sessionID = recording.sessionID, let activeRecording else { return nil }
        let phase: EngineRecordingPhase
        switch recording.phase {
        case .starting: phase = .starting
        case .recording: phase = presentation.isWaitingForDevice ? .waitingForDevice : .recording
        case .stopping: phase = .stopping
        case .idle, .requestingPermission, .importing: return nil
        }
        return try EngineRecordingState(
            sessionID: EngineFailures.wireID(sessionID), source: activeRecording.source,
            device: activeRecording.device, phase: phase
        )
    }

    private func queueState() throws -> [EngineQueuedOperation] {
        var operations: [EngineQueuedOperation] = []
        func add(_ request: PendingProcessing) throws {
            let stage: EngineStage = request.finalizesTranscript ? .finalization : .decisions
            operations.append(try EngineQueuedOperation(sessionID: EngineFailures.wireID(request.sessionID), stage: stage))
        }
        if let current = processingQueue.currentSessionID {
            operations.append(try EngineQueuedOperation(sessionID: EngineFailures.wireID(current), stage: .finalization))
        }
        for request in processingQueue.pending { try add(request) }
        for request in processingQueue.thermallyHeld { try add(request) }
        return Array(operations.prefix(Self.queueLimit))
    }

    /// Records a failure no request awaits: it joins the state's bounded failure list and, once the client has
    /// said hello, is also sent as an `error` event.
    func report(_ failure: EngineFailure) {
        guard !pendingFailureEvents.contains(failure), inFlightFailureEvent != failure else {
            return
        }
        failures.append(failure)
        if failures.count > Self.failureLimit { failures.removeFirst(failures.count - Self.failureLimit) }
        stateDidChange()
        guard eventsEnabled, !eventsClosed else { return }

        if pendingFailureEvents.count == Self.failureLimit {
            pendingFailureEvents.removeFirst()
            EngineLog.write("background error events coalesced; consult state.failures")
        }
        pendingFailureEvents.append(failure)
        if failureEventTask == nil {
            failureEventTask = Task { @MainActor [self] in await drainFailureEvents() }
        }
    }

    private func drainFailureEvents() async {
        while eventsEnabled, !eventsClosed, !pendingFailureEvents.isEmpty {
            let failure = pendingFailureEvents.removeFirst()
            inFlightFailureEvent = failure
            onBackgroundEventStateChange?()
            do {
                try await events.failure(failure)
            } catch {
                EngineLog.write("error event not sent: \(error)")
            }
            inFlightFailureEvent = nil
            onBackgroundEventStateChange?()
        }
        failureEventTask = nil
        onBackgroundEventStateChange?()
    }

    func clearFailures(sessionID: UUID) {
        let wire = EngineFailures.wireID(sessionID)
        failures.removeAll { $0.sessionID == wire }
        stateDidChange()
    }

    // MARK: Settings and models handlers

    func requireSettings(stage: EngineStage) throws -> EngineSettings {
        guard let settings else {
            throw EngineFailures.commandError(
                .settingsRequired, "設定が必要です。settings.replace で設定を保存してください",
                stage: stage, recoveryAction: .replaceSettings
            )
        }
        return settings
    }

    func requireModelsPrepared(stage: EngineStage) throws -> EngineInference {
        guard !isPreparingModels else {
            throw EngineFailures.commandError(
                .busy, "モデルの準備が実行中です", stage: stage, recoveryAction: .retry
            )
        }
        guard let inference else {
            throw EngineFailures.commandError(
                .modelMissing, "モデルが準備されていません。models.prepare を実行してください",
                stage: stage, recoveryAction: .prepareModels
            )
        }
        return inference
    }

    var isIdleForSettingsChange: Bool {
        recording.phase == .idle && isProcessingIdle && !isPreparingModels
    }

    /// No finalization, decision retry or live transcription is queued or running.
    var isProcessingIdle: Bool {
        processingQueue.pending.isEmpty
            && processingQueue.thermallyHeld.isEmpty
            && !processingCoordinator.isDraining
            && processingQueue.currentSessionID == nil
            && processingQueue.claimedSessionIDs.isEmpty
            && liveCoordinator.isASRIdle
    }

    func profileDiffers(_ old: EngineSettings, _ new: EngineSettings) -> Bool {
        old.asrSize != new.asrSize
            || old.executionProvider != new.executionProvider
            || old.threads != new.threads
            || old.decisionsEnabled != new.decisionsEnabled
    }

    func installProcessor(for inference: EngineInference, settings: EngineSettings) {
        let processor = NativeSessionProcessor(
            paths: paths,
            engines: inference.engines,
            audioHandling: SessionProcessingAudio(timelineBuilder: inference.timelineBuilder),
            contentPriority: inference.contentPriority,
            sleep: { try await Task.sleep(for: $0) }
        )
        gateway.install(processor, pacing: settings.lowHeat ? .lowHeat : .normal)
    }
}

// The Sendable requirement of the protocol must be declared in the class's file; its witnesses are in
// `EngineApplication+Processing.swift`.
extension EngineApplicationCore: SessionRecoveryEffects {}

enum PortableThreadLimit {
    /// The engine accepts at most four inference threads, matching `PortableProcessingConfiguration.maximumThreads`.
    static let maximum = 4
}

/// A transcript row that failed to project or encode, with the input it failed on.
struct EngineTranscriptRowFailure: Equatable {
    enum Input: Equatable {
        case segments([MaterializedTranscriptSegment])
        case row(EngineTranscriptRow)
        case removal
    }

    let rowID: String
    let input: Input
    let failure: EngineFailure
}

struct EngineTranscriptCache {
    let sessionID: UUID
    var revision: UInt64
    var rows: [EngineTranscriptRow]
    var materializedSegments: [MaterializedTranscriptSegment]
    var isLiveState: Bool
    var projection: EngineTranscriptProjection.Incremental?
    var reportedTranscriptFailures: [EngineTranscriptRowFailure] = []
}

// MARK: EngineStateHandling

extension EngineApplicationCore: EngineStateHandling {
    func ready() async throws -> EngineReadyPayload {
        EngineReadyPayload(capabilities: try capabilities(), state: currentState())
    }

    func hello() async throws -> EngineReadyPayload {
        try await ready()
    }

    func helloDidComplete() {
        guard !eventsClosed else { return }
        eventsEnabled = true
        do {
            try events.state(currentState())
        } catch {
            EngineLog.write("state event not sent: \(error)")
        }
    }

    func state() async throws -> EngineState {
        currentState()
    }

    func diagnostics(context: EngineRequestContext) async throws -> EngineDiagnosticsResult {
        let decisionUsage: EngineDecisionUsage
        do {
            let snapshot = try await inferenceProvider.decisionUsage()
            let boundaryRequests = try EngineDecisionRequestUsage(
                sendCount: snapshot.boundaryRequests.sendCount,
                inputTokens: snapshot.boundaryRequests.inputTokens,
                successCount: snapshot.boundaryRequests.successCount,
                failureCount: snapshot.boundaryRequests.failureCount
            )
            let priorityRequests = try EngineDecisionRequestUsage(
                sendCount: snapshot.priorityRequests.sendCount,
                inputTokens: snapshot.priorityRequests.inputTokens,
                successCount: snapshot.priorityRequests.successCount,
                failureCount: snapshot.priorityRequests.failureCount
            )
            let mappedSnapshot = try EngineDecisionUsageSnapshot(
                sendCount: snapshot.sendCount,
                inputTokens: snapshot.inputTokens,
                successCount: snapshot.successCount,
                failureCount: snapshot.failureCount,
                pendingBoundarySegmentCount: snapshot.pendingBoundarySegmentCount,
                pendingPriorityClauseCount: snapshot.pendingPriorityClauseCount,
                boundaryRequests: boundaryRequests,
                priorityRequests: priorityRequests
            )
            decisionUsage = .available(mappedSnapshot)
        } catch {
            let failure = EngineFailures.failure(
                code: .internalError,
                message: "発話文判定の利用状況を取得できません: \(error.localizedDescription)",
                stage: .decisions,
                sessionID: nil,
                severity: .error,
                recoveryAction: .retry,
                details: [EngineFailures.detail(for: error)],
                cleanupErrors: []
            )
            decisionUsage = .unavailable(failure)
        }
        return EngineDiagnosticsResult(
            scope: .engineProcess,
            decisionUsage: decisionUsage,
            automaticInputVolume: .none,
            thermalMonitoring: .none
        )
    }
}

// MARK: EngineSettingsHandling

extension EngineApplicationCore: EngineSettingsHandling {
    private var settingsHandler: EngineSettingsStoreHandler {
        EngineSettingsStoreHandler(store: settingsStore) { [self] current, proposed in
            guard !isPreparingModels, !isShuttingDown else { return true }
            guard let current else { return false }
            return !isIdleForSettingsChange && profileDiffers(current, proposed)
        }
    }

    func get(context: EngineRequestContext) async throws -> EngineSettingsResult {
        try await settingsHandler.get(context: context)
    }

    func replace(_ payload: EngineSettingsReplacePayload, context: EngineRequestContext) async throws -> EngineSettingsResult {
        let previous = settings
        let result = try await settingsHandler.replace(payload, context: context)
        if previous?.exportDestinationPath != result.settings.exportDestinationPath {
            savedSessionOperations.resetExportDestination()
        }
        settingsResult = result
        gateway.setPacing(result.settings.lowHeat ? .lowHeat : .normal)
        if let previous, profileDiffers(previous, result.settings) {
            // A changed model profile invalidates the prepared state; no work is running (the handler refused otherwise).
            inference = nil
            presentation.preparationPhase = .idle
            presentation.preparationStatusText = nil
            if let removed = gateway.remove() { await removed.releaseIdleResources() }
        }
        stateDidChange()
        return result
    }
}

// MARK: EngineModelsHandling

extension EngineApplicationCore: EngineModelsHandling {
    private func checkModelPreparationCanContinue() throws {
        do {
            try Task.checkCancellation()
        } catch {
            throw EngineFailures.commandError(.cancelled, "モデルの準備が中止されました", stage: .loadingModels)
        }
        guard !isShuttingDown else {
            throw EngineFailures.commandError(.cancelled, "終了処理中のためモデルを準備できません", stage: .shutdown)
        }
    }

    func prepare(context: EngineRequestContext) async throws {
        let settings = try requireSettings(stage: .validatingModels)
        guard !isPreparingModels else {
            throw EngineFailures.commandError(
                .busy, "モデルの準備が実行中です", stage: .validatingModels, recoveryAction: .retry
            )
        }
        guard !isShuttingDown else {
            throw EngineFailures.commandError(.cancelled, "終了処理中のためモデルを準備できません", stage: .shutdown)
        }
        // Prepared models stay prepared while work uses them; verifying again would compete with that work.
        if inference != nil, !isIdleForSettingsChange { return }
        isPreparingModels = true
        presentation.preparationPhase = .preparing
        presentation.preparationStatusText = UserFacingStatus.preparingASR.text
        let preparationID = UUID()
        presentation.preparationID = preparationID
        stateDidChange()
        defer {
            isPreparingModels = false
            presentation.preparationID = nil
            stateDidChange()
        }

        let requestID = context.requestID
        let events = context.events
        let (progressStream, progressContinuation) = AsyncStream<EngineModelProgress>.makeStream()
        let progressConsumer = Task { @MainActor [weak self] in
            var validatingHighWater = 0
            var loadingHighWater = 0
            var hasStartedLoading = false

            for await progress in progressStream {
                guard let self,
                      self.presentation.preparationID == preparationID,
                      self.isPreparingModels else { continue }

                let stage: EngineStage
                let percentage: Int
                let preparationStatusText: String
                switch progress.stage {
                case .validating:
                    guard !hasStartedLoading else { continue }
                    let current = Int(
                        (Double(progress.completed) / Double(progress.total) * 100).rounded(.down)
                    )
                    validatingHighWater = max(validatingHighWater, current)
                    percentage = validatingHighWater
                    stage = .validatingModels
                    preparationStatusText = UserFacingStatus.preparingASR.text
                case .loading:
                    hasStartedLoading = true
                    let current = Int(
                        (Double(progress.completed) / Double(progress.total) * 100).rounded(.down)
                    )
                    loadingHighWater = max(loadingHighWater, current)
                    percentage = loadingHighWater
                    stage = .loadingModels
                    preparationStatusText = "音声認識モデルを読み込み中（\(percentage)%）"
                }

                do {
                    try events.progress(
                        EngineProgressPayload(
                            stage: stage, completedUnits: UInt64(percentage), totalUnits: 100, sessionID: nil
                        ),
                        requestID: requestID
                    )
                } catch {
                    EngineLog.write("model progress not sent: \(error)")
                }
                self.presentation.preparationStatusText = preparationStatusText
                self.stateDidChange()
            }
        }
        do {
            do {
                try await inferenceProvider.prepare(settings: settings) { progress in
                    precondition(
                        progress.total > 0 && progress.completed >= 0 && progress.completed <= progress.total,
                        "model preparation progress must have a positive total and a completed count within range"
                    )
                    progressContinuation.yield(progress)
                }
            } catch {
                progressContinuation.finish()
                await progressConsumer.value
                throw error
            }
            progressContinuation.finish()
            await progressConsumer.value

            try checkModelPreparationCanContinue()
            let prepared = try inferenceProvider.makeInference(settings: settings)
            if let removed = gateway.remove() { await removed.releaseIdleResources() }
            try checkModelPreparationCanContinue()
            inference = prepared
            installProcessor(for: prepared, settings: settings)
            presentation.preparationPhase = .ready
            presentation.preparationStatusText = nil
        } catch {
            inference = nil
            presentation.preparationID = nil
            presentation.preparationPhase = .failed
            presentation.preparationStatusText = "準備できませんでした: \(error.localizedDescription)"
            if let removed = gateway.remove() { await removed.releaseIdleResources() }
            if error is CancellationError {
                throw EngineFailures.commandError(.cancelled, "モデルの準備が中止されました", stage: .loadingModels)
            }
            throw EngineFailures.commandError(
                from: error, fallback: .modelFailure, stage: .loadingModels, recoveryAction: .prepareModels
            )
        }
        updateRecoveryStatus()
        // Finalizations queued while models were missing, such as launch recovery, can run now.
        processingCoordinator.startDrainIfIdle()
    }

    func inspect(context: EngineRequestContext) async throws -> EngineModelsInspection {
        do {
            let identity = try await inferenceProvider.inspectClauseTagger()
            let mappedIdentity = try EngineClauseTaggerIdentity(
                backend: identity.backend,
                modelID: identity.modelID,
                revision: identity.revision,
                tokenizerSHA256: identity.tokenizerSHA256
            )
            return EngineModelsInspection(clauseTagger: .validated(mappedIdentity))
        } catch is CancellationError {
            throw EngineFailures.commandError(.cancelled, "モデルの確認が中止されました", stage: .validatingModels)
        } catch {
            let commandError = EngineFailures.commandError(
                from: error,
                fallback: .modelFailure,
                stage: .validatingModels,
                recoveryAction: .prepareModels
            )
            return EngineModelsInspection(clauseTagger: .invalid(commandError.failure(requestID: nil)))
        }
    }
}

// MARK: EngineShutdownHandling

extension EngineApplicationCore: EngineShutdownHandling {
    /// Stops capture durably, pauses inference at its next boundary and waits for it. Sessions left unfinished are
    /// recovered on the next launch. Fails when running work does not pause within `shutdownPauseTimeout`.
    func shutdown(reason: EngineShutdownReason) async throws {
        eventsClosed = true
        eventsEnabled = false
        pendingFailureEvents.removeAll()
        onBackgroundEventStateChange?()
        let failureEventTaskAtShutdown = failureEventTask

        isShuttingDown = true
        processingCoordinator.requestPause()
        var sessionIDs = processingQueue.sessionIDs
        if let recordingSessionID = recording.sessionID {
            sessionIDs.insert(recordingSessionID)
        }

        startupTask?.cancel()
        await startupTask?.value
        startTask?.cancel()
        await startTask?.value
        await stopTask?.value
        if recording.phase == .recording,
           let sessionID = recording.sessionID,
           recording.beginStopping(sessionID: sessionID) {
            setRecordingStatus("録音を保存しています", tone: .neutral)
            stateDidChange()
            await runStop(sessionID: sessionID, failureMessage: nil)
        }

        sessionIDs.formUnion(processingQueue.sessionIDs)
        await liveCoordinator.stopVADPolling()
        liveCoordinator.resetVAD()
        await liveCoordinator.cancelAndWait(sessionIDs: sessionIDs)

        do {
            try await waitForProcessingToPause()
        } catch {
            await waitForMutations()
            await failureEventTaskAtShutdown?.value
            throw error
        }
        await waitForMutations()
        await idleReleaseTask?.value
        stateDidChange()
        await failureEventTaskAtShutdown?.value
    }

    private func waitForMutations() async {
        while !mutationTasks.isEmpty {
            let tasks = Array(mutationTasks.values)
            for task in tasks { await task.value }
        }
    }

    private func waitForProcessingToPause() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: shutdownPauseTimeout)
        while processingCoordinator.isDraining {
            if clock.now >= deadline {
                throw EngineFailures.commandError(
                    .internalError, "実行中の処理を安全に中断できませんでした", stage: .shutdown,
                    severity: .fatal, recoveryAction: .restart
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
