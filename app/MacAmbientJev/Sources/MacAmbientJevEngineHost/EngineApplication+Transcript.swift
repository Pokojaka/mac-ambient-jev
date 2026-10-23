import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

extension EngineApplicationCore {
    /// The most rows `rows` and `transcript.watch` carry; the protocol's page limit.
    static let transcriptPageLimit = 200

    private func newRevision() -> UInt64 {
        nextTranscriptRevision += 1
        return nextTranscriptRevision
    }

    private func wireRevision(_ value: UInt64) -> EngineID {
        do {
            return try EngineID(value)
        } catch {
            preconditionFailure("transcript revisions start at 1: \(error)")
        }
    }

    /// Updates any cached view of this session. Only the watched session is streamed.
    func transcriptDidUpdate(sessionID: UUID, segments: [MaterializedTranscriptSegment]) {
        let watchedCache = sessionID == watchedSessionID && transcript?.sessionID == sessionID ? transcript : nil
        let cachedRead = readTranscript?.sessionID == sessionID ? readTranscript : nil
        guard watchedCache != nil || cachedRead != nil else { return }

        var watchedProjection = watchedCache?.projection
        if let watchedCache, watchedProjection == nil {
            watchedProjection = EngineTranscriptProjection.Incremental(rows: watchedCache.rows)
        }
        var readProjection = cachedRead?.projection
        if let cachedRead, readProjection == nil {
            readProjection = EngineTranscriptProjection.Incremental(rows: cachedRead.rows)
        }

        // Save helpers before validation: a failed update leaves its dirty state available for retry.
        if var cache = watchedCache {
            cache.projection = watchedProjection
            transcript = cache
        }
        if var cache = cachedRead {
            cache.projection = readProjection
            readTranscript = cache
        }

        let projectionsAreShared = watchedProjection != nil && watchedProjection === readProjection
        var watchedUpdate: EngineTranscriptProjection.Update?
        var readUpdate: EngineTranscriptProjection.Update?
        var watchedChanges: EngineTranscriptProjection.Changes?
        var readChanges: EngineTranscriptProjection.Changes?
        var projectionFailures: [EngineTranscriptProjection.RowFailure] = []
        var validatedByProjection: [Set<String>] = []
        var deletedByProjection: [Set<String>] = []
        var rowlessByProjection: [Set<String>] = []

        if let watchedProjection {
            do {
                let update = try watchedProjection.update(segments)
                watchedUpdate = update
                watchedChanges = update.changes
                validatedByProjection.append(update.validatedIDs)
                deletedByProjection.append(update.deletedIDs)
                rowlessByProjection.append(update.rowlessIDs)
            } catch {
                projectionFailures.append(contentsOf: error.rows)
                watchedChanges = error.changes
                validatedByProjection.append(error.validatedIDs)
                deletedByProjection.append(error.deletedIDs)
                rowlessByProjection.append(error.rowlessIDs)
            }
        }
        if projectionsAreShared {
            readUpdate = watchedUpdate
            readChanges = watchedChanges
        } else if let readProjection {
            do {
                let update = try readProjection.update(segments)
                readUpdate = update
                readChanges = update.changes
                validatedByProjection.append(update.validatedIDs)
                deletedByProjection.append(update.deletedIDs)
                rowlessByProjection.append(update.rowlessIDs)
            } catch {
                projectionFailures.append(contentsOf: error.rows)
                readChanges = error.changes
                validatedByProjection.append(error.validatedIDs)
                deletedByProjection.append(error.deletedIDs)
                rowlessByProjection.append(error.rowlessIDs)
            }
        }

        guard !validatedByProjection.isEmpty else {
            preconditionFailure("a matching transcript cache has an incremental projection")
        }
        let validatedIDs = validatedByProjection.dropFirst().reduce(validatedByProjection[0]) { result, ids in
            result.intersection(ids)
        }
        let deletedIDs = deletedByProjection.dropFirst().reduce(deletedByProjection[0]) { result, ids in
            result.intersection(ids)
        }
        let rowlessIDs = rowlessByProjection.dropFirst().reduce(rowlessByProjection[0]) { result, ids in
            result.intersection(ids)
        }

        var encodingFailures: [EngineTranscriptProjection.RowFailure] = []
        var encodingValidatedIDs: Set<String> = []
        var changesFit = true
        var encodingOutcomes: [(changes: EngineTranscriptProjection.Changes, isWatched: Bool)] = []
        if let watchedChanges { encodingOutcomes.append((watchedChanges, true)) }
        if !projectionsAreShared, let readChanges { encodingOutcomes.append((readChanges, false)) }
        for outcome in encodingOutcomes where !outcome.changes.isEmpty {
            let changes = outcome.changes
            do {
                let bytes = try EngineTranscriptProjection.encodedChangeBytes(
                    upserts: changes.upserts, removedRowIDs: changes.removedRowIDs
                )
                encodingValidatedIDs.formUnion(changes.upserts.map(\.rowID))
                encodingValidatedIDs.formUnion(changes.removedRowIDs)
                if outcome.isWatched {
                    changesFit = changes.count <= Self.transcriptPageLimit
                        && bytes <= EngineTranscriptProjection.pageByteBudget
                }
            } catch {
                encodingFailures.append(contentsOf: error.rows)
                let failedIDs = Set(error.rows.map(\.rowID))
                encodingValidatedIDs.formUnion(changes.upserts.map(\.rowID).filter { !failedIDs.contains($0) })
                encodingValidatedIDs.formUnion(changes.removedRowIDs.filter { !failedIDs.contains($0) })
            }
        }
        encodingValidatedIDs.formIntersection(validatedIDs.union(deletedIDs))

        var observedFailures: [EngineTranscriptRowFailure] = []
        for row in projectionFailures {
            let marker = EngineTranscriptRowFailure(
                rowID: row.rowID, input: .segments(segments.filter { $0.segmentID == row.rowID }),
                failure: transcriptFailure(row.error, sessionID: sessionID)
            )
            if !observedFailures.contains(marker) { observedFailures.append(marker) }
        }
        let currentUpserts = [watchedChanges, readChanges].compactMap { $0 }.flatMap(\.upserts)
        for row in encodingFailures {
            let input: EngineTranscriptRowFailure.Input = if let upsert = currentUpserts.first(where: { $0.rowID == row.rowID }) {
                .row(upsert)
            } else {
                .removal
            }
            let marker = EngineTranscriptRowFailure(
                rowID: row.rowID, input: input, failure: transcriptFailure(row.error, sessionID: sessionID)
            )
            if !observedFailures.contains(marker) { observedFailures.append(marker) }
        }

        var sourceOrder: [String] = []
        var orderedIDs: Set<String> = []
        for segment in segments where orderedIDs.insert(segment.segmentID).inserted {
            sourceOrder.append(segment.segmentID)
        }
        let observedIDs = Set(observedFailures.map(\.rowID))
        let verifiedNoRowIDs = rowlessIDs.union(deletedIDs)
        if !observedFailures.isEmpty {
            reconcileTranscriptFailures(
                observedFailures, observedIDs: observedIDs, projectionValidatedIDs: validatedIDs,
                encodingValidatedIDs: encodingValidatedIDs, verifiedNoRowIDs: verifiedNoRowIDs,
                sourceOrder: sourceOrder, sessionID: sessionID
            )
            return
        }
        reconcileTranscriptFailures(
            [], observedIDs: [], projectionValidatedIDs: validatedIDs,
            encodingValidatedIDs: encodingValidatedIDs, verifiedNoRowIDs: verifiedNoRowIDs,
            sourceOrder: sourceOrder, sessionID: sessionID
        )

        // Commit only after every projection and every pending row has passed validation.
        if projectionsAreShared {
            watchedProjection?.commit()
        } else {
            watchedProjection?.commit()
            readProjection?.commit()
        }

        let watchedChanged = watchedChanges?.isEmpty == false
        let readChanged = readUpdate?.changes.isEmpty == false
        var updatedWatched: EngineTranscriptCache?
        if watchedChanged, var cache = transcript, cache.sessionID == sessionID, let update = watchedUpdate {
            cache.rows = update.rows
            cache.revision = newRevision()
            cache.isLiveState = true
            transcript = cache
            updatedWatched = cache
        }
        if readChanged, var cache = readTranscript, cache.sessionID == sessionID, let update = readUpdate {
            cache.rows = update.rows
            cache.revision = newRevision()
            cache.isLiveState = true
            readTranscript = cache
        }
        guard let cache = updatedWatched, let changes = watchedChanges else { return }
        do {
            let payload: EngineRowsPayload
            if changesFit {
                payload = try EngineRowsPayload(
                    sessionID: EngineFailures.wireID(sessionID), revision: wireRevision(cache.revision), kind: .changes,
                    rows: changes.upserts, removedRowIDs: changes.removedRowIDs, nextCursor: nil
                )
            } else {
                payload = try Self.reloadRequired(sessionID: sessionID, revision: wireRevision(cache.revision))
            }
            if eventsEnabled { try events.rows(payload) }
        } catch {
            EngineLog.write("rows event not sent: \(error)")
        }
    }

