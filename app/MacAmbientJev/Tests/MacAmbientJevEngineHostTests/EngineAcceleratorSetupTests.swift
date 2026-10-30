import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
@testable import MacAmbientJevEngineProtocol

private actor FakeAccelerator: EngineAcceleratorRegistry, EngineAcceleratorDevice, ASREngine {
    nonisolated let info: EngineAcceleratorDeviceInfo
    nonisolated let adapterIdentity: String
    nonisolated let ortVersion = "1.31.0"
    nonisolated let modelRevision = "fake-model-revision"
    nonisolated let provenance = RunProvenance(engine: "fake-accelerator", model: nil, version: "test", configuration: [:])
    private var output: String
    private var preparationFails = false
    private let duplicateDevices: Bool
    private(set) var calls: [String] = []

    init(output: String, adapterIdentity: String = "test-adapter", duplicateDevices: Bool = false) throws {
        self.output = output; self.adapterIdentity = adapterIdentity; self.duplicateDevices = duplicateDevices
        info = try EngineAcceleratorDeviceInfo(deviceKey: "gpu:10de:2684", type: "gpu", description: "Engine GPU",
            driverVersion: "engine-driver", dedicatedMemoryBytes: 4)
    }
    func bind(_ descriptor: EngineAcceleratorDescriptor) async throws -> [any EngineAcceleratorDevice] {
        calls.append("bind:\(descriptor.providerName)"); return duplicateDevices ? [self, self] : [self]
    }
    func makeASREngine(size: ASRModelSize, threads: Int, language: String, maxNewTokens: Int, noRepeatNgramSize: Int?) async throws -> any ASREngine {
        calls.append("make:\(size):\(threads):\(language):\(maxNewTokens):\(String(describing: noRepeatNgramSize))"); return self
    }
    func configureRetest(output: String, preparationFails: Bool) { self.output = output; self.preparationFails = preparationFails }
    func prepare() async throws {
        calls.append("prepare")
        if preparationFails { throw EngineAdapterError(code: .modelFailure, message: "fake prepare failure", recoveryAction: .none, details: []) }
    }
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        calls.append("transcribe"); return ASRResult(text: output, detectedLanguage: "ja")
    }
    func unload() async { calls.append("unload") }
    func history() -> [String] { calls }
}

@MainActor
@Suite struct EngineAcceleratorSetupTests {
    private struct Fixture {
        let root: URL
        let paths: AppPaths
        let accelerator: FakeAccelerator
        let inference: FakeInferenceProvider
        let app: EngineApplication
        let context: EngineRequestContext
    }

    private func fixture(root existingRoot: URL? = nil, output: String = EngineAcceleratorVerificationFixture.expectedText,
                         adapterIdentity: String = "test-adapter", duplicateDevices: Bool = false) throws -> Fixture {
        let root = try existingRoot ?? ApplicationHarness.makeRoot()
        let paths = engineTestPaths(root: root)
        let transport = EngineTransport(source: ScriptedSource(), sink: ScriptedSink(), limits: testLimits())
        let events = EngineEventEmitter(transport: transport)
        let accelerator = try FakeAccelerator(output: output, adapterIdentity: adapterIdentity, duplicateDevices: duplicateDevices)
        let resources = FakeResourceMonitor(), inference = FakeInferenceProvider()
        let app = EngineApplication(
            configuration: EngineApplicationConfiguration(paths: paths, logicalCPUCount: 4,
                resourceMonitor: resources, memoryProber: resources,
                sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: .seconds(20)),
            capture: FakeCapture(), inference: inference, events: events, acceleratorRegistry: accelerator
        )
        let context = EngineRequestContext(requestID: try EngineID(1), events: events)
        return Fixture(root: root, paths: paths, accelerator: accelerator, inference: inference, app: app, context: context)
    }

