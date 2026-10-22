import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

@MainActor
@Suite struct EngineSettingsStoreHandlerTests {
    private func makeHandler(
        rejects: @escaping @MainActor (EngineSettings?, EngineSettings) -> Bool = { _, _ in false }
    ) throws -> (EngineSettingsStoreHandler, EngineRequestContext, URL) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "EngineSettingsStoreHandlerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = AppPaths(
            applicationSupportURL: base.appending(path: "support", directoryHint: .isDirectory),
            cacheURL: base.appending(path: "cache", directoryHint: .isDirectory),
            sessionsRootOverride: nil
        )
        let transport = EngineTransport(source: ScriptedSource(), sink: ScriptedSink(), limits: testLimits())
        let context = EngineRequestContext(requestID: try EngineID(1), events: EngineEventEmitter(transport: transport))
        return (EngineSettingsStoreHandler(store: EngineSettingsStore(paths: paths, logicalCPUCount: 8), rejectsReplacement: rejects), context, base)
    }

    @Test func getBeforeSetupIsSettingsRequired() async throws {
        let (handler, context, base) = try makeHandler()
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            _ = try await handler.get(context: context)
            Issue.record("expected failure")
        } catch let error as EngineCommandError {
            #expect(error.code == .settingsRequired)
            #expect(error.recoveryAction == .replaceSettings)
        }
    }

    @Test func firstSetupThenGetThenStaleReplace() async throws {
        let (handler, context, base) = try makeHandler()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try await handler.replace(EngineSettingsReplacePayload(expectedRevision: nil, settings: sampleSettings()), context: context)
        #expect(first.revision.value == 1)
        #expect(try await handler.get(context: context) == first)
        do {
            _ = try await handler.replace(EngineSettingsReplacePayload(expectedRevision: nil, settings: sampleSettings()), context: context)
            Issue.record("expected stale revision")
        } catch let error as EngineCommandError {
            #expect(error.code == .staleRevision)
        }
    }

    @Test func conflictingReplacementWhileBusyIsRejectedWithoutWriting() async throws {
        let (handler, context, base) = try makeHandler(rejects: { current, _ in current == nil })
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            _ = try await handler.replace(EngineSettingsReplacePayload(expectedRevision: nil, settings: sampleSettings()), context: context)
            Issue.record("expected busy")
        } catch let error as EngineCommandError {
            #expect(error.code == .busy)
        }
        do {
            _ = try await handler.get(context: context)
            Issue.record("settings were written")
        } catch let error as EngineCommandError {
            #expect(error.code == .settingsRequired)
        }
    }

    @Test func aCorruptFileIsRepairedByAnExplicitFullReplacement() async throws {
        let (handler, context, base) = try makeHandler()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appending(path: "support/mac-ambient-jev", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: root.appending(path: "settings.json"))
        do {
            _ = try await handler.get(context: context)
            Issue.record("expected invalid settings")
        } catch let error as EngineCommandError {
            #expect(error.code == .invalidSettings)
        }
        let repaired = try await handler.replace(EngineSettingsReplacePayload(expectedRevision: nil, settings: sampleSettings()), context: context)
        #expect(repaired.revision.value == 1)
    }
}
