import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
@testable import MacAmbientJevPipeline
import MacAmbientJevTestSupport

@testable import MacAmbientJevEngineHost

private actor TranscriptSecondASRGate {
    private var entered = false
    private var released = false
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendSecondCall() async {
        guard !released else { return }
        entered = true
        entryContinuation?.resume()
        entryContinuation = nil
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { releaseContinuation = continuation }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryContinuation = $0 }
    }

    func release() {
        guard !released else { return }
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
        entryContinuation?.resume()
        entryContinuation = nil
    }
}

private actor TranscriptRecoveryMaintenanceGate {
    private var entered = false
    private var released = false
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func holdMaintenance() async {
        entered = true
        entryContinuation?.resume()
        entryContinuation = nil
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { releaseContinuation = continuation }
        }
    }

    func waitUntilHeld() async {
        if entered { return }
        await withCheckedContinuation { entryContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
        entryContinuation?.resume()
        entryContinuation = nil
    }
}

private struct TranscriptGatedASR: ASREngine {
    let calls: CallCounter
    let gate: TranscriptSecondASRGate
    let text: String
    let provenance = RunProvenance(engine: "transcript-gated-asr", model: nil, version: "test", configuration: [:])

    func prepare() async throws {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        calls.increment("asr")
        if calls.count("asr") == 2 { await gate.suspendSecondCall() }
        return ASRResult(text: text, detectedLanguage: "ja")
    }
    func unload() async { calls.increment("asr.unload") }
}

private struct InjectedMetadataSaveFailure: Error {}

private struct TranscriptMutableASR: ASREngine {
    let text: LockedBox<String>
    let provenance = RunProvenance(engine: "transcript-mutable-asr", model: nil, version: "test", configuration: [:])

    func prepare() async throws {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        ASRResult(text: text.get(), detectedLanguage: "ja")
    }
    func unload() async {}
}

private final class TranscriptMutableTextProvider: EngineInferenceProviding, @unchecked Sendable {
    let base = FakeInferenceProvider()
    let text: LockedBox<String>

    init(text: LockedBox<String>) {
        self.text = text
    }

    func prepare(settings: EngineSettings, onProgress: @escaping @Sendable (EngineModelProgress) -> Void) async throws {
        try await base.prepare(settings: settings, onProgress: onProgress)
    }

    func makeInference(settings: EngineSettings) throws -> EngineInference {
        _ = try base.makeInference(settings: settings)
        return EngineInference(
            engines: SessionProcessingEngines(
                asr: TranscriptMutableASR(text: text), sessionVAD: FakeFinalVAD(segmentCount: 2)
            ),
            contentPriority: .disabled,
            timelineBuilder: FakeTimelineBuilder(),
            makeLiveVADSession: { _, _, _, runID in FakeLiveVAD(segmentationRunID: runID) }
        )
    }

    func decisionUsage() async throws -> DecisionUsageSnapshot { try await base.decisionUsage() }
    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity { try await base.inspectClauseTagger() }
}

private final class TranscriptGenerationTestProvider: EngineInferenceProviding, @unchecked Sendable {
    let base = FakeInferenceProvider()
    let gate = TranscriptSecondASRGate()
    let transcriptText: String

    init(transcriptText: String) {
        self.transcriptText = transcriptText
    }

    func prepare(settings: EngineSettings, onProgress: @escaping @Sendable (EngineModelProgress) -> Void) async throws {
        try await base.prepare(settings: settings, onProgress: onProgress)
    }

    func makeInference(settings: EngineSettings) throws -> EngineInference {
        _ = try base.makeInference(settings: settings)
        return EngineInference(
            engines: SessionProcessingEngines(
                asr: TranscriptGatedASR(calls: base.calls, gate: gate, text: transcriptText),
                sessionVAD: FakeFinalVAD(segmentCount: 2)
            ),
            contentPriority: .disabled,
            timelineBuilder: FakeTimelineBuilder(),
            makeLiveVADSession: { _, _, _, runID in FakeLiveVAD(segmentationRunID: runID) }
        )
    }

    func decisionUsage() async throws -> DecisionUsageSnapshot { try await base.decisionUsage() }
    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity { try await base.inspectClauseTagger() }
}

private struct SilentTranscriptVAD: SessionVADSegmenter {
    let provenance = RunProvenance(engine: "silent-test-vad", model: nil, version: "test", configuration: [:])
    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] { [] }
}

private struct SilentTranscriptTimeline: ImportedAudioTimelineBuilding {
    func build(from sourceURL: URL, into processingDirectory: URL, sessionURL: URL) async throws -> AudioCheckpoint {
        let writer = try DurableAudioWriter(directory: processingDirectory, chunkDurationSeconds: 0.5, sessionURL: sessionURL)
        try await writer.append(samples: [Float](repeating: 0, count: 32_000))
        return try await writer.finish()
    }
}

