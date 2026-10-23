import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

// MARK: Saved sessions

extension EngineApplicationCore {
    /// The catalog, re-read after anything that may have changed it.
    func currentSessions() throws -> [SavedSessionSummary] {
        if savedSessionsAreStale {
            do {
                try savedSessionOperations.refresh(sessionsRoot: paths.sessionsRoot)
            } catch {
                throw EngineFailures.commandError(
                    from: error, fallback: .filesystem, stage: .recovery, recoveryAction: .retry
                )
            }
            savedSessionsAreStale = false
        }
        return savedSessionOperations.sessions
    }

    func readableSession(_ sessionID: UUID) throws -> SavedSession {
        _ = try currentSessions()
        guard let session = savedSessionOperations.readableSession(sessionID) else {
            throw EngineFailures.commandError(
                .sessionNotFound, "保存済み録音が見つからないか、読み取れません", stage: .recovery,
                sessionID: sessionID, recoveryAction: .inspectSession
            )
        }
        return session
    }

    private func status(of session: SavedSession) -> EngineSessionStatus {
        let id = session.sessionID
        if recording.sessionID == id, recording.phase != .idle { return .recording }
        if processingQueue.currentSessionID == id { return .processing }
        if processingQueue.sessionIDs.contains(id) { return .queued }
        switch session.processingStatus {
        case .complete, .classificationPending: return .finalized
        case .running: return .processing
        case .notProcessed: return .queued
        case .paused, .failed, .corrupted: return .failed
        }
    }
}

// MARK: EngineSessionHandling

extension EngineApplicationCore: EngineSessionHandling {
    func list(_ payload: EngineSessionListPayload, context: EngineRequestContext) async throws -> EngineSessionListResult {
        let sessions = try currentSessions()
        var start = 0
        if let cursor = payload.cursor {
            guard let parsed = Int(cursor), parsed >= 0, parsed <= sessions.count, String(parsed) == cursor else {
                throw EngineFailures.commandError(.invalidCursor, "cursor が不正です: \(cursor)", stage: .recovery)
            }
            start = parsed
        }
        let end = min(sessions.count, start + payload.limit)
        let page = try sessions[start..<end].map { summary -> EngineSessionSummary in
            switch summary {
            case let .readable(session):
                return try EngineSessionSummary(
                    folderID: session.sessionURL.lastPathComponent, sessionID: EngineFailures.wireID(session.sessionID),
                    status: status(of: session), error: nil
                )
            case let .unreadable(sessionURL, _, reason):
                return try EngineSessionSummary(
                    folderID: sessionURL.lastPathComponent, sessionID: nil, status: .unreadable,
                    error: EngineFailures.failure(
                        code: .filesystem, message: reason, stage: .recovery, sessionID: nil, severity: .error,
                        recoveryAction: .inspectSession,
                        details: [EngineFailures.detail(domain: "catalog", code: "unreadable", message: reason, path: sessionURL.path)]
                    )
                )
            }
        }
        return try EngineSessionListResult(sessions: page, nextCursor: end < sessions.count ? String(end) : nil)
    }

    func importSession(_ payload: EngineImportPayload, context: EngineRequestContext) async throws -> EngineSessionPayload {
        try await performMutation { [self] in
            try await importRetained(payload, context: context)
        }
    }

