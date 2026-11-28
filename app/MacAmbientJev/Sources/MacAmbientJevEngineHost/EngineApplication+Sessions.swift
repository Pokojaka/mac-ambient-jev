import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

// MARK: Saved sessions

extension EngineApplicationCore {
    /// Formats a session timestamp in Japanese using the caller's time zone.
    ///
    /// Uses Apple's `Date.FormatStyle(date:time:locale:timeZone:)` initializer, available in the installed
    /// Apple Swift 6.4 toolchain. See [Date.FormatStyle](https://developer.apple.com/documentation/foundation/date/formatstyle)
    /// and the [Swift 6.4 release](https://www.swift.org/blog/swift-6.4-released/).
    static func sessionDisplayName(_ date: Date, timeZone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(
            date: .abbreviated,
            time: .shortened,
            locale: Locale(identifier: "ja_JP"),
            timeZone: timeZone
        ))
    }

    /// The catalog, re-read after anything that may have changed it.
    func currentSessions() async throws -> [SavedSessionSummary] {
        while savedSessionsAreStale {
            let version = savedSessionsVersion
            let sessions = try await sessionCatalogLookup(paths.sessionsRoot)
            guard savedSessionsVersion == version else { continue }
            savedSessionOperations.replaceSessions(sessions)
            savedSessionsAreStale = false
        }
        return savedSessionOperations.sessions
    }

    func readableSession(_ sessionID: UUID) async throws -> SavedSession {
        _ = try await currentSessions()
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
    func sessionSummary(_ summary: SavedSessionSummary) throws -> EngineSessionSummary {
        switch summary {
        case let .unreadable(sessionURL, sessionID, reason):
            return try EngineSessionSummary(
                folderID: sessionURL.lastPathComponent,
                sessionID: sessionID.map(EngineFailures.wireID),
                status: .unreadable,
                error: EngineFailures.failure(
                    code: .filesystem,
                    message: reason,
                    stage: .recovery,
                    sessionID: sessionID,
                    severity: .error,
                    recoveryAction: .inspectSession,
                    details: [EngineFailures.detail(
                        domain: "catalog", code: "unreadable", message: reason, path: sessionURL.path
                    )]
                ),
                displayName: "日時を読み取れません",
                statusText: "読み込みエラー: \(reason)",
                folderPath: sessionURL.path,
                exportPath: nil,
                canReprocess: false,
                canRetryDecisions: false,
                canExport: false,
                metadata: .unreadable(reason: reason)
            )

        case let .readable(session):
            let audio: EngineSessionAudio
            switch session.audio {
            case .available:
                audio = .available
            case .missing:
                audio = .missing
            case .unreadable(let reason):
                audio = .unreadable(reason: reason)
            }

            let source: EngineSessionSource
            switch session.source {
            case .recording(.microphone):
                source = .microphone
            case .recording(.systemAudio):
                source = .systemAudio
            case .imported(let originalFilename):
                source = .imported(originalFilename: originalFilename)
            }

            let statusText: String
            switch session.audio {
            case .missing:
                statusText = "保存済み音声がありません"
            case .unreadable(let reason):
                statusText = "音声を読めません: \(reason)"
            case .available:
                statusText = switch session.processingStatus {
                case .notProcessed: "未処理"
                case .running: "処理中"
                case .paused: "処理は中断されました。次回の起動時に再開できます"
                case .complete: session.hasActiveTranscript ? "文字起こしあり" : "処理完了"
                case .classificationPending: "文字起こしあり・判定を再試行"
                case .failed(let reason): "再処理が必要: \(reason ?? "処理に失敗しました")"
                case .corrupted: "文字起こしデータが破損しています（音声から再処理できます）"
                }
            }

            let sessionID = session.sessionID
            let busySession = isSessionBusy(sessionID)
            let processingCount = processingQueue.summaries.count
            let processingAdmissible = !isShuttingDown
                && !processingQueue.isMaintainingStorage
                && recording.phase == .idle
                && settings != nil
                && inference != nil
                && processingCount < Self.queueLimit
            let canReprocess = processingAdmissible && !busySession && session.audioSource != nil
                && monitorFailureError(sessionID: sessionID) == nil
                && modelPreparationError(sessionID: sessionID) == nil
            let canRetryDecisions = processingAdmissible
                && !busySession
                && settings?.decisionsEnabled == true
                && session.processingStatus == .classificationPending
                && session.audioSource != nil
                && session.hasActiveTranscript

            var exportState = savedSessionOperations.exports[sessionID]
            var exportPath: String?
            if case .exported(let folder)? = exportState {
                exportPath = folder.path
            } else if exportState == nil,
                      let destinationPath = settings?.exportDestinationPath,
                      let audioSource = session.audioSource {
                let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
                let folder = destination.appending(
                    path: session.sessionURL.lastPathComponent, directoryHint: .isDirectory
                )
                do {
                    if try SessionFileAccess.isDirectoryIfPresent(folder, relativeTo: destination) == true,
                       SessionExportLayout.isCompleteExport(folder: folder, audioSource: audioSource) {
                        savedSessionOperations.recordExistingExport(.exported(folder), sessionID: sessionID)
                        exportPath = folder.path
                    }
                } catch {
                    savedSessionOperations.recordExistingExport(
                        .failed("書き出し先を確認できません: \(error.localizedDescription)"), sessionID: sessionID
                    )
                }
            }
            exportState = savedSessionOperations.exports[sessionID]
            let exportError: EngineFailure?
            if case let .failed(message)? = exportState {
                exportError = EngineFailures.failure(
                    code: .exportFailure,
                    message: message,
                    stage: .exporting,
                    sessionID: sessionID,
                    severity: .error,
                    recoveryAction: .retry
                )
            } else {
                exportError = nil
            }

            let exportBlockedByMaintenance: Bool
            if processingQueue.isMaintainingStorage {
                switch session.audioSource {
                case .recordedPCM?:
                    exportBlockedByMaintenance = true
                default:
                    exportBlockedByMaintenance = false
                }
            } else {
                exportBlockedByMaintenance = false
            }
            let isCorrupted: Bool
            if case .corrupted = session.processingStatus {
                isCorrupted = true
            } else {
                isCorrupted = false
            }
            let canExport = !isShuttingDown
                && !busySession
                && exportState != .exporting
                && session.hasActiveTranscript
                && session.audioSource != nil
                && !isCorrupted
                && !exportBlockedByMaintenance

            return try EngineSessionSummary(
                folderID: session.sessionURL.lastPathComponent,
                sessionID: EngineFailures.wireID(sessionID),
                status: status(of: session),
                error: exportError,
                displayName: Self.sessionDisplayName(session.createdAt, timeZone: timeZone),
                statusText: statusText,
                folderPath: session.sessionURL.path,
                exportPath: exportPath,
                canReprocess: canReprocess,
                canRetryDecisions: canRetryDecisions,
                canExport: canExport,
                metadata: .readable(
                    createdAt: session.createdAt.timeIntervalSince1970,
                    source: source,
                    audio: audio,
                    hasTranscript: session.hasActiveTranscript
                )
            )
        }
    }

    func list(_ payload: EngineSessionListPayload, context: EngineRequestContext) async throws -> EngineSessionListResult {
        let snapshot: EngineSessionListSnapshot
        let isFirstPage = payload.cursor == nil
        if isFirstPage {
            savedSessionsAreStale = true
            savedSessionsVersion += 1
            let sessions = try await currentSessions().map { try sessionSummary($0) }
            snapshot = try EngineSessionListSnapshot(
                sessions: sessions,
                navigation: EnginePageNavigation(limit: payload.limit)
            )
        } else {
            guard let retained = sessionListSnapshot else {
                throw EngineFailures.commandError(
                    .invalidCursor, "cursor に対応する保存済み録音一覧がありません", stage: .protocolValidation
                )
            }
            snapshot = retained
        }

        let location = try snapshot.navigation.location(cursor: payload.cursor, limit: payload.limit)
        let sessions = snapshot.sessions
        let end = try snapshot.pageSizer.end(from: location.start, limit: payload.limit)

        let cursors = snapshot.navigation.cursors(for: location, end: end, total: sessions.count)
        let result = try EngineSessionListResult(
            sessions: Array(sessions[location.start..<end]),
            nextCursor: cursors.next,
            previousCursor: cursors.previous
        )
        if isFirstPage {
            sessionListSnapshot = snapshot
        }
        return result
    }

    func inspect(
        _ payload: EngineSessionInspectPayload,
        context: EngineRequestContext
    ) async throws -> EngineSessionSummary {
        savedSessionsAreStale = true
        savedSessionsVersion += 1
        guard let catalogSummary = try await currentSessions().first(where: {
            $0.sessionURL.lastPathComponent == payload.folderID
        }) else {
            throw EngineFailures.commandError(
                .sessionNotFound,
                "保存済み録音のフォルダが見つかりません: \(payload.folderID)",
                stage: .recovery,
                recoveryAction: .inspectSession
            )
        }
        let summary = try sessionSummary(catalogSummary)
        let maxID = try EngineID(UInt64.max)
        let output = try EngineOutput(
            version: 1,
            sequence: maxID,
            requestID: maxID,
            event: .completed(.sessionInspect(summary))
        )
        do {
            _ = try EngineCodec.encodeOutput(output)
        } catch EngineProtocolError.lineTooLong {
            throw EngineFailures.commandError(
                .filesystem,
                "保存済み録音の情報が大きすぎて詳細を返せません",
                stage: .recovery,
                recoveryAction: .inspectSession
            )
        }
        return summary
    }

    private func isSessionBusy(_ sessionID: UUID) -> Bool {
        processingQueue.containsProcessing(sessionID)
            || recording.sessionID == sessionID
            || liveCoordinator.hasWork(sessionID: sessionID)
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
        setRecordingStatus(UserFacingStatus.importingAudio.text, tone: .neutral)
        stateDidChange()
        defer {
            recording.finish()
            stateDidChange()
            processingCoordinator.resumeModelHeldProcessing()
        }
        let audioURL = URL(fileURLWithPath: payload.inputPath)
        let importer = RetainedSessionImporter(paths: .trustedApplication(paths), timeZone: timeZone)
        let importRetainedSession = self.importRetainedSession
        let retained: RetainedSession
        do {
            retained = try await Task.detached(executorPreference: BlockingIOExecutor.shared) {
                try await importRetainedSession(audioURL, importer)
            }.value
            setRecordingStatus("「\(audioURL.lastPathComponent)」を読み込みました", tone: .neutral)
        } catch {
            var statusText = "音声ファイルを読み込めませんでした: \(error.localizedDescription)"
            var cleanupErrors: [EngineErrorDetail] = []
            var sessionID: UUID?
            if let retainedError = error as? RetainedImportError, let created = retainedError.createdSession {
                sessionID = created.sessionID
                do {
                    try SessionFileAccess.removeIfPresent(created.sessionURL, relativeTo: paths.sessionsRoot)
                } catch {
                    statusText += "（読み込み途中のセッションを削除できませんでした: \(error.localizedDescription)）"
                    cleanupErrors.append(EngineFailures.detail(
                        domain: "import", code: "cleanup", message: error.localizedDescription, path: created.sessionURL.path
                    ))
                }
            }
            setRecordingStatus(statusText, tone: .error)
            let underlying = (error as? RetainedImportError)?.underlying ?? error
            throw EngineFailures.commandError(
                .filesystem, "音声ファイルを読み込めませんでした: \(underlying.localizedDescription)", stage: .importing,
                sessionID: sessionID, details: [EngineFailures.detail(for: underlying)], cleanupErrors: cleanupErrors
            )
        }
        savedSessionsAreStale = true
        savedSessionsVersion += 1
        processingCoordinator.enqueue(retained.finalize)
        return try EngineSessionPayload(sessionID: EngineFailures.wireID(retained.sessionID))
    }

    private func requireReprocessAdmissible(sessionID: UUID) throws {
        try Task.checkCancellation()
        if recording.sessionID == sessionID {
            throw EngineFailures.commandError(
                .busy, "このセッションは録音中のため再処理できません",
                stage: .finalization, sessionID: sessionID, recoveryAction: .retry
            )
        }
        try requireAcceptingProcessing(stage: .finalization)
        guard recording.phase == .idle else {
            throw EngineFailures.commandError(
                .busy, "録音中または録音・読み込み処理中は再処理できません",
                stage: .finalization, sessionID: sessionID, recoveryAction: .retry
            )
        }
        if processingQueue.containsProcessing(sessionID) {
            throw EngineFailures.commandError(
                .busy, "このセッションは処理待ち・保留中または実行中のため再処理できません",
                stage: .finalization, sessionID: sessionID, recoveryAction: .retry
            )
        }
        if liveCoordinator.hasWork(sessionID: sessionID) {
            throw EngineFailures.commandError(
                .busy, "このセッションのライブ文字起こし処理中は再処理できません",
                stage: .finalization, sessionID: sessionID, recoveryAction: .retry
            )
        }
    }

    private func requireDecisionRetryAdmissible(sessionID: UUID) throws {
        try Task.checkCancellation()
        try requireAcceptingProcessing(stage: .decisions)
        let settings = try requireSettings(stage: .decisions)
        _ = try requireConfiguredInference(stage: .decisions)
        guard recording.phase == .idle else {
            throw EngineFailures.commandError(
                .busy, "録音中は判定を再試行できません", stage: .decisions, sessionID: sessionID, recoveryAction: .retry
            )
        }
        guard !processingQueue.containsProcessing(sessionID),
              recording.sessionID != sessionID,
              !liveCoordinator.hasWork(sessionID: sessionID) else {
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
    }

    func reprocess(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineSessionPayload {
        let sessionID = try EngineFailures.sessionID(payload.sessionID, stage: .finalization)
        try requireReprocessAdmissible(sessionID: sessionID)
        _ = try requireSettings(stage: .finalization)
        let session = try await readableSession(sessionID)
        try requireReprocessAdmissible(sessionID: sessionID)
        _ = try requireSettings(stage: .finalization)
        guard session.audioSource != nil else {
            throw EngineFailures.commandError(
                .filesystem, "保存済み音声がないため再処理できません", stage: .finalization, sessionID: sessionID,
                recoveryAction: .inspectSession
            )
        }
        if let error = monitorFailureError(sessionID: sessionID) { throw error }
        if let error = modelPreparationError(sessionID: sessionID) { throw error }
        _ = try requireConfiguredInference(stage: .finalization)

        let requestID: UUID
        do {
            requestID = try processingCoordinator.enqueueReprocess(sessionID: sessionID)
        } catch let error as SessionProcessingAdmissionError {
            guard case .busy(let message) = error else { throw error }
            throw EngineFailures.commandError(
                .busy, message, stage: .finalization, sessionID: sessionID, recoveryAction: .retry
            )
        }
        completions.register(requestID: requestID, terminalReplyClaim: context.claimTerminalReply)
        stateDidChange()
        return try await awaitCompletion(
            requestID: requestID, sessionID: sessionID, kind: .finalization,
            payload: payload, stage: .finalization
        )
    }

    func retryDecisions(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineSessionPayload {
        let sessionID = try EngineFailures.sessionID(payload.sessionID, stage: .decisions)
        try requireDecisionRetryAdmissible(sessionID: sessionID)
        _ = try await readableSession(sessionID)
        let sessionsRoot = paths.sessionsRoot
        while true {
            let inspectedCompletionEpoch = processingCompletionEpoch
            let inspection: SessionInspection
            do {
                inspection = try await Task.detached(executorPreference: BlockingIOExecutor.shared) {
                    try SessionRecoveryScanner(sessionsRoot: sessionsRoot)
                        .inspect(sessionID: sessionID, includeFailed: false)
                }.value
            } catch {
                if processingCompletionEpoch != inspectedCompletionEpoch {
                    try requireDecisionRetryAdmissible(sessionID: sessionID)
                    continue
                }
                throw EngineFailures.commandError(
                    from: error, fallback: .filesystem, stage: .decisions, sessionID: sessionID,
                    recoveryAction: .retry
                )
            }
            if processingCompletionEpoch != inspectedCompletionEpoch {
                try requireDecisionRetryAdmissible(sessionID: sessionID)
                continue
            }

            let requests = inspection.recovery
                .flatMap { SessionRecoveryPlan($0.action).decisionRetryRequest(sessionID: sessionID) }
                .map { [$0] } ?? []
            try requireDecisionRetryAdmissible(sessionID: sessionID)
            guard !requests.isEmpty else { return payload }
            for request in requests {
                completions.register(requestID: request.requestID, terminalReplyClaim: context.claimTerminalReply)
            }
            for request in requests { processingCoordinator.enqueue(request) }
            stateDidChange()
            for request in requests {
                _ = try await awaitCompletion(
                    requestID: request.requestID, sessionID: sessionID, kind: .decisionRetry,
                    payload: payload, stage: .decisions
                )
            }
            return payload
        }
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
        let processingCount = processingQueue.summaries.count
        guard processingCount < EngineApplicationCore.queueLimit else {
            throw EngineFailures.commandError(
                .busy, "処理待ちが上限に達しているため処理を開始できません", stage: stage, recoveryAction: .retry
            )
        }
    }

    private func awaitCompletion(
        requestID: UUID, sessionID: UUID, kind: EngineCompletionRegistry.Kind,
        payload: EngineSessionPayload, stage: EngineStage
    ) async throws -> EngineSessionPayload {
        switch try await completions.wait(requestID: requestID) {
        case .completed:
            return payload
        case let .failed(message):
            throw EngineFailures.commandError(
                .processingFailure, message, stage: stage, sessionID: sessionID,
                recoveryAction: kind == .finalization ? .reprocess : .retryDecisions
            )
        case .commandFailure(let error):
            throw error
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
        let session = try await readableSession(sessionID)
        let folder = try await performMutation { [self] in
            guard !isSessionBusy(session.sessionID) else {
                throw EngineFailures.commandError(
                    .busy, "このセッションは処理中のため書き出せません", stage: .exporting,
                    sessionID: session.sessionID, recoveryAction: .retry
                )
            }
            return try await exportTrackedBundle(
                session, to: URL(fileURLWithPath: payload.destinationPath, isDirectory: true)
            )
        }
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
            let folder = try await exportSessionBundle(session, directory)
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
