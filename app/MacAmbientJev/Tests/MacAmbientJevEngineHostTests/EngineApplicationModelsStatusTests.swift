import Foundation
import Testing
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

@MainActor
@Suite(.timeLimit(.minutes(10))) struct EngineApplicationModelsStatusTests {
    private func capabilities(_ h: ApplicationHarness) async throws -> EngineCapabilities {
        guard case let .hello(ready) = try await h.call("hello") else { preconditionFailure("hello returned another result") }
        return ready.capabilities
    }

    private func windowsMLSettings() throws -> EngineSettings {
        try EngineSettings(
            schemaVersion: 2, source: .microphone, device: .default, asrSize: .small,
            executionProvider: .windowsML(providerName: "P", deviceKey: "gpu:1", verificationID: "v"),
            threads: 1, lowHeat: false, decisionsEnabled: false, automaticExport: false, exportDestinationPath: nil
        )
    }

    @Test func capabilitiesReportTheKindsTheHostSupports() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cpuOnly = ApplicationHarness(root: root)
        cpuOnly.start()
        #expect(try await capabilities(cpuOnly).executionProviderKinds == [.cpu])
        let request = EngineSettingsReplacePayload(expectedRevision: nil, settings: try windowsMLSettings())
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(try await cpuOnly.failureCode(of: "settings.replace", payload: payload) == .invalidSettings)
        _ = try await cpuOnly.shutdown()

        let windowsRoot = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: windowsRoot) }
        let windows = ApplicationHarness(root: windowsRoot, acceleratorRegistry: WindowsMLCapableRegistry())
        windows.start()
        #expect(try await capabilities(windows).executionProviderKinds == [.cpu, .windowsML])
        try await windows.replaceSettings(try windowsMLSettings(), expectedRevision: nil)
        _ = try await windows.shutdown()
    }

    @Test func statusListsEverySizeWithoutSettingsAndWritesNothing() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = ApplicationHarness(root: root)
        h.start()
        try await h.hello()
        let missing = try EngineASRProfileStatus(asrSize: .large, state: .missing, message: "モデル(asr)がありません")
        let corrupt = try EngineASRProfileStatus(asrSize: .small, state: .corrupt, message: "モデル(vad)が不正です")
        let tagger = try EngineClauseTaggerStatus(state: .corrupt, message: "モデル(clause_tagger)が不正です")
        h.inference.sizeStatuses.set([.small: corrupt, .large: missing])
        h.inference.taggerStatus.set(tagger)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        guard case let .modelsStatus(status) = try await h.call("models.status") else { preconditionFailure("not a status result") }
        #expect(status.asrProfiles == [corrupt, missing])
        #expect(status.clauseTagger == tagger)
        h.inference.sizeStatuses.set([:])
        h.inference.taggerStatus.set(nil)
        guard case let .modelsStatus(installed) = try await h.call("models.status") else { preconditionFailure("not a status result") }
        #expect(installed.asrProfiles.map(\.state) == [.installed, .installed])
        #expect(installed.asrProfiles.allSatisfy { $0.message == nil })
        #expect(installed.clauseTagger.state == .installed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == before)
        _ = try await h.shutdown()
    }
}