    private func importRetained(_ payload: EngineImportPayload, context: EngineRequestContext) async throws -> EngineSessionPayload {
        try requireAcceptingProcessing(stage: .importing)
        guard recording.phase == .idle else {
            throw EngineFailures.commandError(
                .busy, "録音中は取り込めません", stage: .importing, recoveryAction: .retry
            )
        }
        guard (payload.inputPath as NSString).isAbsolutePath else {
            throw EngineFailures.commandError(
                .filesystem, "input_path は絶対パスで指定してください: \(payload.inputPath)", stage: .importing
            )
        }
        recording.beginImport()
        stateDidChange()
        defer {
            recording.finish()
            stateDidChange()
        }
        let audioURL = URL(fileURLWithPath: payload.inputPath)
        let importer = RetainedSessionImporter(paths: .trustedApplication(paths))
        let retained: RetainedSession
        do {
            retained = try await Task.detached(executorPreference: BlockingIOExecutor.shared) { try importer.importRetainedSession(audioURL: audioURL) }.value
        } catch {
            var cleanupErrors: [EngineErrorDetail] = []
            var sessionID: UUID?
            if let retainedError = error as? RetainedImportError, let created = retainedError.createdSession {
                sessionID = created.sessionID
                do {
                    try SessionFileAccess.removeIfPresent(created.sessionURL, relativeTo: paths.sessionsRoot)
                } catch {
                    cleanupErrors.append(EngineFailures.detail(
                        domain: "import", code: "cleanup", message: error.localizedDescription, path: created.sessionURL.path
                    ))
                }
            }
            let underlying = (error as? RetainedImportError)?.underlying ?? error
            throw EngineFailures.commandError(
                .filesystem, "音声ファイルを読み込めませんでした: \(underlying.localizedDescription)", stage: .importing,
                sessionID: sessionID, details: [EngineFailures.detail(for: underlying)], cleanupErrors: cleanupErrors
            )
        }
        savedSessionsAreStale = true
        processingCoordinator.enqueue(retained.finalize)
        return try EngineSessionPayload(sessionID: EngineFailures.wireID(retained.sessionID))
    }