    /// Replaces matching caches with the saved transcript after a successful finalization.
    /// Publication always invalidates existing cursors, even when projected rows are identical.
    func transcriptDidPublish(sessionID: UUID) {
        if transcriptReadSnapshot?.sessionID == sessionID {
            transcriptReadSnapshot = nil
        }
        let watchedCache = sessionID == watchedSessionID && transcript?.sessionID == sessionID ? transcript : nil
        let cachedRead = readTranscript?.sessionID == sessionID ? readTranscript : nil
        guard watchedCache != nil || cachedRead != nil else { return }

        let rows: [EngineTranscriptRow]
        do {
            let session = try readableSession(sessionID)
            guard let audioSource = session.audioSource else {
                throw EngineFailures.commandError(
                    .filesystem, "保存済み音声を使えないため、文字起こしを表示できません", stage: .finalization,
                    sessionID: sessionID, recoveryAction: .inspectSession
                )
            }
            switch try SavedTranscriptLoader.load(sessionURL: session.sessionURL, audioSource: audioSource) {
            case .unavailable:
                throw EngineFailures.commandError(
                    .processingFailure, "確定済みの文字起こしを読み込めませんでした", stage: .finalization,
                    sessionID: sessionID, recoveryAction: .reprocess
                )
            case let .segments(segments):
                rows = try EngineTranscriptProjection.rows(for: segments)
            }
        } catch {
            reportTranscriptError(error, sessionID: sessionID)
            return
        }

        var updatedWatched: EngineTranscriptCache?
        if var cache = watchedCache {
            cache.rows = rows
            cache.revision = newRevision()
            cache.isLiveState = false
            cache.projection = nil
            cache.reportedTranscriptFailures = []
            transcript = cache
            updatedWatched = cache
        }
        if var cache = cachedRead {
            cache.rows = rows
            cache.revision = newRevision()
            cache.isLiveState = false
            cache.projection = nil
            cache.reportedTranscriptFailures = []
            readTranscript = cache
        }

        guard let cache = updatedWatched else { return }
        do {
            let payload = try Self.reloadRequired(
                sessionID: sessionID, revision: wireRevision(cache.revision)
            )
            if eventsEnabled { try events.rows(payload) }
        } catch {
            EngineLog.write("rows event not sent: \(error)")
        }
    }

