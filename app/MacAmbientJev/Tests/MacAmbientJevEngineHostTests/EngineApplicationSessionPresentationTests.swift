import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
import MacAmbientJevTestSupport

private actor PresentationDecisionProvider: DecisionProvider {
    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.9) }),
            continuationProbability: request.next.map { _ in 0.1 },
            fillerRanges: [],
            inputTokens: 1
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        var decisions: [String: ContentPriorityDecision] = [:]
        for target in targets {
            decisions[target.key] = try ContentPriorityDecision(
                priority: .primary,
                confidence: 0.95,
                probabilities: ["PRIMARY": 0.975, "LOW_PRIORITY": 0.025]
            )
        }
        return PriorityBatchResponse(decisions: decisions, inputTokens: 1)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(10))) struct EngineApplicationSessionPresentationTests {
    @Test func sessionDisplayNameUsesTheExplicitTimeZoneAndJapaneseLocale() {
        let date = Date(timeIntervalSince1970: 1_741_429_351)
        let japanTimeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        let utcTimeZone = TimeZone(secondsFromGMT: 0)!

        #expect(EngineApplicationCore.sessionDisplayName(date, timeZone: japanTimeZone) == "2025年3月8日 19:22")
        #expect(EngineApplicationCore.sessionDisplayName(date, timeZone: utcTimeZone) == "2025年3月8日 10:22")
    }

    private func prepared(_ root: URL, decisions: Bool) async throws -> ApplicationHarness {
        let harness = ApplicationHarness(root: root)
        harness.start()
        try await harness.hello()
        try await harness.replaceSettings(try engineTestSettings(decisions: decisions), expectedRevision: nil)
        try await harness.call("models.prepare")
        return harness
    }

    private func requestContext(for harness: ApplicationHarness) throws -> EngineRequestContext {
        EngineRequestContext(requestID: try EngineID(1), events: EngineEventEmitter(transport: harness.transport))
    }

    private func recordAndFinalize(in harness: ApplicationHarness) async throws -> (id: String, folder: URL) {
        guard case let .recordingStart(started) = try await harness.call(
            "recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}"
        ) else {
            Issue.record("recording.start did not return a session")
            throw TestTimeout(description: "missing recording session")
        }
        let capture = try #require(harness.capture.session)
        try await capture.appendSpeech(seconds: 2)
        try await harness.call("recording.stop", payload: "{\"session_id\":\"\(started.sessionID)\"}")
        let finalized = try await harness.waitForSession(status: .finalized)
        #expect(finalized.sessionID == started.sessionID)
        let sessionID = try #require(UUID(uuidString: started.sessionID))
        let folder = try SessionDirectoryLocator(fileManager: .default).resolve(
            sessionsRoot: harness.paths.sessionsRoot, sessionID: sessionID
        )
        return (started.sessionID, folder)
    }

    private func createSession(
        in harness: ApplicationHarness,
        source: SessionSource,
        createdAt: Date,
        includeImportedOriginal: Bool
    ) throws -> URL {
        let folder = try SessionBootstrapper(fileManager: .default).createSession(
            paths: harness.paths,
            sessionID: UUID(),
            source: source,
            createdAt: createdAt,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        if includeImportedOriginal, case .imported = source {
            let audio = SessionLayout(sessionURL: folder).audioDirectory
            try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
            try Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02, 0x03]).write(to: audio.appending(path: "original.wav"))
        }
        return folder
    }

    private func inspect(_ harness: ApplicationHarness, folderID: String) async throws -> EngineSessionSummary {
        let payload = try EngineSessionInspectPayload(folderID: folderID)
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        guard case let .sessionInspect(summary) = try await harness.call("session.inspect", payload: json) else {
            Issue.record("session.inspect did not return a summary")
            throw TestTimeout(description: "missing session.inspect result")
        }
        return summary
    }

    private func list(
        _ core: EngineApplicationCore,
        context: EngineRequestContext,
        cursor: String?,
        limit: Int
    ) async throws -> EngineSessionListResult {
        try await core.list(EngineSessionListPayload(cursor: cursor, limit: limit), context: context)
    }

    private func listedSession(_ harness: ApplicationHarness, sessionID: String) async throws -> EngineSessionSummary {
        guard case let .sessionList(page) = try await harness.call(
            "session.list", payload: "{\"cursor\":null,\"limit\":100}"
        ) else {
            throw TestTimeout(description: "session.list did not return a page")
        }
        return try #require(page.sessions.first { $0.sessionID == sessionID })
    }

    private func expectRecordingWithoutPublishedAudio(_ summary: EngineSessionSummary) {
        #expect(summary.status == .recording)
        #expect(summary.statusText == "保存済み音声がありません")
        #expect(!summary.canReprocess)
        #expect(!summary.canRetryDecisions)
        #expect(!summary.canExport)
        guard case let .readable(_, source, audio, hasTranscript) = summary.metadata else {
            Issue.record("live recording metadata should be readable")
            return
        }
        #expect(source == .microphone)
        #expect(audio == .missing)
        #expect(!hasTranscript)
    }

    private func inspect(
        _ core: EngineApplicationCore,
        context: EngineRequestContext,
        folderID: String
    ) async throws -> EngineSessionSummary {
        try await core.inspect(EngineSessionInspectPayload(folderID: folderID), context: context)
    }

    private func saveMetadata(
        at sessionURL: URL,
        attempt: FinalizationAttempt?,
        activeRuns: ActiveRuns?,
        pendingBoundary: [SegmentTextReference]
    ) throws {
        try ProcessingMetadataStore(sessionURL: sessionURL).save(ProcessingMetadata(
            finalizationAttempt: attempt,
            activeRuns: activeRuns,
            pendingClauseBoundarySegments: pendingBoundary,
            pendingContentPriorityClauses: []
        ))
    }

    private func completeDecisionProcessing(at sessionURL: URL, sessionID: UUID) async throws {
        let store = ProcessingMetadataStore(sessionURL: sessionURL)
        let metadata = try #require(try store.load())
        let activeRuns = try #require(metadata.activeRuns)
        let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: SessionLayout(sessionURL: sessionURL).eventsURL))
        let events = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: activeRuns)
        let usage = DecisionUsageCounter()
        let identity = try DecisionModelIdentity(
            backend: "host-test", model: "deterministic-test", modelRevision: String(repeating: "0", count: 64)
        )
        let decisions = DecisionCoordinator(
            provider: PresentationDecisionProvider(), identity: identity, usageCounter: usage
        )
        let boundaryRunID = "presentation-boundary"
        let priorityRunID = "presentation-priority"
        let coordinator = DecisionEnrichmentCoordinator(
            sessionID: sessionID,
            boundaryRunID: boundaryRunID,
            priorityRunID: priorityRunID,
            writer: try SessionWriter(sessionURL: sessionURL),
            decisions: decisions,
            usageCounter: usage,
            materializer: TranscriptMaterializer(sampleRate: CanonicalAudio.sampleRate)
        )
        let result = try await coordinator.process(
            existingEvents: events,
            activeRuns: activeRuns,
            scope: .all,
            reusableDecisions: [:],
            onEvent: nil
        )
        #expect(result.pendingBoundarySegments.isEmpty)
        #expect(result.pendingPriorityClauses.isEmpty)
        try store.publishDecisionSnapshot(
            basedOn: activeRuns,
            clauseBoundaryRunID: result.boundaryRunID,
            contentPriorityRunID: result.priorityRunID,
            pendingClauseBoundarySegments: result.pendingBoundarySegments,
            pendingContentPriorityClauses: result.pendingPriorityClauses
        )
        await coordinator.recordPublished(result, replacing: metadata.pendingDecisionTargets)
    }

    @Test func recordingPresentationMatchesInspectAndTracksExportState() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try await prepared(root, decisions: false)
        let recorded = try await recordAndFinalize(in: harness)
        let sessionID = try #require(UUID(uuidString: recorded.id))
        try await completeDecisionProcessing(at: recorded.folder, sessionID: sessionID)
        let manifest = try SessionLayout(sessionURL: recorded.folder).loadManifest()
        let resolved = try SessionDirectoryLocator(fileManager: .default).resolve(
            sessionsRoot: harness.paths.sessionsRoot, sessionID: sessionID
        )
        #expect(resolved.standardizedFileURL.path == recorded.folder.standardizedFileURL.path)

        guard case let .sessionList(initialList) = try await harness.call(
            "session.list", payload: "{\"cursor\":null,\"limit\":100}"
        ) else {
            Issue.record("session.list did not return a page")
            return
        }
        let listed = try #require(initialList.sessions.first { $0.folderID == recorded.folder.lastPathComponent })
        let inspected = try await inspect(harness, folderID: listed.folderID)
        #expect(listed == inspected)
        #expect(listed.sessionID == recorded.id)
        #expect(listed.folderPath == resolved.path)
        #expect(listed.displayName == EngineApplicationCore.sessionDisplayName(
            manifest.createdAt, timeZone: .current
        ))
        #expect(listed.statusText == "文字起こしあり")
        #expect(listed.canReprocess)
        #expect(!listed.canRetryDecisions)
        #expect(listed.canExport)
        #expect(listed.status == .finalized)
        #expect(listed.metadata == .readable(
            createdAt: manifest.createdAt.timeIntervalSince1970,
            source: .microphone,
            audio: .available,
            hasTranscript: true
        ))

        let destination = root.appending(path: "explicit-export", directoryHint: .isDirectory)
        let exportPayload = try EngineExportPayload(sessionID: recorded.id, destinationPath: destination.path)
        let exportJSON = String(decoding: try JSONEncoder().encode(exportPayload), as: UTF8.self)
        guard case let .sessionExport(exported) = try await harness.call("session.export", payload: exportJSON) else {
            Issue.record("session.export did not return a result")
            return
        }
        let bundle = URL(fileURLWithPath: exported.destinationPath, isDirectory: true)
        #expect(bundle.standardizedFileURL.path == destination.appending(path: recorded.folder.lastPathComponent).standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: bundle.appending(path: "transcript.txt").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appending(path: "audio.flac").path))

        let afterExport = try await inspect(harness, folderID: listed.folderID)
        #expect(afterExport.exportPath == exported.destinationPath)
        guard case let .sessionList(freshList) = try await harness.call(
            "session.list", payload: "{\"cursor\":null,\"limit\":100}"
        ) else {
            Issue.record("fresh session.list did not return a page")
            return
        }
        let freshListed = try #require(freshList.sessions.first { $0.folderID == listed.folderID })
        #expect(freshListed == afterExport)

        try await harness.replaceSettings(try engineTestSettings(exportPath: destination.path), expectedRevision: 1)
        let probedExisting = try await inspect(harness, folderID: listed.folderID)
        #expect(probedExisting.exportPath == exported.destinationPath)
        #expect(harness.app.core.savedSessionOperations.exports[sessionID] == .exported(bundle))

        try FileManager.default.removeItem(at: bundle.appending(path: "audio.flac"))
        harness.app.core.savedSessionOperations.resetExportDestination()
        let incompleteProbe = try await inspect(harness, folderID: listed.folderID)
        #expect(incompleteProbe.exportPath == nil)
        #expect(try await harness.shutdown() == .shutdownRequested)
    }

    @Test(.timeLimit(.minutes(1))) func recordingListPublishesAudioAfterTheFirstDurableChunk() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try await prepared(root, decisions: false)
        var activeSessionID: String?

        do {
            guard case let .recordingStart(started) = try await harness.call(
                "recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}"
            ) else {
                throw TestTimeout(description: "recording.start did not return a session")
            }
            activeSessionID = started.sessionID
            let capture = try #require(harness.capture.session)

            let initialCheckpoint = try await capture.committedCheckpoint()
            #expect(initialCheckpoint.committedFrames == 0)
            let beforeCaptureAudio = try await listedSession(harness, sessionID: started.sessionID)
            expectRecordingWithoutPublishedAudio(beforeCaptureAudio)

            // A 0.25-second partial chunk remains in memory and is not a source audio file.
            try await capture.appendSpeech(seconds: 0.25)
            let partialCheckpoint = try await capture.committedCheckpoint()
            #expect(partialCheckpoint.committedFrames == 0)
            let duringPartialChunk = try await listedSession(harness, sessionID: started.sessionID)
            expectRecordingWithoutPublishedAudio(duringPartialChunk)

            // 0.75 more seconds crosses the writer's 0.5-second chunk boundary.
            try await capture.appendSpeech(seconds: 0.75)
            let committedCheckpoint = try await capture.committedCheckpoint()
            #expect(committedCheckpoint.committedFrames > 0)
            #expect(!capture.isStopped)

            let duringCommittedCapture = try await listedSession(harness, sessionID: started.sessionID)
            #expect(duringCommittedCapture.status == .recording)
            #expect(duringCommittedCapture.statusText == "未処理")
            #expect(!duringCommittedCapture.canReprocess)
            #expect(!duringCommittedCapture.canRetryDecisions)
            #expect(!duringCommittedCapture.canExport)
            guard case let .readable(_, source, audio, hasTranscript) = duringCommittedCapture.metadata else {
                Issue.record("live recording metadata should be readable")
                throw TestTimeout(description: "live recording metadata was unreadable")
            }
            #expect(source == .microphone)
            #expect(audio == .available)
            #expect(!hasTranscript)

            try await harness.call("recording.stop", payload: "{\"session_id\":\"\(started.sessionID)\"}")
            #expect(capture.isStopped)

            let afterStop = try await listedSession(harness, sessionID: started.sessionID)
            #expect(afterStop.status != .recording)
            guard case let .readable(_, _, audio, _) = afterStop.metadata else {
                Issue.record("saved recording metadata should be readable")
                throw TestTimeout(description: "saved recording metadata was unreadable")
            }
            #expect(audio == .available)
        } catch {
            if let activeSessionID, let capture = harness.capture.session, !capture.isStopped {
                _ = try? await harness.call(
                    "recording.stop", payload: "{\"session_id\":\"\(activeSessionID)\"}"
                )
            }
            if let capture = harness.capture.session, !capture.isStopped {
                _ = try? await capture.stop()
            }
            _ = try? await harness.shutdown()
            throw error
        }
        #expect(try await harness.shutdown() == .shutdownRequested)
    }

    @Test func exportProbeFailuresAreCachedOnSummariesWithoutFailingListOrInspect() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try await prepared(root, decisions: false)
        let recorded = try await recordAndFinalize(in: harness)
        let sessionID = try #require(UUID(uuidString: recorded.id))
        let other = try createSession(
            in: harness, source: .recording(.microphone), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            includeImportedOriginal: false
        )
        let invalidDestination = root.appending(path: "export-destination-file")
        try Data([0x01]).write(to: invalidDestination)
        try await harness.replaceSettings(
            try engineTestSettings(exportPath: invalidDestination.path), expectedRevision: 1
        )

        guard case let .sessionList(listedPage) = try await harness.call(
            "session.list", payload: "{\"cursor\":null,\"limit\":100}"
        ) else {
            Issue.record("session.list should succeed when export destination probing fails")
            return
        }
        let listed = try #require(listedPage.sessions.first { $0.folderID == recorded.folder.lastPathComponent })
        let unrelated = try #require(listedPage.sessions.first { $0.folderID == other.lastPathComponent })
        let cachedFailure = try #require(harness.app.core.savedSessionOperations.exports[sessionID])
        guard case let .failed(message) = cachedFailure else {
            Issue.record("the failed export probe should be cached")
            return
        }
        #expect(message.hasPrefix("書き出し先を確認できません: "))
        #expect(listed.error?.code == .exportFailure)
        #expect(listed.error?.message == message)
        #expect(listed.error?.stage == .exporting)
        #expect(listed.error?.sessionID == EngineFailures.wireID(sessionID))
        #expect(listed.error?.requestID == nil)
        #expect(listed.error?.severity == .error)
        #expect(listed.error?.recoveryAction == .retry)
        #expect(listed.exportPath == nil)
        #expect(listed.status == .finalized)
        #expect(listed.statusText == "文字起こしあり・判定を再試行")
        #expect(listed.metadata == .readable(
            createdAt: try SessionLayout(sessionURL: recorded.folder).loadManifest().createdAt.timeIntervalSince1970,
            source: .microphone, audio: .available, hasTranscript: true
        ))
        #expect(unrelated.error == nil)
        #expect(unrelated.exportPath == nil)

        let inspected = try await inspect(harness, folderID: recorded.folder.lastPathComponent)
        #expect(inspected.error == listed.error)
        #expect(inspected.exportPath == nil)

        #if !os(Windows)
        let symlinkDestination = root.appending(path: "symlink-export-destination", directoryHint: .isDirectory)
        let symlinkTarget = root.appending(path: "symlink-export-target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: symlinkDestination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: symlinkTarget, withIntermediateDirectories: true)
        let symlinkChild = symlinkDestination.appending(
            path: recorded.folder.lastPathComponent, directoryHint: .isDirectory
        )
        try FileManager.default.createSymbolicLink(at: symlinkChild, withDestinationURL: symlinkTarget)
        try await harness.replaceSettings(
            try engineTestSettings(exportPath: symlinkDestination.path), expectedRevision: 2
        )
        guard case let .sessionList(symlinkPage) = try await harness.call(
            "session.list", payload: "{\"cursor\":null,\"limit\":100}"
        ) else {
            Issue.record("session.list should also succeed when a probed export child is a symlink")
            return
        }
        let symlinkListed = try #require(
            symlinkPage.sessions.first { $0.folderID == recorded.folder.lastPathComponent }
        )
        let symlinkCachedFailure = try #require(harness.app.core.savedSessionOperations.exports[sessionID])
        guard case let .failed(symlinkMessage) = symlinkCachedFailure else {
            Issue.record("the symlink probe failure should be cached")
            return
        }
        #expect(symlinkMessage.hasPrefix("書き出し先を確認できません: "))
        #expect(symlinkListed.error?.code == .exportFailure)
        #expect(symlinkListed.error?.message == symlinkMessage)
        #expect(symlinkListed.exportPath == nil)
        #expect(try await inspect(harness, folderID: recorded.folder.lastPathComponent) == symlinkListed)
        #endif
        #expect(try await harness.shutdown() == .shutdownRequested)
    }

    @Test func settingsDestinationChangesInvalidateCachedExportProbes() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try await prepared(root, decisions: false)
        let recorded = try await recordAndFinalize(in: harness)
        let sessionID = try #require(UUID(uuidString: recorded.id))
        let core = harness.app.core

        let invalidDestination = root.appending(path: "export-destination-file")
        try Data([0x01]).write(to: invalidDestination)
        try await harness.replaceSettings(
            try engineTestSettings(exportPath: invalidDestination.path), expectedRevision: 1
        )
        let failedProbe = try await inspect(harness, folderID: recorded.folder.lastPathComponent)
        #expect(failedProbe.error?.code == .exportFailure)
        #expect(failedProbe.exportPath == nil)
        let failedState = try #require(core.savedSessionOperations.exports[sessionID])
        guard case let .failed(failureMessage) = failedState else {
            Issue.record("the bad destination probe should be cached as a failure")
            return
        }

        do {
            try await harness.replaceSettings(
                try engineTestSettings(automaticExport: true, exportPath: invalidDestination.path), expectedRevision: 1
            )
            Issue.record("a stale settings revision should fail")
        } catch let error as CommandFailure {
            #expect(error.failure.code == .staleRevision)
        }
        #expect(core.savedSessionOperations.exports[sessionID] == failedState)

        try await harness.replaceSettings(
            try engineTestSettings(automaticExport: true, exportPath: invalidDestination.path), expectedRevision: 2
        )
        #expect(core.savedSessionOperations.exports[sessionID] == failedState)
        let unchangedDestinationProbe = try await inspect(harness, folderID: recorded.folder.lastPathComponent)
        #expect(unchangedDestinationProbe.error?.message == failureMessage)
        #expect(unchangedDestinationProbe.exportPath == nil)

        let completeDestination = root.appending(path: "complete-export", directoryHint: .isDirectory)
        let session = try core.readableSession(sessionID)
        let completeBundle = try SessionExporter().export(session: session, to: completeDestination)
        #expect(FileManager.default.fileExists(atPath: completeBundle.appending(path: "transcript.txt").path))
        #expect(FileManager.default.fileExists(atPath: completeBundle.appending(path: "audio.flac").path))

        try await harness.replaceSettings(
            try engineTestSettings(exportPath: completeDestination.path), expectedRevision: 3
        )
        #expect(core.savedSessionOperations.exports[sessionID] == nil)
        let completeProbe = try await inspect(harness, folderID: recorded.folder.lastPathComponent)
        #expect(completeProbe.error == nil)
        #expect(completeProbe.exportPath == completeBundle.path)
        #expect(core.savedSessionOperations.exports[sessionID] == .exported(completeBundle))

        let emptyDestination = root.appending(path: "empty-export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: emptyDestination, withIntermediateDirectories: false)
        try await harness.replaceSettings(
            try engineTestSettings(exportPath: emptyDestination.path), expectedRevision: 4
        )
        #expect(core.savedSessionOperations.exports[sessionID] == nil)
        let emptyProbe = try await inspect(harness, folderID: recorded.folder.lastPathComponent)
        #expect(emptyProbe.error == nil)
        #expect(emptyProbe.exportPath == nil)
        #expect(core.savedSessionOperations.exports[sessionID] == nil)

        try await harness.replaceSettings(
            try engineTestSettings(exportPath: completeDestination.path), expectedRevision: 5
        )
        #expect(core.savedSessionOperations.exports[sessionID] == nil)
        let reprobedComplete = try await inspect(harness, folderID: recorded.folder.lastPathComponent)
        #expect(reprobedComplete.error == nil)
        #expect(reprobedComplete.exportPath == completeBundle.path)
        #expect(core.savedSessionOperations.exports[sessionID] == .exported(completeBundle))

        try await harness.replaceSettings(try engineTestSettings(), expectedRevision: 6)
        #expect(core.savedSessionOperations.exports[sessionID] == nil)
        let noDestination = try await inspect(harness, folderID: recorded.folder.lastPathComponent)
        #expect(noDestination.error == nil)
        #expect(noDestination.exportPath == nil)
        #expect(try await harness.shutdown() == .shutdownRequested)
    }

    @Test func catalogFixturesExposeReadableAndUnreadableMetadataWithoutInventingFields() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try await prepared(root, decisions: false)
        let epoch = Date(timeIntervalSince1970: 1_700_100_000)
        let missingRecording = try createSession(
            in: harness, source: .recording(.systemAudio), createdAt: epoch, includeImportedOriginal: false
        )
        let imported = try createSession(
            in: harness, source: .imported(originalFilename: "lecture.wav"), createdAt: epoch.addingTimeInterval(1), includeImportedOriginal: true
        )
        let corruptMetadata = try createSession(
            in: harness, source: .imported(originalFilename: "corrupt.wav"), createdAt: epoch.addingTimeInterval(2), includeImportedOriginal: true
        )
        try Data("{broken".utf8).write(to: SessionLayout(sessionURL: corruptMetadata).processingMetadataURL)
        let missingImportedOriginal = try createSession(
            in: harness, source: .imported(originalFilename: "missing.wav"), createdAt: epoch.addingTimeInterval(3), includeImportedOriginal: false
        )
        let brokenFolder = harness.paths.sessionsRoot.appending(path: "broken-manifest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: brokenFolder, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: SessionLayout(sessionURL: brokenFolder).manifestURL)

        let knownSessionID = UUID()
        let directUnreadable = try harness.app.core.sessionSummary(.unreadable(
            sessionURL: root.appending(path: "direct-unreadable", directoryHint: .isDirectory),
            sessionID: knownSessionID,
            reason: "known manifest identity"
        ))
        #expect(directUnreadable.sessionID == EngineFailures.wireID(knownSessionID))
        #expect(directUnreadable.error?.sessionID == EngineFailures.wireID(knownSessionID))

        let mismatchedOriginal = try createSession(
            in: harness, source: .imported(originalFilename: "mismatched-folder.wav"),
            createdAt: epoch.addingTimeInterval(4), includeImportedOriginal: true
        )
        let mismatchedFolder = harness.paths.sessionsRoot.appending(
            path: "manifest-id-mismatch", directoryHint: .isDirectory
        )
        try FileManager.default.moveItem(at: mismatchedOriginal, to: mismatchedFolder)
        let mismatchedSessionID = try SessionLayout(sessionURL: mismatchedFolder).loadManifest().sessionID

        let missing = try await inspect(harness, folderID: missingRecording.lastPathComponent)
        #expect(missing.statusText == "保存済み音声がありません")
        #expect(missing.metadata == .readable(
            createdAt: epoch.timeIntervalSince1970, source: .systemAudio, audio: .missing, hasTranscript: false
        ))
        #expect(!missing.canReprocess)
        #expect(!missing.canExport)

        let retained = try await inspect(harness, folderID: imported.lastPathComponent)
        #expect(retained.metadata == .readable(
            createdAt: epoch.addingTimeInterval(1).timeIntervalSince1970,
            source: .imported(originalFilename: "lecture.wav"), audio: .available, hasTranscript: false
        ))
        #expect(retained.statusText == "未処理")
        #expect(retained.canReprocess)

        let corrupted = try await inspect(harness, folderID: corruptMetadata.lastPathComponent)
        #expect(corrupted.statusText == "文字起こしデータが破損しています（音声から再処理できます）")
        #expect(corrupted.canReprocess)
        #expect(!corrupted.canExport)

        let missingOriginal = try await inspect(harness, folderID: missingImportedOriginal.lastPathComponent)
        guard case let .readable(_, _, audio, false) = missingOriginal.metadata,
              case let .unreadable(reason) = audio else {
            Issue.record("missing imported original was not reported as unreadable audio")
            return
        }
        #expect(missingOriginal.statusText == "音声を読めません: \(reason)")
        #expect(!missingOriginal.canReprocess)
        #expect(!missingOriginal.canExport)

        let unreadable = try await inspect(harness, folderID: brokenFolder.lastPathComponent)
        #expect(unreadable.status == .unreadable)
        #expect(unreadable.sessionID == nil)
        #expect(unreadable.error?.sessionID == nil)
        #expect(unreadable.displayName == "日時を読み取れません")
        #expect(unreadable.folderID == brokenFolder.lastPathComponent)
        #expect(unreadable.folderPath == brokenFolder.path)
        #expect(unreadable.error != nil)
        #expect(unreadable.metadata == .unreadable(reason: unreadable.error!.message))
        #expect(!unreadable.canReprocess && !unreadable.canRetryDecisions && !unreadable.canExport)

        let knownUnreadable = try await inspect(harness, folderID: mismatchedFolder.lastPathComponent)
        #expect(knownUnreadable.status == .unreadable)
        #expect(knownUnreadable.sessionID == EngineFailures.wireID(mismatchedSessionID))
        #expect(knownUnreadable.error?.sessionID == EngineFailures.wireID(mismatchedSessionID))
        guard case let .unreadable(knownReason) = knownUnreadable.metadata else {
            Issue.record("a manifest identity mismatch should have unreadable metadata")
            return
        }
        #expect(knownUnreadable.error?.message == knownReason)
        #expect(!knownUnreadable.canReprocess && !knownUnreadable.canRetryDecisions && !knownUnreadable.canExport)

        guard case let .sessionList(page) = try await harness.call(
            "session.list", payload: "{\"cursor\":null,\"limit\":100}"
        ) else {
            Issue.record("session.list did not return a page")
            return
        }
        let listedUnreadable = try #require(page.sessions.first { $0.folderID == brokenFolder.lastPathComponent })
        #expect(listedUnreadable.status == unreadable.status)
        #expect(listedUnreadable.folderPath == unreadable.folderPath)
        #expect(listedUnreadable.error?.sessionID == nil)
        let listedKnownUnreadable = try #require(page.sessions.first { $0.folderID == mismatchedFolder.lastPathComponent })
        #expect(listedKnownUnreadable.sessionID == EngineFailures.wireID(mismatchedSessionID))
        #expect(listedKnownUnreadable.error?.sessionID == EngineFailures.wireID(mismatchedSessionID))
        #expect(!listedUnreadable.canReprocess && !listedUnreadable.canRetryDecisions && !listedUnreadable.canExport)
        do {
            _ = try await inspect(harness, folderID: "not-a-session")
            Issue.record("unknown session folder should fail")
        } catch let error as CommandFailure {
            #expect(error.failure.code == .sessionNotFound)
        }
        do {
            _ = try await inspect(harness, folderID: "../outside-catalog")
            Issue.record("traversal-shaped folder ID should fail")
        } catch let error as CommandFailure {
            #expect(error.failure.code == .sessionNotFound)
        }
        #expect(try await harness.shutdown() == .shutdownRequested)
    }

    @Test func processingWordingAndPendingClassificationFollowRealMetadataAndEvents() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try await prepared(root, decisions: true)
        let sessionURL = try createSession(
            in: harness, source: .imported(originalFilename: "state.wav"),
            createdAt: Date(timeIntervalSince1970: 1_700_200_000), includeImportedOriginal: true
        )
        let stateCases: [(FinalizationAttempt?, String)] = [
            (nil, "未処理"),
            (FinalizationAttempt(attemptID: "running", state: .running, failureReason: nil), "処理中"),
            (FinalizationAttempt(attemptID: "complete", state: .complete, failureReason: nil), "処理完了"),
            (FinalizationAttempt(attemptID: "failed", state: .failed, failureReason: "decode stopped"), "再処理が必要: decode stopped"),
            (FinalizationAttempt(attemptID: "paused", state: .paused, failureReason: nil), "処理は中断されました。次回の起動時に再開できます")
        ]
        for (attempt, expectedText) in stateCases {
            try saveMetadata(at: sessionURL, attempt: attempt, activeRuns: nil, pendingBoundary: [])
                let summary = try await inspect(harness.app.core, context: requestContext(for: harness), folderID: sessionURL.lastPathComponent)
            #expect(summary.statusText == expectedText)
        }

        let missing = try createSession(
            in: harness, source: .recording(.microphone), createdAt: Date(timeIntervalSince1970: 1_700_200_100), includeImportedOriginal: false
        )
        try saveMetadata(
            at: missing,
            attempt: FinalizationAttempt(attemptID: "failed-missing", state: .failed, failureReason: "failure hidden by audio"),
            activeRuns: nil, pendingBoundary: []
        )
        let unreadable = try createSession(
            in: harness, source: .imported(originalFilename: "unreadable.wav"), createdAt: Date(timeIntervalSince1970: 1_700_200_101), includeImportedOriginal: false
        )
        try saveMetadata(
            at: unreadable,
            attempt: FinalizationAttempt(attemptID: "failed-unreadable", state: .failed, failureReason: "failure hidden by unreadable audio"),
            activeRuns: nil, pendingBoundary: []
        )
        #expect(try await inspect(harness.app.core, context: requestContext(for: harness), folderID: missing.lastPathComponent).statusText == "保存済み音声がありません")
        let unreadableSummary = try await inspect(harness.app.core, context: requestContext(for: harness), folderID: unreadable.lastPathComponent)
        guard case let .readable(_, _, .unreadable(reason), false) = unreadableSummary.metadata else {
            Issue.record("missing import must be unreadable audio")
            return
        }
        #expect(unreadableSummary.statusText == "音声を読めません: \(reason)")

        let recorded = try await recordAndFinalize(in: harness)
        let layout = SessionLayout(sessionURL: recorded.folder)
        let currentMetadata = try #require(try ProcessingMetadataStore(sessionURL: recorded.folder).load())
        let activeRuns = try #require(currentMetadata.activeRuns)
        let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: layout.eventsURL))
        let events = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: activeRuns)
        let source = try #require(try events.compactMap { try $0.asrSource() }.first)
        try ProcessingMetadataStore(sessionURL: recorded.folder).save(ProcessingMetadata(
            finalizationAttempt: FinalizationAttempt(attemptID: "classification-pending", state: .complete, failureReason: nil),
            activeRuns: activeRuns,
            pendingClauseBoundarySegments: [source],
            pendingContentPriorityClauses: []
        ))
        let pending = try await inspect(harness.app.core, context: requestContext(for: harness), folderID: recorded.folder.lastPathComponent)
        #expect(pending.statusText == "文字起こしあり・判定を再試行")
        #expect(pending.canRetryDecisions)
        #expect(pending.canReprocess)
        let manifest = try layout.loadManifest()
        #expect(pending.metadata == .readable(
            createdAt: manifest.createdAt.timeIntervalSince1970, source: .microphone,
            audio: .available, hasTranscript: true
        ))

        let recordedAudioURL = layout.recordingFLACURL
        let recordedAudioData = try Data(contentsOf: recordedAudioURL)
        try FileManager.default.removeItem(at: recordedAudioURL)
        var recordedAudioRestored = false
        defer {
            if !recordedAudioRestored {
                try? recordedAudioData.write(to: recordedAudioURL)
            }
        }
        let withoutAudio = try await inspect(
            harness.app.core, context: requestContext(for: harness), folderID: recorded.folder.lastPathComponent
        )
        guard case .readable(_, _, .unreadable(_), true) = withoutAudio.metadata else {
            Issue.record("missing recorded FLAC must preserve the pending transcript and report unreadable audio")
            return
        }
        #expect(!withoutAudio.canRetryDecisions)

        try recordedAudioData.write(to: recordedAudioURL)
        recordedAudioRestored = true
        #expect(try Data(contentsOf: recordedAudioURL) == recordedAudioData)
        let restoredAudio = try await inspect(
            harness.app.core, context: requestContext(for: harness), folderID: recorded.folder.lastPathComponent
        )
        guard case .readable(_, _, .available, true) = restoredAudio.metadata else {
            Issue.record("restored recorded FLAC must retain the pending transcript")
            return
        }
        #expect(restoredAudio.canRetryDecisions)

        try await harness.replaceSettings(try engineTestSettings(decisions: false), expectedRevision: 1)
        let disabled = try await inspect(harness.app.core, context: requestContext(for: harness), folderID: recorded.folder.lastPathComponent)
        #expect(!disabled.canRetryDecisions)
        #expect(disabled.statusText == "文字起こしあり・判定を再試行")
        #expect(try await harness.shutdown() == .shutdownRequested)
    }

    @Test func actionGatesReflectLiveCoreStateAndDoNotRequireAnExportDestination() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try await prepared(root, decisions: true)
        let recorded = try await recordAndFinalize(in: harness)
        let core = harness.app.core
        let context = try requestContext(for: harness)
        let sessionID = try #require(UUID(uuidString: recorded.id))
        let layout = SessionLayout(sessionURL: recorded.folder)
        let metadata = try #require(try ProcessingMetadataStore(sessionURL: recorded.folder).load())
        let activeRuns = try #require(metadata.activeRuns)
        let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: layout.eventsURL))
        let events = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: activeRuns)
        try saveMetadata(
            at: recorded.folder,
            attempt: FinalizationAttempt(attemptID: "action-gate-pending", state: .complete, failureReason: nil),
            activeRuns: activeRuns,
            pendingBoundary: try events.compactMap { try $0.asrSource() }
        )
        let readable = try #require(core.savedSessionOperations.readableSession(sessionID))
        let initial = try await inspect(core, context: context, folderID: recorded.folder.lastPathComponent)
        #expect(initial.canExport)
        #expect(initial.exportPath == nil)
        #expect(initial.canReprocess)
        #expect(initial.canRetryDecisions)

        core.recording.beginImport()
        #expect(!(try await inspect(core, context: context, folderID: recorded.folder.lastPathComponent)).canReprocess)
        core.recording.finish()

        core.isPreparingModels = true
        #expect(!(try await inspect(core, context: context, folderID: recorded.folder.lastPathComponent)).canReprocess)
        core.isPreparingModels = false

        core.processingQueue.beginStorageMaintenance()
        #expect(!(try await inspect(core, context: context, folderID: recorded.folder.lastPathComponent)).canReprocess)
        core.processingQueue.endStorageMaintenance()

        let installedInference = try #require(core.inference)
        core.inference = nil
        #expect(!(try await inspect(core, context: context, folderID: recorded.folder.lastPathComponent)).canReprocess)
        core.inference = installedInference

        core.isShuttingDown = true
        let shuttingDown = try await inspect(core, context: context, folderID: recorded.folder.lastPathComponent)
        #expect(!shuttingDown.canReprocess && !shuttingDown.canExport)
        core.isShuttingDown = false

        let claimed = core.processingQueue.claimReprocessing(sessionID)
        #expect(claimed)
        #expect(!(try await inspect(core, context: context, folderID: recorded.folder.lastPathComponent)).canReprocess)
        core.processingQueue.releaseReprocessing(sessionID)

        core.processingQueue.holdForHeat(.finalize(sessionID: sessionID, metadataPolicy: .reject))
        let thermallyHeld = try await inspect(core, context: context, folderID: recorded.folder.lastPathComponent)
        #expect(!thermallyHeld.canReprocess)
        #expect(!thermallyHeld.canRetryDecisions)
        #expect(!thermallyHeld.canExport)
        let didResumeHeld = core.processingQueue.resumeHeld(isCritical: false, pausesProcessing: false)
        #expect(didResumeHeld)
        let dequeued = core.processingQueue.dequeue()
        let resumed = try #require(dequeued)
        #expect(resumed.sessionID == sessionID)
        core.processingQueue.begin(resumed)
        core.processingQueue.completeCurrent()

        core.processingQueue.begin(.finalize(sessionID: sessionID, metadataPolicy: .reject))
        let queued = try await inspect(core, context: context, folderID: recorded.folder.lastPathComponent)
        #expect(!queued.canReprocess && !queued.canExport)
        core.processingQueue.completeCurrent()

        #expect(core.savedSessionOperations.beginExport(readable, isMaintainingStorage: false) == .ready)
        #expect(!(try await inspect(core, context: context, folderID: recorded.folder.lastPathComponent)).canExport)
        core.savedSessionOperations.resetExportDestination()
        #expect((try await inspect(core, context: context, folderID: recorded.folder.lastPathComponent)).canExport)
        #expect(try await harness.shutdown() == .shutdownRequested)
    }

    @Test func byteLimitedListSnapshotPagesRemainStableAndRejectForeignCursors() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = try await prepared(root, decisions: false)
        let core = harness.app.core
        let context = try requestContext(for: harness)
        do {
            _ = try await list(core, context: context, cursor: "no-retained-snapshot", limit: 100)
            Issue.record("a cursor without a retained list snapshot must fail")
        } catch let error as EngineCommandError {
            #expect(error.code == .invalidCursor)
        }

        let longReason = String(repeating: "あ", count: 100_000)
        var fixtures: [URL] = []
        for index in 0..<10 {
            let folder = try createSession(
                in: harness, source: .imported(originalFilename: "large-\(index).wav"),
                createdAt: Date(timeIntervalSince1970: 1_700_300_000 + Double(index * 60)), includeImportedOriginal: true
            )
            try saveMetadata(
                at: folder,
                attempt: FinalizationAttempt(attemptID: "failure-\(index)", state: .failed, failureReason: longReason),
                activeRuns: nil, pendingBoundary: []
            )
            fixtures.append(folder)
        }
        let transcriptFolder = try createSession(
            in: harness, source: .imported(originalFilename: "transcript.wav"),
            createdAt: Date(timeIntervalSince1970: 1_700_400_000), includeImportedOriginal: true
        )
        let transcriptID = try SessionLayout(sessionURL: transcriptFolder).loadManifest().sessionID
        try await writeTranscriptHistory(at: transcriptFolder, sessionID: transcriptID, segmentCount: 55)

        let transcriptPage = try await core.read(
            EngineTranscriptReadPayload(
                sessionID: transcriptID.uuidString.lowercased(), revision: nil, cursor: nil, limit: 50
            ), context: context
        )
        let transcriptCursor = try #require(transcriptPage.nextCursor)

        let first = try await list(core, context: context, cursor: nil, limit: 100)
        #expect(first.sessions.count < 100)
        #expect(first.previousCursor == nil)
        #expect(first.nextCursor != nil)
        var forwardPages = [first]
        while let cursor = forwardPages.last?.nextCursor {
            forwardPages.append(try await list(core, context: context, cursor: cursor, limit: 100))
        }
        #expect(forwardPages.count >= 3)
        #expect(forwardPages.last?.nextCursor == nil)
        let expectedCatalogOrder = try core.currentSessions().map { $0.sessionURL.lastPathComponent }
        let flattened = forwardPages.flatMap { $0.sessions.map(\.folderID) }
        #expect(flattened == expectedCatalogOrder)
        #expect(flattened.count == 11)

        for page in forwardPages {
            let output = try EngineOutput(
                version: 1, sequence: EngineID(UInt64.max), requestID: EngineID(UInt64.max),
                event: .completed(.sessionList(page))
            )
            let line = try EngineCodec.encodeOutput(output)
            #expect(line.count <= 1_048_576 + 1)
            #expect(line.last == 0x0A)
        }
        let firstNext = try #require(first.nextCursor)
        let repeatedSecond = try await list(core, context: context, cursor: firstNext, limit: 100)
        #expect(repeatedSecond == forwardPages[1])

        let firstLargeFolder = try #require(fixtures.first)
        try saveMetadata(
            at: firstLargeFolder,
            attempt: FinalizationAttempt(attemptID: "changed", state: .failed, failureReason: "current-state"),
            activeRuns: nil, pendingBoundary: []
        )
        let currentInspect = try await inspect(core, context: context, folderID: firstLargeFolder.lastPathComponent)
        #expect(currentInspect.statusText == "再処理が必要: current-state")
        let snapshotSecond = try await list(core, context: context, cursor: firstNext, limit: 100)
        #expect(snapshotSecond == forwardPages[1])

        var backwardPages: [EngineSessionListResult] = []
        var backwardCursor = forwardPages.last?.previousCursor
        while let cursor = backwardCursor {
            let page = try await list(core, context: context, cursor: cursor, limit: 100)
            backwardPages.append(page)
            backwardCursor = page.previousCursor
        }
        #expect(backwardPages.count == forwardPages.count - 1)
        for (backward, expected) in zip(backwardPages, forwardPages.dropLast().reversed()) {
            #expect(backward.sessions == expected.sessions)
            #expect(backward.nextCursor == expected.nextCursor)
            #expect(backward.previousCursor == expected.previousCursor)
        }

        let oldForwardToken = try #require(first.nextCursor)
        let oldBackwardToken = try #require(forwardPages.last?.previousCursor)
        let externallyAdded = try createSession(
            in: harness, source: .imported(originalFilename: "external.wav"),
            createdAt: Date(timeIntervalSince1970: 1_700_500_000), includeImportedOriginal: true
        )
        let refreshedFirstPage = try await list(core, context: context, cursor: nil, limit: 100)
        #expect(refreshedFirstPage.sessions.contains { $0.folderID == externallyAdded.lastPathComponent })
        let refreshedFirstCursor = try #require(refreshedFirstPage.nextCursor)
        let refreshedSecondPageBeforeRejection = try await list(
            core, context: context, cursor: refreshedFirstCursor, limit: 100
        )
        do {
            _ = try await list(core, context: context, cursor: refreshedFirstCursor, limit: 99)
            Issue.record("a retained cursor cannot be reused with a changed limit")
        } catch let error as EngineCommandError {
            #expect(error.code == .invalidCursor)
        }
        let refreshedSecondPageAfterRejection = try await list(
            core, context: context, cursor: refreshedFirstCursor, limit: 100
        )
        #expect(refreshedSecondPageAfterRejection == refreshedSecondPageBeforeRejection)
        _ = try await list(core, context: context, cursor: nil, limit: 100)
        for cursor in [oldForwardToken, oldBackwardToken, "17", transcriptCursor] {
            do {
                _ = try await list(core, context: context, cursor: cursor, limit: 100)
                Issue.record("foreign or invalid list cursor should fail: \(cursor)")
            } catch let error as EngineCommandError {
                #expect(error.code == .invalidCursor)
            }
        }
        #expect(try await harness.shutdown() == .shutdownRequested)
    }

    @Test func listRejectsOneOversizedSummaryAndStopsAtTheRequestedHundredRows() async throws {
        let oversizedRoot = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: oversizedRoot) }
        let oversizedHarness = try await prepared(oversizedRoot, decisions: false)
        let oversized = try createSession(
            in: oversizedHarness, source: .imported(originalFilename: "too-large.wav"),
            createdAt: Date(timeIntervalSince1970: 1_700_500_000), includeImportedOriginal: true
        )
        try saveMetadata(
            at: oversized,
            attempt: FinalizationAttempt(
                attemptID: "oversized", state: .failed, failureReason: String(repeating: "あ", count: 400_000)
            ),
            activeRuns: nil, pendingBoundary: []
        )
        do {
            _ = try await list(
                oversizedHarness.app.core, context: requestContext(for: oversizedHarness), cursor: nil, limit: 100
            )
            Issue.record("a single summary larger than the output line must fail")
        } catch let error as EngineCommandError {
            #expect(error.code == .filesystem)
        }

        let oversizedContext = try requestContext(for: oversizedHarness)
        do {
            _ = try await inspect(
                oversizedHarness.app.core, context: oversizedContext, folderID: oversized.lastPathComponent
            )
            Issue.record("a single summary larger than the output line must fail inspection")
        } catch let error as EngineCommandError {
            #expect(error.code == .filesystem)
            #expect(error.message == "保存済み録音の情報が大きすぎて詳細を返せません")
            #expect(error.stage == .recovery)
            #expect(error.recoveryAction == .inspectSession)
        }
        let inspectPayload = try EngineSessionInspectPayload(folderID: oversized.lastPathComponent)
        let inspectJSON = String(decoding: try JSONEncoder().encode(inspectPayload), as: UTF8.self)
        #expect(try await oversizedHarness.failureCode(of: "session.inspect", payload: inspectJSON) == .filesystem)
        _ = try await oversizedHarness.call("state.get")
        #expect(try await oversizedHarness.shutdown() == .shutdownRequested)

        let boundaryRoot = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: boundaryRoot) }
        let boundaryHarness = try await prepared(boundaryRoot, decisions: false)
        for index in 0..<101 {
            _ = try createSession(
                in: boundaryHarness, source: .imported(originalFilename: "boundary-\(index).wav"),
                createdAt: Date(timeIntervalSince1970: 1_700_600_000 + Double(index * 60)), includeImportedOriginal: false
            )
        }
        let context = try requestContext(for: boundaryHarness)
        let hundred = try await list(boundaryHarness.app.core, context: context, cursor: nil, limit: 100)
        #expect(hundred.sessions.count == 100)
        let finalCursor = try #require(hundred.nextCursor)
        let one = try await list(boundaryHarness.app.core, context: context, cursor: finalCursor, limit: 100)
        #expect(one.sessions.count == 1)
        #expect(one.nextCursor == nil)
        #expect(one.previousCursor != nil)
        #expect(try await boundaryHarness.shutdown() == .shutdownRequested)
    }

    private func writeTranscriptHistory(at sessionURL: URL, sessionID: UUID, segmentCount: Int) async throws {
        let layout = SessionLayout(sessionURL: sessionURL)
        try SessionAudioStorageStore(layout: layout).save(.importedOriginal(
            try TimelineAudioInfo(committedFrames: Int64(segmentCount * 1_000), gapEvents: [])
        ))
        let writer = try SessionWriter(sessionURL: sessionURL)
        let segmentation = "history-seg"
        let asr = "history-asr"
        let provenance = RunProvenance(engine: "host-test-history", model: nil, version: "1", configuration: [:])
        try await writer.append(EventDraft(
            eventType: "processing.run.started", sessionID: sessionID, processingRunID: segmentation,
            payload: ProcessingRunStartedPayload(stage: .segmentation, provenance: provenance)
        ))
        try await writer.append(EventDraft(
            eventType: "processing.run.started", sessionID: sessionID, processingRunID: asr,
            payload: ProcessingRunStartedPayload(stage: .asr, provenance: provenance)
        ))
        for index in 0..<segmentCount {
            let segmentID = "history-\(index)"
            let start = Int64(index * 1_000)
            try await writer.append(EventDraft(
                eventType: "segment.created", sessionID: sessionID, segmentationRunID: segmentation,
                segmentID: segmentID, sourceStartFrame: start, sourceEndFrame: start + 900, payload: EmptyPayload()
            ))
            try await writer.append(EventDraft(
                eventType: "asr.completed", sessionID: sessionID, processingRunID: asr,
                segmentationRunID: segmentation, segmentID: segmentID,
                sourceStartFrame: start, sourceEndFrame: start + 900,
                payload: ASRCompletedEventPayload(
                    text: "履歴の文字起こし \(index)。", detectedLanguage: "ja", provenance: provenance
                )
            ))
        }
        try await writer.append(EventDraft(
            eventType: "processing.run.completed", sessionID: sessionID, processingRunID: segmentation,
            payload: ProcessingRunCompletedPayload(stage: .segmentation, succeeded: true, completedCount: segmentCount, failedCount: 0)
        ))
        try await writer.append(EventDraft(
            eventType: "processing.run.completed", sessionID: sessionID, processingRunID: asr,
            payload: ProcessingRunCompletedPayload(stage: .asr, succeeded: true, completedCount: segmentCount, failedCount: 0)
        ))
        let activeRuns = ActiveRuns(segmentation: segmentation, asr: asr)
        let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: layout.eventsURL))
        let events = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: activeRuns)
        let pendingBoundary = try events.compactMap { try $0.asrSource() }
        try saveMetadata(
            at: sessionURL,
            attempt: FinalizationAttempt(attemptID: "history-complete", state: .complete, failureReason: nil),
            activeRuns: activeRuns,
            pendingBoundary: pendingBoundary
        )
    }
}
