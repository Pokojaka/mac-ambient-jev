import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
import MacAmbientJevTestSupport

@testable import MacAmbientJevEngineHost

@MainActor
@Suite(.timeLimit(.minutes(10))) struct EngineApplicationTranscriptTests {
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

        try await h.sink.changes.wait("watched transcript change event") {
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

        await core.failureWorkerFinished()
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
        await core.failureWorkerFinished()
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
        await core.failureWorkerFinished()
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
        #expect(repairedCache.reportedTranscriptFailures.isEmpty)
        try await h.sink.changes.wait("large transcript reload event") {
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
        await core.failureWorkerFinished()
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

    @Test func oversizedRowsReportEveryFailingIdentityUntilEachIsRepaired() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let core = h.app.core
        _ = try await core.watch(
            EngineSessionPayload(sessionID: sessionID), context: requestContext(for: h)
        )
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        await drainTranscriptFailures(in: h)
        await h.transport.drain()

        let originalCache = try #require(core.transcript)
        let oversizedText = String(repeating: "\u{0001}", count: 60_000)
        let firstID = "oversized-transcript-first"
        let secondID = "oversized-transcript-second"
        let oversizedFirst = try materializedApplicationSegment(id: firstID, text: oversizedText)
        let oversizedSecond = try materializedApplicationSegment(id: secondID, text: oversizedText)
        let repairedFirst = try materializedApplicationSegment(id: firstID, text: "repaired first row")
        let repairedSecond = try materializedApplicationSegment(id: secondID, text: "repaired second row")
        let stableRow = try materializedApplicationSegment(id: "oversized-transcript-stable", text: "stable row")
        var segments = [oversizedFirst, repairedSecond, stableRow]

        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let outputsWithFirstFailure = try h.outputs
        let firstOversizedFailures = failureEvents(for: sessionID, in: outputsWithFirstFailure)
            .filter { $0.code == .rowTooLarge }
        #expect(firstOversizedFailures.count == 1)
        let firstFailure = try #require(firstOversizedFailures.first)
        #expect(firstFailure.message.contains(firstID))
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [firstID])
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        segments[1] = oversizedSecond
        for _ in 0..<30 {
            core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        }
        await drainTranscriptFailures(in: h)
        let outputsWithBothFailures = try h.outputs
        let oversizedFailures = failureEvents(for: sessionID, in: outputsWithBothFailures)
            .filter { $0.code == .rowTooLarge }
        #expect(oversizedFailures.count == 2)
        let secondFailure = try #require(oversizedFailures.last)
        #expect(secondFailure.message.contains(secondID))
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [firstID, secondID])
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        segments[0] = repairedFirst
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        #expect(failureEvents(for: sessionID, in: try h.outputs)
            .filter { $0.code == .rowTooLarge } == [firstFailure, secondFailure])
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [secondID])
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        segments[0] = oversizedFirst
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let failuresAfterReintroduction = failureEvents(for: sessionID, in: try h.outputs)
            .filter { $0.code == .rowTooLarge }
        #expect(failuresAfterReintroduction == [firstFailure, secondFailure, firstFailure])
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [firstID, secondID])
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        segments[0] = repairedFirst
        segments[1] = repairedSecond
        let expectedRows = try EngineTranscriptProjection.rows(for: segments)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        let repairedCache = try #require(core.transcript)
        #expect(repairedCache.revision > originalCache.revision)
        #expect(repairedCache.rows == expectedRows)
        #expect(repairedCache.reportedTranscriptFailures.isEmpty)
        await h.transport.drain()
        #expect(failureEvents(for: sessionID, in: try h.outputs)
            .filter { $0.code == .rowTooLarge } == [firstFailure, secondFailure, firstFailure])

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func mixedProjectionAndEncodingFailuresRetainSkippedMarkers() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let core = h.app.core
        _ = try await core.watch(
            EngineSessionPayload(sessionID: sessionID), context: requestContext(for: h)
        )
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        await drainTranscriptFailures(in: h)
        await h.transport.drain()

        let originalCache = try #require(core.transcript)
        let failuresBefore = failureEvents(for: sessionID, in: try h.outputs)
        let stateCountBefore = stateEventCount(in: try h.outputs)
        let oversizedID = "mixed-failure-oversized-A"
        let duplicateBID = "mixed-failure-duplicate-B"
        let duplicateCID = "mixed-failure-duplicate-C"
        let oversizedText = String(repeating: "\u{0001}", count: 60_000)
        let oversizedA = try materializedApplicationSegment(id: oversizedID, text: oversizedText)
        let repairedA = try materializedApplicationSegment(id: oversizedID, text: "repaired A")
        let duplicateBFirst = try materializedApplicationSegment(id: duplicateBID, text: "first B")
        let duplicateBSecond = try materializedApplicationSegment(id: duplicateBID, text: "second B")
        let duplicateCFirst = try materializedApplicationSegment(id: duplicateCID, text: "first C")
        let duplicateCSecond = try materializedApplicationSegment(id: duplicateCID, text: "second C")
        let unrelated = try materializedApplicationSegment(id: "mixed-failure-unrelated", text: "unrelated")
        let changedUnrelated = try materializedApplicationSegment(
            id: unrelated.segmentID, text: "changed unrelated"
        )

        var segments = [oversizedA, unrelated]
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let outputsWithOversizedA = try h.outputs
        let firstOversizedFailures = failureEvents(for: sessionID, in: outputsWithOversizedA)
            .filter { $0.code == .rowTooLarge }
        #expect(firstOversizedFailures.count == 1)
        let firstOversizedFailure = try #require(firstOversizedFailures.first)
        #expect(failureEvents(for: sessionID, in: outputsWithOversizedA)
            .filter { $0.code == .processingFailure }.isEmpty)
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [oversizedID])
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        segments = [oversizedA, duplicateBFirst, duplicateBSecond, unrelated]
        for _ in 0..<5 {
            core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        }
        await drainTranscriptFailures(in: h)
        let outputsWithDuplicateB = try h.outputs
        let oversizedFailuresWithB = failureEvents(for: sessionID, in: outputsWithDuplicateB)
            .filter { $0.code == .rowTooLarge }
        let projectionFailuresWithB = failureEvents(for: sessionID, in: outputsWithDuplicateB)
            .filter { $0.code == .processingFailure }
        #expect(oversizedFailuresWithB == [firstOversizedFailure])
        #expect(projectionFailuresWithB.count == 1)
        let firstDuplicateFailure = try #require(projectionFailuresWithB.first)
        #expect(firstDuplicateFailure.message.contains(duplicateBID))
        #expect(core.failures.filter { $0.sessionID == sessionID }
            == failuresBefore + [firstOversizedFailure, firstDuplicateFailure])
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [oversizedID, duplicateBID])
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)
        let stateCountAfterDuplicateB = stateEventCount(in: outputsWithDuplicateB)
        #expect(stateCountAfterDuplicateB == stateCountBefore + 2)

        for _ in 0..<5 {
            core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        }
        segments[3] = changedUnrelated
        for _ in 0..<5 {
            core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        }
        await drainTranscriptFailures(in: h)
        let outputsAfterMixedRepeats = try h.outputs
        #expect(failureEvents(for: sessionID, in: outputsAfterMixedRepeats)
            == [firstOversizedFailure, firstDuplicateFailure])
        #expect(core.failures.filter { $0.sessionID == sessionID }
            == failuresBefore + [firstOversizedFailure, firstDuplicateFailure])
        #expect(stateEventCount(in: outputsAfterMixedRepeats) == stateCountAfterDuplicateB)
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [oversizedID, duplicateBID])
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        segments = [oversizedA, duplicateBFirst, changedUnrelated]
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let outputsAfterRepairingB = try h.outputs
        #expect(failureEvents(for: sessionID, in: outputsAfterRepairingB)
            == [firstOversizedFailure, firstDuplicateFailure])
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [oversizedID])
        #expect(stateEventCount(in: outputsAfterRepairingB) == stateCountAfterDuplicateB)
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        segments = [oversizedA, duplicateBFirst, duplicateCFirst, duplicateCSecond, changedUnrelated]
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let outputsWithDuplicateC = try h.outputs
        let failuresWithDuplicateC = failureEvents(for: sessionID, in: outputsWithDuplicateC)
        #expect(failuresWithDuplicateC.filter { $0.code == .processingFailure }.count == 2)
        let duplicateCFailure = try #require(failuresWithDuplicateC.last)
        #expect(duplicateCFailure.message.contains(duplicateCID))
        #expect(failuresWithDuplicateC.filter { $0.code == .rowTooLarge } == [firstOversizedFailure])
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [oversizedID, duplicateCID])
        let stateCountWithDuplicateC = stateEventCount(in: outputsWithDuplicateC)
        #expect(stateCountWithDuplicateC == stateCountAfterDuplicateB + 1)
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        segments[0] = repairedA
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let outputsAfterRepairingA = try h.outputs
        #expect(failureEvents(for: sessionID, in: outputsAfterRepairingA)
            == [firstOversizedFailure, firstDuplicateFailure, duplicateCFailure])
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [duplicateCID])
        #expect(stateEventCount(in: outputsAfterRepairingA) == stateCountWithDuplicateC)
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        segments[0] = oversizedA
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let outputsAfterReintroducingA = try h.outputs
        let oversizedFailuresAfterReintroduction = failureEvents(for: sessionID, in: outputsAfterReintroducingA)
            .filter { $0.code == .rowTooLarge }
        #expect(oversizedFailuresAfterReintroduction == [firstOversizedFailure, firstOversizedFailure])
        #expect(failureEvents(for: sessionID, in: outputsAfterReintroducingA)
            .filter { $0.code == .processingFailure } == [firstDuplicateFailure, duplicateCFailure])
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [oversizedID, duplicateCID])
        #expect(stateEventCount(in: outputsAfterReintroducingA) == stateCountWithDuplicateC + 1)
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        // Delete A while B is failing; its marker must clear despite the rejected snapshot.
        segments = [duplicateBFirst, duplicateBSecond, unrelated]
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let outputsAfterDeletingA = try h.outputs
        let failuresAfterDeletingA = failureEvents(for: sessionID, in: outputsAfterDeletingA)
        #expect(failuresAfterDeletingA.filter { $0.code == .rowTooLarge }
            == [firstOversizedFailure, firstOversizedFailure])
        #expect(failuresAfterDeletingA.filter { $0.code == .processingFailure }
            == [firstDuplicateFailure, duplicateCFailure, firstDuplicateFailure])
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [duplicateBID])
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        segments = [oversizedA, duplicateBFirst, duplicateBSecond, unrelated]
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let outputsAfterReintroducingDeletedA = try h.outputs
        let finalOversizedFailures = failureEvents(for: sessionID, in: outputsAfterReintroducingDeletedA)
            .filter { $0.code == .rowTooLarge }
        #expect(finalOversizedFailures == [firstOversizedFailure, firstOversizedFailure, firstOversizedFailure])
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [oversizedID, duplicateBID])
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        segments = [repairedA, duplicateBFirst, unrelated]
        let expectedRows = try EngineTranscriptProjection.rows(for: segments)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        let repairedCache = try #require(core.transcript)
        #expect(repairedCache.revision > originalCache.revision)
        #expect(repairedCache.rows == expectedRows)
        #expect(repairedCache.reportedTranscriptFailures.isEmpty)
        await h.transport.drain()
        let finalFailures = failureEvents(for: sessionID, in: try h.outputs)
        #expect(finalFailures.filter { $0.code == .rowTooLarge }
            == [firstOversizedFailure, firstOversizedFailure, firstOversizedFailure])
        #expect(finalFailures.filter { $0.code == .processingFailure }
            == [firstDuplicateFailure, duplicateCFailure, firstDuplicateFailure])

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func skippedDiarizedValidationRetainsEncodingFailureMarker() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let core = h.app.core
        _ = try await core.watch(
            EngineSessionPayload(sessionID: sessionID), context: requestContext(for: h)
        )
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        await drainTranscriptFailures(in: h)
        await h.transport.drain()

        let originalCache = try #require(core.transcript)
        let oversizedID = "skipped-diarized-oversized-A"
        let duplicateID = "skipped-diarized-duplicate-B"
        let oversizedText = String(repeating: "\u{0001}", count: 60_000)
        let oversizedA = try materializedApplicationDiarizedSegment(
            id: oversizedID, text: oversizedText, start: 0, speakerID: "speaker-a"
        )
        let duplicateFirst = try materializedApplicationDiarizedSegment(
            id: duplicateID, text: "first B", start: 200, speakerID: "speaker-b"
        )
        let duplicateSecond = try materializedApplicationDiarizedSegment(
            id: duplicateID, text: "second B", start: 300, speakerID: "speaker-c"
        )

        var segments = [oversizedA]
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let outputsWithOversizedA = try h.outputs
        let oversizedFailures = failureEvents(for: sessionID, in: outputsWithOversizedA)
            .filter { $0.code == .rowTooLarge }
        #expect(oversizedFailures.count == 1)
        let firstOversizedFailure = try #require(oversizedFailures.first)
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [oversizedID])
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)
        let projection = try #require(core.transcript?.projection)
        let projectedBeforeUncertainContext = projection.totalProjectedSegments

        segments = [oversizedA, duplicateFirst, duplicateSecond]
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let outputsWithUncertainLabels = try h.outputs
        #expect(projection.totalProjectedSegments == projectedBeforeUncertainContext)
        #expect(failureEvents(for: sessionID, in: outputsWithUncertainLabels)
            .filter { $0.code == .rowTooLarge } == [firstOversizedFailure])
        let duplicateFailures = failureEvents(for: sessionID, in: outputsWithUncertainLabels)
            .filter { $0.code == .processingFailure }
        #expect(duplicateFailures.count == 1)
        let duplicateFailure = try #require(duplicateFailures.first)
        #expect(duplicateFailure.message.contains(duplicateID))
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [oversizedID, duplicateID])
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        segments = [oversizedA, duplicateFirst]
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let outputsAfterRepairingDuplicate = try h.outputs
        #expect(projection.totalProjectedSegments > projectedBeforeUncertainContext)
        #expect(failureEvents(for: sessionID, in: outputsAfterRepairingDuplicate)
            .filter { $0.code == .rowTooLarge } == [firstOversizedFailure])
        #expect(failureEvents(for: sessionID, in: outputsAfterRepairingDuplicate)
            .filter { $0.code == .processingFailure } == [duplicateFailure])
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == [oversizedID])
        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func transcriptFailureTrackingIsBoundedToTheFailureLimit() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let core = h.app.core
        _ = try await core.watch(
            EngineSessionPayload(sessionID: sessionID), context: requestContext(for: h)
        )
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        await drainTranscriptFailures(in: h)
        let originalCache = try #require(core.transcript)
        let failureCountBefore = failureEvents(for: sessionID, in: try h.outputs).count
        let limit = EngineApplicationCore.failureLimit

        var segments: [MaterializedTranscriptSegment] = []
        for index in 0...limit {
            let rowID = "bounded-failure-\(index)"
            segments.append(try materializedApplicationSegment(id: rowID, text: "first \(index)"))
            segments.append(try materializedApplicationSegment(id: rowID, text: "second \(index)"))
            core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
            await drainTranscriptFailures(in: h)
        }

        #expect(core.transcript?.revision == originalCache.revision)
        #expect(core.transcript?.rows == originalCache.rows)
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == (0..<limit).map { "bounded-failure-\($0)" })
        let outputsAfterAccumulation = try h.outputs
        #expect(failureEvents(for: sessionID, in: outputsAfterAccumulation).count == failureCountBefore + limit)

        let stateCountBeforeRepeat = stateEventCount(in: outputsAfterAccumulation)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let outputsAfterRepeat = try h.outputs
        #expect(failureEvents(for: sessionID, in: outputsAfterRepeat).count == failureCountBefore + limit)
        #expect(stateEventCount(in: outputsAfterRepeat) == stateCountBeforeRepeat)

        // Repairing the first failing row brings the next one within the limit, so it is reported.
        segments.remove(at: 1)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let failuresAfterRepair = failureEvents(for: sessionID, in: try h.outputs)
        #expect(failuresAfterRepair.count == failureCountBefore + limit + 1)
        #expect(failuresAfterRepair.last?.message.contains("bounded-failure-\(limit)") == true)
        #expect(core.transcript?.reportedTranscriptFailures.map(\.rowID) == (1...limit).map { "bounded-failure-\($0)" })

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

        try await h.sink.changes.wait("final transcript reload_required event") {
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
        let watchedPage = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: context)
        #expect(watchedPage.previousCursor == nil)
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
        #expect(firstPage.previousCursor == nil)
        let originalRevision = firstPage.revision
        let firstNextCursor = try #require(firstPage.nextCursor)

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
                sessionID: sessionID, revision: originalRevision, cursor: firstNextCursor, limit: 100
            ),
            context: context
        )
        #expect(secondOriginalPage.revision == originalRevision)
        #expect(secondOriginalPage.rows == Array(originalRows[100..<200]))
        let secondNextCursor = try #require(secondOriginalPage.nextCursor)
        #expect(secondNextCursor != firstNextCursor)
        #expect(secondOriginalPage.previousCursor != nil)
        let finalOriginalPage = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: originalRevision,
                cursor: secondNextCursor, limit: 100
            ),
            context: context
        )
        #expect(finalOriginalPage.revision == originalRevision)
        #expect(finalOriginalPage.rows == Array(originalRows[200..<205]))
        #expect(finalOriginalPage.nextCursor == nil)
        #expect(finalOriginalPage.previousCursor != nil)

        let refreshedPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 100),
            context: context
        )
        #expect(refreshedPage.revision.value == updatedCache.revision)
        #expect(refreshedPage.revision != originalRevision)
        #expect(refreshedPage.rows == Array(updatedRows.prefix(100)))
        let refreshedNextCursor = try #require(refreshedPage.nextCursor)

        do {
            _ = try await core.read(
                EngineTranscriptReadPayload(
                    sessionID: sessionID, revision: originalRevision, cursor: firstNextCursor, limit: 100
                ),
                context: context
            )
            Issue.record("the replaced snapshot revision must be stale")
        } catch let error as EngineCommandError {
            #expect(error.code == .staleRevision)
        } catch {
            Issue.record("expected stale_revision, got \(error)")
        }

        let otherWatchedPage = try await core.watch(
            EngineSessionPayload(sessionID: otherSessionID), context: context
        )
        #expect(otherWatchedPage.previousCursor == nil)
        let afterWatchChange = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: refreshedPage.revision,
                cursor: refreshedNextCursor, limit: 100
            ),
            context: context
        )
        #expect(afterWatchChange.revision == refreshedPage.revision)
        #expect(afterWatchChange.rows == Array(updatedRows[100..<200]))
        #expect(afterWatchChange.previousCursor != nil)
        let refreshedFinalCursor = try #require(afterWatchChange.nextCursor)
        let refreshedFinalPage = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: refreshedPage.revision,
                cursor: refreshedFinalCursor, limit: 100
            ),
            context: context
        )
        #expect(refreshedFinalPage.rows == Array(updatedRows[200..<205]))
        #expect(refreshedFinalPage.nextCursor == nil)

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func previousCursorsRetraceByteLimitedPagesAndInvalidateWithSnapshots() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let otherSessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let core = h.app.core
        let watchedPage = try await core.watch(
            EngineSessionPayload(sessionID: sessionID), context: context
        )
        #expect(watchedPage.previousCursor == nil)
        let sessionUUID = try #require(UUID(uuidString: sessionID))

        let textByteCounts = [220_000, 180_000, 240_000, 100_000, 220_000, 200_000,
                              230_000, 140_000, 210_000, 180_000, 120_000]
        let originalSegments = try textByteCounts.enumerated().map { index, byteCount in
            let character = String(UnicodeScalar(65 + index)!)
            return try materializedApplicationSegment(
                id: "byte-page-row-\(index)", text: String(repeating: character, count: byteCount)
            )
        }
        let originalRows = try EngineTranscriptProjection.rows(for: originalSegments)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: originalSegments)
        #expect(core.transcript?.rows == originalRows)

        let firstPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 200),
            context: context
        )
        let originalRevision = firstPage.revision
        #expect(firstPage.previousCursor == nil)
        var originalPages = [firstPage]
        var nextCursor = firstPage.nextCursor
        var distinctNextCursors: Set<String> = []
        if let nextCursor { #expect(distinctNextCursors.insert(nextCursor).inserted) }

        // Change the live cache after page one; the read navigation must retain its immutable rows.
        var updatedSegments = originalSegments
        updatedSegments[2] = try materializedApplicationSegment(
            id: "byte-page-row-2", text: String(repeating: "Z", count: 215_000)
        )
        updatedSegments.remove(at: 5)
        updatedSegments.append(try materializedApplicationSegment(
            id: "byte-page-row-appended", text: String(repeating: "Q", count: 140_000)
        ))
        let updatedRows = try EngineTranscriptProjection.rows(for: updatedSegments)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: updatedSegments)
        let updatedCache = try #require(core.transcript)
        #expect(updatedCache.revision > originalRevision.value)
        #expect(updatedCache.rows == updatedRows)

        for _ in 0..<20 {
            guard let cursor = nextCursor else { break }
            let page = try await core.read(
                EngineTranscriptReadPayload(
                    sessionID: sessionID, revision: originalRevision, cursor: cursor, limit: 200
                ),
                context: context
            )
            originalPages.append(page)
            #expect(page.revision == originalRevision)
            #expect(page.previousCursor != nil)
            if let returnedCursor = page.nextCursor {
                #expect(distinctNextCursors.insert(returnedCursor).inserted)
            }
            nextCursor = page.nextCursor
        }
        #expect(nextCursor == nil)
        #expect(originalPages.count >= 3)
        #expect(originalPages.first?.previousCursor == nil)
        #expect(originalPages.last?.nextCursor == nil)
        #expect(distinctNextCursors.count == originalPages.count - 1)
        #expect(originalPages.flatMap(\.rows) == originalRows)
        for page in originalPages {
            try expectPageFitsWire(page)
        }

        // Replay every returned cursor and compare the complete pages, including opaque tokens.
        let retainedFirstPageCursor = try #require(originalPages[1].previousCursor)
        for index in 0..<originalPages.count {
            let requestCursor: String
            if index == 0 {
                requestCursor = retainedFirstPageCursor
            } else {
                requestCursor = try #require(originalPages[index - 1].nextCursor)
            }
            let repeatedPage = try await core.read(
                EngineTranscriptReadPayload(
                    sessionID: sessionID, revision: originalRevision, cursor: requestCursor, limit: 200
                ),
                context: context
            )
            #expect(repeatedPage == originalPages[index])
        }

        // Follow previous_cursor from the tail to the first page, comparing rows and both tokens.
        var previousCursor: String? = try #require(originalPages.last?.previousCursor)
        for index in stride(from: originalPages.count - 2, through: 0, by: -1) {
            let cursor = try #require(previousCursor)
            let page = try await core.read(
                EngineTranscriptReadPayload(
                    sessionID: sessionID, revision: originalRevision, cursor: cursor, limit: 200
                ),
                context: context
            )
            let cachedPage = originalPages[index]
            #expect(page.rows == cachedPage.rows)
            #expect(page.revision == cachedPage.revision)
            #expect(page.previousCursor == cachedPage.previousCursor)
            #expect(page.nextCursor == cachedPage.nextCursor)
            previousCursor = page.previousCursor
        }
        #expect(previousCursor == nil)

        // Walking forward again from the first page must reproduce every cached page.
        var forwardCursor: String? = try #require(originalPages.first?.nextCursor)
        for index in 1..<originalPages.count {
            let cursor = try #require(forwardCursor)
            let page = try await core.read(
                EngineTranscriptReadPayload(
                    sessionID: sessionID, revision: originalRevision, cursor: cursor, limit: 200
                ),
                context: context
            )
            #expect(page == originalPages[index])
            forwardCursor = page.nextCursor
        }
        #expect(forwardCursor == nil)

        let firstNextCursor = try #require(originalPages.first?.nextCursor)
        let lastPreviousCursor = try #require(originalPages.last?.previousCursor)
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: originalRevision, cursor: "100", limit: 200,
            context: context, code: .invalidCursor
        )
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: originalRevision, cursor: "unknown-cursor-token", limit: 200,
            context: context, code: .invalidCursor
        )
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: originalRevision, cursor: firstNextCursor, limit: 199,
            context: context, code: .invalidCursor
        )
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: nil, cursor: firstNextCursor, limit: 200,
            context: context, code: .invalidCursor
        )
        do {
            _ = try await core.list(
                EngineSessionListPayload(cursor: firstNextCursor, limit: 100), context: context
            )
            Issue.record("a transcript cursor must not be accepted by session.list")
        } catch let error as EngineCommandError {
            #expect(error.code == .invalidCursor)
        } catch {
            Issue.record("expected invalid_cursor from session.list, got \(error)")
        }
        #expect(core.transcriptReadSnapshot?.rows == originalRows)

        let retainedRevisionRestart = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: originalRevision, cursor: nil, limit: 2
            ),
            context: context
        )
        #expect(retainedRevisionRestart.revision == originalRevision)
        #expect(retainedRevisionRestart.rows == Array(originalRows.prefix(2)))
        #expect(retainedRevisionRestart.previousCursor == nil)
        let retainedRevisionNextCursor = try #require(retainedRevisionRestart.nextCursor)
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: originalRevision,
            cursor: firstNextCursor, limit: 200, context: context, code: .invalidCursor
        )
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: originalRevision,
            cursor: lastPreviousCursor, limit: 200, context: context, code: .invalidCursor
        )
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: originalRevision,
            cursor: retainedRevisionNextCursor, limit: 1, context: context, code: .invalidCursor
        )

        let retainedRevisionSecondPage = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: originalRevision,
                cursor: retainedRevisionNextCursor, limit: 2
            ),
            context: context
        )
        #expect(retainedRevisionSecondPage.revision == originalRevision)
        #expect(retainedRevisionSecondPage.rows == Array(originalRows[2..<4]))
        let justUsedRetainedRevisionCursor = retainedRevisionNextCursor
        let sameRevisionRestart = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: originalRevision, cursor: nil, limit: 2
            ),
            context: context
        )
        #expect(sameRevisionRestart.revision == originalRevision)
        #expect(sameRevisionRestart.rows == Array(originalRows.prefix(2)))
        #expect(sameRevisionRestart.previousCursor == nil)
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: originalRevision,
            cursor: justUsedRetainedRevisionCursor, limit: 2, context: context, code: .invalidCursor
        )

        // A fresh first-page read for this same cache revision creates a new cursor namespace.
        let currentWatchedCache = try #require(core.transcript)
        let freshFirstPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 200),
            context: context
        )
        #expect(freshFirstPage.revision.value == currentWatchedCache.revision)
        #expect(freshFirstPage.revision != originalRevision)
        let freshNextCursor = try #require(freshFirstPage.nextCursor)
        #expect(freshNextCursor != firstNextCursor)
        #expect(freshNextCursor != lastPreviousCursor)
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: freshFirstPage.revision,
            cursor: firstNextCursor, limit: 200, context: context, code: .invalidCursor
        )
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: freshFirstPage.revision,
            cursor: lastPreviousCursor, limit: 200, context: context, code: .invalidCursor
        )

        // Watching another session has no previous cursor and leaves read navigation intact.
        let otherWatchedPage = try await core.watch(
            EngineSessionPayload(sessionID: otherSessionID), context: context
        )
        #expect(otherWatchedPage.previousCursor == nil)
        let freshSecondPage = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: freshFirstPage.revision,
                cursor: freshNextCursor, limit: 200
            ),
            context: context
        )
        #expect(freshSecondPage.revision == freshFirstPage.revision)
        #expect(freshSecondPage.rows == Array(updatedRows.dropFirst(freshFirstPage.rows.count).prefix(freshSecondPage.rows.count)))

        let otherSessionPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: otherSessionID, revision: nil, cursor: nil, limit: 200),
            context: context
        )
        try await expectTranscriptReadFailure(
            core, sessionID: otherSessionID, revision: otherSessionPage.revision,
            cursor: freshNextCursor, limit: 200, context: context, code: .invalidCursor
        )

        // Re-establish the large snapshot to verify publication invalidates both cursor directions.
        let restoredWatch = try await core.watch(
            EngineSessionPayload(sessionID: sessionID), context: context
        )
        #expect(restoredWatch.previousCursor == nil)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: originalSegments)
        #expect(core.transcript?.rows == originalRows)
        let publicationFirstPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 200),
            context: context
        )
        var publicationPages = [publicationFirstPage]
        var publicationNextCursor = publicationFirstPage.nextCursor
        for _ in 0..<20 {
            guard let cursor = publicationNextCursor else { break }
            let page = try await core.read(
                EngineTranscriptReadPayload(
                    sessionID: sessionID, revision: publicationFirstPage.revision,
                    cursor: cursor, limit: 200
                ),
                context: context
            )
            publicationPages.append(page)
            publicationNextCursor = page.nextCursor
        }
        #expect(publicationNextCursor == nil)
        #expect(publicationPages.count >= 3)
        for page in publicationPages {
            try expectPageFitsWire(page)
        }
        let publicationRevision = publicationFirstPage.revision
        let publicationNextToken = try #require(publicationFirstPage.nextCursor)
        let publicationPreviousToken = try #require(publicationPages.last?.previousCursor)
        #expect(publicationNextToken != publicationPreviousToken)

        core.transcriptDidPublish(sessionID: sessionUUID)
        let publishedCache = try #require(core.transcript)
        #expect(publishedCache.revision > publicationRevision.value)
        #expect(core.transcriptReadSnapshot == nil)
        let publishedRevision = try EngineID(publishedCache.revision)
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: publicationRevision,
            cursor: publicationNextToken, limit: 200, context: context, code: .staleRevision
        )
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: publicationRevision,
            cursor: publicationPreviousToken, limit: 200, context: context, code: .staleRevision
        )
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: publishedRevision,
            cursor: publicationNextToken, limit: 200, context: context, code: .invalidCursor
        )
        try await expectTranscriptReadFailure(
            core, sessionID: sessionID, revision: publishedRevision,
            cursor: publicationPreviousToken, limit: 200, context: context, code: .invalidCursor
        )

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    private func expectTranscriptReadFailure(
        _ core: EngineApplicationCore,
        sessionID: String,
        revision: EngineID?,
        cursor: String?,
        limit: Int,
        context: EngineRequestContext,
        code: EngineErrorCode
    ) async throws {
        let payload = try EngineTranscriptReadPayload(
            sessionID: sessionID, revision: revision, cursor: cursor, limit: limit
        )
        do {
            _ = try await core.read(payload, context: context)
            Issue.record("expected \(code.rawValue) for transcript read")
        } catch let error as EngineCommandError {
            #expect(error.code == code)
        } catch {
            Issue.record("expected \(code.rawValue), got \(error)")
        }
    }

    private func expectPageFitsWire(_ page: EngineTranscriptPage) throws {
        #expect(page.rows.count <= 200)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encodedRows = try encoder.encode(page.rows)
        #expect(encodedRows.count >= 2)
        #expect(encodedRows.count - 2 <= 700_000)
        for row in page.rows {
            let encodedRow = try encoder.encode(row)
            #expect(encodedRow.count <= EngineCodec.maxRowBytes)
        }
        let maximumID = try EngineID(UInt64.max)
        let output = try EngineOutput(
            version: 1, sequence: maximumID, requestID: maximumID,
            event: .completed(.transcriptRead(page))
        )
        let encodedOutput = try EngineCodec.encodeOutput(output)
        #expect(encodedOutput.count - 1 <= EngineJSONValidator.maxLineBytes)
    }

    private func drainTranscriptFailures(in h: ApplicationHarness) async {
        await h.app.core.failureWorkerFinished()
        await h.transport.drain()
    }

    private func failureEvents(for sessionID: String, in outputs: [EngineOutput]) -> [EngineFailure] {
        outputs.compactMap { output in
            guard case let .error(failure) = output.event, failure.sessionID == sessionID else { return nil }
            return failure
        }
    }

    private func stateEventCount(in outputs: [EngineOutput]) -> Int {
        outputs.filter { output in
            if case .state = output.event { return true }
            return false
        }.count
    }

    private func prepared(_ root: URL) async throws -> ApplicationHarness {
        let h = ApplicationHarness(root: root)
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        try await h.callAcknowledgingResources("models.prepare")
        try await acknowledgeResourceWarning(h.app, workload: .live, context: try requestContext(for: h))
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
        while true {
            let statesBefore = h.stateEventCount
            if try await h.sessions().contains(where: { $0.sessionID == sessionID && $0.status == .finalized }) {
                return
            }
            try await h.sink.changes.wait("session \(sessionID) to finalize") { h.stateEventCount > statesBefore }
        }
    }

    private func requestContext(for h: ApplicationHarness) throws -> EngineRequestContext {
        EngineRequestContext(
            requestID: try EngineID(10_000), events: EngineEventEmitter(transport: h.transport)
        )
    }
}

private func materializedApplicationDiarizedSegment(
    id: String, text: String, start: Int64, speakerID: String
) throws -> MaterializedTranscriptSegment {
    let source = try SegmentTextReference(
        segmentationRunID: "transcript-test-run", segmentID: id, asrRunID: "transcript-test-asr", asrEventSeq: 1
    )
    let projection = try TranscriptTextProjector().project(sourceText: text, fillerRanges: [])
    return try MaterializedTranscriptSegment(
        segmentID: id, source: source, startMilliseconds: start, endMilliseconds: start + 100,
        text: text, textProjection: projection,
        speakers: [MaterializedSpeakerSpan(
            id: speakerID, startMilliseconds: start, endMilliseconds: start + 100,
            confidence: 1, displayLabel: nil
        )],
        clauseState: .classified, clauseSlices: [], isDiarized: true
    )
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
