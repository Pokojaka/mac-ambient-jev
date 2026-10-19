import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import MacAmbientJevAppleSupport
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private enum Outcome: CaseIterable, CustomTestStringConvertible {
    case success, noSpeech, vadFails, diarizationFails, diarizationCancelled, asrFails, paused

    var testDescription: String { String(describing: self) }

    var reachesDiarization: Bool {
        switch self {
        case .success, .diarizationFails, .diarizationCancelled, .asrFails, .paused: true
        case .noSpeech, .vadFails: false
        }
    }

    var completes: Bool { self == .success || self == .noSpeech }
}

private enum Kind: CaseIterable, CustomTestStringConvertible {
    case recording, imported

    var testDescription: String { String(describing: self) }
}

private struct ExpectedFailure: Error {}

/// Two blocks of constant speech, so every engine can derive its result from the audio it receives.
private let speechSamples: [Float] =
    Array(repeating: 0.3, count: 16_000) + Array(repeating: -0.5, count: 16_000)
private let silentSamples = [Float](repeating: 0, count: 32_000)

private final class EngineObservations: Sendable {
    private let cafSeenDuringDiarization = Mutex(false)
    var sawDiarizationInput: Bool { cafSeenDuringDiarization.withLock { $0 } }
    func diarizationInputSeen() { cafSeenDuringDiarization.withLock { $0 = true } }
}

private struct ProbeVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "probe-vad", model: nil, version: "test", configuration: [:])
    let fails: Bool

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        guard !fails else { throw ExpectedFailure() }
        let samples = try reader.readSamples(frameRange: 0..<reader.info.committedFrames)
        guard let first = samples.firstIndex(where: { abs($0) > 0.05 }),
              let last = samples.lastIndex(where: { abs($0) > 0.05 }) else { return [] }
        return [SegmentReference(
            segmentationRunID: runID, segmentID: "speech", startFrame: Int64(first), endFrame: Int64(last + 1)
        )]
    }
}

private struct ProbeDiarizer: DiarizationEngine {
    enum Mode: Sendable { case succeed, fail, cancel }

    let provenance = RunProvenance(engine: "probe-diarizer", model: nil, version: "test", configuration: [:])
    let mode: Mode
    let observations: EngineObservations

    func prepare() async throws {}
    func unload() async {}

    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] {
        let file = try AVAudioFile(forReading: fileURL)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        observations.diarizationInputSeen()
        switch mode {
        case .fail: throw ExpectedFailure()
        case .cancel: throw CancellationError()
        case .succeed: break
        }
        let samples = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        return stride(from: 0, to: samples.count, by: 16_000).map { start in
            let block = samples[start..<min(start + 16_000, samples.count)]
            return SpeakerSpan(
                speakerID: block.reduce(0, +) > 0 ? "S1" : "S2",
                startFrame: Int64(start), endFrame: Int64(start + block.count), confidence: 0.9
            )
        }
    }
}

private struct ProbeASR: ASREngine {
    let provenance = RunProvenance(engine: "probe-asr", model: nil, version: "test", configuration: [:])
    let fails: Bool

    func prepare() async throws {}
    func unload() async {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        guard !fails else { throw ExpectedFailure() }
        let mean = input.samples.reduce(0, +) / Float(input.samples.count)
        return ASRResult(text: "mean \(String(format: "%.3f", mean))", detectedLanguage: "ja")
    }
}

private func engines(for outcome: Outcome, observations: EngineObservations) -> SessionProcessingEngines {
    SessionProcessingEngines(
        asr: ProbeASR(fails: outcome == .asrFails),
        diarization: ProbeDiarizer(
            mode: outcome == .diarizationFails ? .fail : outcome == .diarizationCancelled ? .cancel : .succeed,
            observations: observations
        ),
        finalTranscriptVAD: ProbeVAD(fails: outcome == .vadFails)
    )
}

private actor UpdateRecorder {
    private(set) var last: [MaterializedTranscriptSegment] = []
    private(set) var statuses: [String] = []
    func record(_ segments: [MaterializedTranscriptSegment]) { last = segments }
    func record(status: String) { statuses.append(status) }
}

private struct Fixture {
    let root: URL
    let paths: AppPaths
    let sessionID: UUID
    let layout: SessionLayout
    let kind: Kind

    func manifest() throws -> SessionManifest { try layout.loadManifest() }

    func source() throws -> SessionAudioSource {
        try #require(try layout.audioSource(for: manifest()))
    }

