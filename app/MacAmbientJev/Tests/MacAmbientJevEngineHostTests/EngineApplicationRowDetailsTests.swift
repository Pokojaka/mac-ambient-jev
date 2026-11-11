import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
import MacAmbientJevTestSupport

@MainActor
@Suite(.timeLimit(.minutes(10))) struct EngineApplicationRowDetailsTests {
    @Test func persistedDetailsUseControllerCodecAndMatchSavedMaterialization() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)

        guard case let .transcriptWatch(watched) = try await h.call(
            "transcript.watch", payload: try json(EngineSessionPayload(sessionID: sessionID))
        ) else { throw TestTimeout(description: "transcript.watch returned the wrong result") }
        guard case let .transcriptRead(read) = try await h.call(
            "transcript.read",
            payload: try json(EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 200))
        ) else { throw TestTimeout(description: "transcript.read returned the wrong result") }
        #expect(read.revision == watched.revision)
        let expectedRow = try #require(read.rows.first)
        let core = h.app.core
        let uuid = try #require(UUID(uuidString: sessionID))
        let savedSession = try core.readableSession(uuid)
        let audioSource = try #require(savedSession.audioSource)
        guard case let .segments(savedSegments) = try SavedTranscriptLoader.load(
            sessionURL: savedSession.sessionURL, audioSource: audioSource
        ) else { throw TestTimeout(description: "saved transcript was unavailable") }
        let cached = try #require(core.transcriptReadSnapshot)
        #expect(cached.materializedSegments == savedSegments)
        let segment = try #require(savedSegments.first { $0.segmentID == expectedRow.rowID })
        let liveRow = try #require(LiveTranscriptProjection().rows(for: [segment]).first)
        let payload = try detailsPayload(
            sessionID: sessionID, revision: read.revision, rowID: expectedRow.rowID
        )
        let detail = try await controllerRowDetails(h, payload)

        #expect(detail.sessionID == sessionID)
        #expect(detail.revision == read.revision)
        #expect(detail.rowID == expectedRow.rowID)
        #expect(detail.clauseState.rawValue == liveRow.clauseState.rawValue)
        #expect(detail.clauseStateText == liveRow.clauseState.rowDetailsDescription)
        #expect(liveRow.text == segment.displayText)
        #expect(expectedRow.text == liveRow.text)
        #expect(expectedRow.startMS == liveRow.startMilliseconds)
        #expect(expectedRow.endMS == liveRow.endMilliseconds)
        #expect(expectedRow.clauseState == EngineClauseState(rawValue: liveRow.clauseState.rawValue))

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func eventMaterializationPreservesStatesOrderAndBlankVisibility() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let core = h.app.core
        _ = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: requestContext(for: h))

        let segments = try materializedClauseStateRows()
        let uuid = try #require(UUID(uuidString: sessionID))
        core.transcriptDidUpdate(sessionID: uuid, segments: segments)
        let cache = try #require(core.transcript)
        let expectedRows = try EngineTranscriptProjection.rows(for: segments)
        #expect(cache.rows == expectedRows)
        #expect(cache.materializedSegments == segments)
        try await waitForRowsEvent(in: h, sessionID: sessionID, revision: cache.revision, kind: .changes)

        let visibleSegments = segments.filter { $0.hasRecognizedText && !$0.displayText.isEmpty }
        let liveRows = try LiveTranscriptProjection().rows(for: segments)
        #expect(liveRows.map(\.segmentID) == [
            "state-boundary-pending", "state-awaiting", "state-priority", "state-classified"
        ])
        #expect(segments.last?.text == "")
        #expect(cache.rows.count == visibleSegments.count)

        let expectedStates: [(String, EngineClauseState, String)] = [
            ("state-boundary-pending", .boundaryPending, "発話文: 境界判定を保留中"),
            ("state-awaiting", .awaitingNextSegment, "発話文: 続き待ち"),
            ("state-priority", .priorityPending, "発話文: 優先度判定を待っています"),
            ("state-classified", .classified, "発話文: 判定済み")
        ]
        for (rowID, state, text) in expectedStates {
            let segment = try #require(segments.first { $0.segmentID == rowID })
            let live = try #require(liveRows.first { $0.segmentID == rowID })
            let page = try await core.rowDetails(
                detailsPayload(sessionID: sessionID, revision: try EngineID(cache.revision), rowID: rowID),
                context: requestContext(for: h)
            )
            #expect(page.rowID == rowID)
            #expect(page.clauseState == state)
            #expect(page.clauseStateText == text)
            #expect(live.text == segment.displayText)
            #expect(live.clauseState.rawValue == page.clauseState.rawValue)
        }
        let blank = try #require(segments.last)
        #expect(!cache.rows.contains { $0.rowID == blank.segmentID })
        try await expectCommandError(.rowNotFound) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionID, revision: try EngineID(cache.revision), rowID: blank.segmentID),
                context: requestContext(for: h)
            )
        }
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func revisionAndRowErrorsHaveDeterministicPriority() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let core = h.app.core
        _ = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: requestContext(for: h))
        let segments = try materializedClauseStateRows()
        let uuid = try #require(UUID(uuidString: sessionID))
        core.transcriptDidUpdate(sessionID: uuid, segments: segments)
        let cache = try #require(core.transcript)
        let revision = try EngineID(cache.revision)

        let nonexistentSession = UUID().uuidString.lowercased()
        try await expectCommandError(.sessionNotFound) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: nonexistentSession, revision: revision, rowID: "missing"),
                context: requestContext(for: h)
            )
        }
        let oldRevision = try EngineID(max(1, cache.revision - 1))
        try await expectCommandError(.staleRevision) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionID, revision: oldRevision, rowID: "missing"),
                context: requestContext(for: h)
            )
        }
        try await expectCommandError(.rowNotFound) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionID, revision: revision, rowID: "missing"),
                context: requestContext(for: h)
            )
        }
        #expect(segments.contains { $0.segmentID == "state-blank" })
        #expect(!cache.rows.contains { $0.rowID == "state-blank" })
        try await expectCommandError(.rowNotFound) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionID, revision: revision, rowID: "state-blank"),
                context: requestContext(for: h)
            )
        }
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func retainedReadSnapshotMaterializesDetailsAfterLiveReplacement() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let core = h.app.core
        _ = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: requestContext(for: h))
        let uuid = try #require(UUID(uuidString: sessionID))
        let oldRowA = try explicitSegment(
            id: "read-snapshot-A", start: 0, end: 100, text: "古い一行目",
            clauseState: .boundaryPending, clauseSlices: []
        )
        let oldRowB = try explicitSegment(
            id: "read-snapshot-B", start: 100, end: 200, text: "古い二行目",
            clauseState: .awaitingNextSegment, clauseSlices: []
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [oldRowA, oldRowB])
        let cacheR = try #require(core.transcript)
        let revisionR = try EngineID(cacheR.revision)
        let oldRead = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 1),
            context: requestContext(for: h)
        )
        let readSnapshotR = try #require(core.transcriptReadSnapshot)
        #expect(oldRead.revision == revisionR)
        #expect(oldRead.rows.map(\.rowID) == [oldRowA.segmentID])
        #expect(oldRead.nextCursor != nil)
        #expect(readSnapshotR.materializedSegments == [oldRowA, oldRowB])

        let newRowA = try explicitSegment(
            id: oldRowA.segmentID, start: oldRowA.startMilliseconds, end: oldRowA.endMilliseconds,
            text: oldRowA.text, clauseState: .classified, clauseSlices: []
        )
        let newRowB = try explicitSegment(
            id: oldRowB.segmentID, start: oldRowB.startMilliseconds, end: oldRowB.endMilliseconds,
            text: oldRowB.text, clauseState: .classified, clauseSlices: []
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [newRowA, newRowB])
        let cacheR2 = try #require(core.transcript)
        let revisionR2 = try EngineID(cacheR2.revision)
        #expect(revisionR2.value > revisionR.value)

        let oldDetail = try await core.rowDetails(
            detailsPayload(sessionID: sessionID, revision: revisionR, rowID: oldRowA.segmentID),
            context: requestContext(for: h)
        )
        #expect(oldDetail.revision == revisionR)
        #expect(oldDetail.clauseState == .boundaryPending)

        let oldReadContinuation = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: revisionR, cursor: try #require(oldRead.nextCursor), limit: 1
            ), context: requestContext(for: h)
        )
        #expect(oldReadContinuation.revision == oldRead.revision)
        #expect(oldReadContinuation.rows.map(\.rowID) == [oldRowB.segmentID])
        #expect(oldReadContinuation.rows.first?.text == "古い二行目")
        #expect(core.transcriptReadSnapshot?.revision == revisionR.value)

        let otherOldDetail = try await core.rowDetails(
            detailsPayload(sessionID: sessionID, revision: revisionR, rowID: oldRowB.segmentID),
            context: requestContext(for: h)
        )
        #expect(otherOldDetail.rowID == oldRowB.segmentID)
        #expect(otherOldDetail.clauseState == .awaitingNextSegment)
        let freshRead = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 1),
            context: requestContext(for: h)
        )
        #expect(freshRead.revision == revisionR2)
        let newDetail = try await core.rowDetails(
            detailsPayload(sessionID: sessionID, revision: freshRead.revision, rowID: newRowA.segmentID),
            context: requestContext(for: h)
        )
        #expect(newDetail.revision == revisionR2)
        #expect(newDetail.clauseState == .classified)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func finalPublicationInvalidatesDetailsEvenForSameRows() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let core = h.app.core
        let watched = try await core.watch(
            EngineSessionPayload(sessionID: sessionID), context: requestContext(for: h)
        )
        let uuid = try #require(UUID(uuidString: sessionID))
        let savedSession = try core.readableSession(uuid)
        let audioSource = try #require(savedSession.audioSource)
        guard case let .segments(savedSegments) = try SavedTranscriptLoader.load(
            sessionURL: savedSession.sessionURL, audioSource: audioSource
        ) else { throw TestTimeout(description: "saved transcript was unavailable") }
        let saved = try #require(savedSegments.first)
        let savedRow = try #require(watched.rows.first)
        let liveSegment = try explicitSegment(
            id: saved.segmentID, start: saved.startMilliseconds, end: saved.endMilliseconds,
            text: saved.text, clauseState: saved.clauseState, clauseSlices: saved.clauseSlices
        )
        #expect(try EngineTranscriptProjection.rows(for: [liveSegment]) == [savedRow])
        core.transcriptDidUpdate(sessionID: uuid, segments: [liveSegment])
        let beforePublication = try #require(core.transcript)
        let oldRevision = try EngineID(beforePublication.revision)
        _ = try await core.rowDetails(
            detailsPayload(sessionID: sessionID, revision: oldRevision, rowID: saved.segmentID),
            context: requestContext(for: h)
        )
        #expect(try EngineTranscriptProjection.rows(for: beforePublication.materializedSegments) == [savedRow])

        core.transcriptDidPublish(sessionID: uuid)
        let afterPublication = try #require(core.transcript)
        #expect(afterPublication.rows == beforePublication.rows)
        #expect(afterPublication.revision > beforePublication.revision)
        try await waitForRowsEvent(
            in: h, sessionID: sessionID, revision: afterPublication.revision, kind: .reloadRequired
        )
        try await expectCommandError(.staleRevision) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionID, revision: oldRevision, rowID: saved.segmentID),
                context: requestContext(for: h)
            )
        }
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func rowlessUpdatesDoNotAdvanceRevisionOrEmitRows() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let core = h.app.core
        let uuid = try #require(UUID(uuidString: sessionID))
        try await populateWatchedAndReadCaches(h, sessionID: sessionID)

        let visible = try rowDetailsVisibleSegment()
        #expect(try EngineTranscriptProjection.rows(for: [visible]).count == 1)
        core.transcriptDidUpdate(sessionID: uuid, segments: [visible])
        try await controllerRequestBarrier(h)
        let watchedCache = try #require(core.transcript)
        let readCache = try #require(core.readTranscript)
        let watchedRevision = watchedCache.revision
        let readRevision = readCache.revision
        let nextRevision = core.nextTranscriptRevision
        let rowsBaseline = try rowsPayloads(in: h, sessionID: sessionID)

        let empty = try explicitSegment(
            id: "rowless-empty", start: 200, end: 300, text: "",
            clauseState: nil, clauseSlices: []
        )
        let whitespace = try explicitSegment(
            id: "rowless-whitespace", start: 300, end: 400, text: " \n\t",
            clauseState: nil, clauseSlices: []
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [visible, empty, whitespace])
        try await controllerRequestBarrier(h)
        #expect(core.transcript?.revision == watchedRevision)
        #expect(core.readTranscript?.revision == readRevision)
        #expect(core.nextTranscriptRevision == nextRevision)
        let rowsAfterAppend = try rowsPayloads(in: h, sessionID: sessionID)
        #expect(rowsAfterAppend == rowsBaseline)

        let modifiedEmpty = try explicitSegment(
            id: empty.segmentID, start: 210, end: 310, text: "  ",
            clauseState: nil, clauseSlices: []
        )
        let modifiedWhitespace = try explicitSegment(
            id: whitespace.segmentID, start: 310, end: 410, text: "\n \t ",
            clauseState: nil, clauseSlices: []
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [visible, modifiedEmpty, modifiedWhitespace])
        try await controllerRequestBarrier(h)
        #expect(core.transcript?.revision == watchedRevision)
        #expect(core.readTranscript?.revision == readRevision)
        #expect(core.nextTranscriptRevision == nextRevision)
        let rowsAfterModify = try rowsPayloads(in: h, sessionID: sessionID)
        #expect(rowsAfterModify == rowsBaseline)

        core.transcriptDidUpdate(sessionID: uuid, segments: [visible])
        try await controllerRequestBarrier(h)
        #expect(core.transcript?.revision == watchedRevision)
        #expect(core.readTranscript?.revision == readRevision)
        #expect(core.nextTranscriptRevision == nextRevision)
        let rowsAfterNoChange = try rowsPayloads(in: h, sessionID: sessionID)
        #expect(rowsAfterNoChange == rowsBaseline)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func staleDetailsRequestDoesNotLoadTranscriptOrMutateCaches() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let watchedSessionID = try await recordAndFinalize(in: h)
        let readSessionID = try await recordAndFinalize(in: h)
        let corruptTargetID = try await recordAndFinalize(in: h)
        let validTargetID = try await recordAndFinalize(in: h)
        let core = h.app.core

        let catalog = try await h.sessions()
        for sessionID in [watchedSessionID, readSessionID, corruptTargetID, validTargetID] {
            #expect(catalog.contains { $0.sessionID == sessionID && $0.status == .finalized })
        }
        let corruptUUID = try #require(UUID(uuidString: corruptTargetID))
        let corruptSession = try core.readableSession(corruptUUID)
        try Data("{broken\n".utf8).write(to: SessionLayout(sessionURL: corruptSession.sessionURL).eventsURL)

        guard case .transcriptWatch = try await h.call(
            "transcript.watch", payload: try json(EngineSessionPayload(sessionID: watchedSessionID))
        ) else { throw TestTimeout(description: "transcript.watch returned the wrong result") }
        guard case .transcriptRead = try await h.call(
            "transcript.read",
            payload: try json(EngineTranscriptReadPayload(
                sessionID: readSessionID, revision: nil, cursor: nil, limit: 1
            ))
        ) else { throw TestTimeout(description: "transcript.read returned the wrong result") }
        let watchedUUID = try #require(UUID(uuidString: watchedSessionID))
        let detailsSeed = try rowDetailsVisibleSegment()
        core.transcriptDidUpdate(sessionID: watchedUUID, segments: [detailsSeed])
        try await controllerRequestBarrier(h)
        let watchedRow = try #require(core.transcript?.rows.first)
        let detailsRevision = try EngineID(try #require(core.transcript?.revision))
        _ = try await controllerRowDetails(
            h, detailsPayload(sessionID: watchedSessionID, revision: detailsRevision, rowID: watchedRow.rowID)
        )

        let watchedCacheBefore = try #require(core.transcript)
        let readCacheBefore = try #require(core.readTranscript)
        let watchedProjectionBefore = watchedCacheBefore.projection
        let readSnapshotBefore = try #require(core.transcriptReadSnapshot)
        let detailsSnapshotBefore = try #require(core.transcriptRowDetailsSnapshot)
        let readNavigationBefore = try #require(core.transcriptReadNavigation)
        let nextRevisionBefore = core.nextTranscriptRevision
        let watchedSelectionBefore = core.watchedSessionID
        #expect(watchedCacheBefore.sessionID == UUID(uuidString: watchedSessionID))
        #expect(readCacheBefore.sessionID == UUID(uuidString: readSessionID))
        #expect(readSnapshotBefore.sessionID == UUID(uuidString: readSessionID))
        #expect(detailsSnapshotBefore.sessionID == UUID(uuidString: watchedSessionID))
        #expect(core.transcript?.sessionID != corruptUUID)
        #expect(core.readTranscript?.sessionID != corruptUUID)
        #expect(core.transcript?.sessionID != UUID(uuidString: validTargetID))
        #expect(core.readTranscript?.sessionID != UUID(uuidString: validTargetID))

        let staleRevision = try EngineID(nextRevisionBefore + 100)
        let corruptError = try await h.failureCode(
            of: "transcript.row_details",
            payload: try json(detailsPayload(
                sessionID: corruptTargetID, revision: staleRevision, rowID: "missing"))
        )
        #expect(corruptError == .staleRevision)
        let validError = try await h.failureCode(
            of: "transcript.row_details",
            payload: try json(detailsPayload(
                sessionID: validTargetID, revision: staleRevision, rowID: "missing"))
        )
        #expect(validError == .staleRevision)

        #expect(core.nextTranscriptRevision == nextRevisionBefore)
        #expect(core.watchedSessionID == watchedSelectionBefore)
        #expect(core.transcript?.sessionID == watchedCacheBefore.sessionID)
        #expect(core.transcript?.revision == watchedCacheBefore.revision)
        #expect(core.transcript?.rows == watchedCacheBefore.rows)
        #expect(core.transcript?.materializedSegments == watchedCacheBefore.materializedSegments)
        #expect(core.transcript?.isLiveState == watchedCacheBefore.isLiveState)
        #expect((core.transcript?.projection == nil) == (watchedCacheBefore.projection == nil))
        if let watchedProjectionBefore {
            #expect(core.transcript?.projection === watchedProjectionBefore)
        }
        #expect(core.readTranscript?.sessionID == readCacheBefore.sessionID)
        #expect(core.readTranscript?.revision == readCacheBefore.revision)
        #expect(core.readTranscript?.rows == readCacheBefore.rows)
        #expect(core.readTranscript?.materializedSegments == readCacheBefore.materializedSegments)
        #expect(core.readTranscript?.isLiveState == readCacheBefore.isLiveState)
        #expect((core.readTranscript?.projection == nil) == (readCacheBefore.projection == nil))
        #expect(core.transcriptReadSnapshot?.sessionID == readSnapshotBefore.sessionID)
        #expect(core.transcriptReadSnapshot?.revision == readSnapshotBefore.revision)
        #expect(core.transcriptReadSnapshot?.rows == readSnapshotBefore.rows)
        #expect(core.transcriptReadSnapshot?.materializedSegments == readSnapshotBefore.materializedSegments)
        let detailsSnapshotAfter = try #require(core.transcriptRowDetailsSnapshot)
        #expect(detailsSnapshotAfter.sessionID == detailsSnapshotBefore.sessionID)
        #expect(detailsSnapshotAfter.revision == detailsSnapshotBefore.revision)
        #expect(detailsSnapshotAfter.rowID == detailsSnapshotBefore.rowID)
        #expect(core.transcriptReadNavigation === readNavigationBefore)
        #expect(try await h.shutdown() == .shutdownRequested)
    }
}

