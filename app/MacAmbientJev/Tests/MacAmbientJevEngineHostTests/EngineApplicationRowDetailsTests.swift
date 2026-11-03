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
            sessionID: sessionID, revision: read.revision, rowID: expectedRow.rowID, cursor: nil, limit: 200
        )
        let detail = try await controllerRowDetails(h, payload)

        #expect(detail.sessionID == sessionID)
        #expect(detail.revision == read.revision)
        #expect(detail.rowID == expectedRow.rowID)
        #expect(detail.speakers == (try wireSpeakers(segment.speakers)))
        #expect(detail.clauseState.rawValue == liveRow.clauseState.rawValue)
        #expect(detail.clauseStateText == liveRow.clauseState.rowDetailsDescription)
        #expect(liveRow.text == segment.displayText)
        #expect(expectedRow.text == liveRow.text)
        #expect(expectedRow.startMS == liveRow.startMilliseconds)
        #expect(expectedRow.endMS == liveRow.endMilliseconds)
        #expect(expectedRow.clauseState == EngineClauseState(rawValue: liveRow.clauseState.rawValue))

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func eventMaterializationPreservesSpeakersStatesOrderAndBlankVisibility() async throws {
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
            "state-boundary-pending", "state-awaiting", "state-priority", "state-classified", "state-no-speakers"
        ])
        #expect(segments.last?.text == "")
        #expect(segments.last?.speakers.isEmpty == true)
        let noSpeaker = try #require(segments.first { $0.segmentID == "state-no-speakers" })
        let noSpeakerDetail = try await core.rowDetails(
            detailsPayload(
                sessionID: sessionID, revision: try EngineID(cache.revision),
                rowID: noSpeaker.segmentID, cursor: nil, limit: 200
            ), context: requestContext(for: h)
        )
        #expect(noSpeakerDetail.speakers.isEmpty)
        #expect(noSpeakerDetail.nextCursor == nil)
        #expect(noSpeakerDetail.previousCursor == nil)
        #expect(cache.rows.first { $0.rowID == noSpeaker.segmentID }?.headings == [.unknown])
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
                detailsPayload(sessionID: sessionID, revision: try EngineID(cache.revision), rowID: rowID, cursor: nil, limit: 200),
                context: requestContext(for: h)
            )
            #expect(page.rowID == rowID)
            #expect(page.clauseState == state)
            #expect(page.clauseStateText == text)
            #expect(page.speakers == (try wireSpeakers(segment.speakers)))
            #expect(page.speakers.map(\.speakerID) == segment.speakers.map(\.id))
            #expect(page.speakers.map(\.startMS) == segment.speakers.map(\.startMilliseconds))
            #expect(page.speakers.map(\.endMS) == segment.speakers.map(\.endMilliseconds))
            #expect(live.text == segment.displayText)
            #expect(live.clauseState.rawValue == page.clauseState.rawValue)
            #expect(live.speakers == segment.speakers)
        }
        let blank = try #require(segments.last)
        #expect(!cache.rows.contains { $0.rowID == blank.segmentID })
        try await expectCommandError(.rowNotFound) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionID, revision: try EngineID(cache.revision), rowID: blank.segmentID, cursor: nil, limit: 200),
                context: requestContext(for: h)
            )
        }
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func revisionRowAndCursorErrorsHaveDeterministicPriority() async throws {
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
                detailsPayload(sessionID: nonexistentSession, revision: revision, rowID: "missing", cursor: "unknown", limit: 1),
                context: requestContext(for: h)
            )
        }
        let oldRevision = try EngineID(max(1, cache.revision - 1))
        try await expectCommandError(.staleRevision) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionID, revision: oldRevision, rowID: "missing", cursor: "unknown", limit: 1),
                context: requestContext(for: h)
            )
        }
        try await expectCommandError(.rowNotFound) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionID, revision: revision, rowID: "missing", cursor: "unknown", limit: 1),
                context: requestContext(for: h)
            )
        }
        try await expectCommandError(.invalidCursor) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionID, revision: revision, rowID: "state-classified", cursor: "unknown", limit: 1),
                context: requestContext(for: h)
            )
        }
        #expect(segments.contains { $0.segmentID == "state-blank" })
        #expect(!cache.rows.contains { $0.rowID == "state-blank" })
        try await expectCommandError(.rowNotFound) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionID, revision: revision, rowID: "state-blank", cursor: nil, limit: 1),
                context: requestContext(for: h)
            )
        }
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func byteAndCountPagingPreservesExactSpansInBothDirections() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let core = h.app.core
        _ = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: requestContext(for: h))
        let uuid = try #require(UUID(uuidString: sessionID))
        let largeIDA = String(repeating: "日\"\\", count: 34_000) + "A"
        let largeIDB = String(repeating: "日\"\\", count: 34_000) + "B"
        let sourceSpans: [MaterializedSpeakerSpan] = (0..<16).map { index in
            let speakerID = index.isMultiple(of: 2) ? largeIDA : largeIDB
            let start = Int64(1_000 + index * 10)
            return MaterializedSpeakerSpan(
                id: speakerID, startMilliseconds: start, endMilliseconds: start + 200,
                confidence: nil, displayLabel: index.isMultiple(of: 2) ? "Speaker 1" : "Speaker 2"
            )
        }
        let stressSegment = try explicitSegment(
            id: "details-byte-stress", start: 0, end: 100, text: "詳細ページ",
            speakers: sourceSpans, clauseState: .classified, clauseSlices: [], isDiarized: true
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [stressSegment])
        let cache = try #require(core.transcript)
        let context = try requestContext(for: h)
        let revision = try EngineID(cache.revision)
        var pages: [EngineTranscriptRowDetailsPage] = []
        var cursor: String?
        repeat {
            let page = try await core.rowDetails(
                detailsPayload(sessionID: sessionID, revision: revision, rowID: stressSegment.segmentID, cursor: cursor, limit: 200),
                context: context
            )
            pages.append(page)
            cursor = page.nextCursor
            let maxID = try EngineID(UInt64.max)
            let output = try EngineOutput(
                version: 1, sequence: maxID, requestID: maxID,
                event: .completed(.transcriptRowDetails(page))
            )
            let encoded = try EngineCodec.encodeOutput(output)
            #expect(encoded.count - 1 <= EngineLineFramer.maxLineBytes)
        } while cursor != nil

        #expect(pages.count >= 3)
        #expect(pages.allSatisfy { $0.speakers.count < 200 })
        #expect(pages.map(\.speakers).flatMap { $0 } == (try wireSpeakers(sourceSpans)))
        #expect(pages.contains { page in
            guard let maxID = try? EngineID(UInt64.max),
                  let output = try? EngineOutput(
                    version: 1, sequence: maxID, requestID: maxID,
                    event: .completed(.transcriptRowDetails(page))
                  ),
                  let encoded = try? EngineCodec.encodeOutput(output) else { return false }
            return encoded.count - 1 > 700_000
        })
        for index in 0..<(pages.count - 1) {
            let boundary = try #require(pages[index].nextCursor)
            let backward = try #require(pages[index + 1].previousCursor)
            let priorPage = try await core.rowDetails(
                detailsPayload(sessionID: sessionID, revision: revision, rowID: stressSegment.segmentID, cursor: backward, limit: 200),
                context: context
            )
            #expect(priorPage.speakers == pages[index].speakers)
            #expect(priorPage.nextCursor == boundary)
        }
        #expect(pages[0].previousCursor == nil)
        #expect(pages.last?.nextCursor == nil)

        let emptySegment = try explicitSegment(
            id: "details-empty", start: 200, end: 300, text: "空の話者", speakers: [],
            clauseState: .classified, clauseSlices: [], isDiarized: true
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [stressSegment, emptySegment])
        let emptyRevision = try EngineID(try #require(core.transcript?.revision))
        let emptyPage = try await core.rowDetails(
            detailsPayload(sessionID: sessionID, revision: emptyRevision, rowID: emptySegment.segmentID, cursor: nil, limit: 200),
            context: context
        )
        #expect(emptyPage.speakers.isEmpty)
        #expect(emptyPage.nextCursor == nil)
        #expect(emptyPage.previousCursor == nil)

        let counted: [MaterializedSpeakerSpan] = (0..<201).map { index in
            let speakerID = "speaker-\(index % 2)"
            let start = Int64(index * 20)
            return MaterializedSpeakerSpan(
                id: speakerID, startMilliseconds: start, endMilliseconds: start + 50,
                confidence: nil, displayLabel: "Speaker \(index % 2 + 1)"
            )
        }
        let countedSegment = try explicitSegment(
            id: "details-count-stress", start: 400, end: 500, text: "件数上限", speakers: counted,
            clauseState: .classified, clauseSlices: [], isDiarized: true
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [countedSegment])
        let countedRevision = try EngineID(try #require(core.transcript?.revision))
        let firstCountPage = try await core.rowDetails(
            detailsPayload(sessionID: sessionID, revision: countedRevision, rowID: countedSegment.segmentID, cursor: nil, limit: 200),
            context: context
        )
        #expect(firstCountPage.speakers.count == 200)
        let finalCountPage = try await core.rowDetails(
            detailsPayload(
                sessionID: sessionID, revision: countedRevision, rowID: countedSegment.segmentID,
                cursor: try #require(firstCountPage.nextCursor), limit: 200
            ),
            context: context
        )
        #expect(finalCountPage.speakers.count == 1)
        #expect(firstCountPage.speakers + finalCountPage.speakers == (try wireSpeakers(counted)))

        let hugeSpan = MaterializedSpeakerSpan(
            id: String(repeating: "日\"\\", count: 170_000), startMilliseconds: 0,
            endMilliseconds: 1, confidence: nil, displayLabel: "巨大"
        )
        let tooLargeSegment = try explicitSegment(
            id: "details-one-span-too-large", start: 600, end: 700, text: "巨大な話者", speakers: [hugeSpan],
            clauseState: .classified, clauseSlices: [], isDiarized: true
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [tooLargeSegment])
        try await expectCommandError(.rowTooLarge) {
            _ = try await core.rowDetails(
                detailsPayload(
                    sessionID: sessionID, revision: try EngineID(try #require(core.transcript?.revision)),
                    rowID: tooLargeSegment.segmentID, cursor: nil, limit: 200
                ), context: context
            )
        }
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func detailsNavigationIsRowScopedAndSnapshotsStayIndependent() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionA = try await recordAndFinalize(in: h)
        let sessionB = try await recordAndFinalize(in: h)
        let core = h.app.core
        _ = try await core.watch(EngineSessionPayload(sessionID: sessionA), context: requestContext(for: h))
        let uuidA = try #require(UUID(uuidString: sessionA))
        let rowA = try explicitSegment(
            id: "navigation-A", start: 0, end: 100, text: "行A",
            speakers: (0..<4).map { index in
                MaterializedSpeakerSpan(id: "nav-speaker-\(index)", startMilliseconds: Int64(index * 100),
                                        endMilliseconds: Int64(index * 100 + 80), confidence: nil,
                                        displayLabel: "Speaker \(index + 1)")
            }, clauseState: .classified, clauseSlices: [], isDiarized: true
        )
        let rowB = try explicitSegment(
            id: "navigation-B", start: 100, end: 200, text: "行B",
            speakers: [MaterializedSpeakerSpan(id: "nav-speaker-B", startMilliseconds: 100, endMilliseconds: 120,
                                               confidence: nil, displayLabel: "Speaker 1")],
            clauseState: .classified, clauseSlices: [], isDiarized: true
        )
        core.transcriptDidUpdate(sessionID: uuidA, segments: [rowA, rowB])
        let cacheA = try #require(core.transcript)
        let revisionA = try EngineID(cacheA.revision)
        let context = try requestContext(for: h)
        let first = try await core.rowDetails(
            detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: nil, limit: 1), context: context
        )
        let firstForward = try #require(first.nextCursor)
        try await expectCommandError(.invalidCursor) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: firstForward, limit: 2),
                context: context
            )
        }
        let second = try await core.rowDetails(
            detailsPayload(
                sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID,
                cursor: firstForward, limit: 1
            ), context: context
        )
        let priorForward = try #require(second.nextCursor)
        let priorBackward = try #require(second.previousCursor)
        #expect(second.speakers.count == 1)
        try await expectCommandError(.invalidCursor) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: priorBackward, limit: 2),
                context: context
            )
        }
        let recoveredBackward = try await core.rowDetails(
            detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: priorBackward, limit: 1),
            context: context
        )
        #expect(recoveredBackward.speakers == first.speakers)

        let restartedSameLimit = try await core.rowDetails(
            detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: nil, limit: 1), context: context
        )
        #expect(restartedSameLimit.speakers == first.speakers)
        try await expectCommandError(.invalidCursor) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: priorForward, limit: 1), context: context
            )
        }
        try await expectCommandError(.invalidCursor) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: priorBackward, limit: 1), context: context
            )
        }

        let freshLimitOne = try await core.rowDetails(
            detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: nil, limit: 1), context: context
        )
        let freshNext = try #require(freshLimitOne.nextCursor)
        let freshSecond = try await core.rowDetails(
            detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: freshNext, limit: 1), context: context
        )
        let changeLimitPage = try await core.rowDetails(
            detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: nil, limit: 200), context: context
        )
        #expect(changeLimitPage.speakers.count == rowA.speakers.count)
        #expect(changeLimitPage.nextCursor == nil)
        try await expectCommandError(.invalidCursor) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: freshNext, limit: 1), context: context
            )
        }
        try await expectCommandError(.invalidCursor) {
            _ = try await core.rowDetails(
                detailsPayload(
                    sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID,
                    cursor: try #require(freshSecond.previousCursor), limit: 1
                ), context: context
            )
        }

        let rowAAtLimitOne = try await core.rowDetails(
            detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: nil, limit: 1), context: context
        )
        let rowTokenBeforeSwitch = try #require(rowAAtLimitOne.nextCursor)
        try await expectCommandError(.invalidCursor) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowB.segmentID, cursor: rowTokenBeforeSwitch, limit: 1),
                context: context
            )
        }
        let recoveredRowA = try await core.rowDetails(
            detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: rowTokenBeforeSwitch, limit: 1),
            context: context
        )
        #expect(recoveredRowA.speakers == Array(try wireSpeakers(rowA.speakers).dropFirst().prefix(1)))
        _ = try await core.rowDetails(
            detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowB.segmentID, cursor: nil, limit: 1), context: context
        )
        try await expectCommandError(.invalidCursor) {
            _ = try await core.rowDetails(
                detailsPayload(sessionID: sessionA, revision: revisionA, rowID: rowA.segmentID, cursor: rowTokenBeforeSwitch, limit: 1),
                context: context
            )
        }
        let watchB = try await core.watch(EngineSessionPayload(sessionID: sessionB), context: context)
        let sessionBRow = try #require(watchB.rows.first)
        try await expectCommandError(.invalidCursor) {
            _ = try await core.rowDetails(
                detailsPayload(
                    sessionID: sessionB, revision: watchB.revision, rowID: sessionBRow.rowID,
                    cursor: rowTokenBeforeSwitch, limit: 1
                ), context: context
            )
        }

        #expect(core.watchedSessionID == UUID(uuidString: sessionB))
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func liveUpdatesRetainDetailsAndReadSnapshotsAcrossReplacement() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let core = h.app.core
        let initialWatch = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: requestContext(for: h))
        let uuid = try #require(UUID(uuidString: sessionID))
        let savedSession = try core.readableSession(uuid)
        let audioSource = try #require(savedSession.audioSource)
        guard case let .segments(savedSegments) = try SavedTranscriptLoader.load(
            sessionURL: savedSession.sessionURL, audioSource: audioSource
        ) else { throw TestTimeout(description: "saved transcript was unavailable") }
        let saved = try #require(savedSegments.first)
        let savedRow = try #require(initialWatch.rows.first)
        let repeatedSpeakers: [MaterializedSpeakerSpan] = (0..<4).map { index in
            let start = Int64(10 + index * 20)
            return MaterializedSpeakerSpan(
                id: "publication-speaker", startMilliseconds: start,
                endMilliseconds: start + 70, confidence: 0.9, displayLabel: nil
            )
        }
        let publishedCandidate = try explicitSegment(
            id: saved.segmentID, start: saved.startMilliseconds, end: saved.endMilliseconds,
            text: saved.text, speakers: repeatedSpeakers, clauseState: saved.clauseState,
            clauseSlices: saved.clauseSlices, isDiarized: saved.isDiarized
        )
        #expect(try EngineTranscriptProjection.rows(for: [publishedCandidate]) == [savedRow])
        let continuationRow = try explicitSegment(
            id: "snapshot-read-continuation", start: saved.endMilliseconds + 10,
            end: saved.endMilliseconds + 110, text: "読み取り続き", speakers: [],
            clauseState: .classified, clauseSlices: [], isDiarized: false
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [publishedCandidate, continuationRow])
        let liveCache = try #require(core.transcript)
        let originalRevision = try EngineID(liveCache.revision)
        let originalRows = liveCache.rows
        #expect(originalRows.count == 2)
        try await waitForRowsEvent(in: h, sessionID: sessionID, revision: liveCache.revision, kind: .changes)

        let oldRead = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 1), context: requestContext(for: h)
        )
        let oldReadSnapshot = try #require(core.transcriptReadSnapshot)
        let firstDetail = try await core.rowDetails(
            detailsPayload(sessionID: sessionID, revision: originalRevision, rowID: saved.segmentID, cursor: nil, limit: 1),
            context: requestContext(for: h)
        )
        let oldDetailNext = try #require(firstDetail.nextCursor)
        let oldDetailSecond = try await core.rowDetails(
            detailsPayload(sessionID: sessionID, revision: originalRevision, rowID: saved.segmentID, cursor: oldDetailNext, limit: 1),
            context: requestContext(for: h)
        )

        let labelChanged = try explicitSegment(
            id: publishedCandidate.segmentID, start: publishedCandidate.startMilliseconds, end: publishedCandidate.endMilliseconds,
            text: publishedCandidate.text,
            speakers: repeatedSpeakers.map {
                MaterializedSpeakerSpan(id: $0.id, startMilliseconds: $0.startMilliseconds, endMilliseconds: $0.endMilliseconds,
                                        confidence: $0.confidence, displayLabel: "Speaker 1")
            }, clauseState: publishedCandidate.clauseState, clauseSlices: publishedCandidate.clauseSlices,
            isDiarized: publishedCandidate.isDiarized
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [labelChanged, continuationRow])
        let labelCache = try #require(core.transcript)
        #expect(labelCache.revision > liveCache.revision)
        #expect(labelCache.rows == originalRows)
        try await waitForRowsEvent(in: h, sessionID: sessionID, revision: labelCache.revision, kind: .reloadRequired)
        let intervalChanged = try explicitSegment(
            id: labelChanged.segmentID, start: labelChanged.startMilliseconds, end: labelChanged.endMilliseconds,
            text: labelChanged.text,
            speakers: repeatedSpeakers.map {
                MaterializedSpeakerSpan(id: $0.id, startMilliseconds: $0.startMilliseconds + 1,
                                        endMilliseconds: $0.endMilliseconds + 1, confidence: $0.confidence,
                                        displayLabel: "Speaker 1")
            }, clauseState: labelChanged.clauseState, clauseSlices: labelChanged.clauseSlices,
            isDiarized: labelChanged.isDiarized
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [intervalChanged, continuationRow])
        let intervalCache = try #require(core.transcript)
        #expect(intervalCache.revision > labelCache.revision)
        #expect(intervalCache.rows == originalRows)
        try await waitForRowsEvent(in: h, sessionID: sessionID, revision: intervalCache.revision, kind: .reloadRequired)
        core.transcriptDidUpdate(sessionID: uuid, segments: [intervalChanged, continuationRow])
        #expect(core.transcript?.revision == intervalCache.revision)

        let newRead = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 1), context: requestContext(for: h)
        )
        let newReadSnapshot = try #require(core.transcriptReadSnapshot)
        #expect(newRead.revision.value > oldRead.revision.value)
        #expect(newReadSnapshot.revision == newRead.revision.value)
        #expect(oldReadSnapshot.revision == oldRead.revision.value)
        let oldDetailContinuation = try await core.rowDetails(
            detailsPayload(
                sessionID: sessionID, revision: originalRevision, rowID: saved.segmentID, cursor: oldDetailNext, limit: 1
            ), context: requestContext(for: h)
        )
        #expect(oldDetailContinuation.speakers == oldDetailSecond.speakers)
        #expect(oldDetailContinuation.revision == originalRevision)
        #expect(core.watchedSessionID == uuid)
        let detailForOtherRow = try await core.rowDetails(
            detailsPayload(
                sessionID: sessionID, revision: newRead.revision,
                rowID: continuationRow.segmentID, cursor: nil, limit: 1
            ), context: requestContext(for: h)
        )
        #expect(detailForOtherRow.rowID == continuationRow.segmentID)
        try await expectCommandError(.staleRevision) {
            _ = try await core.rowDetails(
                detailsPayload(
                    sessionID: sessionID, revision: originalRevision,
                    rowID: saved.segmentID, cursor: oldDetailNext, limit: 1
                ), context: requestContext(for: h)
            )
        }
        let readAfterDetails = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: newRead.revision,
                cursor: try #require(newRead.nextCursor), limit: 1
            ), context: requestContext(for: h)
        )
        #expect(readAfterDetails.revision == newRead.revision)
        #expect(core.transcriptReadSnapshot?.revision == newReadSnapshot.revision)
        #expect(core.watchedSessionID == uuid)
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
        let oldSpeakerA = MaterializedSpeakerSpan(
            id: "snapshot-old-A", startMilliseconds: 10, endMilliseconds: 40,
            confidence: 0.8, displayLabel: "Speaker 1"
        )
        let oldSpeakerB = MaterializedSpeakerSpan(
            id: "snapshot-old-B", startMilliseconds: 110, endMilliseconds: 140,
            confidence: 0.7, displayLabel: "Speaker 2"
        )
        let oldRowA = try explicitSegment(
            id: "read-snapshot-A", start: 0, end: 100, text: "古い一行目", speakers: [oldSpeakerA],
            clauseState: .boundaryPending, clauseSlices: [], isDiarized: true
        )
        let oldRowB = try explicitSegment(
            id: "read-snapshot-B", start: 100, end: 200, text: "古い二行目", speakers: [oldSpeakerB],
            clauseState: .awaitingNextSegment, clauseSlices: [], isDiarized: true
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

        let newSpeakerA = MaterializedSpeakerSpan(
            id: "snapshot-new-A", startMilliseconds: 20, endMilliseconds: 60,
            confidence: 0.95, displayLabel: "Speaker 3"
        )
        let newSpeakerB = MaterializedSpeakerSpan(
            id: "snapshot-new-B", startMilliseconds: 120, endMilliseconds: 160,
            confidence: 0.9, displayLabel: "Speaker 4"
        )
        let newRowA = try explicitSegment(
            id: oldRowA.segmentID, start: oldRowA.startMilliseconds, end: oldRowA.endMilliseconds,
            text: oldRowA.text, speakers: [newSpeakerA], clauseState: .classified,
            clauseSlices: [], isDiarized: true
        )
        let newRowB = try explicitSegment(
            id: oldRowB.segmentID, start: oldRowB.startMilliseconds, end: oldRowB.endMilliseconds,
            text: oldRowB.text, speakers: [newSpeakerB], clauseState: .classified,
            clauseSlices: [], isDiarized: true
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [newRowA, newRowB])
        let cacheR2 = try #require(core.transcript)
        let revisionR2 = try EngineID(cacheR2.revision)
        #expect(revisionR2.value > revisionR.value)

        let oldDetail = try await core.rowDetails(
            detailsPayload(sessionID: sessionID, revision: revisionR, rowID: oldRowA.segmentID, cursor: nil, limit: 200),
            context: requestContext(for: h)
        )
        #expect(oldDetail.revision == revisionR)
        #expect(oldDetail.speakers == (try wireSpeakers(oldRowA.speakers)))
        #expect(oldDetail.speakers != (try wireSpeakers(newRowA.speakers)))
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
            detailsPayload(sessionID: sessionID, revision: revisionR, rowID: oldRowB.segmentID, cursor: nil, limit: 200),
            context: requestContext(for: h)
        )
        #expect(otherOldDetail.speakers == (try wireSpeakers(oldRowB.speakers)))
        let freshRead = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 1),
            context: requestContext(for: h)
        )
        #expect(freshRead.revision == revisionR2)
        let newDetail = try await core.rowDetails(
            detailsPayload(sessionID: sessionID, revision: freshRead.revision, rowID: newRowA.segmentID, cursor: nil, limit: 200),
            context: requestContext(for: h)
        )
        #expect(newDetail.revision == revisionR2)
        #expect(newDetail.speakers == (try wireSpeakers(newRowA.speakers)))
        #expect(newDetail.speakers != oldDetail.speakers)
        #expect(newDetail.clauseState == .classified)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func finalPublicationInvalidatesBothDetailsDirectionsEvenForSameRows() async throws {
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
        let speakers: [MaterializedSpeakerSpan] = (0..<4).map { index in
            let start = Int64(10 + index * 20)
            return MaterializedSpeakerSpan(
                id: "publication-speaker", startMilliseconds: start, endMilliseconds: start + 70,
                confidence: 0.9, displayLabel: nil
            )
        }
        let liveSegment = try explicitSegment(
            id: saved.segmentID, start: saved.startMilliseconds, end: saved.endMilliseconds,
            text: saved.text, speakers: speakers, clauseState: saved.clauseState,
            clauseSlices: saved.clauseSlices, isDiarized: saved.isDiarized
        )
        #expect(try EngineTranscriptProjection.rows(for: [liveSegment]) == [savedRow])
        core.transcriptDidUpdate(sessionID: uuid, segments: [liveSegment])
        let beforePublication = try #require(core.transcript)
        let oldRevision = try EngineID(beforePublication.revision)
        try await waitForRowsEvent(
            in: h, sessionID: sessionID, revision: beforePublication.revision, kind: .reloadRequired
        )
        let first = try await core.rowDetails(
            detailsPayload(sessionID: sessionID, revision: oldRevision, rowID: saved.segmentID, cursor: nil, limit: 1),
            context: requestContext(for: h)
        )
        let forward = try #require(first.nextCursor)
        let second = try await core.rowDetails(
            detailsPayload(sessionID: sessionID, revision: oldRevision, rowID: saved.segmentID, cursor: forward, limit: 1),
            context: requestContext(for: h)
        )
        let backward = try #require(second.previousCursor)
        #expect(second.speakers.count == 1)
        #expect(try EngineTranscriptProjection.rows(for: beforePublication.materializedSegments) == [savedRow])

        core.transcriptDidPublish(sessionID: uuid)
        let afterPublication = try #require(core.transcript)
        #expect(afterPublication.rows == beforePublication.rows)
        #expect(afterPublication.revision > beforePublication.revision)
        try await waitForRowsEvent(
            in: h, sessionID: sessionID, revision: afterPublication.revision, kind: .reloadRequired
        )
        for oldCursor in [forward, backward] {
            try await expectCommandError(.staleRevision) {
                _ = try await core.rowDetails(
                    detailsPayload(
                        sessionID: sessionID, revision: oldRevision, rowID: saved.segmentID,
                        cursor: oldCursor, limit: 1
                    ), context: requestContext(for: h)
                )
            }
            try await expectCommandError(.invalidCursor) {
                _ = try await core.rowDetails(
                    detailsPayload(
                        sessionID: sessionID, revision: try EngineID(afterPublication.revision),
                        rowID: saved.segmentID, cursor: oldCursor, limit: 1
                    ), context: requestContext(for: h)
                )
            }
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
            id: "rowless-empty", start: 200, end: 300, text: "", speakers: [],
            clauseState: nil, clauseSlices: [], isDiarized: false
        )
        let whitespace = try explicitSegment(
            id: "rowless-whitespace", start: 300, end: 400, text: " \n\t", speakers: [],
            clauseState: nil, clauseSlices: [], isDiarized: false
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [visible, empty, whitespace])
        try await controllerRequestBarrier(h)
        #expect(core.transcript?.revision == watchedRevision)
        #expect(core.readTranscript?.revision == readRevision)
        #expect(core.nextTranscriptRevision == nextRevision)
        let rowsAfterAppend = try rowsPayloads(in: h, sessionID: sessionID)
        #expect(rowsAfterAppend == rowsBaseline)

        let modifiedEmpty = try explicitSegment(
            id: empty.segmentID, start: 210, end: 310, text: "  ", speakers: [],
            clauseState: nil, clauseSlices: [], isDiarized: false
        )
        let modifiedWhitespace = try explicitSegment(
            id: whitespace.segmentID, start: 310, end: 410, text: "\n \t ", speakers: [],
            clauseState: nil, clauseSlices: [], isDiarized: false
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

    @Test func confidenceOnlyUpdatesDoNotAdvanceRevisionOrEmitRows() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let core = h.app.core
        let uuid = try #require(UUID(uuidString: sessionID))
        try await populateWatchedAndReadCaches(h, sessionID: sessionID)

        let visible = try rowDetailsVisibleSegment()
        core.transcriptDidUpdate(sessionID: uuid, segments: [visible])
        try await controllerRequestBarrier(h)
        let seededWatchCache = try #require(core.transcript)
        let seededReadCache = try #require(core.readTranscript)
        let watchedRevision = seededWatchCache.revision
        let readRevision = seededReadCache.revision
        let nextRevision = core.nextTranscriptRevision
        let rowsBaseline = try rowsPayloads(in: h, sessionID: sessionID)

        let confidenceChanged = try explicitSegment(
            id: visible.segmentID, start: visible.startMilliseconds, end: visible.endMilliseconds,
            text: visible.text,
            speakers: visible.speakers.enumerated().map { index, speaker in
                MaterializedSpeakerSpan(
                    id: speaker.id, startMilliseconds: speaker.startMilliseconds,
                    endMilliseconds: speaker.endMilliseconds, confidence: index == 0 ? 0.55 : 0.65,
                    displayLabel: speaker.displayLabel
                )
            }, clauseState: visible.clauseState, clauseSlices: visible.clauseSlices,
            isDiarized: visible.isDiarized
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [confidenceChanged])
        try await controllerRequestBarrier(h)
        #expect(core.transcript?.revision == watchedRevision)
        #expect(core.readTranscript?.revision == readRevision)
        #expect(core.nextTranscriptRevision == nextRevision)
        let rowsAfterNoChange = try rowsPayloads(in: h, sessionID: sessionID)
        #expect(rowsAfterNoChange == rowsBaseline)

        let visibleDetailChange = try explicitSegment(
            id: confidenceChanged.segmentID, start: confidenceChanged.startMilliseconds,
            end: confidenceChanged.endMilliseconds, text: confidenceChanged.text,
            speakers: confidenceChanged.speakers.map {
                MaterializedSpeakerSpan(
                    id: $0.id, startMilliseconds: $0.startMilliseconds + 1,
                    endMilliseconds: $0.endMilliseconds + 1, confidence: $0.confidence,
                    displayLabel: $0.displayLabel == "Speaker 1" ? "Speaker 2" : "Speaker 1"
                )
            }, clauseState: confidenceChanged.clauseState,
            clauseSlices: confidenceChanged.clauseSlices, isDiarized: confidenceChanged.isDiarized
        )
        core.transcriptDidUpdate(sessionID: uuid, segments: [visibleDetailChange])
        let changedWatchCache = try #require(core.transcript)
        let changedReadCache = try #require(core.readTranscript)
        #expect(changedWatchCache.revision > watchedRevision)
        #expect(changedReadCache.revision > readRevision)
        #expect(core.nextTranscriptRevision > nextRevision)
        #expect(changedWatchCache.rows == seededWatchCache.rows)
        try await waitForRowsEvent(
            in: h, sessionID: sessionID, revision: changedWatchCache.revision, kind: .reloadRequired
        )
        try await controllerRequestBarrier(h)
        let rowsAfterDetailChange = try rowsPayloads(in: h, sessionID: sessionID)
        #expect(rowsAfterDetailChange.count == rowsBaseline.count + 1)
        #expect(rowsAfterDetailChange.last?.revision.value == changedWatchCache.revision)
        #expect(rowsAfterDetailChange.last?.kind == .reloadRequired)
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
        let firstDetailsPage = try await controllerRowDetails(
            h, detailsPayload(
                sessionID: watchedSessionID, revision: detailsRevision, rowID: watchedRow.rowID,
                cursor: nil, limit: 1
            )
        )
        let detailsCursor = try #require(firstDetailsPage.nextCursor)
        let detailsContinuationBefore = try await core.rowDetails(
            detailsPayload(
                sessionID: watchedSessionID, revision: detailsRevision, rowID: watchedRow.rowID,
                cursor: detailsCursor, limit: 1
            ), context: requestContext(for: h)
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
                sessionID: corruptTargetID, revision: staleRevision, rowID: "missing",
                cursor: nil, limit: 1
            ))
        )
        #expect(corruptError == .staleRevision)
        let validError = try await h.failureCode(
            of: "transcript.row_details",
            payload: try json(detailsPayload(
                sessionID: validTargetID, revision: staleRevision, rowID: "missing",
                cursor: nil, limit: 1
            ))
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
        let detailsContinuationAfter = try await core.rowDetails(
            detailsPayload(
                sessionID: watchedSessionID, revision: detailsRevision, rowID: watchedRow.rowID,
                cursor: detailsCursor, limit: 1
            ), context: requestContext(for: h)
        )
        #expect(detailsContinuationAfter.speakers == detailsContinuationBefore.speakers)
        #expect(detailsContinuationAfter.previousCursor == detailsContinuationBefore.previousCursor)
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
        id: "row-details-visible-nondiarized", start: 0, end: 100, text: "表示される発話",
        speakers: [
            MaterializedSpeakerSpan(
                id: "visible-speaker-a", startMilliseconds: 10, endMilliseconds: 40,
                confidence: 0.8, displayLabel: "Speaker 1"
            ),
            MaterializedSpeakerSpan(
                id: "visible-speaker-b", startMilliseconds: 50, endMilliseconds: 80,
                confidence: 0.7, displayLabel: "Speaker 2"
            )
        ], clauseState: .classified, clauseSlices: [], isDiarized: false
    )
}