    func cleanUp() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: layout.audioDirectory.path)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: layout.derivedDirectory.path
        )
        try? FileManager.default.removeItem(at: root)
    }

    /// The only CAF `diarize` receives, plus the import timeline, as left by a killed run.
    func seedStaleTransients() throws {
        try FileManager.default.createDirectory(at: layout.derivedDirectory, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: layout.diarizationInputURL)
        try Data("stale".utf8).write(to: layout.recordingFLACPartialURL)
        if kind == .imported {
            try FileManager.default.createDirectory(at: layout.processingDirectory, withIntermediateDirectories: true)
            try Data("stale".utf8).write(to: layout.processingDirectory.appending(path: "stale"))
        }
    }

    func processor(_ engines: SessionProcessingEngines) -> NativeSessionProcessor {
        NativeSessionProcessor(paths: paths, engines: engines, contentPriority: .disabled)
    }

    func process(
        _ processor: NativeSessionProcessor,
        shouldPause: Bool = false,
        recorder: UpdateRecorder = UpdateRecorder()
    ) async throws -> (SessionProcessingResult, UpdateRecorder) {
        let result = await processor.processSession(
            sessionID: sessionID,
            pacingMode: .normal,
            shouldPause: { shouldPause },
            onPhase: { _ in },
            metadataPolicy: .reject,
            onStatus: { await recorder.record(status: $0) },
            onUpdate: { segments, _ in await recorder.record(segments) }
        )
        return (result, recorder)
    }
}

private func makeFixture(_ kind: Kind, samples: [Float]) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    let sessionID = UUID()
    let bootstrapper = SessionBootstrapper(fileManager: .default)
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    switch kind {
    case .recording:
        let layout = SessionLayout(sessionURL: try bootstrapper.createSession(
            paths: paths, sessionID: sessionID, source: .recording(.microphone),
            createdAt: createdAt, timeZone: TimeZone(secondsFromGMT: 0)!
        ))
        let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: layout.sessionURL)
        try await writer.append(samples: samples)
        _ = try await writer.finish()
        return Fixture(root: root, paths: paths, sessionID: sessionID, layout: layout, kind: kind)
    case .imported:
        let layout = SessionLayout(sessionURL: try bootstrapper.createSession(
            paths: paths, sessionID: sessionID, source: .imported(originalFilename: "fixture.caf"),
            createdAt: createdAt, timeZone: TimeZone(secondsFromGMT: 0)!
        ))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: layout.audioDirectory.appending(path: "original.caf"), settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
        return Fixture(root: root, paths: paths, sessionID: sessionID, layout: layout, kind: kind)
    }
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func expectNoTransients(_ fixture: Fixture) {
    #expect(!exists(fixture.layout.derivedDirectory))
    #expect(!exists(fixture.layout.diarizationInputURL))
    #expect(!exists(fixture.layout.recordingFLACPartialURL))
    if fixture.kind == .imported {
        #expect(!exists(fixture.layout.processingDirectory))
    }
}

@Test(arguments: Outcome.allCases, Kind.allCases)
private func everyOutcomeRemovesTheDiarizationInputAndTheImportTimeline(outcome: Outcome, kind: Kind) async throws {
    let fixture = try await makeFixture(kind, samples: outcome == .noSpeech ? silentSamples : speechSamples)
    defer { fixture.cleanUp() }
    try fixture.seedStaleTransients()
    let observations = EngineObservations()

    let (result, _) = try await fixture.process(
        fixture.processor(engines(for: outcome, observations: observations)), shouldPause: outcome == .paused
    )

    #expect(result.disposition == (outcome.completes ? .completed : outcome == .paused ? .paused : .failed))
    #expect(observations.sawDiarizationInput == outcome.reachesDiarization)
    expectNoTransients(fixture)
    let storage = try SessionAudioStorageStore(layout: fixture.layout).load()
    switch (kind, outcome.completes) {
    case (.recording, true):
        guard case .recordingFLAC(let info) = storage else {
            Issue.record("a completed recording is stored as FLAC, not \(storage)")
            return
        }
        #expect(info.committedFrames == 32_000)
        #expect(!exists(fixture.layout.processingDirectory))
        #expect(exists(fixture.layout.recordingFLACURL))
    case (.recording, false):
        guard case .recordingPCM = storage else {
            Issue.record("a recording without a published transcript stays PCM, not \(storage)")
            return
        }
        #expect(exists(fixture.layout.processingDirectory))
        #expect(!exists(fixture.layout.recordingFLACURL))
    case (.imported, _):
        #expect(exists(fixture.layout.audioDirectory.appending(path: "original.caf")))
        #expect(!exists(fixture.layout.recordingFLACURL))
    }
}

@Test
func aFinalizationThatFailsToStartStillRemovesStaleTransients() async throws {
    let fixture = try await makeFixture(.recording, samples: speechSamples)
    defer { fixture.cleanUp() }
    try fixture.seedStaleTransients()
    try Data("{broken".utf8).write(to: fixture.layout.processingMetadataURL)

    let (result, _) = try await fixture.process(
        fixture.processor(engines(for: .success, observations: EngineObservations()))
    )

    #expect(result.disposition == .failed)
    #expect(result.message?.hasPrefix("確定処理を開始できませんでした") == true)
    expectNoTransients(fixture)
    guard case .recordingPCM = try SessionAudioStorageStore(layout: fixture.layout).load() else {
        Issue.record("a start failure leaves the recording as PCM")
        return
    }
}