@MainActor
private func populateWatchedAndReadCaches(_ h: ApplicationHarness, sessionID: String) async throws {
    guard case .transcriptRead = try await h.call(
        "transcript.read",
        payload: try json(EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 200))
    ) else { throw TestTimeout(description: "transcript.read returned the wrong result") }
    guard case .transcriptWatch = try await h.call(
        "transcript.watch", payload: try json(EngineSessionPayload(sessionID: sessionID))
    ) else { throw TestTimeout(description: "transcript.watch returned the wrong result") }
}

@MainActor
private func controllerRequestBarrier(_ h: ApplicationHarness) async throws {
    _ = try await h.call("state.get")
}

@MainActor
private func rowsPayloads(in h: ApplicationHarness, sessionID: String) throws -> [EngineRowsPayload] {
    try h.outputs.compactMap { output in
        guard case let .rows(payload) = output.event, payload.sessionID == sessionID else { return nil }
        return payload
    }
}

private func rowDetailsVisibleSegment() throws -> MaterializedTranscriptSegment {
    try explicitSegment(
        id: "row-details-visible", start: 0, end: 100, text: "表示される発話",
        clauseState: .classified, clauseSlices: []
    )
}

@MainActor
private func prepared(_ root: URL) async throws -> ApplicationHarness {
    let h = ApplicationHarness(root: root)
    h.start()
    try await h.hello()
    try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
    await h.awaitModels()
    return h
}

