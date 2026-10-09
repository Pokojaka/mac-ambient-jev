import Foundation
import Testing
@testable import MacAmbientJevCore

private enum PipelineTestError: Error {
    case failed
}

private actor SuccessfulPipelineASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        #expect(!input.samples.isEmpty)
        return ASRResult(text: "公開鍵暗号です", detectedLanguage: "ja")
    }

    func unload() async {}
}

private actor FailingPipelineASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        throw PipelineTestError.failed
    }

    func unload() async {}
}

private actor SequencedPipelineASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var count = 0

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        count += 1
        return ASRResult(text: "result-\(count)", detectedLanguage: "en")
    }

    func unload() async {}
}

private actor StalledPipelineASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var entered = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var transcriptionWaiter: CheckedContinuation<ASRResult, Never>?

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        await withCheckedContinuation { continuation in
            transcriptionWaiter = continuation
            entered = true
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitUntilTranscribing() async {
        if entered { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func finish() {
        transcriptionWaiter?.resume(returning: ASRResult(text: "処理済み", detectedLanguage: nil))
        transcriptionWaiter = nil
    }

    func unload() async {}
}


private func makeCoordinator(
    root: URL,
    processing: URL,
    checkpoint: AudioCheckpoint,
    asr: any ASREngine,
    pacingMode: ASRPacingMode,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    shouldPause: @escaping @Sendable () async -> Bool
) throws -> PipelineCoordinator {
    PipelineCoordinator(
        sessionID: UUID(),
        segmentationRunID: "seg",
        asrRunID: "asr",
        writer: try SessionWriter(sessionURL: root),
        asr: asr,
        loader: ASRAudioLoader(reader: try ProcessingTimelineReader(directory: processing, checkpoint: checkpoint, sessionURL: root)),
        pacingMode: pacingMode,
        sleep: sleep,
        shouldPause: shouldPause
    )
}

private func segments(_ ranges: [(String, Int64, Int64)]) -> [SegmentReference] {
    ranges.map { SegmentReference(segmentationRunID: "seg", segmentID: $0.0, startFrame: $0.1, endFrame: $0.2) }
}

private func pendingNow(_ segments: [SegmentReference]) -> [String: Date] {
    Dictionary(uniqueKeysWithValues: segments.map { ($0.segmentID, Date()) })
}

private func recognizedTexts(_ events: [TranscriptEvent]) -> [String] {
    events.compactMap { event in
        guard case .asrCompleted(let result) = event.kind else { return nil }
        return result.text
    }
}

private let noSleep: @Sendable (Duration) async throws -> Void = { _ in }
private let neverPause: @Sendable () async -> Bool = { false }

@Test
func durableAudioCommitsWhileASRIsStalled() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let processing = root.appending(path: "audio/processing")
    let processingWriter = try DurableAudioWriter(directory: processing, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await processingWriter.append(samples: Array(repeating: 0.25, count: 10))
    let checkpoint = try await processingWriter.finish()
    let captureWriter = try DurableAudioWriter(directory: root.appending(path: "audio/capture"), chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let asr = StalledPipelineASR()
    let coordinator = try makeCoordinator(
        root: root, processing: processing, checkpoint: checkpoint, asr: asr,
        pacingMode: .normal, sleep: noSleep, shouldPause: neverPause
    )
    let input = segments([("s1", 0, 10)])
    let task = Task {
        try await coordinator.run(segments: input, pendingSince: pendingNow(input), existingEvents: [])
    }
    await asr.waitUntilTranscribing()
    try await captureWriter.append(samples: Array(repeating: 0.5, count: 20))
    #expect(await captureWriter.committedSnapshot().committedFrames == 20)
    await asr.finish()
    #expect(recognizedTexts(try await task.value.events) == ["処理済み"])
}

private actor PacingProbe {
    private var observations: [(Duration, Int)] = []

    func record(duration: Duration, log: String) {
        let completedCount = log.components(
            separatedBy: #""event_type":"asr.completed""#
        ).count - 1
        observations.append((duration, completedCount))
    }

    func snapshot() -> [(Duration, Int)] { observations }
}

@Test
func lowHeatRestsAfterPersistedCompletionOnlyBetweenSegments() async throws {
    for mode: ASRPacingMode in [.normal, .lowHeat] {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let audioDirectory = root.appending(path: "audio/processing", directoryHint: .isDirectory)
        let audioWriter = try DurableAudioWriter(directory: audioDirectory, chunkDurationSeconds: 1, sessionURL: root)
        try await audioWriter.append(samples: Array(repeating: 0.25, count: 48_000))
        let checkpoint = try await audioWriter.finish()
        let probe = PacingProbe()
        let eventsURL = root.appending(path: "events.jsonl")
        let coordinator = try makeCoordinator(
            root: root, processing: audioDirectory, checkpoint: checkpoint,
            asr: SequencedPipelineASR(), pacingMode: mode,
            sleep: { duration in
                let log = try String(contentsOf: eventsURL, encoding: .utf8)
                await probe.record(duration: duration, log: log)
            },
            shouldPause: neverPause
        )

        let input = segments([("seg_0", 0, 16_000), ("seg_1", 16_000, 32_000), ("seg_2", 32_000, 48_000)])
        let result = try await coordinator.run(
            segments: input, pendingSince: pendingNow(input), existingEvents: []
        )

        #expect(result.disposition == .completed)
        #expect(result.completedCount == 3)
        #expect(recognizedTexts(result.events) == ["result-1", "result-2", "result-3"])
        let observations = await probe.snapshot()
        if mode == .lowHeat {
            #expect(observations.map(\.0) == [.seconds(2), .seconds(2)])
            #expect(observations.map(\.1) == [1, 2])
            #expect(result.metrics.pacingWaitCount == 2)
        } else {
            #expect(observations.isEmpty)
            #expect(result.metrics.pacingWaitCount == 0)
        }
        #expect(result.metrics.processedAudioSeconds == 3)
        #expect(result.metrics.asrRTF != nil)
    }
}

@Test
func criticalThermalPauseStopsBeforeRemainingSegmentsWithoutCompletingTheRun() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let audioDirectory = root.appending(path: "audio/processing")
    let writer = try DurableAudioWriter(directory: audioDirectory, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await writer.append(samples: Array(repeating: 0.25, count: 20))
    let checkpoint = try await writer.finish()
    let eventsURL = root.appending(path: "events.jsonl")
    let coordinator = try makeCoordinator(
        root: root, processing: audioDirectory, checkpoint: checkpoint,
        asr: SequencedPipelineASR(), pacingMode: .normal, sleep: noSleep,
        shouldPause: {
            let log = try? String(contentsOf: eventsURL, encoding: .utf8)
            return log?.contains(#""event_type":"asr.completed""#) == true
        }
    )
    let input = segments([("first", 0, 10), ("second", 10, 20)])
    let result = try await coordinator.run(segments: input, pendingSince: pendingNow(input), existingEvents: [])
    #expect(result.disposition == .paused)
    #expect(result.completedCount == 1)
    #expect(result.metrics.initialPendingCount == 2)
    let log = try String(contentsOf: eventsURL, encoding: .utf8)
    #expect(log.components(separatedBy: #""event_type":"asr.completed""#).count - 1 == 1)
    #expect(!log.contains(#""event_type":"processing.run.completed""#))
}

@Test
func coordinatorRejectsSegmentWithoutPendingTime() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let audioDirectory = root.appending(path: "audio/processing")
    let writer = try DurableAudioWriter(directory: audioDirectory, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await writer.append(samples: Array(repeating: 0.25, count: 20))
    let checkpoint = try await writer.finish()
    let coordinator = try makeCoordinator(
        root: root, processing: audioDirectory, checkpoint: checkpoint,
        asr: SequencedPipelineASR(), pacingMode: .normal, sleep: noSleep, shouldPause: neverPause
    )
    let input = segments([("first", 0, 10), ("second", 10, 20)])

    await #expect(throws: PipelineCoordinatorError.missingPendingTime(segmentID: "second")) {
        _ = try await coordinator.run(
            segments: input, pendingSince: ["first": Date()], existingEvents: []
        )
    }
    #expect(try String(contentsOf: root.appending(path: "events.jsonl"), encoding: .utf8).isEmpty)
}

@Test
func coordinatorPersistsCompletedResultAndCompletesTheRun() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let audioDirectory = root.appending(path: "audio/processing", directoryHint: .isDirectory)
    let audioWriter = try DurableAudioWriter(directory: audioDirectory, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await audioWriter.append(samples: Array(repeating: 0.25, count: 10))
    let checkpoint = try await audioWriter.finish()
    let coordinator = try makeCoordinator(
        root: root, processing: audioDirectory, checkpoint: checkpoint,
        asr: SuccessfulPipelineASR(), pacingMode: .normal, sleep: noSleep, shouldPause: neverPause
    )

    let input = segments([("seg_000001", 0, 10)])
    let result = try await coordinator.run(segments: input, pendingSince: pendingNow(input), existingEvents: [])

    #expect(result.disposition == .completed)
    #expect(result.completedCount == 1)
    #expect(recognizedTexts(result.events) == ["公開鍵暗号です"])
    let log = try String(contentsOf: root.appending(path: "events.jsonl"), encoding: .utf8)
    #expect(log.contains(#""event_type":"asr.completed""#))
    #expect(log.contains(#""succeeded":true"#))
}

@Test
func coordinatorReportsRecognitionFailuresByKind() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let audioDirectory = root.appending(path: "audio/processing", directoryHint: .isDirectory)
    let audioWriter = try DurableAudioWriter(directory: audioDirectory, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await audioWriter.append(samples: Array(repeating: 0.25, count: 10))
    let checkpoint = try await audioWriter.finish()
    let coordinator = try makeCoordinator(
        root: root, processing: audioDirectory, checkpoint: checkpoint,
        asr: FailingPipelineASR(), pacingMode: .normal, sleep: noSleep, shouldPause: neverPause
    )

    let input = segments([("seg_000001", 0, 10)])
    let result = try await coordinator.run(segments: input, pendingSince: pendingNow(input), existingEvents: [])

    #expect(result.completedCount == 0)
    guard case .failed(let failure) = result.disposition else {
        Issue.record("failed recognition must fail the run")
        return
    }
    #expect(failure.failedSegmentCount == 1)
    #expect(failure.failureCounts == [.transcriptionFailed: 1])
    #expect(failure.firstRecognitionMessage != nil)
    #expect(failure.persistenceFailure == nil)
    let log = try String(contentsOf: root.appending(path: "events.jsonl"), encoding: .utf8)
    #expect(log.contains(#""event_type":"asr.failed""#))
    #expect(log.contains(#""succeeded":false"#))
}


private actor SuccessfulDiarizationEngine: DiarizationEngine {
    nonisolated let provenance = RunProvenance(engine: "fake-diarizer", model: nil, version: "test", configuration: [:])
    func prepare() async throws {}
    func unload() async {}

    func diarize(
        fileURL: URL,
        canonicalSampleRate: Double,
        sessionURL: URL
    ) async throws -> [SpeakerSpan] {
        [
            SpeakerSpan(
                speakerID: "S1",
                startFrame: 0,
                endFrame: 50,
                confidence: 0.9
            ),
            SpeakerSpan(
                speakerID: "S2",
                startFrame: 50,
                endFrame: 100,
                confidence: 0.8
            )
        ]
    }
}

@Test
func diarizationCoordinatorAppendsSpeakerSpansAndMaterializesThem() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let writer = try SessionWriter(sessionURL: root)
    let existing: [TranscriptEvent] = [
        .segmentCreated(
            seq: 1,
            segmentationRunID: "seg_01",
            segmentID: "seg_000001",
            startFrame: 0,
            endFrame: 100
        ),
        .asrCompleted(
            seq: 2,
            runID: "asr_01",
            segmentationRunID: "seg_01",
            segmentID: "seg_000001",
            text: "話者が交代します",
            detectedLanguage: "ja"
        )
    ]

    let coordinator = DiarizationCoordinator(
        sessionID: sessionID,
        runID: "diar_01",
        writer: writer,
        engine: SuccessfulDiarizationEngine(),
        materializer: TranscriptMaterializer(sampleRate: 100)
    )

    let result = try await coordinator.process(
        fileURL: root.appending(path: "dummy.caf"),
        canonicalSampleRate: 100,
        existingEvents: existing,
        activeRuns: ActiveRuns(
            segmentation: "seg_01",
            asr: "asr_01",
            diarization: "diar_01"
        )
    )

    #expect(result.speakerSpans.count == 2)
    #expect(result.materializedSegments.first?.speakers.count == 2)

    let log = try String(
        contentsOf: root.appending(path: "events.jsonl"),
        encoding: .utf8
    )
    #expect(
        log.components(separatedBy: #""event_type":"speaker.span""#).count - 1 == 2
    )
    #expect(log.contains(#""stage":"diarization""#))
}

private actor ScriptedPipelineASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var results: [String?]
    private let prepareFails: Bool

    init(results: [String?], prepareFails: Bool) {
        self.results = results
        self.prepareFails = prepareFails
    }

    func prepare() async throws {
        if prepareFails { throw PipelineTestError.failed }
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        guard let text = results.removeFirst() else { throw PipelineTestError.failed }
        return ASRResult(text: text, detectedLanguage: nil)
    }

    func unload() async {}
}

private func asrEventPayloads(in root: URL) throws -> [String: [String: Any]] {
    let lines = try SessionRecovery.recoverJSONL(
        Data(contentsOf: root.appending(path: "events.jsonl"))
    ).lines
    var payloads: [String: [String: Any]] = [:]
    for line in lines {
        let event = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        guard let type = event["event_type"] as? String,
              type == "asr.completed" || type == "asr.failed",
              let segmentID = event["segment_id"] as? String else { continue }
        payloads[segmentID] = try #require(event["payload"] as? [String: Any])
    }
    return payloads
}

@Test
func asrEventsPersistRecognitionOutcomeAndFailureKind() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let processing = root.appending(path: "audio/processing")
    let audioWriter = try DurableAudioWriter(directory: processing, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await audioWriter.append(samples: Array(repeating: 0.25, count: 30))
    let checkpoint = try await audioWriter.finish()
    let coordinator = try makeCoordinator(
        root: root, processing: processing, checkpoint: checkpoint,
        asr: ScriptedPipelineASR(results: ["話した内容", " \n", nil], prepareFails: false),
        pacingMode: .normal, sleep: noSleep, shouldPause: neverPause
    )

    let input = segments([
        ("spoken", 0, 10), ("silent", 10, 20), ("failed", 20, 30), ("unreadable", 20, 40)
    ])
    let result = try await coordinator.run(segments: input, pendingSince: pendingNow(input), existingEvents: [])

    #expect(result.completedCount == 2)
    guard case .failed(let failure) = result.disposition else {
        Issue.record("failed segments must fail the run")
        return
    }
    #expect(failure.failureCounts == [.transcriptionFailed: 1, .audioUnreadable: 1])
    let payloads = try asrEventPayloads(in: root)
    #expect(payloads["spoken"]?["outcome"] as? String == "recognized")
    #expect(payloads["silent"]?["outcome"] as? String == "empty")
    #expect(payloads["failed"]?["kind"] as? String == "transcription_failed")
    #expect(payloads["unreadable"]?["kind"] as? String == "audio_unreadable")
}

@Test
func asrPreparationFailureIsPersistedAsEngineUnavailable() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let processing = root.appending(path: "audio/processing")
    let audioWriter = try DurableAudioWriter(directory: processing, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await audioWriter.append(samples: Array(repeating: 0.25, count: 10))
    let checkpoint = try await audioWriter.finish()
    let coordinator = try makeCoordinator(
        root: root, processing: processing, checkpoint: checkpoint,
        asr: ScriptedPipelineASR(results: [], prepareFails: true),
        pacingMode: .normal, sleep: noSleep, shouldPause: neverPause
    )

    let input = segments([("s1", 0, 10)])
    let result = try await coordinator.run(segments: input, pendingSince: pendingNow(input), existingEvents: [])

    #expect(result.disposition == .failed(ASRRunFailure(
        failedSegmentCount: 1,
        failureCounts: [.engineUnavailable: 1],
        firstRecognitionMessage: PipelineTestError.failed.localizedDescription,
        persistenceFailure: nil
    )))
    #expect(try asrEventPayloads(in: root)["s1"]?["kind"] as? String == "engine_unavailable")
}

@Test
func unwritableEventLogFailsTheRunAsAPersistenceFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let processing = root.appending(path: "audio/processing")
    let audioWriter = try DurableAudioWriter(directory: processing, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    try await audioWriter.append(samples: Array(repeating: 0.25, count: 10))
    let checkpoint = try await audioWriter.finish()
    let coordinator = try makeCoordinator(
        root: root, processing: processing, checkpoint: checkpoint,
        asr: FailingPipelineASR(), pacingMode: .normal, sleep: noSleep, shouldPause: neverPause
    )
    let eventsURL = root.appending(path: "events.jsonl")
    try FileManager.default.removeItem(at: eventsURL)
    try FileManager.default.createDirectory(at: eventsURL, withIntermediateDirectories: true)

    let input = segments([("s1", 0, 10)])
    let result = try await coordinator.run(segments: input, pendingSince: pendingNow(input), existingEvents: [])

    guard case .failed(let failure) = result.disposition else {
        Issue.record("an unwritable log must fail the run")
        return
    }
    #expect(failure.failureCounts == [.transcriptionFailed: 1])
    #expect(failure.persistenceFailure != nil)
    #expect(failure.localizedDescription.contains("イベントログへ保存できませんでした"))
}