@Test
func finishingALiveRecordingCompactsItToFLAC() async throws {
    let fixture = try await makeFixture(.recording, samples: speechSamples)
    defer { fixture.cleanUp() }
    guard case .recordedPCM(let checkpoint) = try fixture.source() else {
        Issue.record("a fresh recording is PCM")
        return
    }

    let result = await fixture.processor(engines(for: .success, observations: EngineObservations()))
        .finishLiveTranscription(
            sessionID: fixture.sessionID, checkpoint: checkpoint, finalSegments: [], pacingMode: .normal,
            shouldPause: { false }, onPhase: { _ in }, onStatus: { _ in }, onUpdate: { _, _ in }
        )

    #expect(result.disposition == .completed)
    #expect(try SessionAudioStorageStore(layout: fixture.layout).load() == .recordingFLAC(try checkpoint.info))
    #expect(!exists(fixture.layout.processingDirectory))
    expectNoTransients(fixture)
}

@Test
func aCleanupFailureAfterACompletedRunKeepsTheTranscriptAndSaysSo() async throws {
    let fixture = try await makeFixture(.recording, samples: silentSamples)
    defer { fixture.cleanUp() }
    try fixture.seedStaleTransients()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.layout.derivedDirectory.path)

    let (result, recorder) = try await fixture.process(
        fixture.processor(engines(for: .noSpeech, observations: EngineObservations()))
    )

    #expect(result.disposition == .failed)
    #expect(result.retainedTranscript == .finalized)
    #expect(result.message?.hasPrefix("文字起こしは保存しましたが、音声の一時ファイルを削除できませんでした: ") == true)
    #expect(await recorder.statuses.last == result.message)
    #expect(try ProcessingMetadataStore(sessionURL: fixture.layout.sessionURL).load()?.activeRuns != nil)
    #expect(try SessionStorageMaintenance.required(layout: fixture.layout, manifest: fixture.manifest()) != nil)
}

@Test
func aCleanupFailureAfterAFailedRunFollowsTheRunError() async throws {
    let fixture = try await makeFixture(.recording, samples: speechSamples)
    defer { fixture.cleanUp() }
    try fixture.seedStaleTransients()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.layout.derivedDirectory.path)

    let (result, _) = try await fixture.process(
        fixture.processor(engines(for: .vadFails, observations: EngineObservations()))
    )

    #expect(result.disposition == .failed)
    let message = try #require(result.message)
    let separator = try #require(message.range(of: "。音声の一時ファイルを削除できませんでした: "))
    #expect(!message[..<separator.lowerBound].isEmpty)
}

@Test
func aCompactionFailureKeepsTheTranscriptAndPCMAndLaunchMaintenanceFinishesIt() async throws {
    let fixture = try await makeFixture(.recording, samples: silentSamples)
    defer { fixture.cleanUp() }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.layout.audioDirectory.path)

    let (result, _) = try await fixture.process(
        fixture.processor(engines(for: .noSpeech, observations: EngineObservations()))
    )

    #expect(result.disposition == .failed)
    #expect(result.retainedTranscript == .finalized)
    #expect(result.message?.hasPrefix("文字起こしは保存しましたが、録音を FLAC にできませんでした: ") == true)
    #expect(try ProcessingMetadataStore(sessionURL: fixture.layout.sessionURL).load()?.activeRuns != nil)
    guard case .recordingPCM = try SessionAudioStorageStore(layout: fixture.layout).load() else {
        Issue.record("a failed compaction leaves the recording as PCM")
        return
    }
    #expect(exists(fixture.layout.processingDirectory))

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.layout.audioDirectory.path)
    let manifest = try fixture.manifest()
    let maintenance = try #require(try SessionStorageMaintenance.required(layout: fixture.layout, manifest: manifest))
    #expect(maintenance == .compactRecording)
    try SessionStorageMaintainer.run(maintenance, layout: fixture.layout, manifest: manifest)
    #expect(try SessionStorageMaintenance.required(layout: fixture.layout, manifest: manifest) == nil)
    #expect(!exists(fixture.layout.processingDirectory))
    #expect(exists(fixture.layout.recordingFLACURL))
}

private func transcript(_ segments: [MaterializedTranscriptSegment]) -> [String] {
    segments.map { segment in
        let speakers = segment.speakers.map { "\($0.displayLabel ?? $0.id)@\($0.startMilliseconds)-\($0.endMilliseconds)" }
        return "\(segment.startMilliseconds)-\(segment.endMilliseconds) \(segment.text) \(speakers)"
    }
}

