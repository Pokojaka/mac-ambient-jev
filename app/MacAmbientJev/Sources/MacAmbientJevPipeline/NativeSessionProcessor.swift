import Foundation
import MacAmbientJevCore

public enum RetainedTranscript: Sendable, Equatable {
    case finalized
    case provisional
    case nothing
}

public struct SessionProcessingResult: Sendable {
    public let disposition: BatchDisposition
    public let metrics: ASRBatchMetrics?
    public let message: String?
    public let noSpeech: Bool
    public let retainedTranscript: RetainedTranscript?
    /// Why a paused run stopped; nil for a cancellation.
    public var pauseReason: InferenceHoldReason? = nil

    public static func completed(metrics: ASRBatchMetrics?, noSpeech: Bool) -> SessionProcessingResult {
        SessionProcessingResult(disposition: .completed, metrics: metrics, message: nil,
                                noSpeech: noSpeech, retainedTranscript: nil)
    }

    public static func paused(metrics: ASRBatchMetrics?, retained: RetainedTranscript,
                               message: String, reason: InferenceHoldReason? = nil) -> SessionProcessingResult {
        SessionProcessingResult(disposition: .paused, metrics: metrics, message: message,
                                noSpeech: false, retainedTranscript: retained, pauseReason: reason)
    }

    public static func failed(message: String, metrics: ASRBatchMetrics?,
                              retained: RetainedTranscript?) -> SessionProcessingResult {
        SessionProcessingResult(disposition: .failed, metrics: metrics, message: message,
                                noSpeech: false, retainedTranscript: retained)
    }
}

public struct SessionProcessingEngines: Sendable {
    public let asr: any ASREngine
    public let finalTranscriptVAD: any FinalTranscriptVADSegmenter

    public init(asr: any ASREngine, finalTranscriptVAD: any FinalTranscriptVADSegmenter) {
        self.asr = asr
        self.finalTranscriptVAD = finalTranscriptVAD
    }
}

public enum ContentPriorityAccess: Sendable {
    case disabled
    case localTagger(NativeSessionProcessor.DecisionCoordinatorFactory, usageCounter: DecisionUsageCounter)
}