private final class SilentTranscriptProvider: EngineInferenceProviding, @unchecked Sendable {
    let base = FakeInferenceProvider()
    func prepare(settings: EngineSettings, onProgress: @escaping @Sendable (EngineModelProgress) -> Void) async throws {
        try await base.prepare(settings: settings, onProgress: onProgress)
    }
    func makeInference(settings: EngineSettings) throws -> EngineInference {
        EngineInference(
            engines: SessionProcessingEngines(asr: FakeASR(calls: base.calls), sessionVAD: SilentTranscriptVAD()),
            contentPriority: .disabled, timelineBuilder: SilentTranscriptTimeline(),
            makeLiveVADSession: { _, _, _, runID in FakeLiveVAD(segmentationRunID: runID) }
        )
    }
    func decisionUsage() async throws -> DecisionUsageSnapshot { try await base.decisionUsage() }
    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity { try await base.inspectClauseTagger() }
}

@MainActor
@Suite(.timeLimit(.minutes(10))) struct EngineApplicationTranscriptTests {
    @Test func rewatchFinalizedSilenceKeepsFinalScreen() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = ApplicationHarness(root: root, provider: SilentTranscriptProvider())
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        await h.awaitModels()
        let audio = root.appending(path: "silence.wav")
        try Data("silence fixture".utf8).write(to: audio)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import", payload: String(decoding: try JSONEncoder().encode(EngineImportPayload(inputPath: audio.path)), as: UTF8.self)
        ) else { Issue.record("session.import did not return a session"); return }
        _ = try await h.waitForSession(status: .finalized)
        await h.app.core.processingCoordinator.waitUntilIdle()
        guard case let .transcriptWatch(page) = try await h.call(
            "transcript.watch", payload: "{\"session_id\":\"\(imported.sessionID)\"}"
        ) else { Issue.record("transcript.watch did not return a page"); return }
        #expect(page.rows.isEmpty)
        #expect(try await h.state().screen == .finalized)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

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

    @Test func failedOversizedWatchPreservesThePreviousWatchedSession() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriptText = LockedBox("通常の文字起こしです。")
        let provider = TranscriptMutableTextProvider(text: transcriptText)
        let h = try await prepared(root, provider: provider)
        let sessionA = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        _ = try await h.app.core.watch(EngineSessionPayload(sessionID: sessionA), context: context)
        let cacheA = try #require(h.app.core.transcript)

        transcriptText.set(String(repeating: "x", count: EngineCodec.maxRowBytes))
        let sessionB = try await recordAndFinalize(in: h)
        do {
            _ = try await h.app.core.watch(EngineSessionPayload(sessionID: sessionB), context: context)
            Issue.record("watching an oversized row must fail")
        } catch let error as EngineCommandError {
            #expect(error.code == .rowTooLarge)
            #expect(error.details.contains { $0.code == "row_too_large" })
        } catch {
            Issue.record("expected row_too_large, got \(error)")
        }

        #expect(h.app.core.watchedSessionID == UUID(uuidString: sessionA))
        #expect(h.app.core.transcript?.sessionID == cacheA.sessionID)
        #expect(h.app.core.transcript?.revision == cacheA.revision)
        let sessionAUUID = try #require(UUID(uuidString: sessionA))
        h.app.core.transcriptDidUpdate(sessionID: sessionAUUID, segments: [
            try materializedApplicationSegment(id: "after-failed-watch-A", text: "A は引き続き更新されます")
        ])
        try await h.sink.changes.wait("updates continue for the previously watched session") {
            ((try? h.outputs) ?? []).contains { output in
                guard case let .rows(payload) = output.event else { return false }
                return payload.sessionID == sessionA && payload.kind == .changes
                    && payload.rows.contains { $0.rowID == "after-failed-watch-A" }
            }
        }
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func recoveryClaimKeepsSavedTranscriptVisibleDuringAndAfterClaim() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        let recoveryGate = TranscriptRecoveryMaintenanceGate()
        let maintenance = SessionMaintenanceCandidate(
            sessionID: sessionUUID,
            sessionURL: URL(fileURLWithPath: "/recovery-transcript-test"),
            maintenance: .removeTransients
        )
        let recoveryTask = Task { @MainActor in
            await h.app.core.processingCoordinator.recoverPendingSessions(
                effects: h.app.core,
                scan: { SessionRecoveryScan(candidates: [], maintenance: [maintenance], failures: []) },
                maintain: { _, _ in
                    await recoveryGate.holdMaintenance()
                    return [:]
                }
            )
        }
        await recoveryGate.waitUntilHeld()

        let duringClaim = try await h.app.core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 50),
            context: context
        )
        #expect(!duringClaim.rows.isEmpty)

        await recoveryGate.release()
        await recoveryTask.value
        let afterClaim = try await h.app.core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: duringClaim.revision, cursor: nil, limit: 50
            ),
            context: context
        )
        #expect(afterClaim.revision == duringClaim.revision)
        #expect(afterClaim.rows == duringClaim.rows)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func firstOrdinaryGenerationNotifiesWatchedTranscriptBeforeRows() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = TranscriptGenerationTestProvider(transcriptText: "日本語のテストです。")
        let h = ApplicationHarness(root: root, provider: provider)
        provider.base.holdPrepare()
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)

        let audio = root.appending(path: "ordinary-generation.wav")
        try Data("fake wav".utf8).write(to: audio)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import", payload: "{\"input_path\":\(String(decoding: try JSONEncoder().encode(audio.path), as: UTF8.self))}"
        ) else {
            Issue.record("session.import did not return a session")
            return
        }
        guard case .transcriptWatch = try await h.call(
            "transcript.watch", payload: String(decoding: try JSONEncoder().encode(
                EngineSessionPayload(sessionID: imported.sessionID)
            ), as: UTF8.self)
        ) else {
            Issue.record("transcript.watch did not return its response")
            return
        }
        let sessionUUID = try #require(UUID(uuidString: imported.sessionID))
        #expect(h.app.core.transcript?.generationID == nil)
        guard case let .transcriptRead(beforeGeneration) = try await h.call(
            "transcript.read",
            payload: String(decoding: try JSONEncoder().encode(EngineTranscriptReadPayload(
                sessionID: imported.sessionID, revision: nil, cursor: nil, limit: 200
            )), as: UTF8.self)
        ) else {
            Issue.record("transcript.read did not return its pre-generation snapshot")
            _ = try await h.shutdown()
            return
        }
        #expect(beforeGeneration.rows.isEmpty)

        provider.base.releasePrepare()
        await h.awaitModels()
        await provider.gate.waitUntilEntered()
        try await h.sink.changes.wait("rows for the initial ordinary generation") {
            ((try? h.outputs) ?? []).contains { output in
                guard case let .rows(payload) = output.event else { return false }
                return payload.sessionID == imported.sessionID && !payload.rows.isEmpty
            }
        }
        guard case let .transcriptRead(page) = try await h.call(
            "transcript.read",
            payload: String(decoding: try JSONEncoder().encode(EngineTranscriptReadPayload(
                sessionID: imported.sessionID, revision: nil, cursor: nil, limit: 200
            )), as: UTF8.self)
        ) else {
            Issue.record("transcript.read did not return rows from the new generation")
            _ = try await h.shutdown()
            return
        }
        guard let row = page.rows.first else {
            Issue.record("fresh generation transcript was unexpectedly empty")
            _ = try await h.shutdown()
            return
        }
        let detailsPayload = try EngineTranscriptRowDetailsPayload(
            sessionID: imported.sessionID, revision: page.revision, rowID: row.rowID
        )
        do {
            guard case .transcriptRowDetails = try await h.call(
                "transcript.row_details",
                payload: String(decoding: try JSONEncoder().encode(detailsPayload), as: UTF8.self)
            ) else {
                Issue.record("fresh generation row details were rejected")
                _ = try await h.shutdown()
                return
            }
        } catch {
            Issue.record("fresh generation row details were rejected: \(error)")
            _ = try await h.shutdown()
            return
        }
        let layout = SessionLayout(sessionURL: try await h.app.core.readableSession(sessionUUID).sessionURL)
        let generationID = try #require(try ProcessingLogState(
            eventsURL: layout.eventsURL, sessionID: sessionUUID
        )?.generation.id)
        #expect(h.app.core.transcript?.generationID == generationID)
        await provider.gate.release()
        _ = try await h.waitForSession(status: .finalized)
        _ = try await h.shutdown()
    }

    @Test func firstWatchRebuildsAfterReprocessChangesGenerationDuringDurableLookup() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        let session = try await h.app.core.readableSession(sessionUUID)
        let eventsURL = SessionLayout(sessionURL: session.sessionURL).eventsURL
        let generationBeforeReprocess = try #require(try ProcessingLogState(
            eventsURL: eventsURL, sessionID: sessionUUID
        )?.generation.id)

        let lookupGate = h.transcriptGenerationLookupGate
        await lookupGate.arm()
        defer { Task { await lookupGate.release() } }
        let watchPayload = try EngineSessionPayload(sessionID: sessionID)
        let encodedWatchPayload = String(decoding: try JSONEncoder().encode(watchPayload), as: UTF8.self)
        let watchTask = Task { @MainActor in
            try await h.call("transcript.watch", payload: encodedWatchPayload)
        }
        await lookupGate.waitUntilSuspended()

        guard case .sessionReprocess = try await h.call(
            "session.reprocess", payload: encodedWatchPayload
        ) else {
            Issue.record("session.reprocess did not return its session")
            await lookupGate.release()
            return
        }
        let generationAfterReprocess = try #require(try ProcessingLogState(
            eventsURL: eventsURL, sessionID: sessionUUID
        )?.generation.id)
        #expect(generationAfterReprocess != generationBeforeReprocess)
        await lookupGate.release()

        guard case let .transcriptWatch(page) = try await watchTask.value else {
            Issue.record("transcript.watch did not return its page")
            _ = try await h.shutdown()
            return
        }
        guard case let .segments(savedGenerationID, savedSegments) = try SavedTranscriptLoader.load(
            sessionURL: session.sessionURL
        ) else {
            Issue.record("saved transcript was unavailable after reprocess")
            _ = try await h.shutdown()
            return
        }
        let cache = try #require(h.app.core.transcript)
        #expect(savedGenerationID == generationAfterReprocess)
        #expect(cache.generationID == savedGenerationID)
        #expect(cache.materializedSegments == savedSegments)
        #expect(cache.rows == page.rows)
        let row = try #require(page.rows.first)
        let detailsPayload = try EngineTranscriptRowDetailsPayload(
            sessionID: sessionID, revision: page.revision, rowID: row.rowID
        )
        guard case .transcriptRowDetails = try await h.call(
            "transcript.row_details",
            payload: String(decoding: try JSONEncoder().encode(detailsPayload), as: UTF8.self)
        ) else {
            Issue.record("row details rejected the first watch revision")
            _ = try await h.shutdown()
            return
        }
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func freshReadRestartsWhenPublicationReplacesItsRevisionDuringDurableLookup() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let core = h.app.core
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        let previousPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 200),
            context: context
        )

        let lookupGate = h.transcriptGenerationLookupGate
        await lookupGate.arm(skippingCalls: 1)
        defer { Task { await lookupGate.release() } }
        let freshRead = Task { @MainActor in
            try await core.read(
                EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 200),
                context: context
            )
        }
        await lookupGate.waitUntilSuspended()

        await core.transcriptDidPublish(sessionID: sessionUUID)
        let publishedCache = try #require(core.readTranscript)
        #expect(publishedCache.revision > previousPage.revision.value)
        await lookupGate.release()

        let restartedPage = try await freshRead.value
        #expect(restartedPage.revision.value == publishedCache.revision)
        #expect(restartedPage.revision != previousPage.revision)
        #expect(restartedPage.rows == publishedCache.rows)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func freshReadKeepsItsOwnCacheWhenAnotherSessionReadsDuringDurableLookup() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionA = try await recordAndFinalize(in: h)
        let sessionB = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let core = h.app.core
        let sessionAUUID = try #require(UUID(uuidString: sessionA))
        let sessionBUUID = try #require(UUID(uuidString: sessionB))
        let lookupGate = h.transcriptGenerationLookupGate
        await lookupGate.arm(skippingCalls: 1)
        defer { Task { await lookupGate.release() } }

        let readA = Task { @MainActor in
            try await core.read(
                EngineTranscriptReadPayload(sessionID: sessionA, revision: nil, cursor: nil, limit: 200),
                context: context
            )
        }
        await lookupGate.waitUntilSuspended()
        let expectedRowsA = try #require(core.readTranscript)
        #expect(expectedRowsA.sessionID == sessionAUUID)

        let pageB = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionB, revision: nil, cursor: nil, limit: 200),
            context: context
        )
        #expect(pageB.sessionID == sessionB)
        #expect(core.readTranscript?.sessionID == sessionBUUID)

        await lookupGate.release()
        let pageA = try await readA.value
        #expect(pageA.sessionID == sessionA)
        #expect(pageA.rows == expectedRowsA.rows)
        #expect(!pageA.rows.isEmpty)
        #expect(core.transcriptReadSnapshot?.sessionID == sessionAUUID)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func retainedRevisionRestartRacingFirstPageReturnsUsableCursor() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = TranscriptGenerationTestProvider(transcriptText: "日本語のテストです。")
        await provider.gate.release()
        let h = try await prepared(root, provider: provider)
        let sessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let core = h.app.core
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        _ = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: context)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: [
            try materializedApplicationSegment(id: "restart-row-1", text: "最初の行"),
            try materializedApplicationSegment(id: "restart-row-2", text: "次の行"),
        ])
        let firstPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 1),
            context: context
        )
        let firstCursor = try #require(firstPage.nextCursor)

        let lookupGate = h.transcriptGenerationLookupGate
        await lookupGate.arm(skippingCalls: 1)
        defer { Task { await lookupGate.release() } }
        let restart = Task { @MainActor in
            try await core.read(
                EngineTranscriptReadPayload(
                    sessionID: sessionID, revision: firstPage.revision, cursor: nil, limit: 1
                ),
                context: context
            )
        }
        await lookupGate.waitUntilSuspended()
        let racingFirstPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 1),
            context: context
        )
        #expect(racingFirstPage.nextCursor != nil)

        await lookupGate.release()
        let restartedPage = try await restart.value
        #expect(restartedPage.revision == firstPage.revision)
        #expect(restartedPage.nextCursor != nil)
        let nextPage = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: restartedPage.revision,
                cursor: try #require(restartedPage.nextCursor), limit: 1
            ),
            context: context
        )
        #expect(nextPage.rows.first?.rowID != restartedPage.rows.first?.rowID)
        #expect(nextPage.rows.first?.rowID != nil)
        #expect(firstCursor != restartedPage.nextCursor)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func failedRetainedRevisionRestartPreservesInstalledCursors() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = TranscriptGenerationTestProvider(transcriptText: "日本語のテストです。")
        await provider.gate.release()
        let h = try await prepared(root, provider: provider)
        let sessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let core = h.app.core
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        _ = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: context)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: [
            try materializedApplicationSegment(id: "retained-row-1", text: "最初の行"),
            try materializedApplicationSegment(id: "retained-row-2", text: "二番目の行"),
        ])
        let firstPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 1),
            context: context
        )
        let oldNextCursor = try #require(firstPage.nextCursor)
        let originalSnapshot = try #require(core.transcriptReadSnapshot)
        var oversizedSnapshot = originalSnapshot
        oversizedSnapshot.rows[1] = try EngineTranscriptRow(
            rowID: "retained-row-2", startMS: 0, endMS: 1,
            text: String(repeating: "x", count: EngineCodec.maxRowBytes), clauseState: .classified
        )
        core.transcriptReadSnapshot = oversizedSnapshot
        do {
            _ = try await core.read(
                EngineTranscriptReadPayload(
                    sessionID: sessionID, revision: firstPage.revision, cursor: nil, limit: 2
                ),
                context: context
            )
            Issue.record("oversized retained-revision restart must fail")
        } catch let error as EngineCommandError {
            #expect(error.code == .rowTooLarge)
        } catch {
            Issue.record("expected row_too_large, got \(error)")
        }
        core.transcriptReadSnapshot = originalSnapshot

        let previousPage = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: sessionID, revision: firstPage.revision, cursor: oldNextCursor, limit: 1
            ),
            context: context
        )
        #expect(previousPage.rows.first?.rowID == "retained-row-2")
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func continuationBecomesStaleWhenReplacementSelectsGenerationDuringLookup() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = TranscriptGenerationTestProvider(transcriptText: "日本語のテストです。")
        await provider.gate.release()
        let h = try await prepared(root, provider: provider)
        let sessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        _ = try await h.app.core.watch(EngineSessionPayload(sessionID: sessionID), context: context)
        h.app.core.transcriptDidUpdate(sessionID: sessionUUID, segments: [
            try materializedApplicationSegment(id: "replacement-row-1", text: "最初の行"),
            try materializedApplicationSegment(id: "replacement-row-2", text: "次の行"),
        ])
        let firstPage = try await h.app.core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 1),
            context: context
        )
        let cursor = try #require(firstPage.nextCursor)

        let lookupGate = h.transcriptGenerationLookupGate
        await lookupGate.arm(skippingCalls: 1)
        defer { Task { await lookupGate.release() } }
        let continuation = Task { @MainActor in
            try await h.app.core.read(
                EngineTranscriptReadPayload(
                    sessionID: sessionID, revision: firstPage.revision, cursor: cursor, limit: 1
                ),
                context: context
            )
        }
        await lookupGate.waitUntilSuspended()
        guard case .sessionReprocess = try await h.call(
            "session.reprocess", payload: "{\"session_id\":\"\(sessionID)\"}"
        ) else {
            Issue.record("session.reprocess did not return its session")
            await lookupGate.release()
            return
        }
        await lookupGate.release()
        do {
            _ = try await continuation.value
            Issue.record("continuation after generation replacement must be stale")
        } catch let error as EngineCommandError {
            #expect(error.code == .staleRevision)
        } catch {
            Issue.record("expected stale_revision, got \(error)")
        }
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func continuationReadRejectsNavigationReplacedDuringDurableLookupThroughRPC() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = TranscriptGenerationTestProvider(transcriptText: "日本語のテストです。")
        await provider.gate.release()
        let h = try await prepared(root, provider: provider)
        let sessionID = try await recordAndFinalize(in: h)
        let setupPayload = try EngineTranscriptReadPayload(
            sessionID: sessionID, revision: nil, cursor: nil, limit: 200
        )
        _ = try await h.call(
            "transcript.read", payload: String(decoding: try JSONEncoder().encode(setupPayload), as: UTF8.self)
        )
        h.app.core.transcriptDidUpdate(
            sessionID: try #require(UUID(uuidString: sessionID)),
            segments: [
                try materializedApplicationSegment(id: "navigation-row-1", text: "first page"),
                try materializedApplicationSegment(id: "navigation-row-2", text: "second page"),
            ]
        )

        let firstPayload = try EngineTranscriptReadPayload(
            sessionID: sessionID, revision: nil, cursor: nil, limit: 1
        )
        let firstJSON = String(decoding: try JSONEncoder().encode(firstPayload), as: UTF8.self)
        guard case let .transcriptRead(firstPage) = try await h.call("transcript.read", payload: firstJSON) else {
            Issue.record("transcript.read did not return the initial page")
            _ = try await h.shutdown()
            return
        }
        let oldCursor = try #require(firstPage.nextCursor)

        let lookupGate = h.transcriptGenerationLookupGate
        await lookupGate.arm(skippingCalls: 1)
        let continuationPayload = try EngineTranscriptReadPayload(
            sessionID: sessionID, revision: firstPage.revision, cursor: oldCursor, limit: 1
        )
        let continuationJSON = String(decoding: try JSONEncoder().encode(continuationPayload), as: UTF8.self)
        let continuation = Task { @MainActor in
            try await h.call("transcript.read", payload: continuationJSON)
        }
        await lookupGate.waitUntilSuspended()

        let resetPayload = try EngineTranscriptReadPayload(
            sessionID: sessionID, revision: nil, cursor: nil, limit: 1
        )
        let resetJSON = String(decoding: try JSONEncoder().encode(resetPayload), as: UTF8.self)
        guard case let .transcriptRead(resetPage) = try await h.call("transcript.read", payload: resetJSON) else {
            Issue.record("transcript.read did not return the replacement first page")
            await lookupGate.release()
            _ = try await h.shutdown()
            return
        }
        let resetNextCursor = try #require(resetPage.nextCursor)

        await lookupGate.release()
        do {
            _ = try await continuation.value
            Issue.record("continuation using replaced navigation must fail")
        } catch let error as CommandFailure {
            #expect(error.failure.code == .invalidCursor)
            #expect(error.failure.message == "cursor に対応する文字起こし snapshot がありません")
        } catch {
            Issue.record("expected invalid_cursor, got \(error)")
        }

        let nextPayload = try EngineTranscriptReadPayload(
            sessionID: sessionID, revision: resetPage.revision, cursor: resetNextCursor, limit: 1
        )
        let nextJSON = String(decoding: try JSONEncoder().encode(nextPayload), as: UTF8.self)
        guard case let .transcriptRead(nextPage) = try await h.call("transcript.read", payload: nextJSON) else {
            Issue.record("the replacement first page's next cursor was rejected")
            _ = try await h.shutdown()
            return
        }
        #expect(nextPage.rows.first?.rowID != resetPage.rows.first?.rowID)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func transcriptReadRebuildsAfterFinalizationDuringGenerationLookup() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = TranscriptGenerationTestProvider(transcriptText: "日本語のテストです。")
        let h = try await prepared(root, provider: provider)
        let lookupGate = h.transcriptGenerationLookupGate
        let exportGate = h.sessionBundleExportGate
        await lookupGate.arm()
        await exportGate.arm()
        defer {
            Task {
                await lookupGate.release()
                await exportGate.release()
                await provider.gate.release()
            }
        }
        let exportPath = root.appending(path: "finalization-race-export", directoryHint: .isDirectory)
        try await h.replaceSettings(
            engineTestSettings(automaticExport: true, exportPath: exportPath.path), expectedRevision: 1
        )

        let audio = root.appending(path: "transcript-finalization-race.wav")
        try Data("fake wav".utf8).write(to: audio)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import",
            payload: String(decoding: try JSONEncoder().encode(EngineImportPayload(inputPath: audio.path)), as: UTF8.self)
        ) else {
            Issue.record("session.import did not return a session")
            return
        }
        await provider.gate.waitUntilEntered()

        let readPayload = try EngineTranscriptReadPayload(
            sessionID: imported.sessionID, revision: nil, cursor: nil, limit: 200
        )
        let encodedReadPayload = String(decoding: try JSONEncoder().encode(readPayload), as: UTF8.self)
        let firstReadTask = Task { @MainActor in
            try await h.call("transcript.read", payload: encodedReadPayload)
        }
        await lookupGate.waitUntilSuspended()

        await provider.gate.release()
        await exportGate.waitUntilSuspended()
        await lookupGate.release()

        guard case let .transcriptRead(firstPage) = try await firstReadTask.value else {
            Issue.record("transcript.read did not return its first page")
            return
        }
        #expect(!firstPage.rows.isEmpty)
        #expect(firstPage.rows.contains { $0.text == "日本語のテストです。" })

        await exportGate.release()
        _ = try await h.waitForSession(status: .finalized)
        guard case let .transcriptRead(secondPage) = try await h.call(
            "transcript.read", payload: encodedReadPayload
        ) else {
            Issue.record("idle transcript.read did not return its page")
            return
        }
        #expect(!secondPage.rows.isEmpty)
        #expect(secondPage.rows == firstPage.rows)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func metadataSaveFailureAfterGenerationAppendRejectsOldCursorsAndDetails() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let failMetadataSave = LockedBox(false)
        let injectedSaveFailures = LockedBox(0)
        let h = ApplicationHarness(root: root, saveProcessingMetadata: { sessionURL, metadata in
            if failMetadataSave.get() {
                injectedSaveFailures.set(injectedSaveFailures.get() + 1)
                throw InjectedMetadataSaveFailure()
            }
            try ProcessingMetadataStore(sessionURL: sessionURL).save(metadata)
        })
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        await h.awaitModels()
        let sessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let core = h.app.core
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        _ = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: context)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: [
            try materializedApplicationSegment(id: "old-row-1", text: "old first"),
            try materializedApplicationSegment(id: "old-row-2", text: "old second")
        ])
        let oldPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 1),
            context: context
        )
        let oldCursor = try #require(oldPage.nextCursor)
        let oldRow = try #require(oldPage.rows.first)
        _ = try await core.rowDetails(
            EngineTranscriptRowDetailsPayload(
                sessionID: sessionID, revision: oldPage.revision, rowID: oldRow.rowID
            ),
            context: context
        )

        let session = try await core.readableSession(sessionUUID)
        let layout = SessionLayout(sessionURL: session.sessionURL)
        let oldGenerationID = try #require(try ProcessingLogState(
            eventsURL: layout.eventsURL, sessionID: sessionUUID
        )?.generation.id)
        #expect(try ProcessingMetadataStore(sessionURL: session.sessionURL).load()?.generationID == oldGenerationID)
        failMetadataSave.set(true)
        let failureCode = try await h.failureCode(
            of: "session.reprocess", payload: "{\"session_id\":\"\(sessionID)\"}"
        )
        #expect(failureCode == .processingFailure)
        #expect(injectedSaveFailures.get() > 0)
        let state = try #require(try ProcessingLogState(eventsURL: layout.eventsURL, sessionID: sessionUUID))
        #expect(state.generation.id != oldGenerationID)
        let metadataAfterFailure = try #require(
            try ProcessingMetadataStore(sessionURL: session.sessionURL).load()
        )
        #expect(metadataAfterFailure.generationID == state.generation.id)
        #expect(metadataAfterFailure.state == .failed)

        let readPayload = try EngineTranscriptReadPayload(
            sessionID: sessionID, revision: oldPage.revision, cursor: oldCursor, limit: 1
        )
        #expect(try await h.failureCode(
            of: "transcript.read", payload: String(decoding: try JSONEncoder().encode(readPayload), as: UTF8.self)
        ) == .staleRevision)
        let detailsPayload = try EngineTranscriptRowDetailsPayload(
            sessionID: sessionID, revision: oldPage.revision, rowID: oldRow.rowID
        )
        #expect(try await h.failureCode(
            of: "transcript.row_details",
            payload: String(decoding: try JSONEncoder().encode(detailsPayload), as: UTF8.self)
        ) == .staleRevision)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func durableGenerationRejectsOldWireRevisionBeforeMainActorInvalidation() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let core = h.app.core
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        _ = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: context)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: [
            try materializedApplicationSegment(id: "interval-row-1", text: "first"),
            try materializedApplicationSegment(id: "interval-row-2", text: "second")
        ])
        let firstRead = try EngineTranscriptReadPayload(
            sessionID: sessionID, revision: nil, cursor: nil, limit: 1
        )
        guard case let .transcriptRead(oldPage) = try await h.call(
            "transcript.read", payload: String(decoding: try JSONEncoder().encode(firstRead), as: UTF8.self)
        ) else {
            Issue.record("transcript.read did not return the original page")
            return
        }
        let oldCursor = try #require(oldPage.nextCursor)
        let oldRow = try #require(oldPage.rows.first)
        let detailsPayload = try EngineTranscriptRowDetailsPayload(
            sessionID: sessionID, revision: oldPage.revision, rowID: oldRow.rowID
        )
        guard case .transcriptRowDetails = try await h.call(
            "transcript.row_details", payload: String(decoding: try JSONEncoder().encode(detailsPayload), as: UTF8.self)
        ) else {
            Issue.record("transcript.row_details did not return details")
            return
        }

        let session = try await core.readableSession(sessionUUID)
        let layout = SessionLayout(sessionURL: session.sessionURL)
        let previousGenerationID = try #require(try ProcessingLogState(
            eventsURL: layout.eventsURL, sessionID: sessionUUID
        )?.generation.id)
        let provenance = RunProvenance(
            engine: "durable-generation-race-test", model: nil, version: "1", configuration: [:]
        )
        let generation = PipelineGeneration(
            id: UUID(), runs: ActiveRuns(segmentation: "race-seg", asr: "race-asr"),
            sampleRate: CanonicalAudio.sampleRate,
            segmentationProvenance: provenance, asrProvenance: provenance
        )
        try await SessionWriter(sessionURL: session.sessionURL).append(generation.startEvent(sessionID: sessionUUID))
        #expect(generation.id != previousGenerationID)

        let oldRevisionRead = try EngineTranscriptReadPayload(
            sessionID: sessionID, revision: oldPage.revision, cursor: oldCursor, limit: 1
        )
        #expect(try await h.failureCode(
            of: "transcript.read",
            payload: String(decoding: try JSONEncoder().encode(oldRevisionRead), as: UTF8.self)
        ) == .staleRevision)
        #expect(try await h.failureCode(
            of: "transcript.row_details",
            payload: String(decoding: try JSONEncoder().encode(detailsPayload), as: UTF8.self)
        ) == .staleRevision)
        _ = try await h.shutdown()
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

    @Test func skippedDuplicateProjectionRetainsEncodingFailureMarker() async throws {
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
        let oversizedID = "duplicate-projection-oversized-A"
        let duplicateID = "duplicate-projection-B"
        let oversizedText = String(repeating: "\u{0001}", count: 60_000)
        let oversizedA = try materializedApplicationSegment(id: oversizedID, text: oversizedText)
        let duplicateFirst = try materializedApplicationSegment(id: duplicateID, text: "first B")
        let duplicateSecond = try materializedApplicationSegment(id: duplicateID, text: "second B")

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
        let projectedBeforeDuplicates = projection.totalProjectedSegments

        segments = [oversizedA, duplicateFirst, duplicateSecond]
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: segments)
        await drainTranscriptFailures(in: h)
        let outputsWithDuplicates = try h.outputs
        #expect(projection.totalProjectedSegments == projectedBeforeDuplicates)
        #expect(failureEvents(for: sessionID, in: outputsWithDuplicates)
            .filter { $0.code == .rowTooLarge } == [firstOversizedFailure])
        let duplicateFailures = failureEvents(for: sessionID, in: outputsWithDuplicates)
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
        #expect(projection.totalProjectedSegments > projectedBeforeDuplicates)
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

        await core.transcriptDidPublish(sessionID: try #require(UUID(uuidString: sessionID)))

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

    @Test func publicationClearsReadSnapshotCreatedDuringCatalogLookup() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionID = try await recordAndFinalize(in: h)
        let otherSessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let core = h.app.core
        _ = try await core.watch(EngineSessionPayload(sessionID: sessionID), context: context)
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        #expect(core.readTranscript == nil)
        core.transcriptDidUpdate(sessionID: sessionUUID, segments: [
            try materializedApplicationSegment(id: "publication-race-row-1", text: "最初の行"),
            try materializedApplicationSegment(id: "publication-race-row-2", text: "次の行"),
        ])

        let catalogGate = h.sessionCatalogLookupGate
        await catalogGate.arm()
        core.savedSessionsAreStale = true
        let publication = Task { @MainActor in
            await core.transcriptDidPublish(sessionID: sessionUUID)
        }
        await catalogGate.waitUntilSuspended()

        let freshPage = try await core.read(
            EngineTranscriptReadPayload(sessionID: sessionID, revision: nil, cursor: nil, limit: 1),
            context: context
        )
        let cursor = try #require(freshPage.nextCursor)
        #expect(core.transcriptReadSnapshot?.revision == freshPage.revision.value)

        let otherPage = try await core.watch(
            EngineSessionPayload(sessionID: otherSessionID), context: context
        )
        #expect(otherPage.sessionID == otherSessionID)
        await catalogGate.release()
        await publication.value
        do {
            _ = try await core.read(
                EngineTranscriptReadPayload(
                    sessionID: sessionID, revision: freshPage.revision, cursor: cursor, limit: 1
                ),
                context: context
            )
            Issue.record("a read snapshot created during publication must be stale")
        } catch let error as EngineCommandError {
            #expect(error.code == .staleRevision)
        } catch {
            Issue.record("expected stale_revision, got \(error)")
        }

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func publicationUpdatesWatchedCacheAfterAnUnrelatedReadReplacesReadCache() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let watchedSessionID = try await recordAndFinalize(in: h)
        let unrelatedSessionID = try await recordAndFinalize(in: h)
        let context = try requestContext(for: h)
        let priorPage = try await h.app.core.read(
            EngineTranscriptReadPayload(
                sessionID: watchedSessionID, revision: nil, cursor: nil, limit: 50
            ),
            context: context
        )
        _ = try await h.app.core.watch(EngineSessionPayload(sessionID: watchedSessionID), context: context)
        let watchedUUID = try #require(UUID(uuidString: watchedSessionID))
        let catalogGate = h.sessionCatalogLookupGate
        await catalogGate.arm()
        h.app.core.savedSessionsAreStale = true
        let publication = Task { @MainActor in
            await h.app.core.transcriptDidPublish(sessionID: watchedUUID)
        }
        await catalogGate.waitUntilSuspended()

        let unrelatedPage = try await h.app.core.read(
            EngineTranscriptReadPayload(
                sessionID: unrelatedSessionID, revision: nil, cursor: nil, limit: 50
            ),
            context: context
        )
        #expect(h.app.core.readTranscript?.sessionID == UUID(uuidString: unrelatedSessionID))
        await catalogGate.release()
        await publication.value

        let publishedCache = try #require(h.app.core.transcript)
        #expect(publishedCache.sessionID == watchedUUID)
        #expect(publishedCache.revision > priorPage.revision.value)
        #expect(publishedCache.isLiveState == false)
        #expect(h.app.core.readTranscript?.sessionID == UUID(uuidString: unrelatedSessionID))
        #expect(h.app.core.readTranscript?.revision == unrelatedPage.revision.value)
        try await h.sink.changes.wait("watched session receives final reload_required") {
            ((try? h.outputs) ?? []).contains { output in
                guard case let .rows(payload) = output.event else { return false }
                return payload.sessionID == watchedSessionID && payload.kind == .reloadRequired
                    && payload.revision.value == publishedCache.revision
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

        await core.transcriptDidPublish(sessionID: sessionUUID)
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
        await h.awaitModels()
        return h
    }

    private func prepared(
        _ root: URL, provider: any EngineInferenceProviding
    ) async throws -> ApplicationHarness {
        let h = ApplicationHarness(root: root, provider: provider)
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        await h.awaitModels()
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
            requestID: try EngineID(10_000), events: EngineEventEmitter(transport: h.transport), terminalReplyClaim: {}
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
        text: text, textProjection: projection, clauseState: .classified, clauseSlices: []
    )
}
