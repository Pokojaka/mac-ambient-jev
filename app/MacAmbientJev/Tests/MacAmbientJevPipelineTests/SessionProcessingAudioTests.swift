import Dispatch
import Foundation
import Testing
@testable import MacAmbientJevPipeline
@testable import MacAmbientJevCore

private enum TestTimelineBuilderError: Error, Equatable {
    case failedAfterWrite
}

private struct TestTimelineBuildCall: Sendable, Equatable {
    let source: URL
    let directory: URL
    let sessionURL: URL
}

private actor TestTimelineBuilder: ImportedAudioTimelineBuilding {
    enum Behavior: Sendable {
        case valid
        case failAfterWrite
        case corruptAfterWrite
    }

    private let samples: [Float]
    private let behavior: Behavior
    private var calls: [TestTimelineBuildCall]
    private var originalBytesRead: [Data]

    init(samples: [Float], behavior: Behavior) {
        self.samples = samples
        self.behavior = behavior
        self.calls = []
        self.originalBytesRead = []
    }

    func build(from sourceURL: URL, into processingDirectory: URL, sessionURL: URL) async throws -> AudioCheckpoint {
        calls.append(TestTimelineBuildCall(
            source: sourceURL,
            directory: processingDirectory,
            sessionURL: sessionURL
        ))
        originalBytesRead.append(try SessionFileAccess.read(sourceURL, relativeTo: sessionURL))

        let writer = try DurableAudioWriter(
            directory: processingDirectory,
            chunkDurationSeconds: 0.5,
            sessionURL: sessionURL
        )
        try await writer.append(samples: samples)
        let checkpoint = try await writer.finish()

        switch behavior {
        case .valid:
            return checkpoint
        case .failAfterWrite:
            throw TestTimelineBuilderError.failedAfterWrite
        case .corruptAfterWrite:
            try SessionFileAccess.writeAtomically(
                Data(),
                to: processingDirectory.appending(path: checkpoint.chunkFiles[0]),
                relativeTo: sessionURL
            )
            return checkpoint
        }
    }

    func recordedCalls() -> [TestTimelineBuildCall] {
        calls
    }

    func readOriginalBytes() -> [Data] {
        originalBytesRead
    }
}

private actor TestStatusRecorder {
    private var recorded: [String]

    init() {
        self.recorded = []
    }

    func record(_ status: String) {
        recorded.append(status)
    }

    func statuses() -> [String] {
        recorded
    }
}

private enum CompactionCancellationProbeError: Error {
    case cancellationNotObserved
}

private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + .seconds(180)) == .success)
        }
    }
}

private final class SessionProcessingAudioTestExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SessionProcessingAudioTestExecutor")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}

private final class CompactionCancellationProbe: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let cancellationObserved = DispatchSemaphore(value: 0)

    func compact() throws {
        started.signal()
        let deadline = DispatchTime.now() + .seconds(180)
        while !Task.isCancelled {
            guard DispatchTime.now() < deadline else {
                throw CompactionCancellationProbeError.cancellationNotObserved
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        cancellationObserved.signal()
        try Task.checkCancellation()
    }

    func waitUntilStarted() async -> Bool {
        await waitForSignal(started)
    }

    func waitUntilCancellationObserved() async -> Bool {
        await waitForSignal(cancellationObserved)
    }
}

private enum CompactionBoundaryGateError: Error {
    case releaseTimedOut
}

private final class CompactionBoundaryGate: @unchecked Sendable {
    private let published = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func pause(at boundary: RecordingAudioCompactor.Boundary) throws {
        guard boundary == .published else { return }
        published.signal()
        guard resume.wait(timeout: .now() + .seconds(180)) == .success else {
            throw CompactionBoundaryGateError.releaseTimedOut
        }
    }

    func waitUntilPublished() async -> Bool {
        await waitForSignal(published)
    }

    func release() {
        resume.signal()
    }
}

private final class CompactionInvocationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var invoked = false

    func markInvoked() {
        lock.lock()
        defer { lock.unlock() }
        invoked = true
    }

    func wasInvoked() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return invoked
    }
}

