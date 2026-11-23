import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private actor RecordingVADChunkSegmenter: VADChunkSegmenting {
    nonisolated let chunkSize = 4_096
    private var sizes: [Int] = []

    func process16kChunk(
        _ samples: [Float]
    ) async throws -> VADChunkOutput {
        sizes.append(samples.count)
        return VADChunkOutput(segments: [], micLevel: nil)
    }

    func finish(
        totalCanonicalFrames: Int64
    ) async -> [SegmentReference] {
        []
    }

    func recordedChunkSizes() -> [Int] {
        sizes
    }
}

@Test
func liveVADProcessorConsumesEachDurableFrameOnlyOnce() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1, sessionURL: root)
    let vad = RecordingVADChunkSegmenter()

    try await writer.append(
        samples: Array(repeating: Float(0.1), count: 16_000)
    )
    let firstCheckpoint = await writer.committedSnapshot()

    let processor = VADTimelineProcessor(engine: vad)

    _ = try await processor.processAvailable(reader: try ProcessingTimelineReader(directory: root, checkpoint: firstCheckpoint, sessionURL: root))
    #expect(await vad.recordedChunkSizes() == [
        4_096,
        4_096,
        4_096
    ])

    // Polling the same durable boundary must not re-feed audio.
    _ = try await processor.processAvailable(reader: try ProcessingTimelineReader(directory: root, checkpoint: firstCheckpoint, sessionURL: root))
    #expect(await vad.recordedChunkSizes().count == 3)

    try await writer.append(
        samples: Array(repeating: Float(0.2), count: 16_000)
    )
    let secondCheckpoint = await writer.committedSnapshot()

    _ = try await processor.processAvailable(reader: try ProcessingTimelineReader(directory: root, checkpoint: secondCheckpoint, sessionURL: root))
    #expect(await vad.recordedChunkSizes().count == 7)

    _ = try await processor.finish(reader: try ProcessingTimelineReader(directory: root, checkpoint: secondCheckpoint, sessionURL: root))

    let sizes = await vad.recordedChunkSizes()
    #expect(sizes.count == 8)
    #expect(sizes.last == 3_328)
    #expect(sizes.reduce(0, +) == 32_000)
}

private enum InjectedVADFailure: Error { case secondChunk }

private actor FailingOnceVADChunkSegmenter: VADChunkSegmenting {
    nonisolated let chunkSize = 4_096
    private var calls = 0
    private var acceptedFrames = 0

    func process16kChunk(_ samples: [Float]) async throws -> VADChunkOutput {
        calls += 1
        if calls == 2 { throw InjectedVADFailure.secondChunk }
        acceptedFrames += samples.count
        guard calls == 1 else { return VADChunkOutput(segments: [], micLevel: nil) }
        return VADChunkOutput(
            segments: [SegmentReference(segmentationRunID: "seg", segmentID: "before-failure", speechRanges: [0..<100])],
            micLevel: nil
        )
    }

    func finish(totalCanonicalFrames: Int64) async -> [SegmentReference] { [] }
    func acceptedFrameCount() -> Int { acceptedFrames }
}

@Test
func vadProcessorRetryAfterChunkErrorNeitherReplaysAudioNorDropsSegments() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1, sessionURL: root)
    try await writer.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await writer.committedSnapshot()
    let vad = FailingOnceVADChunkSegmenter()
    let processor = VADTimelineProcessor(engine: vad)
    await #expect(throws: InjectedVADFailure.secondChunk) {
        try await processor.processAvailable(reader: try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root))
    }
    var emitted = try await processor.processAvailable(reader: try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root))
    emitted += try await processor.finish(reader: try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root))
    #expect(await vad.acceptedFrameCount() == 16_000)
    #expect(emitted.map(\.segmentID) == ["before-failure"])
}

private enum InjectedRecoveryWriterFailure: Error { case eventLimit }