    func reprocess(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineSessionPayload {
        let sessionID = try EngineFailures.sessionID(payload.sessionID, stage: .finalization)
        try requireAcceptingProcessing(stage: .finalization)
        _ = try requireSettings(stage: .finalization)
        _ = try requireModelsPrepared(stage: .finalization)
        guard recording.phase == .idle else {
            throw EngineFailures.commandError(
                .busy, "録音中は再処理できません", stage: .finalization, sessionID: sessionID, recoveryAction: .retry
            )
        }
        let session = try readableSession(sessionID)
        guard session.audioSource != nil else {
            throw EngineFailures.commandError(
                .filesystem, "保存済み音声がないため再処理できません", stage: .finalization, sessionID: sessionID,
                recoveryAction: .inspectSession
            )
        }
        guard !processingQueue.containsForReprocessing(sessionID), processingQueue.claimReprocessing(sessionID) else {
            throw EngineFailures.commandError(
                .busy, "このセッションは処理待ちまたは処理中です", stage: .finalization, sessionID: sessionID, recoveryAction: .retry
            )
        }
        processingCoordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .replace))
        stateDidChange()
        return try await awaitCompletion(sessionID: sessionID, kind: .finalization, payload: payload, stage: .finalization)
    }

    func retryDecisions(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineSessionPayload {
        let sessionID = try EngineFailures.sessionID(payload.sessionID, stage: .decisions)
        try requireAcceptingProcessing(stage: .decisions)
        let settings = try requireSettings(stage: .decisions)
        _ = try requireModelsPrepared(stage: .decisions)
        guard recording.phase == .idle else {
            throw EngineFailures.commandError(
                .busy, "録音中は判定を再試行できません", stage: .decisions, sessionID: sessionID, recoveryAction: .retry
            )
        }
        guard !processingQueue.containsForReprocessing(sessionID) else {
            throw EngineFailures.commandError(
                .busy, "このセッションは処理待ちまたは処理中です", stage: .decisions,
                sessionID: sessionID, recoveryAction: .retry
            )
        }
        guard settings.decisionsEnabled else {
            throw EngineFailures.commandError(
                .invalidSettings, "判定が無効のため再試行できません", stage: .decisions, sessionID: sessionID,
                recoveryAction: .replaceSettings
            )
        }
        _ = try readableSession(sessionID)
        let sessionsRoot = paths.sessionsRoot
        let candidates: [RecoverableSession]
        do {
            candidates = try SessionRecoveryScanner(sessionsRoot: sessionsRoot).pendingSessions().candidates
        } catch {
            throw EngineFailures.commandError(from: error, fallback: .filesystem, stage: .decisions, sessionID: sessionID, recoveryAction: .retry)
        }
        let requests = candidates
            .filter { $0.manifest.sessionID == sessionID }
            .compactMap { SessionRecoveryPlan($0.action).decisionRetryRequest(sessionID: sessionID) }
        guard !requests.isEmpty else { return payload }
        for request in requests { processingCoordinator.enqueue(request) }
        stateDidChange()
        return try await awaitCompletion(sessionID: sessionID, kind: .decisionRetry, payload: payload, stage: .decisions)
    }

    private func requireAcceptingProcessing(stage: EngineStage) throws {
        guard !isShuttingDown else {
            throw EngineFailures.commandError(.cancelled, "終了処理中のため処理を開始できません", stage: stage)
        }
        guard !processingQueue.isMaintainingStorage else {
            throw EngineFailures.commandError(
                .busy, "起動時の保存データの整理が終わるまで処理を開始できません", stage: stage, recoveryAction: .retry
            )
        }
        guard !isPreparingModels else {
            throw EngineFailures.commandError(
                .busy, "モデルの準備が実行中のため処理を開始できません", stage: stage, recoveryAction: .retry
            )
        }
        let processingCount = processingQueue.pending.count
            + processingQueue.thermallyHeld.count
            + (processingQueue.currentSessionID == nil ? 0 : 1)
        guard processingCount < EngineApplicationCore.queueLimit else {
            throw EngineFailures.commandError(
                .busy, "処理待ちが上限に達しているため処理を開始できません", stage: stage, recoveryAction: .retry
            )
        }
    }

    private func awaitCompletion(
        sessionID: UUID, kind: EngineCompletionRegistry.Kind, payload: EngineSessionPayload, stage: EngineStage
    ) async throws -> EngineSessionPayload {
        switch try await completions.wait(sessionID: sessionID, kind: kind) {
        case .completed:
            return payload
        case let .failed(message):
            throw EngineFailures.commandError(
                .processingFailure, message, stage: stage, sessionID: sessionID,
                recoveryAction: kind == .finalization ? .reprocess : .retryDecisions
            )
        case .paused:
            throw EngineFailures.commandError(
                .cancelled, "処理は中断されました。次回の起動時に再開できます", stage: stage, sessionID: sessionID,
                severity: .warning, recoveryAction: .reprocess
            )
        }
    }

    func export(_ payload: EngineExportPayload, context: EngineRequestContext) async throws -> EngineExportResult {
        guard !isShuttingDown else {
            throw EngineFailures.commandError(.cancelled, "終了処理中のため書き出しを開始できません", stage: .shutdown)
        }
        let sessionID = try EngineFailures.sessionID(payload.sessionID, stage: .exporting)
        guard (payload.destinationPath as NSString).isAbsolutePath else {
            throw EngineFailures.commandError(
                .exportFailure, "destination_path は絶対パスで指定してください: \(payload.destinationPath)",
                stage: .exporting, sessionID: sessionID
            )
        }
        let session = try readableSession(sessionID)
        let folder = try await exportBundle(session, to: URL(fileURLWithPath: payload.destinationPath, isDirectory: true))
        return try EngineExportResult(sessionID: payload.sessionID, destinationPath: folder.path)
    }

    /// Publishes the session's `transcript.txt` and audio under `directory`. Returns the published bundle folder.
    func exportBundle(_ session: SavedSession, to directory: URL) async throws -> URL {
        try await performMutation { [self] in
            try await exportTrackedBundle(session, to: directory)
        }
    }

    private func exportTrackedBundle(_ session: SavedSession, to directory: URL) async throws -> URL {
        switch savedSessionOperations.beginExport(session, isMaintainingStorage: processingQueue.isMaintainingStorage) {
        case .alreadyExporting:
            throw EngineFailures.commandError(
                .busy, "このセッションは書き出し中です", stage: .exporting, sessionID: session.sessionID, recoveryAction: .retry
            )
        case let .blocked(message):
            throw EngineFailures.commandError(
                .busy, message, stage: .exporting, sessionID: session.sessionID, recoveryAction: .retry
            )
        case .ready:
            break
        }
        do {
            let folder = try await Task.detached(executorPreference: BlockingIOExecutor.shared) { try SessionExporter().export(session: session, to: directory) }.value
            savedSessionOperations.completeExport(sessionID: session.sessionID, folder: folder)
            return folder
        } catch {
            savedSessionOperations.failExport(sessionID: session.sessionID, message: error.localizedDescription)
            throw EngineFailures.commandError(
                from: error, fallback: .exportFailure, stage: .exporting, sessionID: session.sessionID, recoveryAction: .retry
            )
        }
    }
}
