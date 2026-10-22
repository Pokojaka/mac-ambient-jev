import Foundation
import MacAmbientJevCore

public struct SessionFileProcessingResources: Sendable {
    public let engines: SessionProcessingEngines
    public let contentPriority: ContentPriorityAccess
    public let decisionProviderFactory: DecisionProviderFactory?

    public init(
        engines: SessionProcessingEngines,
        contentPriority: ContentPriorityAccess,
        decisionProviderFactory: DecisionProviderFactory?
    ) {
        self.engines = engines
        self.contentPriority = contentPriority
        self.decisionProviderFactory = decisionProviderFactory
    }
}

public enum SessionFileProcessingError: LocalizedError {
    case invalidOutput(String)
    case audioFileNotFound(String)
    case processingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOutput(let message): "出力先が不正です: \(message)"
        case .audioFileNotFound(let path): "音声ファイルが見つかりません: \(path)"
        case .processingFailed(let message): "録音データの処理に失敗しました: \(message)"
        }
    }
}

public struct SessionFileProcessingService: Sendable {
    public struct ImportRequest: Sendable {
        public let audioURL: URL
        public let outputURL: URL
        public let keepSession: Bool
        public let pacingMode: ASRPacingMode
        public let withDecisions: Bool

        public init(
            audioURL: URL,
            outputURL: URL,
            keepSession: Bool,
            pacingMode: ASRPacingMode,
            withDecisions: Bool
        ) {
            self.audioURL = audioURL
            self.outputURL = outputURL
            self.keepSession = keepSession
            self.pacingMode = pacingMode
            self.withDecisions = withDecisions
        }
    }

    public struct ResumeRequest: Sendable {
        public let sessionID: UUID
        public let outputURL: URL
        public let pacingMode: ASRPacingMode
        public let withDecisions: Bool

        public init(
            sessionID: UUID,
            outputURL: URL,
            pacingMode: ASRPacingMode,
            withDecisions: Bool
        ) {
            self.sessionID = sessionID
            self.outputURL = outputURL
            self.pacingMode = pacingMode
            self.withDecisions = withDecisions
        }
    }

    public struct Inspection: Encodable, Sendable {
        public let sessionID: UUID
        public let action: String
        public let maintenance: String?

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case action
            case maintenance
        }

