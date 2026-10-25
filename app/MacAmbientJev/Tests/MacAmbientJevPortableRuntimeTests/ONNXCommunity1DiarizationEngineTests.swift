import Dispatch
import Foundation
import MacAmbientJevCore
import MacAmbientJevTestSupport
import Testing
@testable import MacAmbientJevDiarization
@testable import MacAmbientJevPortableRuntime

private final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    let changes = ChangeSignal()
    private var loads = 0
    private var loadExecutorMatches: [Bool] = []
    private var runs = 0
    private var runExecutorMatches: [Bool] = []
    private var inFlight = 0
    private var peak = 0
    private var requests: [(sampleCount: Int64, firstSamples: [Float])] = []

    func recordLoad(onBlockingIOExecutor: Bool) {
        lock.lock()
        loads += 1
        loadExecutorMatches.append(onBlockingIOExecutor)
        lock.unlock()
        changes.signal()
    }

    func begin(sampleCount: Int64, firstSamples: [Float], onBlockingIOExecutor: Bool) {
        lock.lock()
        runs += 1
        runExecutorMatches.append(onBlockingIOExecutor)
        inFlight += 1
        peak = max(peak, inFlight)
        requests.append((sampleCount, firstSamples))
        lock.unlock()
        changes.signal()
    }

    func end() {
        lock.lock()
        inFlight -= 1
        lock.unlock()
        changes.signal()
    }

    var snapshot: (
        loads: Int,
        loadExecutorMatches: [Bool],
        runs: Int,
        runExecutorMatches: [Bool],
        peak: Int,
        inFlight: Int,
        requests: [(sampleCount: Int64, firstSamples: [Float])]
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            loads,
            loadExecutorMatches,
            runs,
            runExecutorMatches,
            peak,
            inFlight,
            requests
        )
    }
}

private final class KernelRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var isReleased = false

    func wait() {
        releaseSemaphore.wait()
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        releaseSemaphore.signal()
    }
}

private final class WaitConditionProbe: @unchecked Sendable {
    let changes = ChangeSignal()
    private let lock = NSLock()
    private var hasEvaluatedCondition = false

    func evaluateFalse() -> Bool {
        lock.lock()
        hasEvaluatedCondition = true
        lock.unlock()
        changes.signal()
        return false
    }

    var conditionWasEvaluated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasEvaluatedCondition
    }
}

private let testProvenance = RunProvenance(
    engine: "fake-community1", model: nil, version: "test", configuration: [:]
)

private func fakeEngine(
    directory: URL,
    log: RunLog,
    runDelay: TimeInterval = 0,
    runGate: KernelRunGate? = nil
) -> ONNXCommunity1DiarizationEngine {
    ONNXCommunity1DiarizationEngine(
        modelDirectory: directory,
        provenance: testProvenance,
        loadKernel: { _ in
            let isBlockingIOExecutor = withUnsafeCurrentTask {
                $0?.unownedTaskExecutor == BlockingIOExecutor.shared.asUnownedTaskExecutor()
            }
            log.recordLoad(onBlockingIOExecutor: isBlockingIOExecutor)
            return Community1DiarizationKernel { sampleCount, readFrames in
                let head = try readFrames(0..<min(sampleCount, 4))
                let isBlockingIOExecutor = withUnsafeCurrentTask {
                    $0?.unownedTaskExecutor == BlockingIOExecutor.shared.asUnownedTaskExecutor()
                }
                log.begin(
                    sampleCount: sampleCount,
                    firstSamples: head,
                    onBlockingIOExecutor: isBlockingIOExecutor
                )
                defer { log.end() }
                runGate?.wait()
                if runDelay > 0 { Thread.sleep(forTimeInterval: runDelay) }
                return [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: sampleCount, confidence: 1)]
            }
        }
    )
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Community1Engine-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite(.timeLimit(.minutes(10)))
struct ONNXCommunity1DiarizationEngineTests {
    @Test
    func prepareAndUnloadAreIdempotentAndPrepareLoadsAgainAfterUnload() async throws {
        let log = RunLog()
        let engine = fakeEngine(directory: URL(fileURLWithPath: "/models"), log: log)
        #expect(await engine.isPrepared == false)

        try await engine.prepare()
        try await engine.prepare()
        #expect(await engine.isPrepared)
        #expect(log.snapshot.loads == 1)

        await engine.unload()
        await engine.unload()
        #expect(await engine.isPrepared == false)

        try await engine.prepare()
        #expect(await engine.isPrepared)
        #expect(log.snapshot.loads == 2)
    }