    private func reportTranscriptError(_ error: any Error, sessionID: UUID) {
        report(transcriptFailure(error, sessionID: sessionID))
    }

    /// Reconciles observed failures without dropping markers for rows this update did not verify.
    private func reconcileTranscriptFailures(
        _ observed: [EngineTranscriptRowFailure], observedIDs: Set<String>,
        projectionValidatedIDs: Set<String>, encodingValidatedIDs: Set<String>, verifiedNoRowIDs: Set<String>,
        sourceOrder: [String], sessionID: UUID
    ) {
        let previous: [EngineTranscriptRowFailure]
        if sessionID == watchedSessionID, let cache = transcript, cache.sessionID == sessionID {
            previous = cache.reportedTranscriptFailures
        } else if let cache = readTranscript, cache.sessionID == sessionID {
            previous = cache.reportedTranscriptFailures
        } else {
            preconditionFailure("transcript failures are tracked only for a cached session")
        }

        var merged = previous.filter { failure in
            guard !observedIDs.contains(failure.rowID) else { return false }
            switch failure.input {
            case .segments:
                return !projectionValidatedIDs.contains(failure.rowID)
                    && !verifiedNoRowIDs.contains(failure.rowID)
            case .row, .removal:
                return !encodingValidatedIDs.contains(failure.rowID)
                    && !verifiedNoRowIDs.contains(failure.rowID)
            }
        }
        for failure in observed where !merged.contains(failure) {
            merged.append(failure)
        }
        var sourcePositions: [String: Int] = [:]
        for (index, id) in sourceOrder.enumerated() where sourcePositions[id] == nil {
            sourcePositions[id] = index
        }
        let ordered = merged.enumerated().sorted { lhs, rhs in
            let leftPosition = sourcePositions[lhs.element.rowID] ?? Int.max
            let rightPosition = sourcePositions[rhs.element.rowID] ?? Int.max
            return leftPosition == rightPosition ? lhs.offset < rhs.offset : leftPosition < rightPosition
        }.prefix(Self.failureLimit).map(\.element)
        if ordered == previous { return }
        if sessionID == watchedSessionID, var cache = transcript, cache.sessionID == sessionID {
            cache.reportedTranscriptFailures = ordered
            transcript = cache
        }
        if var cache = readTranscript, cache.sessionID == sessionID {
            cache.reportedTranscriptFailures = ordered
            readTranscript = cache
        }
        for failure in ordered where !previous.contains(failure) {
            report(failure.failure)
        }
    }