@MainActor
private func recordAndFinalize(in h: ApplicationHarness) async throws -> String {
    guard case let .recordingStart(started) = try await h.call(
        "recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}"
    ) else { throw TestTimeout(description: "recording.start returned the wrong result") }
    let capture = try #require(h.capture.session)
    try await capture.appendSpeech(seconds: 2)
    try await h.call("recording.stop", payload: "{\"session_id\":\"\(started.sessionID)\"}")
    while true {
        let stateCount = h.stateEventCount
        if try await h.sessions().contains(where: { $0.sessionID == started.sessionID && $0.status == .finalized }) {
            return started.sessionID
        }
        try await h.sink.changes.wait("session \(started.sessionID) to finalize") { h.stateEventCount > stateCount }
    }
}

@MainActor
private func requestContext(for h: ApplicationHarness) throws -> EngineRequestContext {
    EngineRequestContext(requestID: try EngineID(10_000), events: EngineEventEmitter(transport: h.transport))
}

private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private func detailsPayload(
    sessionID: String, revision: EngineID, rowID: String
) throws -> EngineTranscriptRowDetailsPayload {
    try EngineTranscriptRowDetailsPayload(sessionID: sessionID, revision: revision, rowID: rowID)
}

@MainActor
private func controllerRowDetails(
    _ h: ApplicationHarness, _ payload: EngineTranscriptRowDetailsPayload
) async throws -> EngineTranscriptRowDetailsPage {
    let countBefore = try h.outputs.count
    guard case let .transcriptRowDetails(page) = try await h.call(
        "transcript.row_details", payload: json(payload)
    ) else { throw TestTimeout(description: "transcript.row_details returned the wrong result") }
    let newOutputs = Array(try h.outputs.dropFirst(countBefore))
    let accepted = newOutputs.compactMap { output -> EngineOutput? in
        guard case let .accepted(accepted) = output.event,
              accepted.command == .transcriptRowDetails else { return nil }
        return output
    }
    let completed = newOutputs.compactMap { output -> EngineOutput? in
        guard case let .completed(.transcriptRowDetails(result)) = output.event, result == page else { return nil }
        return output
    }
    #expect(accepted.count == 1)
    #expect(completed.count == 1)
    #expect(accepted.first?.requestID != nil)
    #expect(accepted.first?.requestID == completed.first?.requestID)
    return page
}