    @Test
    func concurrentPreparesLoadOnceOnTheBlockingIOExecutor() async throws {
        let log = RunLog()
        let engine = fakeEngine(directory: URL(fileURLWithPath: "/models"), log: log)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { try await engine.prepare() }
            }
            try await group.waitForAll()
        }

        #expect(log.snapshot.loads == 1)
        #expect(log.snapshot.loadExecutorMatches == [true])
        #expect(await engine.isPrepared)
    }

    @Test
    func diarizeRequiresAPreparedEngine() async throws {
        let session = try Community1CAFSession(samples: [0.25, -0.5, 0.75])
        defer { session.cleanup() }
        let engine = fakeEngine(directory: URL(fileURLWithPath: "/models"), log: RunLog())

        await #expect(throws: ONNXCommunity1DiarizationEngineError.notPrepared) {
            _ = try await engine.diarize(fileURL: session.cafURL, canonicalSampleRate: 16_000, sessionURL: session.root)
        }
        try await engine.prepare()
        await engine.unload()
        await #expect(throws: ONNXCommunity1DiarizationEngineError.notPrepared) {
            _ = try await engine.diarize(fileURL: session.cafURL, canonicalSampleRate: 16_000, sessionURL: session.root)
        }
    }

    @Test
    func diarizeReadsTheCanonicalCAFThroughTheKernelReader() async throws {
        let samples: [Float] = [0.25, -0.5, 0.75, 0.125, 0.5]
        let session = try Community1CAFSession(samples: samples)
        defer { session.cleanup() }
        let log = RunLog()
        let engine = fakeEngine(directory: URL(fileURLWithPath: "/models"), log: log)
        try await engine.prepare()

        let spans = try await engine.diarize(fileURL: session.cafURL, canonicalSampleRate: 16_000, sessionURL: session.root)

        #expect(spans == [SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 5, confidence: 1)])
        #expect(log.snapshot.requests.map(\.sampleCount) == [5])
        #expect(log.snapshot.requests.map(\.firstSamples) == [Array(samples.prefix(4))])
    }

    @Test
    func diarizeRejectsANoncanonicalSampleRateBeforeReading() async throws {
        let log = RunLog()
        let engine = fakeEngine(directory: URL(fileURLWithPath: "/models"), log: log)
        try await engine.prepare()
        let session = try Community1CAFSession(samples: [0])
        defer { session.cleanup() }

        await #expect(throws: CanonicalAudioError.self) {
            _ = try await engine.diarize(fileURL: session.cafURL, canonicalSampleRate: 48_000, sessionURL: session.root)
        }
        #expect(log.snapshot.runs == 0)
    }

    @Test
    func diarizeRejectsAFileThatIsNotACanonicalCAF() async throws {
        let session = try Community1CAFSession(samples: [0])
        defer { session.cleanup() }
        let notCAF = session.root.appendingPathComponent("input.wav")
        try SessionFileAccess.writeAtomically(Data("RIFF".utf8), to: notCAF, relativeTo: session.root)
        let log = RunLog()
        let engine = fakeEngine(directory: URL(fileURLWithPath: "/models"), log: log)
        try await engine.prepare()

        await #expect(throws: CanonicalCAFError.self) {
            _ = try await engine.diarize(fileURL: notCAF, canonicalSampleRate: 16_000, sessionURL: session.root)
        }
        #expect(log.snapshot.runs == 0)
    }

    @Test
    func concurrentDiarizeCallsRunOneAtATime() async throws {
        let session = try Community1CAFSession(samples: [0.1, 0.2, 0.3, 0.4])
        defer { session.cleanup() }
        let log = RunLog()
        let engine = fakeEngine(directory: URL(fileURLWithPath: "/models"), log: log, runDelay: 0.03)
        try await engine.prepare()

        let results = try await withThrowingTaskGroup(of: [SpeakerSpan].self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await engine.diarize(fileURL: session.cafURL, canonicalSampleRate: 16_000, sessionURL: session.root)
                }
            }
            var all: [[SpeakerSpan]] = []
            for try await spans in group { all.append(spans) }
            return all
        }

        #expect(results.count == 5)
        #expect(results.allSatisfy { $0 == results[0] })
        #expect(log.snapshot.runs == 5)
        #expect(log.snapshot.runExecutorMatches == Array(repeating: true, count: 5))
        #expect(log.snapshot.peak == 1)
    }

    @Test
    func unloadWaitsForTheRunningDiarize() async throws {
        let session = try Community1CAFSession(samples: [0.1, 0.2, 0.3, 0.4])
        defer { session.cleanup() }
        let log = RunLog()
        let gate = KernelRunGate()
        let engine = fakeEngine(directory: URL(fileURLWithPath: "/models"), log: log, runGate: gate)
        try await engine.prepare()

        let running = Task {
            try await engine.diarize(fileURL: session.cafURL, canonicalSampleRate: 16_000, sessionURL: session.root)
        }
        var unloading: Task<Void, Never>?
        do {
            try await log.changes.wait("diarize run entry") { log.snapshot.runs > 0 }
            unloading = Task { await engine.unload() }

            #expect(log.snapshot.inFlight == 1)
            gate.release()
            let spans = try await running.value
            if let unloading { await unloading.value }

            #expect(log.snapshot.inFlight == 0)
            #expect(log.snapshot.runExecutorMatches == [true])
            #expect(spans.count == 1)
            #expect(await engine.isPrepared == false)
        } catch {
            gate.release()
            do {
                _ = try await running.value
            } catch {}
            if let unloading { await unloading.value }
            throw error
        }
    }

    @Test
    func cancellationStopsAChangeSignalWait() async throws {
        let probe = WaitConditionProbe()
        let neverChanges = ChangeSignal()
        let waiting = Task {
            try await neverChanges.wait("cancelled condition") { probe.evaluateFalse() }
        }

        do {
            try await probe.changes.wait("waiter condition to be evaluated") { probe.conditionWasEvaluated }
        } catch {
            waiting.cancel()
            do {
                _ = try await waiting.value
            } catch {}
            throw error
        }
        waiting.cancel()

        await #expect(throws: WaitCancelled.self) {
            try await waiting.value
        }
    }
}