    private func transcriptFailure(_ error: any Error, sessionID: UUID) -> EngineFailure {
        if let command = error as? EngineCommandError {
            return EngineFailures.failure(
                code: command.code, message: command.message, stage: command.stage, sessionID: sessionID,
                severity: command.severity, recoveryAction: command.recoveryAction,
                details: command.details, cleanupErrors: command.cleanupErrors
            )
        }
        return EngineFailures.failure(
            code: .processingFailure, message: "文字起こし表示を更新できませんでした: \(error.localizedDescription)",
            stage: .finalization, sessionID: sessionID, severity: .error, recoveryAction: .reprocess,
            details: [EngineFailures.detail(for: error)]
        )
    }

    private static func reloadRequired(sessionID: UUID, revision: EngineID) throws -> EngineRowsPayload {
        try EngineRowsPayload(
            sessionID: EngineFailures.wireID(sessionID), revision: revision, kind: .reloadRequired,
            rows: [], removedRowIDs: [], nextCursor: nil
        )
    }

    /// The watched session uses its live view; all other sessions share one read cache.
    private func transcriptCache(for sessionID: UUID) throws -> EngineTranscriptCache {
        let session = try readableSession(sessionID)
        let cache = try makeTranscriptCache(for: sessionID, session: session)
        if sessionID == watchedSessionID { transcript = cache } else { readTranscript = cache }
        return cache
    }