        public init(sessionID: UUID, action: String, maintenance: String?) {
            self.sessionID = sessionID
            self.action = action
            self.maintenance = maintenance
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sessionID.uuidString, forKey: .sessionID)
            try container.encode(action, forKey: .action)
            if let maintenance {
                try container.encode(maintenance, forKey: .maintenance)
            } else {
                try container.encodeNil(forKey: .maintenance)
            }
        }
    }

    public enum Event: Sendable {
        case sessionCreated(sessionID: UUID, sessionURL: URL)
        case exported(URL)
        case cleanupFailed(String)
    }

    public struct Callbacks: Sendable {
        public let onEvent: @Sendable (Event) async -> Void
        public let onStatus: NativeSessionProcessor.StatusHandler
        public let onUpdate: NativeSessionProcessor.UpdateHandler
        public let shouldPause: NativeSessionProcessor.PauseCheck
        public let onPhase: NativeSessionProcessor.PhaseHandler

        public init(
            onEvent: @escaping @Sendable (Event) async -> Void,
            onStatus: @escaping NativeSessionProcessor.StatusHandler,
            onUpdate: @escaping NativeSessionProcessor.UpdateHandler,
            shouldPause: @escaping NativeSessionProcessor.PauseCheck,
            onPhase: @escaping NativeSessionProcessor.PhaseHandler
        ) {
            self.onEvent = onEvent
            self.onStatus = onStatus
            self.onUpdate = onUpdate
            self.shouldPause = shouldPause
            self.onPhase = onPhase
        }
    }

    private let paths: AppPaths
    private let protectedRoots: [URL]
    private let timelineBuilder: any ImportedAudioTimelineBuilding
    private let makeResources: @Sendable (_ withDecisions: Bool) throws -> SessionFileProcessingResources
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        paths: AppPaths,
        protectedRoots: [URL],
        timelineBuilder: any ImportedAudioTimelineBuilding,
        makeResources: @escaping @Sendable (_ withDecisions: Bool) throws -> SessionFileProcessingResources,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.paths = paths
        self.protectedRoots = protectedRoots
        self.timelineBuilder = timelineBuilder
        self.makeResources = makeResources
        self.sleep = sleep
    }

    public func inspect(sessionID: UUID) throws -> Inspection {
        let validatedPaths = try validatedPaths()
        do {
            let inspection = try SessionRecoveryScanner(sessionsRoot: validatedPaths.sessionsRoot)
                .inspect(sessionID: sessionID)
            return Inspection(
                sessionID: sessionID,
                action: actionName(inspection.recovery?.action),
                maintenance: inspection.maintenance?.rawValue
            )
        } catch SessionRecoveryScannerError.missingAudio,
                SessionAudioSourceError.importedOriginalMissing {
            return Inspection(sessionID: sessionID, action: "unrecoverable", maintenance: nil)
        }
    }

    public static func resolveResumeSession(sessionID: UUID, root: URL, outputURL: URL) throws -> URL {
        let sessionURL = try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: root, sessionID: sessionID)
        let sessionPath = sessionURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        let outputPath = outputURL.deletingLastPathComponent().resolvingSymlinksInPath()
            .appending(path: outputURL.lastPathComponent).resolvingSymlinksInPath()
            .pathComponents.map { $0.lowercased() }
        guard !outputPath.starts(with: sessionPath) else {
            throw SessionFileProcessingError.invalidOutput(
                "resume output \(outputURL.path) must be outside session directory \(sessionURL.path)"
            )
        }
        return sessionURL
    }

    public func importFile(
        _ request: ImportRequest,
        callbacks: Callbacks
    ) async throws -> SessionProcessingResult {
        let operationPaths = try validatedPaths()
        guard FileManager.default.fileExists(atPath: request.audioURL.path) else {
            throw SessionFileProcessingError.audioFileNotFound(request.audioURL.path)
        }
        guard !sameResolvedPath(request.audioURL, request.outputURL) else {
            throw SessionFileProcessingError.invalidOutput(
                "audio input \(request.audioURL.path) and output \(request.outputURL.path) resolve to the same path"
            )
        }

        let resources = try processingResources(
            withDecisions: request.withDecisions,
            context: "audio \(request.audioURL.path)"
        )
        let sessionID = UUID()
        let sessionURL: URL
        do {
            sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
                paths: operationPaths,
                sessionID: sessionID,
                source: .imported(originalFilename: request.audioURL.lastPathComponent),
                createdAt: Date(),
                timeZone: .current
            )
        } catch {
            throw SessionFileProcessingError.processingFailed(
                "creating an import session for \(request.audioURL.path) beneath \(operationPaths.sessionsRoot.path) failed: \(error.localizedDescription)"
            )
        }

        await callbacks.onEvent(.sessionCreated(sessionID: sessionID, sessionURL: sessionURL))

        do {
            let result = try await processImport(
                request,
                sessionID: sessionID,
                sessionURL: sessionURL,
                paths: operationPaths,
                resources: resources,
                callbacks: callbacks
            )
            await cleanupTemporarySession(
                sessionURL: sessionURL,
                keepSession: request.keepSession,
                callbacks: callbacks
            )
            return result
        } catch {
            await cleanupTemporarySession(
                sessionURL: sessionURL,
                keepSession: request.keepSession,
                callbacks: callbacks
            )
            throw error
        }
    }

    public func resume(
        _ request: ResumeRequest,
        callbacks: Callbacks
    ) async throws -> SessionProcessingResult {
        let operationPaths = try validatedPaths()
        let sessionURL = try Self.resolveResumeSession(
            sessionID: request.sessionID,
            root: operationPaths.sessionsRoot,
            outputURL: request.outputURL
        )
        let scanner = SessionRecoveryScanner(sessionsRoot: operationPaths.sessionsRoot)
        let initialInspection = try scanner.inspect(sessionID: request.sessionID)
        let requiresInference = needsInference(
            for: initialInspection.recovery?.action,
            withDecisions: request.withDecisions
        )
        let resources: SessionFileProcessingResources?
        if requiresInference {
            resources = try processingResources(
                withDecisions: request.withDecisions,
                context: "session \(sessionURL.path)"
            )
        } else {
            resources = nil
        }

        if let maintenance = initialInspection.maintenance {
            do {
                let layout = SessionLayout(sessionURL: sessionURL)
                try SessionStorageMaintainer.run(
                    maintenance,
                    layout: layout,
                    manifest: try layout.loadManifest()
                )
            } catch {
                throw SessionFileProcessingError.processingFailed(
                    "storage maintenance for session \(sessionURL.path) failed: \(error.localizedDescription)"
                )
            }
        }

        let currentInspection = try scanner.inspect(sessionID: request.sessionID)
        switch currentInspection.recovery?.action {
        case .finalize?:
            guard let resources else {
                throw SessionFileProcessingError.processingFailed(
                    "finalization for session \(sessionURL.path) requires processing resources, but the initial recovery inspection did not"
                )
            }
            return try await finalizeResume(
                request,
                sessionURL: sessionURL,
                paths: operationPaths,
                resources: resources,
                callbacks: callbacks
            )
        case .recoverDecisionRun(let boundarySegments, let clauses)?,
             .retryContentPriority(let boundarySegments, let clauses)?:
            guard request.withDecisions else {
                try exportTranscript(
                    sessionURL: sessionURL,
                    outputURL: request.outputURL,
                    withDecisions: false
                )
                await callbacks.onEvent(.exported(request.outputURL))
                return .completed(metrics: nil, noSpeech: false)
            }
            guard let resources else {
                throw SessionFileProcessingError.processingFailed(
                    "decision recovery for session \(sessionURL.path) requires processing resources, but the initial recovery inspection did not"
                )
            }
            return try await retryResumeDecisions(
                boundarySegments: boundarySegments,
                clauses: clauses,
                request: request,
                sessionURL: sessionURL,
                paths: operationPaths,
                resources: resources,
                callbacks: callbacks
            )
        case nil:
            try exportTranscript(
                sessionURL: sessionURL,
                outputURL: request.outputURL,
                withDecisions: request.withDecisions
            )
            await callbacks.onEvent(.exported(request.outputURL))
            return .completed(metrics: nil, noSpeech: false)
        }
    }

    private func processImport(
        _ request: ImportRequest,
        sessionID: UUID,
        sessionURL: URL,
        paths: AppPaths,
        resources: SessionFileProcessingResources,
        callbacks: Callbacks
    ) async throws -> SessionProcessingResult {
        do {
            do {
                _ = try AudioImporter().importFile(request.audioURL, into: sessionURL)
            } catch {
                throw SessionFileProcessingError.processingFailed(
                    "importing audio \(request.audioURL.path) into session \(sessionURL.path) failed: \(error.localizedDescription)"
                )
            }

            let processor = makeProcessor(paths: paths, resources: resources)
            let collector = ProcessingResultCollector()
            do {
                await callbacks.onStatus("処理を開始します: \(request.audioURL.path)")
                let result = await processor.processSession(
                    sessionID: sessionID,
                    pacingMode: request.pacingMode,
                    shouldPause: callbacks.shouldPause,
                    onPhase: callbacks.onPhase,
                    metadataPolicy: .reject,
                    onStatus: callbacks.onStatus,
                    onUpdate: updateHandler(callbacks: callbacks, collector: collector)
                )
                guard result.disposition == .completed else {
                    await processor.releaseIdleResources()
                    return result
                }
                let state = await collector.snapshot().state
                guard state == .complete else {
                    throw SessionFileProcessingError.processingFailed(
                        "finalizing imported audio \(request.audioURL.path) in session \(sessionURL.path) returned completed without a complete transcript update (state: \(describe(state)))"
                    )
                }
                try exportTranscript(
                    sessionURL: sessionURL,
                    outputURL: request.outputURL,
                    withDecisions: request.withDecisions
                )
                await callbacks.onEvent(.exported(request.outputURL))
                await processor.releaseIdleResources()
                return result
            } catch {
                await processor.releaseIdleResources()
                throw error
            }
        } catch let error as SessionFileProcessingError {
            throw error
        } catch {
            throw SessionFileProcessingError.processingFailed(
                "processing imported audio \(request.audioURL.path) in session \(sessionURL.path) failed: \(error.localizedDescription)"
            )
        }
    }

    private func finalizeResume(
        _ request: ResumeRequest,
        sessionURL: URL,
        paths: AppPaths,
        resources: SessionFileProcessingResources,
        callbacks: Callbacks
    ) async throws -> SessionProcessingResult {
        let processor = makeProcessor(paths: paths, resources: resources)
        let collector = ProcessingResultCollector()
        do {
            let result = await processor.processSession(
                sessionID: request.sessionID,
                pacingMode: request.pacingMode,
                shouldPause: callbacks.shouldPause,
                onPhase: callbacks.onPhase,
                metadataPolicy: .reject,
                onStatus: callbacks.onStatus,
                onUpdate: updateHandler(callbacks: callbacks, collector: collector)
            )
            guard result.disposition == .completed else {
                await processor.releaseIdleResources()
                return result
            }
            let state = await collector.snapshot().state
            guard state == .complete else {
                throw SessionFileProcessingError.processingFailed(
                    "finalizing session \(sessionURL.path) returned completed without a complete transcript update (state: \(describe(state)))"
                )
            }
            try exportTranscript(
                sessionURL: sessionURL,
                outputURL: request.outputURL,
                withDecisions: request.withDecisions
            )
            await callbacks.onEvent(.exported(request.outputURL))
            await processor.releaseIdleResources()
            return result
        } catch {
            await processor.releaseIdleResources()
            throw error
        }
    }

    private func retryResumeDecisions(
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference],
        request: ResumeRequest,
        sessionURL: URL,
        paths: AppPaths,
        resources: SessionFileProcessingResources,
        callbacks: Callbacks
    ) async throws -> SessionProcessingResult {
        let processor = makeProcessor(paths: paths, resources: resources)
        let collector = ProcessingResultCollector()
        do {
            await processor.retryContentPrioritySession(
                sessionID: request.sessionID,
                boundarySegments: boundarySegments,
                clauses: clauses,
                onStatus: callbacks.onStatus,
                onUpdate: updateHandler(callbacks: callbacks, collector: collector)
            )
            let state = await collector.snapshot().state
            guard state == .complete else {
                throw SessionFileProcessingError.processingFailed(
                    "retrying decisions for session \(sessionURL.path) did not publish a complete transcript update (state: \(describe(state)))"
                )
            }
            try exportTranscript(
                sessionURL: sessionURL,
                outputURL: request.outputURL,
                withDecisions: true
            )
            await callbacks.onEvent(.exported(request.outputURL))
            await processor.releaseIdleResources()
            return .completed(metrics: nil, noSpeech: false)
        } catch {
            await processor.releaseIdleResources()
            throw error
        }
    }

    private func exportTranscript(
        sessionURL: URL,
        outputURL: URL,
        withDecisions: Bool
    ) throws {
        do {
            guard let metadata = try ProcessingMetadataStore(sessionURL: sessionURL).load(),
                  let runs = metadata.activeRuns,
                  runs.segmentation != nil,
                  runs.asr != nil,
                  runs.diarization != nil else {
                throw SessionFileProcessingError.processingFailed(
                    "export validation for session \(sessionURL.path) requires active segmentation, ASR, and diarization runs"
                )
            }
            let recovered = try SessionRecovery.recoverJSONL(
                SessionFileAccess.read(
                    sessionURL.appending(path: "events.jsonl"),
                    relativeTo: sessionURL
                )
            )
            guard !recovered.droppedIncompleteTail else {
                throw SessionFileProcessingError.processingFailed(
                    "export validation for session \(sessionURL.path) found an incomplete events.jsonl tail"
                )
            }
            let targets = try DecisionRetryAnalyzer().retryTargets(lines: recovered.lines, metadata: metadata)
            let events = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: runs)
            let segments = try TranscriptMaterializer(sampleRate: CanonicalAudio.sampleRate)
                .materialize(events: events, activeRuns: runs)
                .filter(\.hasRecognizedText)

            if withDecisions, !segments.isEmpty {
                guard runs.clauseBoundary != nil,
                      runs.contentPriority != nil,
                      targets.boundarySegments.isEmpty,
                      targets.clauses.isEmpty,
                      metadata.pendingDecisionTargets.isEmpty else {
                    throw SessionFileProcessingError.processingFailed(
                        "decision export validation for session \(sessionURL.path) requires active clause-boundary and content-priority runs with no pending analyzer targets"
                    )
                }
            }

            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(segments).write(to: outputURL, options: .atomic)
        } catch let error as SessionFileProcessingError {
            throw error
        } catch {
            throw SessionFileProcessingError.processingFailed(
                "exporting transcript from session \(sessionURL.path) to \(outputURL.path) failed: \(error.localizedDescription)"
            )
        }
    }

    private func processingResources(
        withDecisions: Bool,
        context: String
    ) throws -> SessionFileProcessingResources {
        let resources: SessionFileProcessingResources
        do {
            resources = try makeResources(withDecisions)
        } catch {
            throw SessionFileProcessingError.processingFailed(
                "creating processing resources for \(context) failed: \(error.localizedDescription)"
            )
        }
        guard withDecisions else { return resources }
        guard let factory = resources.decisionProviderFactory else {
            throw SessionFileProcessingError.processingFailed(
                "decision processing for \(context) requires a DecisionProviderFactory"
            )
        }
        if case .disabled = resources.contentPriority {
            throw SessionFileProcessingError.processingFailed(
                "decision processing for \(context) was requested, but content priority is disabled"
            )
        }
        do {
            _ = try factory.localModelIdentity()
        } catch {
            throw SessionFileProcessingError.processingFailed(
                "decision model preflight for \(context) failed: \(error.localizedDescription)"
            )
        }
        return resources
    }

    private func makeProcessor(
        paths: AppPaths,
        resources: SessionFileProcessingResources
    ) -> NativeSessionProcessor {
        NativeSessionProcessor(
            paths: paths,
            engines: resources.engines,
            audioHandling: SessionProcessingAudio(timelineBuilder: timelineBuilder),
            contentPriority: resources.contentPriority,
            sleep: sleep
        )
    }

    private func updateHandler(
        callbacks: Callbacks,
        collector: ProcessingResultCollector
    ) -> NativeSessionProcessor.UpdateHandler {
        { segments, state in
            await collector.update(segments: segments, state: state)
            await callbacks.onUpdate(segments, state)
        }
    }

    private func cleanupTemporarySession(
        sessionURL: URL,
        keepSession: Bool,
        callbacks: Callbacks
    ) async {
        guard !keepSession else { return }
        do {
            try SessionFileAccess.removeIfPresent(
                sessionURL,
                relativeTo: sessionURL.deletingLastPathComponent()
            )
        } catch {
            await callbacks.onEvent(.cleanupFailed(
                "temporary session \(sessionURL.path) could not be removed: \(error.localizedDescription)"
            ))
        }
    }

    private func validatedPaths() throws -> AppPaths {
        let root = try SessionsRootPolicy.validated(
            paths.sessionsRoot,
            protectedRoots: protectedRoots,
            fileManager: .default
        )
        return AppPaths(
            applicationSupportURL: paths.applicationSupportURL,
            cacheURL: paths.cacheURL,
            sessionsRootOverride: root
        )
    }

    private func sameResolvedPath(_ left: URL, _ right: URL) -> Bool {
        left.resolvingSymlinksInPath().standardizedFileURL.pathComponents.map { $0.lowercased() }
            == right.resolvingSymlinksInPath().standardizedFileURL.pathComponents.map { $0.lowercased() }
    }

    private func actionName(_ action: RecoverableProcessingAction?) -> String {
        switch action {
        case .finalize?: "finalize"
        case .recoverDecisionRun?: "recoverDecisionRun"
        case .retryContentPriority?: "retryContentPriority"
        case nil: "none"
        }
    }

    private func needsInference(
        for action: RecoverableProcessingAction?,
        withDecisions: Bool
    ) -> Bool {
        switch action {
        case .finalize?: true
        case .recoverDecisionRun?, .retryContentPriority?: withDecisions
        case nil: false
        }
    }

    private func describe(_ state: ProcessingState) -> String {
        switch state {
        case .idle: "idle"
        case .running: "running"
        case .backlogged: "backlogged"
        case .complete: "complete"
        case .partialFailure(let message): "partialFailure(\(message))"
        }
    }
}

private actor ProcessingResultCollector {
    private var segments: [MaterializedTranscriptSegment] = []
    private var state: ProcessingState = .idle

    func update(segments: [MaterializedTranscriptSegment], state: ProcessingState) {
        self.segments = segments
        self.state = state
    }

    func snapshot() -> (segments: [MaterializedTranscriptSegment], state: ProcessingState) {
        (segments, state)
    }
}