private func explicitSegment(
    id: String, start: Int64, end: Int64, text: String,
    clauseState: TranscriptClauseState?, clauseSlices: [ClauseRowSlice]
) throws -> MaterializedTranscriptSegment {
    let source = try SegmentTextReference(
        segmentationRunID: "row-details-test-seg", segmentID: id,
        asrRunID: "row-details-test-asr", asrEventSeq: 1
    )
    let projection = try TranscriptTextProjector().project(sourceText: text, fillerRanges: [])
    return try MaterializedTranscriptSegment(
        segmentID: id, source: source, startMilliseconds: start, endMilliseconds: end,
        text: text, textProjection: projection, clauseState: clauseState, clauseSlices: clauseSlices
    )
}

private func materializedClauseStateRows() throws -> [MaterializedTranscriptSegment] {
    let fixtures: [(String, String, TranscriptClauseState?)] = [
        ("state-boundary-pending", "境界保留です。", .boundaryPending),
        ("state-awaiting", "続き待ちです。", .awaitingNextSegment),
        ("state-priority", "優先度待ちです。", .priorityPending),
        ("state-classified", "判定済みです。", .classified),
        ("state-blank", "", nil)
    ]
    return try fixtures.enumerated().map { index, fixture in
        let (segmentID, text, expectedState) = fixture
        let segmentation = "seg-\(index)"
        let asr = "asr-\(index)"
        let boundary = "boundary-\(index)"
        let start = Int64(index * 1_000)
        let sourceEvents: [TranscriptEvent] = [
            .segmentCreated(seq: 1, segmentationRunID: segmentation, segmentID: segmentID,
                            startFrame: start, endFrame: start + 1_000),
            .asrCompleted(seq: 2, runID: asr, segmentationRunID: segmentation, segmentID: segmentID,
                          text: text, detectedLanguage: "ja")
        ]
        var events = sourceEvents
        let activeRuns = ActiveRuns(
            segmentation: segmentation, asr: asr,
            clauseBoundary: expectedState == nil ? nil : boundary,
            contentPriority: expectedState == .classified ? "priority-\(index)" : nil
        )
        if let expectedState {
            let asrSource = try #require(try sourceEvents[1].asrSource())
            switch expectedState {
            case .boundaryPending:
                events.append(.clause(
                    seq: 5, runID: boundary,
                    kind: .clauseBoundaryPending(ClauseBoundaryPendingPayload(
                        source: asrSource, reason: .requestFailed, message: "test boundary pending"
                    ))
                ))
            case .awaitingNextSegment:
                break
            case .priorityPending, .classified:
                let candidates = try ClauseBoundaryCandidate.candidates(in: text)
                let assessment = try ClauseBoundaryAssessment(
                    source: asrSource, candidates: candidates,
                    probabilities: Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, 0.1) }),
                    nextHead: nil, continuationProbability: nil, fillerRanges: [],
                    request: try DecisionRequestRecord(requestID: "boundary-request-\(index)", inputTokens: 1),
                    sourceDecision: .assessed
                )
                events.append(.clause(seq: 5, runID: boundary, kind: .clauseBoundaryAssessed(assessment)))
                var assembly = ClauseBoundaryAssembly(boundaryRunID: boundary)
                let consumed = try assembly.consume(ClauseAssemblyInput(
                    source: asrSource, text: text, state: .assessed(assessment)
                ))
                let closed = consumed.closed + (try assembly.finish()).closed
                for (closedIndex, unit) in closed.enumerated() {
                    events.append(.clause(
                        seq: UInt64(6 + closedIndex), runID: boundary, kind: .clauseClosed(unit)
                    ))
                }
                if expectedState == .classified {
                    let reference = try #require(closed.first?.reference)
                    let decision = try ContentPriorityDecision(
                        priority: .primary, confidence: 1,
                        probabilities: ["PRIMARY": 1, "LOW_PRIORITY": 0]
                    )
                    let assignment = try ClausePriorityAssignment(
                        reference: reference, priority: .primary, needsRetry: false,
                        decision: .classified(requestID: "priority-request-\(index)", answerKey: "u0001", response: decision)
                    )
                    let request = try DecisionRequestRecord(requestID: "priority-request-\(index)", inputTokens: 1)
                    let payload = try ContentPriorityAssignedPayload(assignments: [assignment], request: request)
                    events.append(.clause(
                        seq: 10, runID: "priority-\(index)", kind: .contentPriorityAssigned(payload)
                    ))
                }
            }
        }
        return try #require(try TranscriptMaterializer(sampleRate: 1_000).materialize(
            events: events, activeRuns: activeRuns
        ).first)
    }
}

@MainActor
private func waitForRowsEvent(
    in h: ApplicationHarness, sessionID: String, revision: UInt64, kind: EngineRowsKind
) async throws {
    try await h.sink.changes.wait("transcript rows event at revision \(revision)") {
        ((try? h.outputs) ?? []).contains { output in
            guard case let .rows(payload) = output.event else { return false }
            return payload.sessionID == sessionID && payload.revision.value == revision && payload.kind == kind
        }
    }
}

@MainActor
private func expectCommandError(
    _ expected: EngineErrorCode,
    operation: () async throws -> Void
) async throws {
    do {
        try await operation()
        Issue.record("expected EngineCommandError with code \(expected.rawValue)")
    } catch let error as EngineCommandError {
        #expect(error.code == expected)
    } catch {
        Issue.record("expected EngineCommandError \(expected.rawValue), got \(error)")
    }
}
