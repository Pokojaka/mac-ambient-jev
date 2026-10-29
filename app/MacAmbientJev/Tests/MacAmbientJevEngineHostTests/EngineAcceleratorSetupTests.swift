import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
@testable import MacAmbientJevEngineProtocol

private actor FakeAccelerator: EngineAcceleratorRegistry, EngineAcceleratorDevice, ASREngine {
    nonisolated let ortVersion = "1.31.0"
    nonisolated let modelRevision = "fake-model-revision"
    nonisolated let provenance = RunProvenance(engine: "fake-accelerator", model: nil, version: "test", configuration: [:])
    private let output: String
    private(set) var calls: [String] = []

    init(output: String) { self.output = output }
    func registerLibrary(_ descriptor: EngineAcceleratorDescriptor) async throws {
        calls.append("register:\(descriptor.providerName):\(descriptor.deviceID)")
    }
    func selectDevice(providerName: String, deviceID: String) async throws -> any EngineAcceleratorDevice {
        calls.append("select:\(providerName):\(deviceID)"); return self
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

    private func fixture(root existingRoot: URL? = nil, output: String = EngineAcceleratorVerificationFixture.expectedText) throws -> Fixture {
        let root = try existingRoot ?? ApplicationHarness.makeRoot()
        let paths = engineTestPaths(root: root)
        let transport = EngineTransport(source: ScriptedSource(), sink: ScriptedSink(), limits: testLimits())
        let events = EngineEventEmitter(transport: transport)
        let accelerator = FakeAccelerator(output: output)
        let app = EngineApplication(
            configuration: EngineApplicationConfiguration(paths: paths, logicalCPUCount: 4,
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
        let descriptor = try EngineAcceleratorDescriptor(providerName: "catalog-provider", deviceID: "catalog-device",
            gpuName: "Catalog GPU", driverVersion: "driver-test", adapterID: "adapter-test", architecture: "x64",
            dedicatedVRAMBytes: 4, packageIdentity: "catalog-package", libraryPath: #"C:\catalog\ep.dll"#,
            libraryHash: String(repeating: "a", count: 64), dependencies: [])
        let binding = try await f.app.core.bind(EngineAcceleratorsBindPayload(descriptor: descriptor), context: f.context)
        let result = try await f.app.core.verify(EngineAcceleratorsVerifyPayload(bindingID: binding.bindingID, asrSize: .small, threads: 2), context: f.context)
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
        #expect(key.gpuName == descriptor.gpuName && key.driverVersion == descriptor.driverVersion && key.adapterID == descriptor.adapterID)
        #expect(key.deviceID == descriptor.deviceID && key.architecture == descriptor.architecture && key.epLibraryHash == descriptor.libraryHash)
        #expect(key.modelSize == EngineASRSize.small.rawValue && key.threads == 2)
        #expect(key.modelRevision == f.accelerator.modelRevision && key.ortVersion == f.accelerator.ortVersion && key.ortVersion == "1.31.0")
        let packageIdentity = [descriptor.providerName, descriptor.packageIdentity] + descriptor.dependencies.map(\.hash).sorted()
        #expect(key.epPackageHash == FileSHA256.hexDigest(of: try JSONEncoder().encode(packageIdentity)))
        #expect(key.decodingSettings == EngineAcceleratorVerificationFixture.decodingSettings)
        #expect(key.fixtureHash == EngineAcceleratorVerificationFixture.fixtureHash && key.verificationPolicyVersion == EngineAcceleratorVerificationFixture.policyVersion)
        #expect(try EngineVerificationStore(paths: f.paths).load(for: key) == receipt)
        let receiptText = String(decoding: bytes, as: UTF8.self)
        #expect(!receiptText.contains(descriptor.libraryPath) && !receiptText.contains(binding.bindingID))
        #expect(await f.accelerator.history() == ["register:catalog-provider:catalog-device", "select:catalog-provider:catalog-device",
            "make:small:2:ja:448:nil", "prepare", "transcribe", "unload"])
    }

    @Test func rejectsUnknownAndUnsupportedBindingsAndBusyRecording() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let descriptor = try EngineAcceleratorDescriptor(providerName: "catalog-provider", deviceID: "catalog-device",
            gpuName: "Catalog GPU", driverVersion: "driver-test", adapterID: "adapter-test", architecture: "x64",
            dedicatedVRAMBytes: nil, packageIdentity: "catalog-package", libraryPath: #"C:\catalog\ep.dll"#,
            libraryHash: String(repeating: "b", count: 64), dependencies: [])
        let binding = try await f.app.core.bind(EngineAcceleratorsBindPayload(descriptor: descriptor), context: f.context)
        for payload in [try EngineAcceleratorsVerifyPayload(bindingID: "unknown", asrSize: .small, threads: 2),
                        try EngineAcceleratorsVerifyPayload(bindingID: binding.bindingID, asrSize: .large, threads: 2)] {
            do { _ = try await f.app.core.verify(payload, context: f.context); Issue.record("invalid verification was accepted") }
            catch let error as EngineCommandError { #expect(error.code == .invalidRequest) }
        }
        #expect(await f.accelerator.history().isEmpty)
        let sessionID = UUID()
        f.app.core.recording.start(sessionID: sessionID); f.app.core.recording.didStart(sessionID: sessionID)
        defer { f.app.core.recording.finish() }
        do { _ = try await f.app.core.bind(EngineAcceleratorsBindPayload(descriptor: descriptor), context: f.context); Issue.record("busy bind was accepted") }
        catch let error as EngineCommandError { #expect(error.code == .busy && error.message.contains("録音")) }
        do { _ = try await f.app.core.verify(EngineAcceleratorsVerifyPayload(bindingID: binding.bindingID, asrSize: .small, threads: 2), context: f.context); Issue.record("busy verify was accepted") }
        catch let error as EngineCommandError { #expect(error.code == .busy && error.message.contains("録音")) }
        #expect(await f.accelerator.history().isEmpty)
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
