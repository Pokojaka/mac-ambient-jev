import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevHaasASR

struct HaasASREngineTests {
    @Test
    func canonicalMinimumBeforePrepareThrowsNotPrepared() async {
        let engine = makeEngine()
        await #expect(throws: HaasASRError.notPrepared) {
            _ = try await engine.transcribe(ASRAudioInput(samples: Array(repeating: 0, count: 320), sampleRate: 16_000))
        }
    }

    @Test
    func oversizedInputBeforePrepareThrowsExactDuration() async {
        let engine = makeEngine()
        await #expect(throws: HaasASRError.inputTooLong(seconds: 480_001.0 / 16_000)) {
            _ = try await engine.transcribe(ASRAudioInput(samples: Array(repeating: 0, count: 480_001), sampleRate: 16_000))
        }
    }

    @Test
    func shortInputBeforePrepareReturnsEmptyResult() async throws {
        let result = try await makeEngine().transcribe(
            ASRAudioInput(samples: Array(repeating: 0, count: 319), sampleRate: 16_000)
        )
        #expect(result == ASRResult(text: "", detectedLanguage: nil))
    }

    @Test
    func noncanonicalRatePrecedesLengthAndMinimumChecks() async {
        let engine = makeEngine()
        for count in [1_323_001, 319] {
            do {
                _ = try await engine.transcribe(ASRAudioInput(samples: Array(repeating: 0, count: count), sampleRate: 44_100))
                Issue.record("Expected noncanonicalFormat")
            } catch let error as CanonicalAudioError {
                if case .noncanonicalFormat = error {} else { Issue.record("Expected noncanonicalFormat, got \(error)") }
            } catch {
                Issue.record("Expected CanonicalAudioError, got \(error)")
            }
        }
    }

    @Test
    func unloadCancelsSuspendedPreparationBeforeOpeningGraph() async throws {
        let gate = ModelLocateGate()
        let engine = HaasASREngine(intraOpThreads: 1, locateModel: { try await gate.locate() })
        let preparation = Task { try await engine.prepare() }
        await gate.waitUntilStarted()
        let unloading = Task { await engine.unload() }
        while await engine.state != .stopped { await Task.yield() }
        await gate.resume(with: HaasASRModelFiles(verifiedDirectory: URL(fileURLWithPath: "/nonexistent")))
        await unloading.value

        await #expect(throws: CancellationError.self) { try await preparation.value }
        await #expect(throws: HaasASRError.notPrepared) {
            _ = try await engine.transcribe(ASRAudioInput(samples: Array(repeating: 0, count: 320), sampleRate: 16_000))
        }
        #expect(await engine.state == .stopped)
    }

    private func makeEngine() -> HaasASREngine {
        HaasASREngine(intraOpThreads: 1, locateModel: { HaasASRModelFiles(verifiedDirectory: URL(fileURLWithPath: "/unused")) })
    }
}

private actor ModelLocateGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<HaasASRModelFiles, any Error>?

    func locate() async throws -> HaasASRModelFiles {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        return try await withCheckedThrowingContinuation { result = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func resume(with files: HaasASRModelFiles) {
        result?.resume(returning: files)
        result = nil
    }
}
