import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
@testable import MacAmbientJevEngineProtocol

private actor FakeAccelerator: EngineAcceleratorRegistry, EngineAcceleratorDevice, ASREngine {
    nonisolated let info: EngineAcceleratorDeviceInfo
    nonisolated let ortVersion = "1.31.0"
    nonisolated let modelRevision = "fake-model-revision"
    nonisolated let provenance = RunProvenance(engine: "fake-accelerator", model: nil, version: "test", configuration: [:])
    private let output: String
    private let duplicateDevices: Bool
    private(set) var calls: [String] = []

    init(output: String, duplicateDevices: Bool = false) throws {
        self.output = output; self.duplicateDevices = duplicateDevices
        info = try EngineAcceleratorDeviceInfo(deviceKey: "gpu:10de:2684", type: "gpu", description: "Engine GPU",
            driverVersion: "engine-driver", dedicatedMemoryBytes: 4)
    }
    func bind(_ descriptor: EngineAcceleratorDescriptor) async throws -> [any EngineAcceleratorDevice] {
        calls.append("bind:\(descriptor.providerName)"); return duplicateDevices ? [self, self] : [self]
    }
    func makeASREngine(size: ASRModelSize, threads: Int, language: String, maxNewTokens: Int, noRepeatNgramSize: Int?) async throws -> any ASREngine {
        calls.append("make:\(size):\(threads):\(language):\(maxNewTokens):\(String(describing: noRepeatNgramSize))"); return self
    }
    func prepare() async throws { calls.append("prepare") }
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
        let app: EngineApplication
        let context: EngineRequestContext
    }

    private func fixture(root existingRoot: URL? = nil, output: String = EngineAcceleratorVerificationFixture.expectedText,
                         duplicateDevices: Bool = false) throws -> Fixture {
        let root = try existingRoot ?? ApplicationHarness.makeRoot()
        let paths = engineTestPaths(root: root)
        let transport = EngineTransport(source: ScriptedSource(), sink: ScriptedSink(), limits: testLimits())
        let events = EngineEventEmitter(transport: transport)
        let accelerator = try FakeAccelerator(output: output, duplicateDevices: duplicateDevices)
        let resources = FakeResourceMonitor()
        let app = EngineApplication(
            configuration: EngineApplicationConfiguration(paths: paths, logicalCPUCount: 4,
                resourceMonitor: resources, memoryProber: resources,
                sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: .seconds(20)),
            capture: FakeCapture(), inference: FakeInferenceProvider(), events: events, acceleratorRegistry: accelerator
        )
        let context = EngineRequestContext(requestID: try EngineID(1), events: events)
        return Fixture(root: root, paths: paths, accelerator: accelerator, app: app, context: context)
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
        #expect(key.driverVersion == f.accelerator.info.driverVersion)
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
}