    @Test(arguments: [true, false])
    func verifiesFixedOutputAndPersistsReceipt(passes: Bool) async throws {
        let output = passes ? EngineAcceleratorVerificationFixture.expectedText
            : String(EngineAcceleratorVerificationFixture.expectedText.dropLast()) + "?"
        let f = try fixture(output: output)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let descriptor = try EngineAcceleratorDescriptor(providerName: "catalog-provider", packageFullName: "catalog-package",
            packageArchitecture: "x64", libraryPath: #"C:\catalog\ep.dll"#,
            libraryHash: String(repeating: "a", count: 64), dependencies: [])
        let binding = try await f.app.core.bind(EngineAcceleratorsBindPayload(descriptor: descriptor), context: f.context)
        let result = try await f.app.core.verify(EngineAcceleratorsVerifyPayload(bindingID: binding.bindingID,
            deviceKey: binding.devices[0].deviceKey, asrSize: .small, threads: 2), context: f.context)
        let verificationID: String
        switch result {
        case let .pass(id, rtf):
            #expect(passes); #expect(rtf.isFinite && rtf > 0); verificationID = id
        case let .fail(id, reason, observed):
            #expect(!passes); #expect(observed == output); #expect(!reason.isEmpty); verificationID = id
        }
        let receiptURL = f.paths.root.appending(path: "accelerators/\(verificationID).json")
        let bytes = try Data(contentsOf: receiptURL)
        let receipt = try JSONDecoder().decode(EngineVerificationReceipt.self, from: bytes)
        let key = receipt.key
        #expect(receipt.passed == passes && receipt.observedOutput == output && receipt.rtf.isFinite && receipt.rtf > 0)
        #expect(key.providerName == descriptor.providerName && key.packageFullName == descriptor.packageFullName)
        #expect(key.libraryHash == descriptor.libraryHash && key.packageArchitecture == descriptor.packageArchitecture)
        #expect(key.deviceKey == f.accelerator.info.deviceKey && key.description == f.accelerator.info.description)
        #expect(key.driverVersion == f.accelerator.info.driverVersion && key.adapterIdentity == f.accelerator.adapterIdentity)
        #expect(key.dependencyHashes.isEmpty)
        #expect(key.modelSize == EngineASRSize.small.rawValue && key.threads == 2)
        #expect(key.modelRevision == f.accelerator.modelRevision && key.ortVersion == f.accelerator.ortVersion && key.ortVersion == "1.31.0")
        #expect(key.decodingSettings == EngineAcceleratorVerificationFixture.decodingSettings)
        #expect(key.fixtureHash == EngineAcceleratorVerificationFixture.fixtureHash && key.verificationPolicyVersion == EngineAcceleratorVerificationFixture.policyVersion)
        #expect(try EngineVerificationStore(paths: f.paths).load(for: key) == receipt)
        let receiptText = String(decoding: bytes, as: UTF8.self)
        #expect(!receiptText.contains(descriptor.libraryPath) && !receiptText.contains(binding.bindingID))
        #expect(await f.accelerator.history() == ["bind:catalog-provider", "make:small:2:ja:448:nil", "prepare", "transcribe", "unload"])
    }