@MainActor
private func prepared(_ root: URL) async throws -> ApplicationHarness {
    let h = ApplicationHarness(root: root)
    h.start()
    try await h.hello()
    try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
    try await h.callAcknowledgingResources("models.prepare")
    try await acknowledgeResourceWarning(h.app, workload: .live, context: try requestContext(for: h))
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
    sessionID: String, revision: EngineID, rowID: String, cursor: String?, limit: Int
) throws -> EngineTranscriptRowDetailsPayload {
    try EngineTranscriptRowDetailsPayload(
        sessionID: sessionID, revision: revision, rowID: rowID, cursor: cursor, limit: limit
    )
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

private func wireSpeakers(_ speakers: [MaterializedSpeakerSpan]) throws -> [EngineTranscriptSpeakerSpan] {
    try speakers.map {
        try EngineTranscriptSpeakerSpan(
            speakerID: $0.id, displayLabel: $0.displayLabel ?? $0.id,
            startMS: $0.startMilliseconds, endMS: $0.endMilliseconds
        )
    }
}

private func explicitSegment(
    id: String, start: Int64, end: Int64, text: String,
    speakers: [MaterializedSpeakerSpan], clauseState: TranscriptClauseState?,
    clauseSlices: [ClauseRowSlice], isDiarized: Bool
) throws -> MaterializedTranscriptSegment {
    let source = try SegmentTextReference(
        segmentationRunID: "row-details-test-seg", segmentID: id,
        asrRunID: "row-details-test-asr", asrEventSeq: 1
    )
    let projection = try TranscriptTextProjector().project(sourceText: text, fillerRanges: [])
    return try MaterializedTranscriptSegment(
        segmentID: id, source: source, startMilliseconds: start, endMilliseconds: end,
        text: text, textProjection: projection, speakers: speakers, clauseState: clauseState,
        clauseSlices: clauseSlices, isDiarized: isDiarized
    )
}

private func materializedClauseStateRows() throws -> [MaterializedTranscriptSegment] {
    let fixtures: [(String, String, TranscriptClauseState?)] = [
        ("state-boundary-pending", "境界保留です。", .boundaryPending),
        ("state-awaiting", "続き待ちです。", .awaitingNextSegment),
        ("state-priority", "優先度待ちです。", .priorityPending),
        ("state-classified", "判定済みです。", .classified),
        ("state-no-speakers", "話者なしです。", .classified),
        ("state-blank", "", nil)
    ]
    return try fixtures.enumerated().map { index, fixture in
        let (segmentID, text, expectedState) = fixture
        let segmentation = "seg-\(index)"
        let asr = "asr-\(index)"
        let boundary = "boundary-\(index)"
        let diarization = "diar-\(index)"
        let start = Int64(index * 1_000)
        var sourceEvents: [TranscriptEvent] = [
            .segmentCreated(seq: 1, segmentationRunID: segmentation, segmentID: segmentID,
                            startFrame: start, endFrame: start + 1_000),
            .asrCompleted(seq: 2, runID: asr, segmentationRunID: segmentation, segmentID: segmentID,
                          text: text, detectedLanguage: "ja")
        ]
        if index < 4 {
            sourceEvents.append(contentsOf: [
                .speakerSpan(seq: 3, runID: diarization, speakerID: "speaker-\(index)-a",
                             startFrame: start + 100, endFrame: start + 500, confidence: 0.9),
                .speakerSpan(seq: 4, runID: diarization, speakerID: "speaker-\(index)-b",
                             startFrame: start + 400, endFrame: start + 800, confidence: 0.8)
            ])
        }
        var events = sourceEvents
        let activeRuns = ActiveRuns(
            segmentation: segmentation, asr: asr, diarization: diarization,
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
