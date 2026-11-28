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
        transcriptEpoch += 1
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

        let watchedRowsChanged = watchedChanges?.isEmpty == false
        let readRowsChanged = readUpdate?.changes.isEmpty == false

        var updatedWatched: EngineTranscriptCache?
        if var cache = transcript, cache.sessionID == sessionID, let update = watchedUpdate {
            cache.rows = update.rows
            cache.materializedSegments = segments
            cache.isLiveState = true
            if watchedRowsChanged {
                cache.revision = newRevision()
                updatedWatched = cache
            }
            transcript = cache
        }
        if var cache = readTranscript, cache.sessionID == sessionID, let update = readUpdate {
            cache.rows = update.rows
            cache.materializedSegments = segments
            cache.isLiveState = true
            if readRowsChanged {
                cache.revision = newRevision()
            }
            readTranscript = cache
        }
        guard let cache = updatedWatched else { return }
        do {
            let payload: EngineRowsPayload
            if let changes = watchedChanges, !changes.isEmpty, changesFit {
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

    /// Selecting a new generation invalidates every snapshot from the previous one immediately.
    func transcriptDidSelectGeneration(sessionID: UUID, generationID: UUID) {
        transcriptEpoch += 1
        finalPublishedSessionIDs.remove(sessionID)
        if transcriptRowDetailsSnapshot?.sessionID == sessionID {
            transcriptRowDetailsSnapshot = nil
        }
        if transcriptReadSnapshot?.sessionID == sessionID {
            transcriptReadSnapshot = nil
            transcriptReadNavigation = nil
        }

        var watchedRevision: UInt64?
        if var cache = transcript, cache.sessionID == sessionID {
            cache.generationID = generationID
            cache.rows = []
            cache.materializedSegments = []
            cache.revision = newRevision()
            cache.isLiveState = true
            cache.projection = EngineTranscriptProjection.Incremental(rows: [])
            cache.reportedTranscriptFailures = []
            watchedRevision = cache.revision
            transcript = cache
        }
        if var cache = readTranscript, cache.sessionID == sessionID {
            cache.generationID = generationID
            cache.rows = []
            cache.materializedSegments = []
            cache.revision = newRevision()
            cache.isLiveState = true
            cache.projection = EngineTranscriptProjection.Incremental(rows: [])
            cache.reportedTranscriptFailures = []
            readTranscript = cache
        }

        guard let watchedRevision else { return }
        do {
            let payload = try Self.reloadRequired(
                sessionID: sessionID, revision: wireRevision(watchedRevision)
            )
            if eventsEnabled { try events.rows(payload) }
        } catch {
            EngineLog.write("rows event not sent: \(error)")
        }
    }

    /// Replaces matching caches with the saved transcript after a successful finalization.
    /// Publication always invalidates existing cursors, even when projected rows are identical.
    func transcriptDidPublish(sessionID: UUID) async {
        retireTranscriptSnapshots(sessionID: sessionID)
        defer { retireTranscriptSnapshots(sessionID: sessionID) }

        let watchedCache = sessionID == watchedSessionID && transcript?.sessionID == sessionID ? transcript : nil
        let cachedRead = readTranscript?.sessionID == sessionID ? readTranscript : nil
        guard watchedCache != nil || cachedRead != nil else { return }

        let generationID: UUID
        let rows: [EngineTranscriptRow]
        let materializedSegments: [MaterializedTranscriptSegment]
        var watchedValid = false
        var readValid = false
        do {
            let session = try await readableSession(sessionID)
            watchedValid = watchedCache != nil
                && transcript?.sessionID == sessionID
                && transcript?.revision == watchedCache?.revision
            readValid = cachedRead != nil
                && readTranscript?.sessionID == sessionID
                && readTranscript?.revision == cachedRead?.revision
            guard watchedValid || readValid else { return }
            guard session.audioSource != nil else {
                throw EngineFailures.commandError(
                    .filesystem, "保存済み音声を使えないため、文字起こしを表示できません", stage: .finalization,
                    sessionID: sessionID, recoveryAction: .inspectSession
                )
            }
            switch try SavedTranscriptLoader.load(sessionURL: session.sessionURL) {
            case .unavailable:
                throw EngineFailures.commandError(
                    .processingFailure, "文字起こしを読み込めませんでした", stage: .finalization,
                    sessionID: sessionID, recoveryAction: .reprocess
                )
            case let .segments(savedGenerationID, segments):
                generationID = savedGenerationID
                rows = try EngineTranscriptProjection.rows(for: segments)
                materializedSegments = segments
            }
        } catch {
            reportTranscriptError(error, sessionID: sessionID)
            return
        }

        var updatedWatched: EngineTranscriptCache?
        if watchedValid, var cache = watchedCache {
            cache.generationID = generationID
            cache.rows = rows
            cache.materializedSegments = materializedSegments
            cache.revision = newRevision()
            cache.isLiveState = false
            cache.projection = nil
            cache.reportedTranscriptFailures = []
            transcript = cache
            updatedWatched = cache
        }
        if readValid, var cache = cachedRead {
            cache.generationID = generationID
            cache.rows = rows
            cache.materializedSegments = materializedSegments
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

    private func retireTranscriptSnapshots(sessionID: UUID) {
        if transcriptReadSnapshot?.sessionID == sessionID {
            transcriptReadSnapshot = nil
            transcriptReadNavigation = nil
        }
        if transcriptRowDetailsSnapshot?.sessionID == sessionID {
            transcriptRowDetailsSnapshot = nil
        }
        transcriptEpoch += 1
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

    private func durableGenerationID(for session: SavedSession) async throws -> UUID? {
        try await transcriptGenerationLookup(session)
    }

    private func retainsTranscriptRevision(_ revision: UInt64, sessionID: UUID) -> Bool {
        [transcript, readTranscript, transcriptReadSnapshot].contains {
            $0?.sessionID == sessionID && $0?.revision == revision
        }
    }

    private func staleRevision(sessionID: UUID) -> EngineCommandError {
        EngineFailures.commandError(
            .staleRevision, "文字起こしの revision が古くなっています。最初から読み直してください",
            stage: .finalization, sessionID: sessionID, recoveryAction: .retry
        )
    }

    private func validateGeneration(
        _ cachedGenerationID: UUID?, against durableGenerationID: UUID?, sessionID: UUID
    ) throws {
        guard cachedGenerationID == durableGenerationID else { throw staleRevision(sessionID: sessionID) }
    }

    /// The watched session uses its live view; all other sessions share one read cache.
    private func transcriptCache(
        for sessionID: UUID, asWatched: Bool = false
    ) async throws -> (cache: EngineTranscriptCache, session: SavedSession) {
        while true {
            let session = try await readableSession(sessionID)
            let liveOrPending = isLiveOrPending(sessionID)
            let revision = nextTranscriptRevision
            let epoch = transcriptEpoch
            let cache = try await makeTranscriptCache(
                for: sessionID, session: session, isLiveOrPending: liveOrPending, asWatched: asWatched
            )
            guard isLiveOrPending(sessionID) == liveOrPending,
                  nextTranscriptRevision == revision,
                  transcriptEpoch == epoch else {
                continue
            }
            if !asWatched {
                if sessionID == watchedSessionID { transcript = cache }
                else { readTranscript = cache }
            }
            nextTranscriptRevision = max(nextTranscriptRevision, cache.revision)
            return (cache, session)
        }
    }

    private func isLiveOrPending(_ sessionID: UUID) -> Bool {
        (recording.sessionID == sessionID || processingQueue.liveProjectionSessionIDs.contains(sessionID))
            && !finalPublishedSessionIDs.contains(sessionID)
    }

    private func makeTranscriptCache(
        for sessionID: UUID,
        session: SavedSession,
        isLiveOrPending: Bool,
        asWatched: Bool
    ) async throws -> EngineTranscriptCache {
        let isWatched = asWatched || sessionID == watchedSessionID
        let existingCache = isWatched
            ? (transcript?.sessionID == sessionID ? transcript : nil)
            : (readTranscript?.sessionID == sessionID ? readTranscript : nil)
        let durableGenerationID = try await durableGenerationID(for: session)
        let cacheRevision = nextTranscriptRevision + 1
        if isLiveOrPending {
            let generationID = durableGenerationID
            if let existingCache, existingCache.generationID == generationID, existingCache.isLiveState {
                return existingCache
            }
            return EngineTranscriptCache(
                sessionID: sessionID, generationID: generationID, revision: cacheRevision,
                rows: [], materializedSegments: [], isLiveState: true, projection: nil
            )
        }
        guard session.audioSource != nil else {
            throw EngineFailures.commandError(
                .filesystem, "保存済み音声を使えないため、文字起こしを表示できません", stage: .finalization,
                sessionID: sessionID, recoveryAction: .inspectSession
            )
        }
        if let existingCache, !existingCache.isLiveState, existingCache.generationID == durableGenerationID {
            return existingCache
        }
        let generationID: UUID?
        let rows: [EngineTranscriptRow]
        let materializedSegments: [MaterializedTranscriptSegment]
        do {
            let savedTranscript = try await Task.detached(executorPreference: BlockingIOExecutor.shared) {
                try SavedTranscriptLoader.load(sessionURL: session.sessionURL)
            }.value
            switch savedTranscript {
            case .unavailable:
                generationID = nil
                rows = []
                materializedSegments = []
            case let .segments(savedGenerationID, segments):
                generationID = savedGenerationID
                rows = try EngineTranscriptProjection.rows(for: segments)
                materializedSegments = segments
            }
        } catch {
            throw EngineFailures.commandError(
                from: error, fallback: .processingFailure, stage: .finalization, sessionID: sessionID,
                recoveryAction: .reprocess
            )
        }
        if let existingCache, existingCache.generationID == generationID,
           (!existingCache.isLiveState || !existingCache.rows.isEmpty) {
            return existingCache
        }
        return EngineTranscriptCache(
            sessionID: sessionID, generationID: generationID, revision: cacheRevision,
            rows: rows, materializedSegments: materializedSegments, isLiveState: false, projection: nil
        )
    }
}

extension EngineApplicationCore: EngineTranscriptHandling {
    func read(_ payload: EngineTranscriptReadPayload, context: EngineRequestContext) async throws -> EngineTranscriptPage {
        let sessionID = try EngineFailures.sessionID(payload.sessionID, stage: .finalization)
        if payload.revision == nil, payload.cursor != nil {
            throw EngineFailures.commandError(
                .invalidCursor, "cursor には revision が必要です", stage: .finalization, sessionID: sessionID
            )
        }

        while true {
            let (latestCache, session) = try await transcriptCache(for: sessionID)
            let freshReadState: (epoch: UInt64, isLiveOrPending: Bool)?
            if payload.revision == nil {
                freshReadState = (transcriptEpoch, isLiveOrPending(sessionID))
            } else {
                freshReadState = nil
            }
            let cache: EngineTranscriptCache
            let navigation: EnginePageNavigation
            let isContinuation = payload.cursor != nil
            if let revision = payload.revision {
                if let snapshot = transcriptReadSnapshot,
                   snapshot.sessionID == sessionID,
                   snapshot.revision == revision.value {
                    cache = snapshot
                    if isContinuation {
                        guard let retainedNavigation = transcriptReadNavigation else {
                            preconditionFailure("a retained transcript snapshot has navigation")
                        }
                        navigation = retainedNavigation
                    } else {
                        navigation = EnginePageNavigation(limit: payload.limit)
                    }
                } else if latestCache.revision == revision.value {
                    guard !isContinuation else {
                        throw EngineFailures.commandError(
                            .invalidCursor, "cursor に対応する文字起こし snapshot がありません",
                            stage: .finalization, sessionID: sessionID
                        )
                    }
                    cache = latestCache
                    navigation = EnginePageNavigation(limit: payload.limit)
                } else {
                    throw EngineFailures.commandError(
                        .staleRevision, "文字起こしの revision が古くなっています。最初から読み直してください",
                        stage: .finalization, sessionID: sessionID, recoveryAction: .retry
                    )
                }
            } else {
                cache = latestCache
                navigation = EnginePageNavigation(limit: payload.limit)
            }

            let selectedRevision = cache.revision
            let durableGenerationID = try await durableGenerationID(for: session)
            if let freshReadState {
                guard transcriptEpoch == freshReadState.epoch,
                      isLiveOrPending(sessionID) == freshReadState.isLiveOrPending else {
                    continue
                }
            } else {
                guard retainsTranscriptRevision(selectedRevision, sessionID: sessionID) else {
                    throw staleRevision(sessionID: sessionID)
                }
            }
            try validateGeneration(cache.generationID, against: durableGenerationID, sessionID: sessionID)
            if isContinuation, transcriptReadNavigation?.id != navigation.id {
                throw EngineFailures.commandError(
                    .invalidCursor, "cursor に対応する文字起こし snapshot がありません",
                    stage: .finalization, sessionID: sessionID
                )
            }

            let location = try navigation.location(cursor: payload.cursor, limit: payload.limit)
            let page = try EngineTranscriptProjection.page(
                of: cache.rows, from: location.start, limit: payload.limit
            )
            let cursors = navigation.cursors(
                for: location, end: location.start + page.count, total: cache.rows.count
            )
            let response = try EngineTranscriptPage(
                sessionID: payload.sessionID, revision: wireRevision(cache.revision), rows: Array(page),
                nextCursor: cursors.next, previousCursor: cursors.previous
            )

            // Commit the selected snapshot and navigation only after the page is valid.
            transcriptReadSnapshot = cache
            transcriptReadNavigation = navigation
            return response
        }
    }

    func rowDetails(
        _ payload: EngineTranscriptRowDetailsPayload,
        context: EngineRequestContext
    ) async throws -> EngineTranscriptRowDetailsPage {
        let sessionID = try EngineFailures.sessionID(payload.sessionID, stage: .finalization)
        let session = try await readableSession(sessionID)
        let revision = payload.revision.value
        if let snapshot = transcriptRowDetailsSnapshot,
           snapshot.sessionID == sessionID,
           snapshot.revision == revision,
           snapshot.rowID == payload.rowID {
            let durableGenerationID = try await durableGenerationID(for: session)
            guard transcriptRowDetailsSnapshot?.sessionID == sessionID,
                  transcriptRowDetailsSnapshot?.revision == revision,
                  transcriptRowDetailsSnapshot?.rowID == payload.rowID else {
                throw staleRevision(sessionID: sessionID)
            }
            try validateGeneration(
                snapshot.generationID, against: durableGenerationID, sessionID: sessionID
            )
            return try snapshot.page()
        }

        let cache: EngineTranscriptCache
        if let snapshot = transcriptReadSnapshot,
           snapshot.sessionID == sessionID,
           snapshot.revision == revision {
            cache = snapshot
        } else if let watched = transcript,
                  watched.sessionID == sessionID,
                  watched.revision == revision {
            cache = watched
        } else if let read = readTranscript,
                  read.sessionID == sessionID,
                  read.revision == revision {
            cache = read
        } else {
            throw staleRevision(sessionID: sessionID)
        }
        let durableGenerationID = try await durableGenerationID(for: session)
        guard retainsTranscriptRevision(cache.revision, sessionID: sessionID) else {
            throw staleRevision(sessionID: sessionID)
        }
        try validateGeneration(cache.generationID, against: durableGenerationID, sessionID: sessionID)

        guard cache.rows.contains(where: { $0.rowID == payload.rowID }) else {
            throw EngineFailures.commandError(
                .rowNotFound, "指定された文字起こし行が見つかりません",
                stage: .finalization, sessionID: sessionID, recoveryAction: .inspectSession
            )
        }
        guard let segment = cache.materializedSegments.first(where: { $0.segmentID == payload.rowID }) else {
            throw EngineFailures.commandError(
                .internalError, "文字起こし行の詳細に対応する materialized segment がありません",
                stage: .finalization, sessionID: sessionID, recoveryAction: .restart
            )
        }
        let snapshot = try EngineTranscriptRowDetailsSnapshot(
            sessionID: sessionID, generationID: cache.generationID, revision: revision, segment: segment
        )
        let page = try snapshot.page()
        transcriptRowDetailsSnapshot = snapshot
        return page
    }

    func watch(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineTranscriptPage {
        let sessionID = try EngineFailures.sessionID(payload.sessionID, stage: .finalization)
        let cacheResult = try await transcriptCache(for: sessionID, asWatched: true)
        let cache = cacheResult.cache
        let session = cacheResult.session
        let isLiveOrPending = isLiveOrPending(sessionID)
        let isFinal: Bool
        if isLiveOrPending {
            isFinal = false
        } else {
            switch session.processingStatus {
            case .complete, .classificationPending: isFinal = true
            case .notProcessed, .running, .paused, .failed, .corrupted: isFinal = false
            }
        }
        let tail = try EngineTranscriptProjection.tail(of: cache.rows, limit: Self.transcriptPageLimit)
        let page = try EngineTranscriptPage(
            sessionID: payload.sessionID, revision: wireRevision(cache.revision), rows: Array(tail),
            nextCursor: nil, previousCursor: nil
        )

        // Commit both cache and selection only after session validation and page construction succeeded.
        transcript = cache
        watchedSessionID = sessionID
        watchedSessionIsFinal = isFinal
        stateDidChange()
        return page
    }
}