    private func makeTranscriptCache(for sessionID: UUID, session: SavedSession) throws -> EngineTranscriptCache {
        let isWatched = sessionID == watchedSessionID
        let isLiveOrPending = recording.sessionID == sessionID || processingQueue.sessionIDs.contains(sessionID)
        let existingCache = isWatched
            ? (transcript?.sessionID == sessionID ? transcript : nil)
            : (readTranscript?.sessionID == sessionID ? readTranscript : nil)
        if let existingCache, !isLiveOrPending || existingCache.isLiveState {
            return existingCache
        }

        if isLiveOrPending {
            return EngineTranscriptCache(
                sessionID: sessionID, revision: newRevision(), rows: [], isLiveState: true, projection: nil
            )
        }
        guard let audioSource = session.audioSource else {
            throw EngineFailures.commandError(
                .filesystem, "保存済み音声を使えないため、文字起こしを表示できません", stage: .finalization,
                sessionID: sessionID, recoveryAction: .inspectSession
            )
        }
        let rows: [EngineTranscriptRow]
        do {
            switch try SavedTranscriptLoader.load(sessionURL: session.sessionURL, audioSource: audioSource) {
            case .unavailable: rows = []
            case let .segments(segments): rows = try EngineTranscriptProjection.rows(for: segments)
            }
        } catch {
            throw EngineFailures.commandError(
                from: error, fallback: .processingFailure, stage: .finalization, sessionID: sessionID,
                recoveryAction: .reprocess
            )
        }
        return EngineTranscriptCache(
            sessionID: sessionID, revision: newRevision(), rows: rows, isLiveState: false, projection: nil
        )
    }
}

extension EngineApplicationCore: EngineTranscriptHandling {
    func read(_ payload: EngineTranscriptReadPayload, context: EngineRequestContext) async throws -> EngineTranscriptPage {
        let sessionID = try EngineFailures.sessionID(payload.sessionID, stage: .finalization)
        let latestCache = try transcriptCache(for: sessionID)
        let cache: EngineTranscriptCache
        if let revision = payload.revision {
            if let snapshot = transcriptReadSnapshot,
               snapshot.sessionID == sessionID,
               snapshot.revision == revision.value {
                cache = snapshot
            } else if latestCache.revision == revision.value {
                transcriptReadSnapshot = latestCache
                cache = latestCache
            } else {
                throw EngineFailures.commandError(
                    .staleRevision, "文字起こしの revision が古くなっています。最初から読み直してください",
                    stage: .finalization, sessionID: sessionID, recoveryAction: .retry
                )
            }
        } else {
            transcriptReadSnapshot = latestCache
            cache = latestCache
        }
        var offset = 0
        if let cursor = payload.cursor {
            guard payload.revision != nil else {
                throw EngineFailures.commandError(.invalidCursor, "cursor には revision が必要です", stage: .finalization, sessionID: sessionID)
            }
            guard let parsed = Int(cursor), parsed >= 0, parsed <= cache.rows.count, String(parsed) == cursor else {
                throw EngineFailures.commandError(.invalidCursor, "cursor が不正です: \(cursor)", stage: .finalization, sessionID: sessionID)
            }
            offset = parsed
        }
        let page = try EngineTranscriptProjection.page(of: cache.rows, from: offset, limit: payload.limit)
        let next = offset + page.count
        return try EngineTranscriptPage(
            sessionID: payload.sessionID, revision: wireRevision(cache.revision), rows: Array(page),
            nextCursor: next < cache.rows.count ? String(next) : nil
        )
    }

    func watch(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineTranscriptPage {
        let sessionID = try EngineFailures.sessionID(payload.sessionID, stage: .finalization)
        let session = try readableSession(sessionID)
        let cache = try makeTranscriptCache(for: sessionID, session: session)
        let isLiveOrPending = recording.sessionID == sessionID || processingQueue.sessionIDs.contains(sessionID)
        let isFinal: Bool
        if isLiveOrPending {
            isFinal = false
        } else {
            switch session.processingStatus {
            case .complete, .classificationPending: isFinal = !cache.rows.isEmpty
            case .notProcessed, .running, .paused, .failed, .corrupted: isFinal = false
            }
        }
        let tail = try EngineTranscriptProjection.tail(of: cache.rows, limit: Self.transcriptPageLimit)
        let page = try EngineTranscriptPage(
            sessionID: payload.sessionID, revision: wireRevision(cache.revision), rows: Array(tail), nextCursor: nil
        )

        // Commit only after session validation and page construction succeeded.
        transcript = cache
        watchedSessionID = sessionID
        watchedSessionIsFinal = isFinal
        stateDidChange()
        return page
    }
}