private func makeManualLayout() throws -> SessionLayout {
    let sessionURL = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: false)
    return SessionLayout(sessionURL: sessionURL)
}

private func cleanUp(_ layout: SessionLayout) {
    try? FileManager.default.removeItem(at: layout.sessionURL)
}

private func makeImportedOriginal(_ layout: SessionLayout, bytes: Data) throws -> URL {
    try SessionAudioStorageStore(layout: layout).save(.importedOriginal(nil))
    let originalURL = layout.audioDirectory.appending(path: "original.wav")
    try SessionFileAccess.writeAtomically(bytes, to: originalURL, relativeTo: layout.sessionURL)
    return originalURL
}

private func recordPCM(_ layout: SessionLayout, samples: [Float]) async throws -> AudioCheckpoint {
    let writer = try DurableAudioWriter(
        directory: layout.processingDirectory,
        chunkDurationSeconds: 0.5,
        sessionURL: layout.sessionURL
    )
    try await writer.append(samples: samples)
    return try await writer.finish()
}

private func quantized(_ samples: [Float]) -> [Float] {
    samples.map { Float(RecordingFLAC.quantize16($0)!) / 32_768 }
}

private func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

@Suite("SessionProcessingAudioTests")
struct SessionProcessingAudioTests {
    @Test
    func commonAudioBuildsStoredOriginalAndSavesValidatedInfo() async throws {
        let layout = try makeManualLayout()
        defer { cleanUp(layout) }
        let originalBytes = Data([0x00, 0x7f, 0x13, 0x80, 0xff, 0x42])
        let originalURL = try makeImportedOriginal(layout, bytes: originalBytes)
        let samples: [Float] = [0, 0.5, -0.5, 0.25]
        let builder = TestTimelineBuilder(samples: samples, behavior: .valid)
        let statuses = TestStatusRecorder()
        let audio = SessionProcessingAudio(timelineBuilder: builder)
        let source = SessionAudioSource.importedOriginal(originalURL, timeline: nil)

        let reader = try await audio.open(source, layout: layout) { status in
            await statuses.record(status)
        }

        #expect(await builder.recordedCalls() == [TestTimelineBuildCall(
            source: originalURL,
            directory: layout.processingDirectory,
            sessionURL: layout.sessionURL
        )])
        #expect(await builder.readOriginalBytes() == [originalBytes])
        #expect(await statuses.statuses() == [UserFacingStatus.convertingTimeline.text])
        #expect(reader.info == (try TimelineAudioInfo(committedFrames: Int64(samples.count), gapEvents: [])))
        #expect(try reader.readSamples(frameRange: 0..<Int64(samples.count)) == samples)
        #expect(try SessionAudioStorageStore(layout: layout).load() == .importedOriginal(reader.info))

        let originals = try SessionFileAccess.contentsOfDirectory(layout.audioDirectory, relativeTo: layout.sessionURL)
            .filter { $0.lastPathComponent == "original" || $0.lastPathComponent.hasPrefix("original.") }
        #expect(originals == [originalURL])
        #expect(try SessionFileAccess.read(originalURL, relativeTo: layout.sessionURL) == originalBytes)

        try audio.exportDiarizationAudio(
            reader: reader,
            to: layout.diarizationInputURL,
            sessionURL: layout.sessionURL
        )
        // Windows cannot delete a file while the reader's handle is open.
        do {
            let cafReader = try CanonicalCAFReader(url: layout.diarizationInputURL, sessionURL: layout.sessionURL)
            #expect(cafReader.sampleCount == Int64(samples.count))
            #expect(try cafReader.readSamples(frames: 0..<Int64(samples.count)) == samples)
        }

        let importedSession = SessionSource.imported(originalFilename: "original.wav")
        try SessionTransientAudio.remove(layout: layout, source: importedSession)
        #expect(!fileExists(layout.processingDirectory))
        #expect(!fileExists(layout.derivedDirectory))
        #expect(fileExists(originalURL))
        #expect(try SessionAudioStorageStore(layout: layout).load() == .importedOriginal(reader.info))
        #expect(try SessionFileAccess.read(originalURL, relativeTo: layout.sessionURL) == originalBytes)

        let knownSource = SessionAudioSource.importedOriginal(originalURL, timeline: reader.info)
        let reopenedReader = try await audio.open(knownSource, layout: layout) { status in
            await statuses.record(status)
        }
        #expect(await builder.recordedCalls() == [
            TestTimelineBuildCall(source: originalURL, directory: layout.processingDirectory, sessionURL: layout.sessionURL),
            TestTimelineBuildCall(source: originalURL, directory: layout.processingDirectory, sessionURL: layout.sessionURL)
        ])
        #expect(await builder.readOriginalBytes() == [originalBytes, originalBytes])
        #expect(await statuses.statuses() == [
            UserFacingStatus.convertingTimeline.text,
            UserFacingStatus.convertingTimeline.text
        ])
        #expect(reopenedReader.info == reader.info)
        #expect(try reopenedReader.readSamples(frameRange: 0..<Int64(samples.count)) == samples)
        #expect(try SessionAudioStorageStore(layout: layout).load() == .importedOriginal(reader.info))
        #expect(try SessionFileAccess.read(originalURL, relativeTo: layout.sessionURL) == originalBytes)
    }

    @Test
    func commonAudioPropagatesBuilderFailureWithoutPublishing() async throws {
        let layout = try makeManualLayout()
        defer { cleanUp(layout) }
        let originalBytes = Data([0x44, 0x11, 0x92, 0x00])
        let originalURL = try makeImportedOriginal(layout, bytes: originalBytes)
        let builder = TestTimelineBuilder(samples: [0, 0.5, -0.5, 0.25], behavior: .failAfterWrite)
        let audio = SessionProcessingAudio(timelineBuilder: builder)

        await #expect(throws: TestTimelineBuilderError.failedAfterWrite) {
            _ = try await audio.open(
                .importedOriginal(originalURL, timeline: nil),
                layout: layout,
                onStatus: { _ in }
            )
        }

        #expect(await builder.recordedCalls() == [TestTimelineBuildCall(
            source: originalURL,
            directory: layout.processingDirectory,
            sessionURL: layout.sessionURL
        )])
        #expect(await builder.readOriginalBytes() == [originalBytes])
        #expect(try SessionAudioStorageStore(layout: layout).load() == .importedOriginal(nil))
        #expect(fileExists(layout.processingDirectory))
        #expect(try SessionFileAccess.read(originalURL, relativeTo: layout.sessionURL) == originalBytes)

        try SessionTransientAudio.remove(
            layout: layout,
            source: .imported(originalFilename: "original.wav")
        )
        #expect(!fileExists(layout.processingDirectory))
        #expect(!fileExists(layout.derivedDirectory))
        #expect(try SessionAudioStorageStore(layout: layout).load() == .importedOriginal(nil))
        #expect(fileExists(originalURL))
        #expect(try SessionFileAccess.read(originalURL, relativeTo: layout.sessionURL) == originalBytes)
    }

    @Test
    func commonAudioRejectsCorruptBuilderOutputBeforePublishing() async throws {
        let layout = try makeManualLayout()
        defer { cleanUp(layout) }
        let originalBytes = Data([0x01, 0x02, 0x03, 0x04])
        let originalURL = try makeImportedOriginal(layout, bytes: originalBytes)
        let builder = TestTimelineBuilder(samples: [0, 0.5, -0.5, 0.25], behavior: .corruptAfterWrite)
        let audio = SessionProcessingAudio(timelineBuilder: builder)

        await #expect(throws: ProcessingTimelineReaderError.corruptChunk("chunk-000000.f32le")) {
            _ = try await audio.open(
                .importedOriginal(originalURL, timeline: nil),
                layout: layout,
                onStatus: { _ in }
            )
        }

        #expect(await builder.recordedCalls() == [TestTimelineBuildCall(
            source: originalURL,
            directory: layout.processingDirectory,
            sessionURL: layout.sessionURL
        )])
        #expect(await builder.readOriginalBytes() == [originalBytes])
        #expect(try SessionAudioStorageStore(layout: layout).load() == .importedOriginal(nil))

        try SessionTransientAudio.remove(
            layout: layout,
            source: .imported(originalFilename: "original.wav")
        )
        #expect(!fileExists(layout.processingDirectory))
        #expect(!fileExists(layout.derivedDirectory))
        #expect(try SessionAudioStorageStore(layout: layout).load() == .importedOriginal(nil))
        #expect(fileExists(originalURL))
        #expect(try SessionFileAccess.read(originalURL, relativeTo: layout.sessionURL) == originalBytes)
    }

    @Test
    func commonAudioReadsAndCompactsRecordingWithoutInvokingBuilder() async throws {
        let layout = try makeManualLayout()
        defer { cleanUp(layout) }
        try SessionAudioStorageStore(layout: layout).save(.recordingPCM)
        let samples: [Float] = [0, 0.5, -0.5, 0.25]
        let checkpoint = try await recordPCM(layout, samples: samples)
        let builder = TestTimelineBuilder(samples: [0.75], behavior: .valid)
        let statuses = TestStatusRecorder()
        let audio = SessionProcessingAudio(timelineBuilder: builder)

        let pcmReader = try await audio.open(.recordedPCM(checkpoint), layout: layout) { status in
            await statuses.record(status)
        }
        #expect(pcmReader.info == (try checkpoint.info))
        #expect(try pcmReader.readSamples(frameRange: 0..<Int64(samples.count)) == samples)
        #expect(try SessionAudioStorageStore(layout: layout).load() == .recordingPCM)
        #expect(await builder.recordedCalls().isEmpty)
        #expect(await statuses.statuses().isEmpty)

        try await audio.compactRecording(layout: layout)

        let info = try checkpoint.info
        #expect(try SessionAudioStorageStore(layout: layout).load() == .recordingFLAC(info))
        #expect(!fileExists(layout.processingDirectory))
        #expect(fileExists(layout.recordingFLACURL))

        let flacReader = try await audio.open(.recordedFLAC(info), layout: layout) { status in
            await statuses.record(status)
        }
        let expectedSamples = quantized(samples)
        #expect(flacReader.info == info)
        #expect(try flacReader.readSamples(frameRange: 0..<Int64(samples.count)) == expectedSamples)
        #expect(await builder.recordedCalls().isEmpty)
        #expect(await statuses.statuses().isEmpty)

        try audio.exportDiarizationAudio(
            reader: flacReader,
            to: layout.diarizationInputURL,
            sessionURL: layout.sessionURL
        )
        let cafReader = try CanonicalCAFReader(url: layout.diarizationInputURL, sessionURL: layout.sessionURL)
        #expect(cafReader.sampleCount == Int64(samples.count))
        #expect(try cafReader.readSamples(frames: 0..<Int64(samples.count)) == expectedSamples)
    }

    @Test
    func compactRecordingPropagatesParentCancellationToDetachedCompaction() async throws {
        let executor = SessionProcessingAudioTestExecutor()
        try await withTaskExecutorPreference(executor) {
            let layout = try makeManualLayout()
            defer { cleanUp(layout) }
            let probe = CompactionCancellationProbe()
            let audio = SessionProcessingAudio(
                timelineBuilder: TestTimelineBuilder(samples: [], behavior: .valid),
                compactionOperation: { _ in try probe.compact() }
            )
            let compactionTask = Task {
                try await audio.compactRecording(layout: layout)
            }

            #expect(await probe.waitUntilStarted())
            compactionTask.cancel()

            await #expect(throws: CancellationError.self) {
                try await compactionTask.value
            }
            #expect(await probe.waitUntilCancellationObserved())
        }
    }

    @Test
    func compactRecordingDoesNotLaunchDetachedWorkForPreCancelledParent() async throws {
        let layout = try makeManualLayout()
        defer { cleanUp(layout) }
        let invocation = CompactionInvocationFlag()
        let audio = SessionProcessingAudio(
            timelineBuilder: TestTimelineBuilder(samples: [], behavior: .valid),
            compactionOperation: { _ in invocation.markInvoked() }
        )
        let compactionTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await audio.compactRecording(layout: layout)
        }

        await #expect(throws: CancellationError.self) {
            try await compactionTask.value
        }
        #expect(!invocation.wasInvoked())
    }

    @Test
    func cancelledRealCompactionAtPublishedBoundaryRecoversWithoutReprocessingTranscript() async throws {
        let executor = SessionProcessingAudioTestExecutor()
        try await withTaskExecutorPreference(executor) {
            let layout = try makeManualLayout()
            defer { cleanUp(layout) }
            try SessionAudioStorageStore(layout: layout).save(.recordingPCM)
            let samples = (0..<20_000).map { sin(Float($0) * 0.013) * 0.8 }
            let checkpoint = try await recordPCM(layout, samples: samples)
            let eventWriter = try SessionWriter(sessionURL: layout.sessionURL)
            try await eventWriter.append(EventDraft(
                eventType: "segment.created",
                sessionID: UUID(),
                segmentationRunID: "seg_finalized",
                segmentID: "segment_000001",
                sourceStartFrame: 0,
                sourceEndFrame: Int64(samples.count),
                payload: EmptyPayload()
            ))
            let transcriptLog = try SessionWriter.readDurableLog(eventsURL: layout.eventsURL)
            let builder = TestTimelineBuilder(samples: [], behavior: .valid)
            let gate = CompactionBoundaryGate()
            let interruptedAudio = SessionProcessingAudio(
                timelineBuilder: builder,
                compactionOperation: { layout in
                    _ = try RecordingAudioCompactor(interrupt: { boundary in
                        try gate.pause(at: boundary)
                    }).compact(layout: layout)
                }
            )
            let compactionTask = Task {
                try await interruptedAudio.compactRecording(layout: layout)
            }

            #expect(await gate.waitUntilPublished())
            compactionTask.cancel()
            gate.release()
            await #expect(throws: CancellationError.self) {
                try await compactionTask.value
            }

            let info = try checkpoint.info
            #expect(try SessionAudioStorageStore(layout: layout).load() == .recordingPCM)
            #expect(try AudioCheckpoint.loadRecovered(
                from: layout.processingDirectory,
                relativeTo: layout.sessionURL
            ) == checkpoint)
            try FLACTimelineReader(
                url: layout.recordingFLACURL,
                info: info,
                sessionURL: layout.sessionURL
            ).validateAudio()
            #expect(try SessionWriter.readDurableLog(eventsURL: layout.eventsURL) == transcriptLog)

            let recoveryAudio = SessionProcessingAudio(timelineBuilder: builder)
            try await recoveryAudio.compactRecording(layout: layout)

            #expect(try SessionAudioStorageStore(layout: layout).load() == .recordingFLAC(info))
            #expect(!fileExists(layout.processingDirectory))
            #expect(!fileExists(layout.recordingFLACPartialURL))
            let reader = try await recoveryAudio.open(.recordedFLAC(info), layout: layout) { _ in }
            #expect(try reader.readSamples(frameRange: 0..<info.committedFrames) == quantized(samples))
            #expect(await builder.recordedCalls().isEmpty)
            #expect(try SessionWriter.readDurableLog(eventsURL: layout.eventsURL) == transcriptLog)
        }
    }

    @Test
    func commonAudioRecordingReadFailureDoesNotTryImportBuilder() async throws {
        let layout = try makeManualLayout()
        defer { cleanUp(layout) }
        try SessionAudioStorageStore(layout: layout).save(.recordingPCM)
        let checkpoint = try await recordPCM(layout, samples: [0, 0.5, -0.5, 0.25])
        let missingChunk = layout.processingDirectory.appending(path: checkpoint.chunkFiles[0])
        try SessionFileAccess.writeAtomically(Data(), to: missingChunk, relativeTo: layout.sessionURL)
        let builder = TestTimelineBuilder(samples: [0.75], behavior: .valid)
        let statuses = TestStatusRecorder()
        let audio = SessionProcessingAudio(timelineBuilder: builder)

        await #expect(throws: ProcessingTimelineReaderError.corruptChunk(checkpoint.chunkFiles[0])) {
            _ = try await audio.open(.recordedPCM(checkpoint), layout: layout) { status in
                await statuses.record(status)
            }
        }

        #expect(try SessionAudioStorageStore(layout: layout).load() == .recordingPCM)
        #expect(await builder.recordedCalls().isEmpty)
        #expect(await statuses.statuses().isEmpty)
    }
}