private actor RecoveryVADChunkSegmenter: VADChunkSegmenting {
    nonisolated let chunkSize = 4_096
    private let changesSecondRange: Bool
    private var cursor: Int64 = 0
    private var sizes: [Int] = []
    init(changesSecondRange: Bool) { self.changesSecondRange = changesSecondRange }

    func process16kChunk(_ samples: [Float]) async throws -> VADChunkOutput {
        let start = cursor
        cursor += Int64(samples.count)
        sizes.append(samples.count)
        let ordinal = sizes.count, secondStart = start + 200 + (changesSecondRange && ordinal == 1 ? 1 : 0)
        return VADChunkOutput(segments: [SegmentReference(
            segmentationRunID: "vad_recovery_test", segmentID: String(format: "seg_%06d", ordinal),
            speechRanges: [start..<(start + 100), secondStart..<(start + 300)]
        )], micLevel: nil)
    }
    func finish(totalCanonicalFrames: Int64) async -> [SegmentReference] { [] }
    func recordedChunkSizes() -> [Int] { sizes }
}

private actor InterruptingSessionEventWriter: SessionEventAppending {
    private let writer: SessionWriter
    private let interruptAfter: Int
    private var successfulAppends = 0
    init(writer: SessionWriter, interruptAfter: Int) { self.writer = writer; self.interruptAfter = interruptAfter }

    func append<Payload: Codable & Sendable>(_ draft: EventDraft<Payload>) async throws -> EventEnvelope<Payload> {
        guard successfulAppends < interruptAfter else { throw InjectedRecoveryWriterFailure.eventLimit }
        let envelope = try await writer.append(draft)
        successfulAppends += 1
        return envelope
    }
}

