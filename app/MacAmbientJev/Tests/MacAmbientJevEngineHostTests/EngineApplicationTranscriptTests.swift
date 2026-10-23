import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

@testable import MacAmbientJevEngineHost

@MainActor
@Suite struct EngineApplicationTranscriptTests {
    @Test func watchedAndReadCachesRemainIndependentAndInvalidWatchIsTransactional() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionA = try await recordAndFinalize(in: h)
        let sessionB = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let core = h.app.core

        let watchedPage = try await core.watch(
            EngineSessionPayload(sessionID: sessionA), context: context
        )
        let readPayload = try EngineTranscriptReadPayload(
            sessionID: sessionB, revision: nil, cursor: nil, limit: 50
        )
        let readPage = try await core.read(readPayload, context: context)
        let repeatedRead = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionB, revision: readPage.revision, cursor: nil, limit: 50
            ),
            context: context
        )
        #expect(repeatedRead.revision == readPage.revision)
        #expect(core.readTranscript?.revision == readPage.revision.value)

        let updatedSegment = try materializedApplicationSegment(id: "manual-update-A", text: "updated watched session A")
        let sessionAUUID = try #require(UUID(uuidString: sessionA))
        core.transcriptDidUpdate(sessionID: sessionAUUID, segments: [updatedSegment])

        let updatedCache = try #require(core.transcript)
        #expect(updatedCache.sessionID == sessionAUUID)
        #expect(updatedCache.revision > watchedPage.revision.value)
        #expect(updatedCache.rows.map(\.rowID) == ["manual-update-A"])
        #expect(core.readTranscript?.sessionID == UUID(uuidString: sessionB))
        #expect(core.readTranscript?.revision == readPage.revision.value)

        try await waitOnMain(timeout: 10, "watched transcript change event") {
            ((try? h.outputs) ?? []).contains { output in
                guard case let .rows(payload) = output.event else { return false }
                return payload.sessionID == sessionA && payload.kind == .changes
                    && payload.rows.contains { $0.rowID == "manual-update-A" && $0.text == "updated watched session A" }
            }
        }

        let cacheBeforeInvalidWatch = try #require(core.transcript)
        let watchedSessionBeforeInvalidWatch = core.watchedSessionID
        let nonexistentID = UUID().uuidString.lowercased()
        do {
            _ = try await core.watch(EngineSessionPayload(sessionID: nonexistentID), context: context)
            Issue.record("watching a nonexistent session must fail")
        } catch let error as EngineCommandError {
            #expect(error.code == .sessionNotFound)
        } catch {
            Issue.record("expected session_not_found, got \(error)")
        }

        let cacheAfterInvalidWatch = try #require(core.transcript)
        #expect(core.watchedSessionID == watchedSessionBeforeInvalidWatch)
        #expect(cacheAfterInvalidWatch.sessionID == cacheBeforeInvalidWatch.sessionID)
        #expect(cacheAfterInvalidWatch.revision == cacheBeforeInvalidWatch.revision)
        #expect(cacheAfterInvalidWatch.rows == cacheBeforeInvalidWatch.rows)
        #expect(core.readTranscript?.revision == readPage.revision.value)

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func composedProjectionUpdatesOnlyChangedRowsAndKeepsReadSnapshotFrozen() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let core = h.app.core
        _ = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: context)
        let sessionUUID = try #require(UUID(uuidString: sessionID))

        var segments = try (0..<1_000).map { index in
            try materializedApplicationSegment(id: "history-\(index)", text: "history row \(index)")
        }
        let historyRows = try EngineTranscriptProjection.rows(for: segments)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        let historyCache = try #require(core.transcript)
        let projection = try #require(historyCache.projection)
        #expect(historyCache.rows == historyRows)
        #expect(projection.totalProjectedSegments == 1_000)
        #expect(projection.totalDiffedRows == 1_000)

        let projectedBeforeAppend = projection.totalProjectedSegments
        let diffedBeforeAppend = projection.totalDiffedRows
        segments.append(try materializedApplicationSegment(id: "history-1000", text: "appended row"))
        let appendedRows = try EngineTranscriptProjection.rows(for: segments)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        let appendedCache = try #require(core.transcript)
        #expect(appendedCache.rows == appendedRows)
        #expect(projection.totalProjectedSegments - projectedBeforeAppend == 1)
        #expect(projection.totalDiffedRows - diffedBeforeAppend == 1)

        core.readTranscript = appendedCache
        let firstPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 100),
            context: context
        )
        let frozenSnapshot = try #require(core.transcriptReadSnapshot)
        #expect(firstPage.revision.value == appendedCache.revision)
        #expect(frozenSnapshot.rows == appendedRows)
        #expect(core.readTranscript?.projection === projection)

        let stableRevision = appendedCache.revision
        let projectedBeforeNoOp = projection.totalProjectedSegments
        let diffedBeforeNoOp = projection.totalDiffedRows
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        #expect(core.transcript?.revision == stableRevision)
        #expect(core.readTranscript?.revision == stableRevision)
        #expect(projection.totalProjectedSegments == projectedBeforeNoOp)
        #expect(projection.totalDiffedRows == diffedBeforeNoOp)

        segments[500] = try materializedApplicationSegment(id: "history-500", text: "edited late history row")
        segments.remove(at: 4)
        let finalRows = try EngineTranscriptProjection.rows(for: segments)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        let editedWatchedCache = try #require(core.transcript)
        let editedReadCache = try #require(core.readTranscript)
        #expect(editedWatchedCache.rows == finalRows)
        #expect(editedReadCache.rows == finalRows)
        #expect(editedWatchedCache.revision > stableRevision)
        #expect(editedReadCache.revision > stableRevision)
        #expect(editedWatchedCache.projection === projection)
        #expect(editedReadCache.projection === projection)
        #expect(projection.totalProjectedSegments == projectedBeforeNoOp + 1)
        #expect(projection.totalDiffedRows == diffedBeforeNoOp + 1)
        #expect(core.transcriptReadSnapshot?.revision == frozenSnapshot.revision)
        #expect(core.transcriptReadSnapshot?.rows == frozenSnapshot.rows)
        #expect(core.transcriptReadSnapshot?.rows == appendedRows)
        #expect(firstPage.rows == Array(appendedRows.prefix(100)))

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func oversizedRowInLargeBatchIsRejectedRetainedAndRecovered() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let core = h.app.core
        _ = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: context)
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        let originalCache = try #require(core.transcript)
        let originalOversizedText = String(repeating: "\u{0001}", count: 60_000)
        let changedOversizedText = String(repeating: "\u{0002}", count: 60_000)
        #expect(originalOversizedText.utf8.count == changedOversizedText.utf8.count)

        var segments = try (0..<205).map { index in
            try materializedApplicationSegment(id: "batch-row-\(index)", text: "batch text \(index)")
        }
        segments[137] = try materializedApplicationSegment(id: "batch-row-137", text: originalOversizedText)
        #expect(segments.count > EngineApplicationCore.transcriptPageLimit)
        for _ in 0..<30 {
            core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        }

        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)
        #expect(core.failures.filter { $0.code == .rowTooLarge && $0.sessionID == sessionID }.count == 1)
        #expect(core.pendingFailureEvents.count <= 1)
        #expect(core.inFlightFailureEvent == nil || core.inFlightFailureEvent?.code == .rowTooLarge)

        try await waitOnMain(timeout: 10, "oversized transcript failure worker") {
            core.failureEventTask == nil && core.pendingFailureEvents.isEmpty && core.inFlightFailureEvent == nil
        }
        await h.transport.drain()
        let outputsAfterFailure = try h.outputs
        let firstRowTooLargeEvents = outputsAfterFailure.compactMap { output -> EngineFailure? in
            if case let .error(failure) = output.event, failure.code == .rowTooLarge { return failure }
            return nil
        }
        #expect(firstRowTooLargeEvents.count == 1)
        let firstFailure = try #require(firstRowTooLargeEvents.first)

        // Once delivered, identical rejected snapshots must not report the same oversized row again.
        for _ in 0..<5 {
            core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        }
        segments[10] = try materializedApplicationSegment(id: "batch-row-10", text: "changed unrelated row")
        for _ in 0..<5 {
            core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        }
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)
        try await waitOnMain(timeout: 10, "deduplicated oversized transcript failure worker") {
            core.failureEventTask == nil && core.pendingFailureEvents.isEmpty && core.inFlightFailureEvent == nil
        }
        await h.transport.drain()
        let outputsAfterUnrelatedChange = try h.outputs
        let rowTooLargeEventsAfterUnrelatedChange = outputsAfterUnrelatedChange.compactMap { output -> EngineFailure? in
            if case let .error(failure) = output.event, failure.code == .rowTooLarge { return failure }
            return nil
        }
        #expect(rowTooLargeEventsAfterUnrelatedChange == [firstFailure])
        #expect(core.failures.filter { $0.code == .rowTooLarge && $0.sessionID == sessionID } == [firstFailure])

        segments[137] = try materializedApplicationSegment(id: "batch-row-137", text: changedOversizedText)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)
        try await waitOnMain(timeout: 10, "changed oversized transcript failure worker") {
            core.failureEventTask == nil && core.pendingFailureEvents.isEmpty && core.inFlightFailureEvent == nil
        }
        await h.transport.drain()
        let outputsAfterChangedOversizedRow = try h.outputs
        let rowTooLargeEventsAfterContentChange = outputsAfterChangedOversizedRow.compactMap { output -> EngineFailure? in
            if case let .error(failure) = output.event, failure.code == .rowTooLarge { return failure }
            return nil
        }
        #expect(rowTooLargeEventsAfterContentChange.count == 2)
        let secondFailure = try #require(rowTooLargeEventsAfterContentChange.last)
        #expect(secondFailure.message == firstFailure.message)
        #expect(core.failures.filter { $0.code == .rowTooLarge && $0.sessionID == sessionID } == [firstFailure, secondFailure])

        segments[137] = try materializedApplicationSegment(id: "batch-row-137", text: "repaired batch text")
        let expectedRows = try EngineTranscriptProjection.rows(for: segments)
        let projection = try #require(core.transcript?.projection)
        let retainedChanges = try projection.update(segments).changes
        let expectedChanges = EngineTranscriptProjection.changes(from: originalCache.rows, to: expectedRows)
        #expect(retainedChanges.count > EngineApplicationCore.transcriptPageLimit)
        #expect(retainedChanges.upserts == expectedChanges.upserts)
        #expect(retainedChanges.removedRowIDs == expectedChanges.removedRowIDs)
        #expect(retainedChanges.upserts.map(\.rowID) == segments.map(\.segmentID))

        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        let repairedCache = try #require(core.transcript)
        #expect(repairedCache.revision > originalCache.revision)
        #expect(repairedCache.rows == expectedRows)
        #expect(repairedCache.rows.count == segments.count)
        #expect(repairedCache.lastReportedOversizedRow == nil)
        try await waitOnMain(timeout: 10, "large transcript reload event") {
            ((try? h.outputs) ?? []).contains { output in
                guard case let .rows(payload) = output.event else { return false }
                return payload.sessionID == sessionID && payload.revision.value == repairedCache.revision
                    && payload.kind == .reloadRequired
            }
        }
        await h.transport.drain()
        let outputsAfterRepair = try h.outputs
        let repairReloadEvents = outputsAfterRepair.compactMap { output -> EngineRowsPayload? in
            if case let .rows(payload) = output.event, payload.kind == .reloadRequired { return payload }
            return nil
        }
        #expect(repairReloadEvents.contains {
            $0.sessionID == sessionID && $0.revision.value == repairedCache.revision
                && $0.rows.isEmpty && $0.removedRowIDs.isEmpty
        })
        let rowTooLargeEventsAfterRepair = outputsAfterRepair.compactMap { output -> EngineFailure? in
            if case let .error(failure) = output.event, failure.code == .rowTooLarge { return failure }
            return nil
        }
        #expect(rowTooLargeEventsAfterRepair == [firstFailure, secondFailure])
        #expect(core.failures.filter { $0.code == .rowTooLarge && $0.sessionID == sessionID } == [firstFailure, secondFailure])

        // A repaired row clears the marker, so the same old content can be reported again.
        let repairedRevision = repairedCache.revision
        segments[137] = try materializedApplicationSegment(id: "batch-row-137", text: originalOversizedText)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        #expect(core.transcript?.revision == repairedRevision)
        #expect(core.transcript?.rows == expectedRows)
        try await waitOnMain(timeout: 10, "repeated oversized transcript failure worker") {
            core.failureEventTask == nil && core.pendingFailureEvents.isEmpty && core.inFlightFailureEvent == nil
        }
        await h.transport.drain()
        let finalOutputs = try h.outputs
        let finalRowTooLargeEvents = finalOutputs.compactMap { output -> EngineFailure? in
            if case let .error(failure) = output.event, failure.code == .rowTooLarge { return failure }
            return nil
        }
        #expect(finalRowTooLargeEvents.count == 3)
        #expect(finalRowTooLargeEvents.map(\.message) == [firstFailure.message, secondFailure.message, firstFailure.message])
        #expect(core.failures.filter { $0.code == .rowTooLarge && $0.sessionID == sessionID } == [firstFailure, secondFailure, firstFailure])
        #expect(core.pendingFailureEvents.isEmpty)
        #expect(core.failureEventTask == nil)

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func finalPublicationAdvancesRevisionAndRequiresReloadEvenForIdenticalRows() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let core = h.app.core
        let watchedPage = try await core.watch(
            EngineSessionPayload(sessionID: sessionID), context: context
        )
        let establishedSnapshot = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 50),
            context: context
        )
        #expect(establishedSnapshot.revision == watchedPage.revision)
        let previousRevision = establishedSnapshot.revision

        core.transcriptDidPublish(sessionID: try #require(UUID(uuidString: sessionID)))

        let publishedCache = try #require(core.transcript)
        #expect(publishedCache.revision > previousRevision.value)
        #expect(publishedCache.rows == watchedPage.rows)

        do {
            _ = try await core.read(
                EngineTranscriptReadPayload(
                    sessionID: sessionID, revision: previousRevision, cursor: nil, limit: 50
                ),
                context: context
            )
            Issue.record("the pre-publication revision must be stale")
        } catch let error as EngineCommandError {
            #expect(error.code == .staleRevision)
        } catch {
            Issue.record("expected stale_revision, got \(error)")
        }

        try await waitOnMain(timeout: 10, "final transcript reload_required event") {
            ((try? h.outputs) ?? []).contains { output in
                guard case let .rows(payload) = output.event else { return false }
                return payload.sessionID == sessionID && payload.kind == .reloadRequired
                    && payload.revision.value > previousRevision.value
            }
        }

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func pagedReadKeepsImmutableSnapshotAcrossLiveUpdatesAndWatchChanges() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let otherSessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let core = h.app.core
        _ = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: context)
        let sessionUUID = try #require(UUID(uuidString: sessionID))

        let originalSegments = try (0..<205).map { index in
            try materializedApplicationSegment(
                id: "snapshot-row-\(index)", text: "original transcript text \(index)"
            )
        }
        let originalRows = try EngineTranscriptProjection.rows(for: originalSegments)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: originalSegments)
        #expect(core.transcript?.rows == originalRows)

        let firstPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 100),
            context: context
        )
        #expect(firstPage.rows == Array(originalRows.prefix(100)))
        #expect(firstPage.nextCursor == "100")
        let originalRevision = firstPage.revision
        let originalCursor = try #require(firstPage.nextCursor)

        var updatedSegments = originalSegments
        updatedSegments[2] = try materializedApplicationSegment(
            id: "snapshot-row-2", text: "edited transcript text 2"
        )
        updatedSegments.remove(at: 5)
        updatedSegments.append(try materializedApplicationSegment(
            id: "snapshot-row-205", text: "appended transcript text 205"
        ))
        let updatedRows = try EngineTranscriptProjection.rows(for: updatedSegments)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: updatedSegments)
        let updatedCache = try #require(core.transcript)
        #expect(updatedCache.revision > originalRevision.value)
        #expect(updatedCache.rows == updatedRows)

        let secondOriginalPage = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: originalRevision, cursor: originalCursor, limit: 100
            ),
            context: context
        )
        #expect(secondOriginalPage.revision == originalRevision)
        #expect(secondOriginalPage.rows == Array(originalRows[100..<200]))
        #expect(secondOriginalPage.nextCursor == "200")
        let finalOriginalPage = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: originalRevision,
                cursor: "200", limit: 100
            ),
            context: context
        )
        #expect(finalOriginalPage.revision == originalRevision)
        #expect(finalOriginalPage.rows == Array(originalRows[200..<205]))
        #expect(finalOriginalPage.nextCursor == nil)

        let refreshedPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 100),
            context: context
        )
        #expect(refreshedPage.revision.value == updatedCache.revision)
        #expect(refreshedPage.revision != originalRevision)
        #expect(refreshedPage.rows == Array(updatedRows.prefix(100)))
        #expect(refreshedPage.nextCursor == "100")

        do {
            _ = try await core.read(
                EngineTranscriptReadPayload(
                    sessionID: sessionID, revision: originalRevision, cursor: originalCursor, limit: 100
                ),
                context: context
            )
            Issue.record("the replaced snapshot revision must be stale")
        } catch let error as EngineCommandError {
            #expect(error.code == .staleRevision)
        } catch {
            Issue.record("expected stale_revision, got \(error)")
        }

        _ = try await core.watch(EngineSessionPayload(sessionID: otherSessionID), context: context)
        let afterWatchChange = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: refreshedPage.revision,
                cursor: "100", limit: 100
            ),
            context: context
        )
        #expect(afterWatchChange.revision == refreshedPage.revision)
        #expect(afterWatchChange.rows == Array(updatedRows[100..<200]))
        #expect(afterWatchChange.nextCursor == "200")

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    private func prepared(_ root: URL) async throws -> ApplicationHarness {
        let h = ApplicationHarness(root: root)
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        try await h.call("models.prepare")
        return h
    }

    private func recordAndFinalize(in h: ApplicationHarness) async throws -> String {
        guard case let .recordingStart(started) = try await h.call(
            "recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}"
        ) else {
            throw TestTimeout(description: "recording.start did not return a session")
        }
        let capture = try #require(h.capture.session)
        try await capture.appendSpeech(seconds: 2)
        try await h.call("recording.stop", payload: "{\"session_id\":\"\(started.sessionID)\"}")
        try await waitForFinalized(started.sessionID, in: h)
        return started.sessionID
    }

    private func waitForFinalized(_ sessionID: String, in h: ApplicationHarness) async throws {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if try await h.sessions().contains(where: { $0.sessionID == sessionID && $0.status == .finalized }) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TestTimeout(description: "session \(sessionID) did not finalize")
    }

    private func requestContext(for h: ApplicationHarness) throws -> EngineRequestContext {
        EngineRequestContext(
            requestID: try EngineID(10_000), events: EngineEventEmitter(transport: h.transport)
        )
    }
}

private func materializedApplicationSegment(id: String, text: String) throws -> MaterializedTranscriptSegment {
    let source = try SegmentTextReference(
        segmentationRunID: "transcript-test-run", segmentID: id, asrRunID: "transcript-test-asr", asrEventSeq: 1
    )
    let projection = try TranscriptTextProjector().project(sourceText: text, fillerRanges: [])
    return try MaterializedTranscriptSegment(
        segmentID: id, source: source, startMilliseconds: 0, endMilliseconds: 100,
        text: text, textProjection: projection, speakers: [], clauseState: .classified,
        clauseSlices: [], isDiarized: false
    )
}
