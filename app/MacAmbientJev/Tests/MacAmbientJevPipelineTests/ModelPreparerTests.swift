import Foundation
import Synchronization
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private final class FakeProvisioning: ModelProvisioning {
    private struct State {
        var fetched: Set<MacModel> = []
        var failures: [MacModel: Int] = [:]
        var calls: [String] = []
        var gate: CheckedContinuation<Void, Never>?
        var holdFirstFetch = false
    }
    private let state = Mutex(State())
    let sizes: [MacModel: Int64] = [.asr: 2_400, .diarization: 21, .vad: 3]

    init(fetched: Set<MacModel> = []) { state.withLock { $0.fetched = fetched } }

    var calls: [String] { state.withLock { $0.calls } }
    func failNextFetch(of model: MacModel) { state.withLock { $0.failures[model, default: 0] += 1 } }
    func holdFirstFetch() { state.withLock { $0.holdFirstFetch = true } }
    func releaseHeldFetch() { state.withLock { $0.gate?.resume(); $0.gate = nil } }
    var isHolding: Bool { state.withLock { $0.gate != nil } }

    func byteCount(_ model: MacModel) -> Int64 { sizes[model]! }
    func isFetched(_ model: MacModel) -> Bool { state.withLock { $0.fetched.contains(model) } }

    func fetch(_ model: MacModel, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        state.withLock { $0.calls.append("fetch:\(model.rawValue)") }
        if state.withLock({ $0.holdFirstFetch }) {
            state.withLock { $0.holdFirstFetch = false }
            await withCheckedContinuation { continuation in state.withLock { $0.gate = continuation } }
        }
        if state.withLock({ $0.failures[model, default: 0] > 0 }) {
            state.withLock { $0.failures[model, default: 0] -= 1 }
            throw ModelDownloadError.network(file: "\(model.rawValue).bin", reason: "切断されました")
        }
        progress(ModelDownloadProgress(bytesDone: sizes[model]!, bytesTotal: sizes[model]!))
        state.withLock { $0.fetched.insert(model) }
    }

    func verify(_ model: MacModel) async throws { state.withLock { $0.calls.append("verify:\(model.rawValue)") } }
}

private struct RecordingASR: ASREngine {
    let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    func prepare() async throws {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult { preconditionFailure("not used") }
    func unload() async {}
}

@MainActor
@Test
func missingModelsAreFetchedSmallestFirstThenVerified() async {
    let provisioning = FakeProvisioning(fetched: [.diarization])
    let preparer = ModelPreparer(provisioning: provisioning, asr: RecordingASR())
    var phases: [ModelPreparationStatus.Phase] = []
    preparer.onChange = { phases.append($0.phase) }

    preparer.ensurePrepared(after: nil)
    #expect(preparer.status.phase == .downloading)
    #expect(preparer.status.bytesTotal == 2_403)
    await preparer.runTask?.value

    #expect(provisioning.calls == [
        "fetch:vad", "fetch:asr", "verify:vad", "verify:diarization"
    ])
    #expect(preparer.status.phase == .ready)
    #expect(preparer.status.bytesDone == 2_403)
    #expect(phases.contains(.loading))
    #expect(!preparer.isRunning)
}

@MainActor
@Test
func concurrentTriggersJoinTheRunningPreparation() async {
    let provisioning = FakeProvisioning()
    provisioning.holdFirstFetch()
    let preparer = ModelPreparer(provisioning: provisioning, asr: RecordingASR())

    preparer.ensurePrepared(after: nil)
    let running = preparer.runTask
    preparer.ensurePrepared(after: nil)
    preparer.retry(after: nil)
    #expect(preparer.runTask == running)
    while !provisioning.isHolding { await Task.yield() }
    provisioning.releaseHeldFetch()
    await preparer.runTask?.value

    #expect(provisioning.calls.filter { $0.hasPrefix("fetch:") } == ["fetch:vad", "fetch:diarization", "fetch:asr"])
    #expect(preparer.status.phase == .ready)
}

@MainActor
@Test
func aFailureStopsTheRunAndOnlyRetryStartsAnother() async {
    let provisioning = FakeProvisioning()
    provisioning.failNextFetch(of: .diarization)
    let preparer = ModelPreparer(provisioning: provisioning, asr: RecordingASR())

    preparer.ensurePrepared(after: nil)
    await preparer.runTask?.value

    guard case let .failed(reason) = preparer.status.phase else {
        Issue.record("the run must end in a failure: \(preparer.status.phase)")
        return
    }
    #expect(reason.contains("話者分離") && reason.contains("切断されました"))
    #expect(provisioning.calls == ["fetch:vad", "fetch:diarization"])
    #expect(!preparer.isRunning)

    preparer.ensurePrepared(after: nil)
    preparer.ensurePrepared(after: nil)
    #expect(!preparer.isRunning)
    #expect(provisioning.calls == ["fetch:vad", "fetch:diarization"])

    preparer.retry(after: nil)
    await preparer.runTask?.value
    #expect(preparer.status.phase == .ready)
    #expect(provisioning.calls.filter { $0 == "fetch:vad" }.count == 1)
    #expect(provisioning.calls.filter { $0 == "fetch:diarization" }.count == 2)
}

@MainActor
@Test
func afterAnUnloadTheNextRunLoadsWithoutFetching() async {
    let provisioning = FakeProvisioning(fetched: Set(MacModel.allCases))
    let preparer = ModelPreparer(provisioning: provisioning, asr: RecordingASR())
    preparer.ensurePrepared(after: nil)
    await preparer.runTask?.value
    #expect(preparer.status.phase == .ready)

    preparer.ensurePrepared(after: nil)
    #expect(!preparer.isRunning)
    preparer.didUnload()
    #expect(preparer.status.phase == .idle)
    preparer.ensurePrepared(after: nil)
    #expect(preparer.status.phase == .loading)
    await preparer.runTask?.value
    #expect(preparer.status.phase == .ready)
    #expect(!provisioning.calls.contains { $0.hasPrefix("fetch:") })
}