@Test(.timeLimit(.minutes(10)), arguments: [2, 4, 5, 6])
func recoveryPreservesStoredSegmentsAndAppendsOnlyTheTail(_ interruptAfter: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let audioWriter = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1, sessionURL: root)
    try await audioWriter.append(samples: Array(repeating: Float(0.1), count: 16_383))
    let checkpoint = try await audioWriter.finish()
    #expect(checkpoint.committedFrames == 16_383)
    let reader = try ProcessingTimelineReader(directory: root, checkpoint: checkpoint, sessionURL: root)
    let sessionID = UUID(), runID = "vad_recovery_test"
    let interruptedOwner = try await VADSession.open(
        sessionID: sessionID, segmentationRunID: runID, sessionURL: root,
        writer: InterruptingSessionEventWriter(writer: try SessionWriter(sessionURL: root), interruptAfter: interruptAfter),
        makeProcessor: { VADTimelineProcessor(engine: RecoveryVADChunkSegmenter(changesSecondRange: false)) })
    await #expect(throws: InjectedRecoveryWriterFailure.eventLimit) {
        _ = try await interruptedOwner.processAvailable(reader: reader)
        _ = try await interruptedOwner.finish(reader: reader)
    }
    let eventsURL = SessionLayout(sessionURL: root).eventsURL
    let decodeEvents: (Data) throws -> [[String: Any]] = { data in
        try data.split(separator: 0x0A).map { try #require(try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    }
    let savedRecovery = try ASRSessionRecovery(eventsURL: eventsURL, sessionID: sessionID, segmentationRunID: runID, asrRunID: nil)
    let savedPrefix = savedRecovery.segments
    #expect(savedPrefix.count == (interruptAfter == 2 ? 2 : interruptAfter == 4 || interruptAfter == 5 ? 3 : 4))
    let savedEventRecords = try decodeEvents(SessionWriter.readDurableLog(eventsURL: eventsURL))
    let savedSegmentCount = savedEventRecords.filter { $0["event_type"] as? String == "segment.created" }.count

    let mismatchedOwner = try await VADSession.open(
        sessionID: sessionID, segmentationRunID: runID, sessionURL: root, writer: try SessionWriter(sessionURL: root),
        makeProcessor: { VADTimelineProcessor(engine: RecoveryVADChunkSegmenter(changesSecondRange: true)) })
    await #expect(throws: SegmentationConsistencyError.segmentMismatch(ordinal: 1)) {
        _ = try await mismatchedOwner.finish(reader: reader)
    }
    let afterMismatchRecords = try decodeEvents(SessionWriter.readDurableLog(eventsURL: eventsURL))
    #expect(afterMismatchRecords.filter { $0["event_type"] as? String == "segment.created" }.count == savedSegmentCount)

    let goodEngine = RecoveryVADChunkSegmenter(changesSecondRange: false)
    let recoveredOwner = try await VADSession.open(
        sessionID: sessionID, segmentationRunID: runID, sessionURL: root, writer: try SessionWriter(sessionURL: root),
        makeProcessor: { VADTimelineProcessor(engine: goodEngine) })
    var appended = try await recoveredOwner.processAvailable(reader: reader)
    appended += try await recoveredOwner.finish(reader: reader)
    let expectedSegments = [Int64(0), 4_096, 8_192, 12_288].enumerated().map { index, start in
        SegmentReference(segmentationRunID: runID, segmentID: String(format: "seg_%06d", index + 1),
                         speechRanges: [start..<(start + 100), (start + 200)..<(start + 300)])
    }
    let completedSegments = await recoveredOwner.segments
    #expect(appended == Array(completedSegments.dropFirst(savedPrefix.count)))
    #expect(Array(completedSegments.prefix(savedPrefix.count)) == savedPrefix)
    #expect(completedSegments == expectedSegments && Set(completedSegments.map(\.segmentID)).count == 4)
    #expect(await goodEngine.recordedChunkSizes() == [4_096, 4_096, 4_096, 4_095])
    let completedRecovery = try ASRSessionRecovery(eventsURL: eventsURL, sessionID: sessionID, segmentationRunID: runID, asrRunID: nil)
    #expect(completedRecovery.sealedFrames == 16_383 && completedRecovery.consumedFrames == 16_383 && completedRecovery.segmentationCompleted)
    let finalLog = try SessionWriter.readDurableLog(eventsURL: eventsURL)
    let records = try decodeEvents(finalLog), eventTypes = records.compactMap { $0["event_type"] as? String }
    let progressIndex = try #require(eventTypes.firstIndex(of: "segmentation.progress"))
    let sealedIndex = try #require(eventTypes.firstIndex(of: "segmentation.input.sealed"))
    let completionIndex = try #require(eventTypes.firstIndex(of: "segmentation.completed"))
    let tailIndex = try #require(records.firstIndex { $0["segment_id"] as? String == "seg_000004" })
    #expect(eventTypes.prefix(progressIndex).filter { $0 == "segment.created" }.count == 3)
    #expect(eventTypes.filter { $0 == "segment.created" }.count == 4)
    #expect(eventTypes.filter { $0 == "segmentation.progress" }.count == 1)
    #expect(eventTypes.filter { $0 == "segmentation.input.sealed" }.count == 1)
    #expect(eventTypes.filter { $0 == "segmentation.completed" }.count == 1)
    #expect(progressIndex < tailIndex && sealedIndex < tailIndex)
    let progress = try #require(records[progressIndex]["payload"] as? [String: Any])
    let sealed = try #require(records[sealedIndex]["payload"] as? [String: Any])
    let completion = try #require(records[completionIndex]["payload"] as? [String: Any])
    #expect(progress["consumed_frames"] as? Int == 12_288)
    #expect(sealed["frame_count"] as? Int == 16_383)
    #expect(completion["segment_count"] as? Int == 4 && completion["consumed_frames"] as? Int == 16_383)
    let completedOwner = try await VADSession.open(
        sessionID: sessionID, segmentationRunID: runID, sessionURL: root, writer: try SessionWriter(sessionURL: root),
        makeProcessor: { throw InjectedRecoveryWriterFailure.eventLimit })
    #expect(await completedOwner.segments == expectedSegments)
    let noSegments = try await completedOwner.processAvailable(reader: reader)
    let firstFinish = try await completedOwner.finish(reader: reader)
    let repeatedFinish = try await completedOwner.finish(reader: reader)
    #expect(noSegments.isEmpty && firstFinish.isEmpty && repeatedFinish.isEmpty)
    #expect(try SessionWriter.readDurableLog(eventsURL: eventsURL) == finalLog)
}