@Test
func reprocessingAfterCompactionProducesTheSameTranscriptFromTheFLAC() async throws {
    let fixture = try await makeFixture(.recording, samples: speechSamples)
    defer { fixture.cleanUp() }
    let processor = fixture.processor(engines(for: .success, observations: EngineObservations()))

    let (first, firstUpdates) = try await fixture.process(processor)
    let pcmRows = await firstUpdates.last
    let pcmTranscript = transcript(pcmRows)

    #expect(first.disposition == .completed)
    #expect(pcmRows.map(\.text) == ["mean -0.100"])
    #expect(pcmRows.map(\.startMilliseconds) == [0])
    #expect(pcmRows.map(\.endMilliseconds) == [2_000])
    #expect(pcmRows.flatMap(\.speakers).map(\.id) == ["S1", "S2"])
    guard case .recordedFLAC = try fixture.source() else {
        Issue.record("the stored recording is FLAC after finalization")
        return
    }
    #expect(!exists(fixture.layout.processingDirectory))
    let flacBytes = try Data(contentsOf: fixture.layout.recordingFLACURL)

    let (second, secondUpdates) = try await fixture.process(processor)

    #expect(second.disposition == .completed)
    #expect(transcript(await secondUpdates.last) == pcmTranscript)
    #expect(try Data(contentsOf: fixture.layout.recordingFLACURL) == flacBytes)
    #expect(!exists(fixture.layout.processingDirectory))
    expectNoTransients(fixture)
}

@Test
func aFailedReprocessKeepsThePublishedTranscriptAndTheFLAC() async throws {
    let fixture = try await makeFixture(.recording, samples: speechSamples)
    defer { fixture.cleanUp() }
    let (first, firstUpdates) = try await fixture.process(
        fixture.processor(engines(for: .success, observations: EngineObservations()))
    )
    #expect(first.disposition == .completed)
    let published = try ProcessingMetadataStore(sessionURL: fixture.layout.sessionURL).load()?.activeRuns
    let flacBefore = try Data(contentsOf: fixture.layout.recordingFLACURL)
    let storageBefore = try SessionAudioStorageStore(layout: fixture.layout).load()

    let (failed, failedUpdates) = try await fixture.process(
        fixture.processor(engines(for: .asrFails, observations: EngineObservations()))
    )

    #expect(failed.disposition == .failed)
    #expect(failed.retainedTranscript == .finalized)
    #expect(transcript(await failedUpdates.last) == transcript(await firstUpdates.last))
    #expect(try ProcessingMetadataStore(sessionURL: fixture.layout.sessionURL).load()?.activeRuns == published)
    #expect(try Data(contentsOf: fixture.layout.recordingFLACURL) == flacBefore)
    #expect(try SessionAudioStorageStore(layout: fixture.layout).load() == storageBefore)
    #expect(!exists(fixture.layout.processingDirectory))
    expectNoTransients(fixture)
}

@Test
func aCleanupFailureDuringAPauseStaysPausedAndReportsTheCleanupError() async throws {
    let fixture = try await makeFixture(.recording, samples: speechSamples)
    defer { fixture.cleanUp() }
    let partial = fixture.layout.recordingFLACPartialURL
    try Data("stale".utf8).write(to: partial)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: partial.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: partial.path) }

    let (result, recorder) = try await fixture.process(
        fixture.processor(engines(for: .paused, observations: EngineObservations())), shouldPause: true
    )

    #expect(result.disposition == .paused)
    #expect(await recorder.statuses.contains { $0.hasPrefix("音声の一時ファイルを削除できませんでした: ") })
    let attempt = try ProcessingMetadataStore(sessionURL: fixture.layout.sessionURL).load()?.finalizationAttempt
    #expect(attempt?.state == .paused)
}

@Test
func aSessionCompactedByMaintenanceFinalizesFromTheFLACWithoutAStaleSource() async throws {
    let fixture = try await makeFixture(.recording, samples: speechSamples)
    defer { fixture.cleanUp() }
    guard case .recordedPCM = try fixture.source() else {
        Issue.record("a fresh recording is PCM")
        return
    }
    try SessionStorageMaintainer.run(.compactRecording, layout: fixture.layout, manifest: fixture.manifest())
    #expect(!exists(fixture.layout.processingDirectory))

    let (result, updates) = try await fixture.process(
        fixture.processor(engines(for: .success, observations: EngineObservations()))
    )

    #expect(result.disposition == .completed)
    let rows = await updates.last
    #expect(rows.map(\.text) == ["mean -0.100"])
    #expect(rows.map(\.startMilliseconds) == [0])
    #expect(rows.map(\.endMilliseconds) == [2_000])
    #expect(rows.flatMap(\.speakers).map(\.id) == ["S1", "S2"])
    #expect(exists(fixture.layout.recordingFLACURL))
}