public actor NativeSessionProcessor {
    public enum Status: Sendable, Equatable {
        case activity(UserFacingStatus)
        case message(String)
        case paused(InferenceHoldReason)

        public var text: String {
            switch self {
            case .activity(let status): status.text
            case .message(let text): text
            case .paused(let reason): reason.finalizationExplanation
            }
        }
    }

    public typealias DecisionCoordinatorFactory = @Sendable () throws -> DecisionCoordinator
    public typealias DecisionEventWriterFactory = @Sendable (URL) throws -> any DecisionEventWriting
    public typealias StatusHandler = @Sendable (Status) async -> Void
    public typealias UpdateHandler = @Sendable ([MaterializedTranscriptSegment], ProcessingState) async -> Void
    public typealias PauseCheck = InferenceGate
    public typealias PhaseHandler = @Sendable (RunPhase) async -> Void

    /// The sessions a recording keeps running until stop; stop drains these same sessions.
    private struct LiveWorker {
        let asr: LiveASRSession
        let decisions: LiveContentPrioritySession?
    }

    private struct OpenedGeneration {
        let state: ProcessingLogState
        let startedNew: Bool
    }

    private let sessionsRoot: URL
    private let asr: any ASREngine
    private let finalTranscriptVAD: any FinalTranscriptVADSegmenter
    private let audioHandling: any SessionProcessingAudioHandling
    private let contentPriority: ContentPriorityAccess
    private let sleep: @Sendable (Duration) async throws -> Void
    private let makeDecisionEventWriter: DecisionEventWriterFactory
    private var liveASRSessions: [UUID: LiveASRSession] = [:]
    private var liveContentPrioritySessions: [UUID: LiveContentPrioritySession] = [:]
    private var startingLiveSessions: Set<UUID> = []
    private var activeFinalizations: Set<UUID> = []
    private var activeDecisionRetries: Set<UUID> = []

    public init(
        paths: AppPaths,
        engines: SessionProcessingEngines,
        audioHandling: any SessionProcessingAudioHandling,
        contentPriority: ContentPriorityAccess,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        makeDecisionEventWriter: @escaping DecisionEventWriterFactory = { try SessionWriter(sessionURL: $0) }
    ) {
        sessionsRoot = paths.sessionsRoot
        asr = engines.asr
        finalTranscriptVAD = engines.finalTranscriptVAD
        self.audioHandling = audioHandling
        self.contentPriority = contentPriority
        self.sleep = sleep
        self.makeDecisionEventWriter = makeDecisionEventWriter
    }

    public func prepareASR(onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        try await asr.prepare(onProgress: onProgress)
    }

    public func releaseIdleResources() async { await asr.unload() }

    /// Creates the generation and the live worker, and returns the generation's segmentation run ID
    /// that the live VAD session must use.
    public func startLiveTranscription(
        sessionID: UUID,
        sampleRate: Double
    ) async throws -> String {
        guard !activeFinalizations.contains(sessionID), !activeDecisionRetries.contains(sessionID),
              !liveASRSessions.keys.contains(sessionID), !liveContentPrioritySessions.keys.contains(sessionID),
              startingLiveSessions.insert(sessionID).inserted else {
            throw NativeSessionProcessorError.sessionProcessingInProgress
        }
        defer { startingLiveSessions.remove(sessionID) }
        let sessionLayout = try layout(for: sessionID)
        let writer = try SessionWriter(sessionURL: sessionLayout.sessionURL)
        let opened = try await openGeneration(
            sessionID: sessionID, layout: sessionLayout, writer: writer, sampleRate: sampleRate,
            metadataPolicy: .reject, allowFailed: false
        )
        try await ensureSegmentationStarted(opened.state, sessionID: sessionID, writer: writer)
        let liveASR = try await LiveASRSession.open(
            sessionID: sessionID, sessionURL: sessionLayout.sessionURL, writer: writer, asr: asr
        )
        liveASRSessions[sessionID] = liveASR
        if let runs = opened.state.generation.runs.clauseBoundary.flatMap({ boundary in
            opened.state.generation.runs.contentPriority.map { (boundary, $0) }
        }), runs.0 == opened.state.runs.clauseBoundary, runs.1 == opened.state.runs.contentPriority,
           case .localTagger(let factory, let usageCounter) = contentPriority {
            liveContentPrioritySessions[sessionID] = try await LiveContentPrioritySession.open(
                sessionID: sessionID, writer: writer, liveASR: liveASR,
                makeDecisions: factory, usageCounter: usageCounter,
                onStatus: { _ in }, onUpdate: { _ in }
            )
        }
        return liveASR.segmentationRunID
    }

    @discardableResult
    public func registerLiveSegments(sessionID: UUID, segments: [SegmentReference]) async throws -> LiveASRProgress {
        guard !activeFinalizations.contains(sessionID), let liveSession = liveASRSessions[sessionID] else {
            throw NativeSessionProcessorError.liveASRSessionNotStarted
        }
        return try await liveSession.register(segments: segments)
    }

    public func sealLiveSegmentation(sessionID: UUID, frameCount: Int64) async throws {
        guard !activeFinalizations.contains(sessionID), let liveSession = liveASRSessions[sessionID] else {
            throw NativeSessionProcessorError.liveASRSessionNotStarted
        }
        try await liveSession.sealSegmentationInput(frameCount: frameCount)
    }

    public func completeLiveSegmentation(sessionID: UUID, frameCount: Int64, segmentCount: Int) async throws {
        guard !activeFinalizations.contains(sessionID), let liveSession = liveASRSessions[sessionID] else {
            throw NativeSessionProcessorError.liveASRSessionNotStarted
        }
        try await liveSession.completeSegmentation(frameCount: frameCount, segmentCount: segmentCount)
    }

    /// True when the current generation holds a durable ASR failure that only an explicit resume continues.
    public func hasUnresolvedASRFailure(sessionID: UUID) throws -> Bool {
        let sessionLayout = try layout(for: sessionID)
        return try ProcessingLogState(eventsURL: sessionLayout.eventsURL, sessionID: sessionID)?
            .hasUnresolvedASRFailure ?? false
    }

    @discardableResult
    public func processLiveSegments(
        sessionID: UUID,
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint,
        shouldPause: @escaping PauseCheck,
        onStatus: StatusHandler?,
        onUpdate: UpdateHandler?
    ) async throws -> LiveASRProgress {
        guard !activeFinalizations.contains(sessionID), let liveSession = liveASRSessions[sessionID] else {
            throw NativeSessionProcessorError.liveASRSessionNotStarted
        }
        if let onStatus, !segments.isEmpty {
            await onStatus(.message("録音中の発話を文字起こししています"))
        }
        let progress = try await liveSession.process(
            segments: segments, checkpoint: checkpoint,
            onSegmentFinished: { [weak self] status, snapshot in
                await self?.publishLiveSegment(
                    sessionID: sessionID, liveSession: liveSession, status: status,
                    snapshot: snapshot, onStatus: onStatus, onUpdate: onUpdate
                )
            },
            shouldPause: shouldPause
        )
        guard liveASRSessions[sessionID] === liveSession else { return progress }
        if progress.failedCount > 0 {
            throw NativeSessionProcessorError.unresolvedASRFailure
        }
        await publishLiveRows(sessionID: sessionID, liveSession: liveSession, onUpdate: onUpdate)
        return progress
    }

    private func publishLiveSegment(
        sessionID: UUID,
        liveSession: LiveASRSession,
        status: LiveASRSegmentStatus,
        snapshot: LiveASRSnapshot,
        onStatus: StatusHandler?,
        onUpdate: UpdateHandler?
    ) async {
        guard liveASRSessions[sessionID] === liveSession else { return }
        await onUpdate?(snapshot.progress.materializedSegments, .running)
        guard let enrichment = liveContentPrioritySessions[sessionID] else { return }
        do {
            switch status.outcome {
            case .recognized(let source, _):
                try await enrichment.enqueue(
                    source: source, snapshot: snapshot,
                    onStatus: { text in await onStatus?(.message(text)) },
                    onUpdate: { [weak self] _ in
                        await self?.publishLiveRows(sessionID: sessionID, liveSession: liveSession, onUpdate: onUpdate)
                    }
                )
            case .failed, .pending:
                try await enrichment.observe(snapshot: snapshot)
            }
        } catch {
            await enrichment.stop()
            if liveContentPrioritySessions[sessionID] === enrichment { liveContentPrioritySessions[sessionID] = nil }
            let message = "ライブの発話文判定に失敗しました: \(error.localizedDescription)"
            await onStatus?(.message(message))
            await onUpdate?(snapshot.progress.materializedSegments, .partialFailure(message))
        }
    }

    private func publishLiveRows(
        sessionID: UUID,
        liveSession: LiveASRSession,
        onUpdate: UpdateHandler?
    ) async {
        guard liveASRSessions[sessionID] === liveSession, let onUpdate else { return }
        let snapshot = await liveSession.snapshot()
        guard liveASRSessions[sessionID] === liveSession else { return }
        await onUpdate(snapshot.progress.materializedSegments, .running)
    }

    public func cancelLiveTranscription(sessionID: UUID) async {
        liveASRSessions[sessionID] = nil
        if let enrichment = liveContentPrioritySessions.removeValue(forKey: sessionID) {
            await enrichment.stop()
            if case .localTagger(_, let usageCounter) = contentPriority {
                await usageCounter.clearDeferred(sessionID: sessionID, targets: await enrichment.pendingTargets())
            }
        }
    }

    @discardableResult
    public func processSession(
        sessionID: UUID,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping PauseCheck,
        onPhase: @escaping PhaseHandler,
        metadataPolicy: UnreadableMetadataPolicy,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async -> SessionProcessingResult {
        await finalize(
            sessionID: sessionID, metadataPolicy: metadataPolicy, allowFailed: false,
            pacingMode: pacingMode, shouldPause: shouldPause, onPhase: onPhase,
            onStatus: onStatus, onUpdate: onUpdate
        )
    }

    /// Explicit CLI recovery may retry a failed generation without resetting its durable outputs.
    @discardableResult
    public func resumeSession(
        sessionID: UUID,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping PauseCheck,
        onPhase: @escaping PhaseHandler,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async -> SessionProcessingResult {
        await finalize(
            sessionID: sessionID, metadataPolicy: .reject, allowFailed: true,
            pacingMode: pacingMode, shouldPause: shouldPause, onPhase: onPhase,
            onStatus: onStatus, onUpdate: onUpdate
        )
    }

    public func retryContentPrioritySession(
        sessionID: UUID,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference],
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async -> SessionProcessingResult {
        var retainedRows: [MaterializedTranscriptSegment] = []
        var hasRetainedRows = false
        do {
            try Task.checkCancellation()
            guard !startingLiveSessions.contains(sessionID), !activeFinalizations.contains(sessionID),
                  !activeDecisionRetries.contains(sessionID), activeDecisionRetries.insert(sessionID).inserted else {
                throw NativeSessionProcessorError.sessionProcessingInProgress
            }
            defer { activeDecisionRetries.remove(sessionID) }
            guard Set(boundarySegments).count == boundarySegments.count,
                  Set(clauses).count == clauses.count else {
                throw NativeSessionProcessorError.duplicateDecisionRetryTarget
            }
            let sessionLayout = try layout(for: sessionID)
            let reader = EventLogTranscriptReader()
            guard let preview = try reader.read(eventsURL: sessionLayout.eventsURL, sessionID: sessionID),
                  let frameCount = preview.state.sealedFrames else {
                throw NativeSessionProcessorError.transcriptNotPublished
            }
            retainedRows = try TranscriptMaterializer(sampleRate: preview.state.generation.sampleRate)
                .materialize(events: preview.events, activeRuns: preview.state.runs)
            hasRetainedRows = true
            let stored = try reader.validateCompletion(
                eventsURL: sessionLayout.eventsURL, sessionID: sessionID, frameCount: frameCount
            )
            guard stored.state.generation.id == preview.state.generation.id else {
                throw ProcessingLogStateError.missingGeneration
            }
            let lines = try SessionRecovery.recoverJSONL(SessionWriter.readDurableLog(eventsURL: sessionLayout.eventsURL)).lines
            let unpublished = try DecisionRetryAnalyzer().hasUnpublishedDecisionRun(lines: lines, sessionID: sessionID)
            let pendingBoundary = Set(stored.pendingDecisions.boundarySegments)
            let pendingClauses = Set(stored.pendingDecisions.clauses)
            let requestedBoundary = Set(boundarySegments)
            let requestedClauses = Set(clauses)
            guard requestedBoundary.isSubset(of: pendingBoundary), requestedClauses.isSubset(of: pendingClauses),
                  !requestedBoundary.isEmpty || !requestedClauses.isEmpty || unpublished else {
                throw NativeSessionProcessorError.noDecisionRetryTargets
            }
            // Without a selected pair every recognized source is pending; the first pair must cover them all.
            guard decisionIDs(stored.state.runs) != nil || requestedBoundary == pendingBoundary else {
                throw NativeSessionProcessorError.noDecisionRetryTargets
            }
            guard case .localTagger(let factory, let usageCounter) = contentPriority else {
                await onStatus(.activity(.decisionDeferred))
                throw NativeSessionProcessorError.contentPriorityUnavailable
            }
            let decisions: DecisionCoordinator
            do {
                decisions = try factory()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                let initializationError = NativeSessionProcessorError.decisionCoordinatorInitializationFailed(
                    error.localizedDescription
                )
                await onStatus(.message(
                    "\(UserFacingStatus.decisionDeferred.text)。\(initializationError.localizedDescription)"
                ))
                throw initializationError
            }
            await onStatus(.message("保留中の判定を再試行しています（境界 \(boundarySegments.count)区間・優先度 \(clauses.count)節）"))
            await onUpdate(retainedRows, .running)
            // Opening the writer may repair a trailing record, so cancellation is settled before it.
            try Task.checkCancellation()
            let suffix = UUID().uuidString.lowercased()
            let boundaryRunID: String
            let keepsBoundaryRun: Bool
            if requestedBoundary.isEmpty, !unpublished, let current = stored.state.runs.clauseBoundary {
                boundaryRunID = current
                keepsBoundaryRun = true
            } else {
                boundaryRunID = "boundary_\(suffix)"
                keepsBoundaryRun = false
            }
            let priorityRunID = "priority_\(suffix)"
            let eventWriter = try makeDecisionEventWriter(sessionLayout.sessionURL)
            let plan = ReplacementPlan(
                boundaryRunID: boundaryRunID, priorityRunID: priorityRunID,
                boundaryTargets: requestedBoundary, clauseTargets: requestedClauses,
                carry: ReplacementCarry(events: stored.events, runs: stored.state.runs),
                keepsBoundaryRun: keepsBoundaryRun
            )
            let source = try StoredTranscriptSource(
                state: stored.state, boundaryRunID: boundaryRunID, priorityRunID: priorityRunID
            )
            let replacement = try await LiveContentPrioritySession.openReplacement(
                sessionID: sessionID, writer: eventWriter, source: source, plan: plan,
                makeDecisions: { decisions }, usageCounter: usageCounter,
                onStatus: { _ in }, onUpdate: { _ in }
            )
            do {
                try await replacement.replace(snapshot: await source.snapshot())
            } catch {
                await replacement.stop()
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if try await replacement.recordFailure(originalError: error) {
                    throw DecisionEnrichmentError.retryFailedDurably(error.localizedDescription)
                }
                throw error
            }
            // The candidate pair is validated and its rows derived before it is selected; nothing after the
            // selection event can fail, so a selected retry is never reported as paused or failed.
            let selection = DecisionRunReplacement(
                generationID: stored.state.generation.id, previous: decisionIDs(stored.state.runs),
                replacement: DecisionRunIDs(boundary: boundaryRunID, priority: priorityRunID)
            )
            let selected = try reader.validateReplacement(
                eventsURL: sessionLayout.eventsURL, sessionID: sessionID, frameCount: frameCount, replacement: selection
            )
            let selectedRows = try TranscriptMaterializer(sampleRate: selected.state.generation.sampleRate)
                .materialize(events: selected.events, activeRuns: selected.state.runs)
            try Task.checkCancellation()
            do {
                try await eventWriter.appendSelection(selection, sessionID: sessionID)
            } catch DecisionEnrichmentError.selectionConflict {
                throw DecisionEnrichmentError.selectionConflict
            } catch {
                // The marker may or may not have reached the log: never report this as a pause.
                throw DecisionEnrichmentError.selectionOutcomeUnknown(error.localizedDescription)
            }
            await usageCounter.clearDeferred(sessionID: sessionID, targets: stored.pendingDecisions.pendingTargets)
            await usageCounter.recordDeferred(sessionID: sessionID, targets: selected.pendingDecisions.pendingTargets)
            await onUpdate(selectedRows, .complete)
            await onStatus(selected.pendingDecisions.pendingTargets.isEmpty
                           ? .message("保留中の判定を更新しました") : .activity(.decisionDeferred))
            return .completed(metrics: nil, noSpeech: false)
        } catch {
            let retained: RetainedTranscript = hasRetainedRows ? .finalized : .nothing
            let isDefinitiveRetryFailure: Bool
            switch error as? DecisionEnrichmentError {
            case .retryFailedDurably?, .retryCompletionPersistenceFailed?, .selectionConflict?,
                 .selectionOutcomeUnknown?:
                isDefinitiveRetryFailure = true
            default: isDefinitiveRetryFailure = false
            }
            if !isDefinitiveRetryFailure && (error is CancellationError || Task.isCancelled) {
                let message = "処理は中断されました。次回の起動時に再開できます"
                await onStatus(.message(message))
                return .paused(metrics: nil, retained: retained, message: message)
            }
            let message = "発話文の判定を再試行できませんでした: \(error.localizedDescription)"
            if let processorError = error as? NativeSessionProcessorError,
               case .decisionCoordinatorInitializationFailed = processorError {
                // Keep the deferred-engine status already reported above.
            } else {
                await onStatus(.message(message))
            }
            return .failed(message: message, metrics: nil, retained: retained)
        }
    }

    private func finalize(
        sessionID: UUID,
        metadataPolicy: UnreadableMetadataPolicy,
        allowFailed: Bool,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping PauseCheck,
        onPhase: @escaping PhaseHandler,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async -> SessionProcessingResult {
        guard !startingLiveSessions.contains(sessionID), !activeDecisionRetries.contains(sessionID),
              activeFinalizations.insert(sessionID).inserted else {
            let (rows, message) = rowsForFailure(
                layout: nil, sessionID: sessionID,
                message: NativeSessionProcessorError.sessionProcessingInProgress.localizedDescription
            )
            await onPhase(.complete)
            await onStatus(.message(message))
            await onUpdate(rows, .partialFailure(message))
            return .failed(message: message, metrics: nil, retained: rows.isEmpty ? .nothing : .finalized)
        }
        defer { activeFinalizations.remove(sessionID) }
        var resolvedLayout: SessionLayout?
        var loadedManifest: SessionManifest?
        do {
            let sessionLayout = try layout(for: sessionID)
            resolvedLayout = sessionLayout
            let manifest = try sessionLayout.loadManifest()
            loadedManifest = manifest
            let source = try sessionLayout.processingSource(for: manifest)
            let result = await runFinalization(
                sessionID: sessionID, layout: sessionLayout, source: source,
                metadataPolicy: metadataPolicy, allowFailed: allowFailed, pacingMode: pacingMode,
                shouldPause: shouldPause, onPhase: onPhase, onStatus: onStatus, onUpdate: onUpdate
            )
            return await closeStorage(
                result, sessionID: sessionID, layout: sessionLayout, manifest: manifest, source: source,
                onPhase: onPhase, onStatus: onStatus, onUpdate: onUpdate
            )
        } catch {
            var message = "確定処理を開始できませんでした: \(error.localizedDescription)"
            if let resolvedLayout, let loadedManifest {
                do { try SessionTransientAudio.remove(layout: resolvedLayout, source: loadedManifest.source) }
                catch { message += "（音声の一時ファイルを削除できませんでした: \(error.localizedDescription)）" }
            }
            let (rows, reportedMessage) = rowsForFailure(
                layout: resolvedLayout, sessionID: sessionID, message: message
            )
            await onPhase(.complete)
            await onStatus(.message(reportedMessage))
            await onUpdate(rows, .partialFailure(reportedMessage))
            return .failed(message: reportedMessage, metrics: nil, retained: rows.isEmpty ? .nothing : .finalized)
        }
    }

    /// Drains the session: the live worker when the recording kept one, otherwise sessions reopened from the log.
    private func runFinalization(
        sessionID: UUID,
        layout: SessionLayout,
        source: SessionAudioSource,
        metadataPolicy: UnreadableMetadataPolicy,
        allowFailed: Bool,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping PauseCheck,
        onPhase: @escaping PhaseHandler,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async -> SessionProcessingResult {
        let live = takeLiveWorker(sessionID: sessionID)
        let result = await drain(
            sessionID: sessionID, layout: layout, source: source, live: live,
            metadataPolicy: metadataPolicy, allowFailed: allowFailed, pacingMode: pacingMode,
            shouldPause: shouldPause, onPhase: onPhase, onStatus: onStatus, onUpdate: onUpdate
        )
        await live?.decisions?.stop()
        return result
    }

    private func drain(
        sessionID: UUID,
        layout: SessionLayout,
        source: SessionAudioSource,
        live: LiveWorker?,
        metadataPolicy: UnreadableMetadataPolicy,
        allowFailed: Bool,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping PauseCheck,
        onPhase: @escaping PhaseHandler,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async -> SessionProcessingResult {
        var attemptGenerationID: UUID?
        var metrics: ASRBatchMetrics?
        do {
            await onPhase(.preparing)
            let writer = try SessionWriter(sessionURL: layout.sessionURL)
            let sampleRate: Double
            switch source {
            case .recordedPCM(let checkpoint): sampleRate = checkpoint.sampleRate
            case .recordedFLAC(let info): sampleRate = info.sampleRate
            case .importedOriginal(_, _): sampleRate = CanonicalAudio.sampleRate
            }
            let opened = try await openGeneration(
                sessionID: sessionID, layout: layout, writer: writer, sampleRate: sampleRate,
                metadataPolicy: metadataPolicy, allowFailed: allowFailed
            )
            if !opened.state.segmentationCompleted {
                await onStatus(.activity(.detectingSpeech))
            }
            let generationID = opened.state.generation.id
            attemptGenerationID = generationID
            if opened.startedNew {
                await onUpdate([], .running)
            } else {
                await onUpdate(try currentRows(layout: layout, sessionID: sessionID), .running)
            }

            let audio = try await audioHandling.open(source, layout: layout, onStatus: { text in
                await onStatus(.message(text))
            })
            try audio.validateAudio()
            guard let state = try ProcessingLogState(eventsURL: layout.eventsURL, sessionID: sessionID),
                  state.generation.id == generationID else {
                throw ProcessingLogStateError.missingGeneration
            }
            let recognizedCount = state.events.reduce(into: 0) { count, event in
                if case .asrCompleted = event.kind { count += 1 }
            }
            if recognizedCount < state.segments.count {
                await onStatus(.activity(.preparingASR))
            }
            // The live worker knows only the segments it registered: it is kept when live segmentation
            // already completed, and otherwise the sessions are reopened after stored segmentation.
            // It is kept only while it agrees with the log; after a failed ASR write the log is the truth.
            var worker: LiveWorker?
            if state.segmentationCompleted, let live, await live.asr.agrees(with: state) { worker = live }
            // The sessions are reopened from the log, so the old decision worker must stop writing first.
            if worker == nil { await live?.decisions?.stop() }
            try await StoredSegmentation.finish(
                state: state, sessionID: sessionID, audio: audio,
                segmenter: finalTranscriptVAD, writer: writer
            )
            try Task.checkCancellation()

            let liveSession: LiveASRSession
            if let worker {
                liveSession = worker.asr
            } else {
                liveSession = try await LiveASRSession.open(
                    sessionID: sessionID, sessionURL: layout.sessionURL, writer: writer, asr: asr
                )
            }
            guard liveSession.segmentationRunID == state.segmentationRunID,
                  liveSession.asrRunID == state.asrRunID else {
                throw ProcessingLogStateError.missingGeneration
            }
            await onPhase(.asr)
            let drained = try await liveSession.drain(
                reader: audio, pacingMode: pacingMode, sleep: sleep, shouldPause: shouldPause,
                onSegmentFinished: { _, snapshot in
                    await onUpdate(snapshot.progress.materializedSegments, .running)
                }
            )
            metrics = drained?.metrics
            if let drained {
                switch drained.disposition {
                case .paused(let reason):
                    let message = reason.finalizationExplanation
                    try saveStatus(sessionID: sessionID, layout: layout, generationID: generationID, state: .paused, reason: message)
                    let (rows, reportedMessage) = rowsForFailure(layout: layout, sessionID: sessionID, message: message)
                    await onPhase(.complete)
                    if reportedMessage == message { await onStatus(.paused(reason)) }
                    else { await onStatus(.message(reportedMessage)) }
                    await onUpdate(rows, .backlogged)
                    return .paused(
                        metrics: metrics, retained: rows.isEmpty ? .nothing : .finalized,
                        message: reportedMessage, reason: reason
                    )
                case .failed(let failure):
                    let message = failure.localizedDescription
                    try saveStatus(sessionID: sessionID, layout: layout, generationID: generationID, state: .failed, reason: message)
                    let (rows, reportedMessage) = rowsForFailure(layout: layout, sessionID: sessionID, message: message)
                    await onPhase(.complete); await onStatus(.message("確定処理に失敗しました: \(reportedMessage)")); await onUpdate(rows, .partialFailure(reportedMessage))
                    return .failed(message: reportedMessage, metrics: metrics, retained: rows.isEmpty ? .nothing : .finalized)
                case .completed: break
                }
            }
            guard let current = try ProcessingLogState(eventsURL: layout.eventsURL, sessionID: sessionID),
                  current.generation.id == generationID, !current.hasUnresolvedASRFailure else {
                throw ProcessingLogStateError.incompleteRecognition
            }
            let completion = try await liveSession.finish()
            guard completion.succeeded else { throw ProcessingLogStateError.incompleteRecognition }

            let latest = try ProcessingLogState(eventsURL: layout.eventsURL, sessionID: sessionID)
            guard let latest, latest.generation.id == generationID else { throw ProcessingLogStateError.missingGeneration }
            await onPhase(.postprocessing)
            var drainedPendingTargets: Set<DecisionPendingTarget> = []
            if let pair = decisionIDs(latest.generation.runs), decisionIDs(latest.runs) == pair {
                drainedPendingTargets = try await drainDecisions(
                    sessionID: sessionID, writer: writer, liveASR: liveSession, live: worker?.decisions,
                    onStatus: onStatus, onUpdate: onUpdate
                )
            }
            let stored = try EventLogTranscriptReader().validateCompletion(
                eventsURL: layout.eventsURL, sessionID: sessionID, frameCount: audio.info.committedFrames
            )
            guard stored.state.generation.id == generationID else { throw ProcessingLogStateError.missingGeneration }
            let finalRows = try TranscriptMaterializer(sampleRate: stored.state.generation.sampleRate)
                .materialize(events: stored.events, activeRuns: stored.state.runs)
            try saveStatus(sessionID: sessionID, layout: layout, generationID: generationID, state: .complete)
            if case .localTagger(_, let usageCounter) = contentPriority {
                await usageCounter.clearDeferred(
                    sessionID: sessionID,
                    targets: drainedPendingTargets.union(stored.pendingDecisions.pendingTargets)
                )
                await usageCounter.recordDeferred(sessionID: sessionID, targets: stored.pendingDecisions.pendingTargets)
            }
            await onUpdate(finalRows, .complete)
            await onPhase(.complete)
            let initializationFailure = stored.events.lazy.compactMap { event -> String? in
                guard case .clauseBoundaryPending(let payload) = event.kind,
                      payload.reason == .initializationFailed else { return nil }
                return payload.message
            }.last
            if stored.pendingDecisions.pendingTargets.isEmpty || decisionIDs(stored.state.generation.runs) == nil {
                await onStatus(.message(finalRows.isEmpty ? "発話区間は検出されませんでした" : "文字起こしが完了しました（\(completion.completedCount)区間）"))
            } else if let initializationFailure {
                await onStatus(.message("\(UserFacingStatus.decisionDeferred.text)。\(initializationFailure)"))
            } else {
                await onStatus(.activity(.decisionDeferred))
            }
            return .completed(metrics: metrics, noSpeech: completion.completedCount == 0)
        } catch {
            if let cancellation = error as? ASRRunCancellation { metrics = cancellation.metrics }
            // The error decides: only a cancellation pauses. A read, validation or saved failure stays
            // failed even when a shutdown cancelled the task meanwhile.
            let cancelled = error is CancellationError || error is ASRRunCancellation
            var message = cancelled ? "確定処理が中断されたため、一時停止しました"
                : attemptGenerationID == nil ? "確定処理を開始できませんでした: \(error.localizedDescription)"
                : error.localizedDescription
            if let generationID = attemptGenerationID {
                do {
                    try saveStatus(sessionID: sessionID, layout: layout, generationID: generationID, state: cancelled ? .paused : .failed, reason: message)
                } catch {
                    message += "（処理状態を保存できませんでした: \(error.localizedDescription)）"
                }
            }
            let (rows, reportedMessage) = rowsForFailure(layout: layout, sessionID: sessionID, message: message)
            await onPhase(.complete)
            let statusText = cancelled || attemptGenerationID == nil
                ? reportedMessage
                : "確定処理に失敗しました: \(reportedMessage)"
            await onStatus(.message(statusText))
            await onUpdate(rows, cancelled ? .backlogged : .partialFailure(reportedMessage))
            return cancelled
                ? .paused(metrics: metrics, retained: rows.isEmpty ? .nothing : .finalized, message: reportedMessage)
                : .failed(message: reportedMessage, metrics: metrics, retained: rows.isEmpty ? .nothing : .finalized)
        }
    }

    /// Releases the final successor wait of the live decision session, or of one reopened from the log
    /// when the recording kept none, and waits until every decision is saved.
    private func drainDecisions(
        sessionID: UUID,
        writer: SessionWriter,
        liveASR: LiveASRSession,
        live: LiveContentPrioritySession?,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) async throws -> Set<DecisionPendingTarget> {
        guard case .localTagger(let factory, let usageCounter) = contentPriority else { return [] }
        let onDecisionStatus: LiveContentPrioritySession.StatusHandler = { text in await onStatus(.message(text)) }
        let onDecisionUpdate: LiveContentPrioritySession.UpdateHandler = { snapshot in
            await onUpdate(snapshot.progress.materializedSegments, .running)
        }
        let enrichment: LiveContentPrioritySession
        if let live {
            await live.rebind(onStatus: onDecisionStatus, onUpdate: onDecisionUpdate)
            enrichment = live
        } else {
            enrichment = try await LiveContentPrioritySession.open(
                sessionID: sessionID, writer: writer, liveASR: liveASR,
                makeDecisions: factory, usageCounter: usageCounter,
                onStatus: onDecisionStatus, onUpdate: onDecisionUpdate
            )
        }
        do {
            try await enrichment.finishInput(snapshot: await liveASR.snapshot())
            try await enrichment.waitForDrain()
        } catch {
            await enrichment.stop()
            throw error
        }
        return await enrichment.pendingTargets()
    }

    private func takeLiveWorker(sessionID: UUID) -> LiveWorker? {
        let decisions = liveContentPrioritySessions.removeValue(forKey: sessionID)
        guard let asr = liveASRSessions.removeValue(forKey: sessionID) else { return nil }
        return LiveWorker(asr: asr, decisions: decisions)
    }

    private func openGeneration(
        sessionID: UUID,
        layout: SessionLayout,
        writer: SessionWriter,
        sampleRate: Double,
        metadataPolicy: UnreadableMetadataPolicy,
        allowFailed: Bool
    ) async throws -> OpenedGeneration {
        guard sampleRate.isFinite, sampleRate > 0 else { throw ProcessingLogStateError.incompatibleSettings }
        let metadataStore = ProcessingMetadataStore(sessionURL: layout.sessionURL)
        let metadata: ProcessingMetadata?
        do {
            metadata = try metadataStore.load()
        } catch let error as ProcessingMetadataStoreError {
            if metadataPolicy == .replace, case .unreadable = error { metadata = nil }
            else { throw error }
        }

        let previousState: ProcessingLogState?
        if metadataPolicy == .reject {
            previousState = try ProcessingLogState(eventsURL: layout.eventsURL, sessionID: sessionID)
        } else {
            previousState = nil
        }
        if metadataPolicy == .reject, case nil = previousState, metadata != nil {
            throw ProcessingLogStateError.missingGeneration
        }
        if let state = previousState {
            guard settingsMatch(state.generation, sampleRate: sampleRate) else {
                throw ProcessingLogStateError.incompatibleSettings
            }
            if metadata?.generationID == state.generation.id {
                if metadata?.state == .failed && !allowFailed {
                    throw NativeSessionProcessorError.failedGenerationRequiresResume
                }
            }
            if state.hasUnresolvedASRFailure && !allowFailed {
                let error = NativeSessionProcessorError.unresolvedASRFailure
                try metadataStore.save(ProcessingMetadata(
                    generationID: state.generation.id, state: .failed, failureReason: error.localizedDescription
                ))
                throw error
            }
            try metadataStore.save(ProcessingMetadata(generationID: state.generation.id, state: .running, failureReason: nil))
            return OpenedGeneration(state: state, startedNew: false)
        }

        let suffix = UUID().uuidString.lowercased()
        let segmentationID = "seg_\(suffix)"
        let asrID = "asr_\(suffix)"
        let pair = hasDecisionPair ? ("boundary_\(suffix)", "priority_\(suffix)") : nil
        let runIDs = [segmentationID, asrID] + (pair.map { [$0.0, $0.1] } ?? [])
        guard Set(runIDs).count == runIDs.count,
              runIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ProcessingLogStateError.missingGeneration
        }
        let runs = ActiveRuns(
            segmentation: segmentationID, asr: asrID,
            clauseBoundary: pair?.0, contentPriority: pair?.1
        )
        let generation = PipelineGeneration(
            id: UUID(), runs: runs, sampleRate: sampleRate,
            segmentationProvenance: finalTranscriptVAD.provenance, asrProvenance: asr.provenance
        )
        try await writer.append(generation.startEvent(sessionID: sessionID))
        try metadataStore.save(ProcessingMetadata(generationID: generation.id, state: .running, failureReason: nil))
        guard let state = try ProcessingLogState(eventsURL: layout.eventsURL, sessionID: sessionID) else {
            throw ProcessingLogStateError.missingGeneration
        }
        return OpenedGeneration(state: state, startedNew: true)
    }

    private func settingsMatch(_ generation: PipelineGeneration, sampleRate: Double) -> Bool {
        generation.sampleRate == sampleRate
            && generation.segmentationProvenance == finalTranscriptVAD.provenance
            && generation.asrProvenance == asr.provenance
            && ((generation.runs.clauseBoundary != nil) == hasDecisionPair)
            && ((generation.runs.contentPriority != nil) == hasDecisionPair)
    }

    private var hasDecisionPair: Bool {
        if case .localTagger = contentPriority { true } else { false }
    }

    private func ensureSegmentationStarted(
        _ state: ProcessingLogState, sessionID: UUID, writer: SessionWriter
    ) async throws {
        guard state.runStarts[.segmentation] == nil else { return }
        try await writer.append(EventDraft(
            eventType: "processing.run.started", sessionID: sessionID,
            processingRunID: state.segmentationRunID,
            payload: ProcessingRunStartedPayload(stage: .segmentation, provenance: state.generation.segmentationProvenance)
        ))
    }

    private func saveStatus(
        sessionID: UUID,
        layout: SessionLayout,
        generationID: UUID,
        state: ProcessingMetadata.State,
        reason: String? = nil
    ) throws {
        guard let current = try ProcessingLogState(eventsURL: layout.eventsURL, sessionID: sessionID),
              current.generation.id == generationID else {
            throw ProcessingLogStateError.missingGeneration
        }
        try ProcessingMetadataStore(sessionURL: layout.sessionURL)
            .save(ProcessingMetadata(generationID: generationID, state: state, failureReason: reason))
    }

    private func currentRows(layout: SessionLayout, sessionID: UUID) throws -> [MaterializedTranscriptSegment] {
        guard let stored = try EventLogTranscriptReader().read(eventsURL: layout.eventsURL, sessionID: sessionID) else {
            throw ProcessingLogStateError.missingGeneration
        }
        return try TranscriptMaterializer(sampleRate: stored.state.generation.sampleRate)
            .materialize(events: stored.events, activeRuns: stored.state.runs)
    }

    private func rowsForFailure(
        layout: SessionLayout?, sessionID: UUID, message: String
    ) -> (rows: [MaterializedTranscriptSegment], message: String) {
        do {
            let sessionLayout: SessionLayout
            if let layout { sessionLayout = layout } else { sessionLayout = try self.layout(for: sessionID) }
            return (try currentRows(layout: sessionLayout, sessionID: sessionID), message)
        } catch {
            return ([], "\(message)（保存済みの部分文字起こしを読み込めませんでした: \(error.localizedDescription)）")
        }
    }

    private func closeStorage(
        _ attempt: SessionProcessingResult,
        sessionID: UUID,
        layout: SessionLayout,
        manifest: SessionManifest,
        source: SessionAudioSource,
        onPhase: PhaseHandler,
        onStatus: StatusHandler,
        onUpdate: UpdateHandler
    ) async -> SessionProcessingResult {
        var result = attempt
        if result.disposition == .completed,
           case .recordedPCM(let checkpoint) = source, checkpoint.committedFrames > 0 {
            do {
                try Task.checkCancellation()
                try await audioHandling.compactRecording(layout: layout)
                try Task.checkCancellation()
            } catch is CancellationError {
                let message = "文字起こしは完了しましたが、音声の保存整理が中断されました"
                await onPhase(.complete); await onStatus(.message(message))
                result = .paused(metrics: result.metrics, retained: .finalized, message: message)
            } catch {
                let message = "文字起こしは保存しましたが、録音を FLAC にできませんでした: \(error.localizedDescription)"
                await onPhase(.complete); await onStatus(.message(message))
                result = .failed(message: message, metrics: result.metrics, retained: .finalized)
            }
        }
        do {
            try SessionTransientAudio.remove(layout: layout, source: manifest.source)
        } catch {
            let cleanup = "音声の一時ファイルを削除できませんでした: \(error.localizedDescription)"
            let message = [result.message, cleanup].compactMap { $0 }.joined(separator: "。")
            switch result.disposition {
            case .completed:
                let (rows, reportedMessage) = rowsForFailure(
                    layout: layout, sessionID: sessionID, message: "文字起こしは保存しましたが、\(message)"
                )
                result = .failed(message: reportedMessage, metrics: result.metrics, retained: .finalized)
                await onStatus(.message(reportedMessage))
                await onUpdate(rows, .partialFailure(reportedMessage))
            case .failed:
                result = .failed(message: message, metrics: result.metrics, retained: result.retainedTranscript)
                await onStatus(.message(message))
            case .paused:
                result = .paused(
                    metrics: result.metrics, retained: result.retainedTranscript ?? .nothing,
                    message: message, reason: result.pauseReason
                )
                await onStatus(.message(message))
            }
        }
        return result
    }

    private func decisionIDs(_ runs: ActiveRuns) -> DecisionRunIDs? {
        guard let boundary = runs.clauseBoundary, let priority = runs.contentPriority else { return nil }
        return DecisionRunIDs(boundary: boundary, priority: priority)
    }

    private func layout(for sessionID: UUID) throws -> SessionLayout {
        SessionLayout(sessionURL: try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: sessionsRoot, sessionID: sessionID))
    }
}

enum NativeSessionProcessorError: LocalizedError {
    case liveASRSessionNotStarted
    case transcriptNotPublished
    case duplicateDecisionRetryTarget
    case noDecisionRetryTargets
    case contentPriorityUnavailable
    case unresolvedASRFailure
    case failedGenerationRequiresResume
    case sessionProcessingInProgress
    case decisionCoordinatorInitializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .liveASRSessionNotStarted: "録音中の文字起こしセッションが開始されていません"
        case .transcriptNotPublished: "確定済みの文字起こし run がありません"
        case .duplicateDecisionRetryTarget: "判定の再試行対象が重複しています"
        case .noDecisionRetryTargets: "判定の再試行対象がありません"
        case .contentPriorityUnavailable: "判定エンジンが利用できません"
        case .unresolvedASRFailure: "未解決の durable ASR 失敗があるため処理を継続できません"
        case .failedGenerationRequiresResume: "失敗した世代は明示的な resume でのみ再開できます"
        case .sessionProcessingInProgress: "セッションの処理がすでに進行中です"
        case .decisionCoordinatorInitializationFailed(let reason): "判定エンジンを初期化できませんでした: \(reason)"
        }
    }
}