    @Test func rejectsUnknownAndUnsupportedBindingsAndBusyRecording() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let descriptor = try EngineAcceleratorDescriptor(providerName: "catalog-provider", packageFullName: "catalog-package",
            packageArchitecture: "x64", libraryPath: #"C:\catalog\ep.dll"#,
            libraryHash: String(repeating: "b", count: 64), dependencies: [])
        let binding = try await f.app.core.bind(EngineAcceleratorsBindPayload(descriptor: descriptor), context: f.context)
        for payload in [try EngineAcceleratorsVerifyPayload(bindingID: "unknown", deviceKey: binding.devices[0].deviceKey, asrSize: .small, threads: 2),
                        try EngineAcceleratorsVerifyPayload(bindingID: binding.bindingID, deviceKey: "gpu:0000:0000", asrSize: .small, threads: 2),
                        try EngineAcceleratorsVerifyPayload(bindingID: binding.bindingID, deviceKey: binding.devices[0].deviceKey, asrSize: .large, threads: 2)] {
            do { _ = try await f.app.core.verify(payload, context: f.context); Issue.record("invalid verification was accepted") }
            catch let error as EngineCommandError { #expect(error.code == .invalidRequest) }
        }
        #expect(await f.accelerator.history() == ["bind:catalog-provider"])
        let sessionID = UUID()
        f.app.core.recording.start(sessionID: sessionID); f.app.core.recording.didStart(sessionID: sessionID)
        defer { f.app.core.recording.finish() }
        do { _ = try await f.app.core.bind(EngineAcceleratorsBindPayload(descriptor: descriptor), context: f.context); Issue.record("busy bind was accepted") }
        catch let error as EngineCommandError { #expect(error.code == .busy && error.message.contains("録音")) }
        do { _ = try await f.app.core.verify(EngineAcceleratorsVerifyPayload(bindingID: binding.bindingID,
            deviceKey: binding.devices[0].deviceKey, asrSize: .small, threads: 2), context: f.context); Issue.record("busy verify was accepted") }
        catch let error as EngineCommandError { #expect(error.code == .busy && error.message.contains("録音")) }
        #expect(await f.accelerator.history() == ["bind:catalog-provider"])
    }

    @Test func duplicateDeviceKeysRejectBinding() async throws {
        let f = try fixture(duplicateDevices: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let descriptor = try EngineAcceleratorDescriptor(providerName: "catalog-provider", packageFullName: "catalog-package",
            packageArchitecture: "x64", libraryPath: #"C:\catalog\ep.dll"#,
            libraryHash: String(repeating: "a", count: 64), dependencies: [])
        do { _ = try await f.app.core.bind(EngineAcceleratorsBindPayload(descriptor: descriptor), context: f.context); Issue.record("duplicate device keys were accepted") }
        catch let error as EngineCommandError {
            #expect(error.code == .modelFailure && error.message.contains("同じ device_key") && error.message.contains("区別"))
        }
        #expect(f.app.core.acceleratorBindings.isEmpty && f.app.core.profileSetupOperation == nil)
        #expect(await f.accelerator.history() == ["bind:catalog-provider"])
    }

    @Test func profileChoicesUseFreshRevisionsAndSurviveRestart() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let evaluate = try EngineProfilesEvaluatePayload(hardware: .noGPU, acquisition: .unavailable, threads: 1)
        let initial = try await f.app.core.evaluate(evaluate, context: f.context)
        #expect(initial.reason == .noGPU && initial.decisionState == .complete)
        let firstRevision = f.app.core.currentState().revision
        let smallRequest = try EngineProfilesDecidePayload(expectedRevision: firstRevision, choice: .small)
        let small = try await f.app.core.decide(smallRequest, context: f.context)
        #expect(small.decisionState == .complete && small.requestedChoice == .small)
        #expect(try EngineProfileDecisionStore(paths: f.paths).load() == small)
        do { _ = try await f.app.core.decide(smallRequest, context: f.context); Issue.record("stale choice was accepted") }
        catch let error as EngineCommandError { #expect(error.code == .staleRevision) }
        let largeRequest = try EngineProfilesDecidePayload(expectedRevision: f.app.core.currentState().revision, choice: .large)
        let large = try await f.app.core.decide(largeRequest, context: f.context)
        #expect(large.decisionState == .awaitingAssets && large.reason == .awaitingAssets && large.requestedChoice == .large)
        #expect(f.app.core.settings == nil && f.app.core.inference == nil)
        let restarted = try fixture(root: f.root)
        #expect(restarted.app.core.currentState().profileSetup.evaluation == large)
        #expect(try await restarted.app.core.evaluate(evaluate, context: restarted.context) == large)
        #expect(restarted.app.core.currentState().profileSetup.evaluation?.requestedChoice == .large)
    }

    private func descriptor(hash: String = String(repeating: "b", count: 64)) throws -> EngineAcceleratorDescriptor {
        try EngineAcceleratorDescriptor(providerName: "catalog-provider", packageFullName: "catalog-package", packageArchitecture: "x64",
            libraryPath: #"C:\catalog\ep.dll"#, libraryHash: String(repeating: "a", count: 64),
            dependencies: [try EngineAcceleratorDependency(path: #"C:\catalog\dep.dll"#, hash: hash)])
    }
    private func windowsSettings(_ id: String, key: String = "gpu:10de:2684", size: EngineASRSize = .small) throws -> EngineSettings {
        try EngineSettings(schemaVersion: 2, source: .microphone, device: .default, asrSize: size,
            executionProvider: .windowsML(providerName: "catalog-provider", deviceKey: key, verificationID: id), threads: 2,
            lowHeat: false, decisionsEnabled: false, automaticExport: false, exportDestinationPath: nil)
    }
    private func save(_ f: Fixture, _ settings: EngineSettings, revision: UInt64? = nil) async throws {
        _ = try await f.app.core.replace(.init(expectedRevision: try revision.map { try EngineID($0) }, settings: settings), context: f.context)
    }
    private func verified(_ f: Fixture, _ descriptor: EngineAcceleratorDescriptor) async throws -> (EngineAcceleratorsBindResult, String) {
        let binding = try await f.app.core.bind(.init(descriptor: descriptor), context: f.context)
        let result = try await f.app.core.verify(.init(bindingID: binding.bindingID, deviceKey: binding.devices[0].deviceKey, asrSize: .small, threads: 2), context: f.context)
        guard case let .pass(id, _) = result else { throw EngineAdapterError(code: .modelFailure, message: "baseline verification failed", recoveryAction: .none, details: []) }
        let receipt = try #require(try EngineVerificationStore(paths: f.paths).load(identifier: id))
        #expect(receipt.key.adapterIdentity == f.accelerator.adapterIdentity && receipt.key.dependencyHashes == descriptor.dependencies.map(\.hash))
        #expect(!String(decoding: try Data(contentsOf: f.paths.root.appending(path: "accelerators/\(id).json")), as: UTF8.self).contains(descriptor.dependencies[0].path))
        return (binding, id)
    }
    private func reject(_ f: Fixture, reason: String) async throws {
        do { try await f.app.core.prepare(context: f.context); Issue.record("invalid accelerator settings were admitted") }
        catch let error as EngineCommandError {
            #expect(error.code == .invalidSettings && error.stage == .validatingModels && error.recoveryAction == .replaceSettings)
            #expect(error.message.contains(reason))
        }
        #expect(f.inference.calls.count("prepare") == 0 && f.app.core.inference == nil)
    }

    @Test(arguments: ["missingBinding", "missingDevice", "missingReceipt", "invalidID", "corruptJSON", "failedReceipt", "wrongOutput", "changedAdapter", "changedDependency", "large"])
    func rejectsUnverifiedAcceleratorSettings(scenario: String) async throws {
        var f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let d = try descriptor(), seeded = try await verified(f, d), id = seeded.1
        var settings = try windowsSettings(id); try await save(f, settings)
        var reason = ""
        switch scenario {
        case "missingBinding": f = try fixture(root: f.root); reason = "現在の binding がありません"
        case "missingDevice": settings = try windowsSettings(id, key: "gpu:0000:0000"); try await save(f, settings, revision: 1); reason = "device_key が現在の binding にありません"
        case "missingReceipt": settings = try windowsSettings(String(repeating: "0", count: 64)); try await save(f, settings, revision: 1); reason = "検証 receipt がありません"
        case "invalidID": settings = try windowsSettings("not-a-digest"); try await save(f, settings, revision: 1); reason = "receipt を読み込めません"
        case "corruptJSON": try Data([0xFF]).write(to: f.paths.root.appending(path: "accelerators/\(id).json")); reason = "receipt を読み込めません"
        case "failedReceipt", "wrongOutput":
            let receipt = try #require(try EngineVerificationStore(paths: f.paths).load(identifier: id))
            try EngineVerificationStore(paths: f.paths).publish(.init(key: receipt.key, observedOutput: scenario == "wrongOutput" ? "wrong" : receipt.observedOutput, passed: scenario == "wrongOutput", rtf: receipt.rtf, timestamp: receipt.timestamp))
            reason = "合格していません"
        case "changedAdapter": f = try fixture(root: f.root, adapterIdentity: "changed-adapter"); _ = try await f.app.core.bind(.init(descriptor: d), context: f.context); reason = "identity が現在の環境と一致しません"
        case "changedDependency": f = try fixture(root: f.root); _ = try await f.app.core.bind(.init(descriptor: try descriptor(hash: String(repeating: "c", count: 64))), context: f.context); reason = "identity が現在の環境と一致しません"
        case "large": settings = try windowsSettings(id, size: .large); try await save(f, settings, revision: 1); reason = "1.7B のアクセラレーター検証には対応していない"
        default: Issue.record("unknown scenario: \(scenario)"); return
        }
        try await reject(f, reason: reason)
    }

    @Test func admitsVerifiedAcceleratorButDoesNotPrepareCPU() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let d = try descriptor(), seeded = try await verified(f, d), settings = try windowsSettings(seeded.1)
        try await save(f, settings)
        let selected = try #require(try f.app.core.admitAccelerator(settings))
        #expect(selected.verificationID == seeded.1 && selected.descriptor == d && selected.device.info.deviceKey == f.accelerator.info.deviceKey)
        do { try await f.app.core.prepare(context: f.context); Issue.record("accelerated preparation unexpectedly succeeded") }
        catch let error as EngineCommandError { #expect(error.code == .invalidSettings && error.stage == .validatingModels && error.recoveryAction == .replaceSettings && error.message.contains("高速推論はまだ接続されていない")) }
        #expect(f.inference.calls.count("prepare") == 0)
    }

    @Test func rebindReplacesOnlyCurrentProviderBinding() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let d = try descriptor(), seeded = try await verified(f, d), settings = try windowsSettings(seeded.1)
        try await save(f, settings)
        let other = try EngineAcceleratorDescriptor(providerName: "other-provider", packageFullName: "other-package",
            packageArchitecture: "x64", libraryPath: #"C:\other\ep.dll"#,
            libraryHash: String(repeating: "c", count: 64), dependencies: [])
        let otherBinding = try await f.app.core.bind(.init(descriptor: other), context: f.context)
        let replacement = try await f.app.core.bind(.init(descriptor: d), context: f.context)
        #expect(replacement.bindingID != seeded.0.bindingID)
        do {
            _ = try await f.app.core.verify(.init(bindingID: seeded.0.bindingID, deviceKey: seeded.0.devices[0].deviceKey, asrSize: .small, threads: 2), context: f.context)
            Issue.record("superseded binding was accepted")
        } catch let error as EngineCommandError {
            #expect(error.code == .invalidRequest && error.message.contains("binding が見つかりません"))
        }
        let result = try await f.app.core.verify(.init(bindingID: replacement.bindingID, deviceKey: replacement.devices[0].deviceKey, asrSize: .small, threads: 2), context: f.context)
        if case let .pass(id, _) = result { #expect(id == seeded.1) } else { Issue.record("replacement binding did not pass") }
        if case .pass = try await f.app.core.verify(.init(bindingID: otherBinding.bindingID, deviceKey: otherBinding.devices[0].deviceKey, asrSize: .small, threads: 2), context: f.context) {} else { Issue.record("other provider binding was invalidated") }
        let selected = try #require(try f.app.core.admitAccelerator(settings))
        #expect(selected.verificationID == seeded.1)
        do { try await f.app.core.prepare(context: f.context); Issue.record("accelerated preparation unexpectedly succeeded") }
        catch let error as EngineCommandError { #expect(error.message.contains("高速推論はまだ接続されていない")) }
        #expect(f.inference.calls.count("prepare") == 0)
    }

    @Test(arguments: ["outputMismatch", "preparationFailure"])
    func failedRetestRejectsSettingsWithoutChangingBytes(scenario: String) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let d = try descriptor(), seeded = try await verified(f, d), settings = try windowsSettings(seeded.1)
        try await save(f, settings)
        let url = f.paths.root.appending(path: "settings.json"), bytes = try Data(contentsOf: url)
        await f.accelerator.configureRetest(output: scenario == "outputMismatch" ? "wrong" : EngineAcceleratorVerificationFixture.expectedText, preparationFails: scenario == "preparationFailure")
        do {
            let result = try await f.app.core.verify(.init(bindingID: seeded.0.bindingID, deviceKey: seeded.0.devices[0].deviceKey, asrSize: .small, threads: 2), context: f.context)
            if case let .fail(id, _, observed) = result { #expect(scenario == "outputMismatch" && id == seeded.1 && observed == "wrong") }
            else { Issue.record("retest unexpectedly passed") }
        } catch let error as EngineCommandError { #expect(scenario == "preparationFailure" && error.code == .modelFailure) }
        try await reject(f, reason: scenario == "outputMismatch" ? "合格していません" : "検証 receipt がありません")
        #expect(try Data(contentsOf: url) == bytes)
    }
}