@Suite(.timeLimit(.minutes(10)))
struct ONNXCommunity1DiarizationEngineModelDirectoryTests {
    private func engine(directory: URL) throws -> ONNXCommunity1DiarizationEngine {
        try ONNXCommunity1DiarizationEngine(modelDirectory: directory, intraOpThreads: 1)
    }

    @Test
    func aMissingModelDirectoryFailsPreparationWithTheFetchCommand() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let engine = try engine(directory: parent.appendingPathComponent("missing", isDirectory: true))

        do {
            try await engine.prepare()
            Issue.record("prepare() must fail when the model files are missing")
        } catch {
            #expect("\(error)".contains("scripts/fetch_community1_diarization.py"))
        }
        #expect(await engine.isPrepared == false)
    }

    @Test
    func aCorruptModelFileFailsPreparation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for file in try Community1Manifest.bundled().files {
            try Data("corrupt".utf8).write(to: directory.appendingPathComponent(file.name))
        }
        let engine = try engine(directory: directory)

        await #expect(throws: Community1AssetsError.self) { try await engine.prepare() }
        #expect(await engine.isPrepared == false)
    }

    @Test
    func provenanceNamesThePinnedRevisionsAndFileHashes() throws {
        let directory = URL(fileURLWithPath: "/models")
        let provenance = try engine(directory: directory).provenance
        let manifest = try Community1Manifest.bundled()

        #expect(provenance.engine == "onnxruntime-community1-diarizer")
        #expect(provenance.version == "onnxruntime-1.31.0")
        for source in manifest.sources.values {
            #expect(provenance.model?.contains("\(source.repository)@\(source.revision)") == true)
        }
        for file in manifest.files {
            #expect(provenance.configuration["sha256.\(file.name)"] == file.sha256)
        }
        #expect(provenance.configuration["embedding.min_segment_duration_seconds"] == "0.3")
        #expect(provenance.configuration["intra_op_threads"] == "1")
    }
}
