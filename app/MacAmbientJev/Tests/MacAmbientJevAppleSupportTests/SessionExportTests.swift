import AVFoundation
import Foundation
import Testing
@testable import MacAmbientJevAppleSupport
@testable import MacAmbientJevCore

private let fixtureSampleRate = 16_000.0

@Test
func savedTranscriptLoaderReportsNoTranscriptWithoutActiveASRRun() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession(activeRuns: ActiveRuns(segmentation: "seg-run"))

    let transcript = try SavedTranscriptLoader.load(
        sessionURL: fixture.sessionURL(session),
        audioSource: try #require(session.audioSource)
    )

    #expect(transcript == .unavailable)
}

@Test
func savedTranscriptLoaderMaterializesActiveRuns() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession()

    let transcript = try SavedTranscriptLoader.load(
        sessionURL: fixture.sessionURL(session),
        audioSource: try #require(session.audioSource)
    )

    guard case .segments(let segments) = transcript else {
        Issue.record("expected segments, got \(transcript)")
        return
    }
    #expect(segments.map(\.text) == ["こんにちは", "今日の議題です", "  "])
    #expect(segments.map(\.startMilliseconds) == [0, 65_000, 70_000])
}

@Test
func savedTranscriptLoaderKeepsRawFillerTextForPresentationAndExport() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let raw = "えー、今日は公開鍵暗号を説明します。"
    let cleaned = "今日は公開鍵暗号を説明します。"
    let session = try await fixture.writeLiveSession(firstText: raw)
    let layout = SessionLayout(sessionURL: session.sessionURL)
    let asrEventsBefore = try asrEventLines(at: layout.eventsURL)

    let beforeResponse = try SavedTranscriptLoader.load(
        sessionURL: session.sessionURL,
        audioSource: try #require(session.audioSource)
    )
    guard case .segments(let rawSegments) = beforeResponse else {
        Issue.record("expected saved transcript segments before boundary response")
        return
    }
    #expect(rawSegments.first?.text == raw)
    #expect(try LiveTranscriptProjection().rows(for: rawSegments).first?.text == raw)
    #expect(try TranscriptTextRenderer.render(rawSegments)
        == "[00:00] Speaker 1: \(raw)\n[01:05] Speaker 2: 今日の議題です\n")

    let assessedSession = try await fixture.saveFillerAssessment(session: session, rawText: raw)
    let afterResponse = try SavedTranscriptLoader.load(
        sessionURL: assessedSession.sessionURL,
        audioSource: try #require(assessedSession.audioSource)
    )
    guard case .segments(let segments) = afterResponse else {
        Issue.record("expected saved transcript segments after boundary response")
        return
    }

    #expect(segments.first?.text == raw)
    let rows = try LiveTranscriptProjection().rows(for: segments)
    #expect(rows.first?.text == cleaned)
    let exportedText = "[00:00] Speaker 1: \(cleaned)\n[01:05] Speaker 2: 今日の議題です\n"
    #expect(try TranscriptTextRenderer.render(segments) == exportedText)

    let folder = try SessionExporter().export(session: assessedSession, to: fixture.exportRoot)
    #expect(try String(contentsOf: folder.appending(path: "transcript.txt"), encoding: .utf8) == exportedText)
    #expect(try asrEventLines(at: layout.eventsURL) == asrEventsBefore)
}

@Test
func savedTranscriptLoaderRejectsAnIncompleteEventTail() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession()
    let eventsURL = SessionLayout(sessionURL: session.sessionURL).eventsURL
    var bytes = try Data(contentsOf: eventsURL)
    bytes.append(contentsOf: "{\"schema_version\":3".utf8)
    try bytes.write(to: eventsURL)
    #expect(throws: EventLogTranscriptReaderError.self) {
        try SavedTranscriptLoader.load(
            sessionURL: session.sessionURL,
            audioSource: try #require(session.audioSource)
        )
    }
}

@Test
func savedTranscriptLoaderRejectsPendingMetadataThatHidesUnclassifiedRows() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession()
    let store = ProcessingMetadataStore(sessionURL: session.sessionURL)
    let metadata = try #require(try store.load())
    try store.save(ProcessingMetadata(
        finalizationAttempt: metadata.finalizationAttempt,
        activeRuns: metadata.activeRuns,
        pendingClauseBoundarySegments: [],
        pendingContentPriorityClauses: []
    ))
    #expect(throws: EventLogTranscriptReaderError.self) {
        try SavedTranscriptLoader.load(
            sessionURL: session.sessionURL,
            audioSource: try #require(session.audioSource)
        )
    }
}


@Test
func exporterWritesReadableTranscriptAndFlacAudio() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let samples: [Float] = (0..<32_000).map { sin(Float($0) * 0.05) * 0.5 }
    let session = try await fixture.writeLiveSession(samples: samples)

    let folder = try SessionExporter().export(session: session, to: fixture.exportRoot)
    #expect(folder.lastPathComponent == session.sessionURL.lastPathComponent)

    let transcript = try String(contentsOf: folder.appending(path: "transcript.txt"), encoding: .utf8)
    #expect(transcript == "[00:00] Speaker 1: こんにちは\n[01:05] Speaker 2: 今日の議題です\n")

    let flac = try AVAudioFile(forReading: folder.appending(path: "audio.flac"))
    #expect(flac.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatFLAC)
    #expect(try Data(contentsOf: folder.appending(path: "audio.flac")) == Data(contentsOf: SessionLayout(sessionURL: session.sessionURL).recordingFLACURL))
    #expect(flac.length == Int64(samples.count))
    #expect(flac.processingFormat.sampleRate == fixtureSampleRate)
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: flac.processingFormat,
        frameCapacity: AVAudioFrameCount(flac.length)
    ))
    try flac.read(into: buffer)
    let decoded = UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength))
    #expect(decoded.count == samples.count)
    for (index, sample) in samples.enumerated() {
        #expect(decoded[index] == Float(RecordingFLAC.quantize16(sample)!) / 32_768)
    }
}

@Test
func exportRefusesARecordingThatIsNotYetFLAC() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession(compacted: false)

    #expect(throws: SessionExportError.recordingNotCompacted) {
        try SessionExporter().export(session: session, to: fixture.exportRoot)
    }
    if FileManager.default.fileExists(atPath: fixture.exportRoot.path) {
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.exportRoot.path).isEmpty)
    }
}

private func fileBytes(in directory: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in try FileManager.default.subpathsOfDirectory(atPath: directory.path).sorted() {
        let url = directory.appending(path: name)
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[name] = try Data(contentsOf: url)
        }
    }
    return result
}

private func asrEventLines(at eventsURL: URL) throws -> [Data] {
    let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: eventsURL))
    return try EventLogLine.decode(recovered.lines)
        .filter { $0.header.eventType == "asr.completed" }
        .map(\.data)
}

@Test
func exportKeepsTheSessionsInternalAudioUnchanged() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession()
    let layout = SessionLayout(sessionURL: session.sessionURL)
    let flacBefore = try Data(contentsOf: layout.recordingFLACURL)
    let storageBefore = try Data(contentsOf: layout.audioStorageURL)

    try SessionExporter().export(session: session, to: fixture.exportRoot)

    #expect(try Data(contentsOf: layout.recordingFLACURL) == flacBefore)
    #expect(try Data(contentsOf: layout.audioStorageURL) == storageBefore)
    #expect(!FileManager.default.fileExists(atPath: layout.processingDirectory.path))
}

@Test
func exportOfACorruptRecordingFailsAndKeepsThePriorExport() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession()
    let layout = SessionLayout(sessionURL: session.sessionURL)
    let prior = try SessionExporter().export(session: session, to: fixture.exportRoot)
    let priorBytes = try fileBytes(in: prior)

    let flac = try Data(contentsOf: layout.recordingFLACURL)
    try flac.prefix(flac.count / 2).write(to: layout.recordingFLACURL)

    #expect(throws: FLACTimelineReaderError.self) {
        try SessionExporter().export(session: session, to: fixture.exportRoot)
    }
    #expect(try fileBytes(in: prior) == priorBytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.exportRoot.path) == [prior.lastPathComponent])
}

@Test
func exportUsesTheStoredFormEvenWhenTheCatalogRowPredatesCompaction() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession(compacted: false)
    guard case .recordedPCM = session.audioSource else {
        Issue.record("the catalog row was read while the recording was PCM")
        return
    }
    let layout = SessionLayout(sessionURL: session.sessionURL)
    _ = try RecordingAudioCompactor(interrupt: nil).compact(layout: layout)

    let folder = try SessionExporter().export(session: session, to: fixture.exportRoot)

    #expect(try Data(contentsOf: folder.appending(path: "audio.flac")) == Data(contentsOf: layout.recordingFLACURL))
}

@Test
func reexportReplacesTheSameFolder() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession()
    let first = try SessionExporter().export(session: session, to: fixture.exportRoot)
    #expect(first.lastPathComponent == session.sessionURL.lastPathComponent)
    try Data("stale".utf8).write(to: first.appending(path: "stale.txt"))
    try Data("edited".utf8).write(to: first.appending(path: "transcript.txt"))

    let second = try SessionExporter().export(session: session, to: fixture.exportRoot)
    #expect(second.lastPathComponent == session.sessionURL.lastPathComponent)

    #expect(second.standardizedFileURL == first.standardizedFileURL)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.exportRoot.path) == [first.lastPathComponent])
    #expect(try FileManager.default.contentsOfDirectory(atPath: second.path).sorted() == ["audio.flac", "transcript.txt"])
    #expect(try String(contentsOf: second.appending(path: "transcript.txt"), encoding: .utf8).hasPrefix("[00:00] Speaker 1: こんにちは"))
}

@Test
func exporterCopiesImportedOriginalByteForByte() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let wav = fixture.root.appending(path: "source.wav")
    do {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: fixtureSampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: wav, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fixtureSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        try file.write(from: buffer)
        file.close()
    }
    let original = try Data(contentsOf: wav)
    let session = try await fixture.writeImportedSession(
        originalFilename: "定例会議.wav", originalBytes: original
    )

    let folder = try SessionExporter().export(session: session, to: fixture.exportRoot)

    #expect(folder.lastPathComponent == session.sessionURL.lastPathComponent)
    #expect(try Data(contentsOf: folder.appending(path: "audio.wav")) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["audio.wav", "transcript.txt"])
    let layout = SessionLayout(sessionURL: session.sessionURL)
    #expect(try Data(contentsOf: layout.audioDirectory.appending(path: "original.wav")) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: layout.audioDirectory.path).sorted()
        == ["original.wav", "storage.json"])
    #expect(try String(contentsOf: folder.appending(path: "transcript.txt"), encoding: .utf8)
        == "[00:00] Speaker 1: こんにちは\n[01:05] Speaker 2: 今日の議題です\n")
}
 
@Test
func maximumLengthSessionFolderExportsWithFixedStagingName() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let wav = fixture.root.appending(path: "boundary.wav")
    do {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: fixtureSampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: wav, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fixtureSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        try file.write(from: buffer)
        file.close()
    }
    let original = try Data(contentsOf: wav)
    let session = try await fixture.writeImportedSession(
        originalFilename: String(repeating: "a", count: 300) + ".wav",
        originalBytes: original
    )

    let folder = try SessionExporter().export(session: session, to: fixture.exportRoot)

    #expect(folder.lastPathComponent == session.sessionURL.lastPathComponent)
    #expect(folder.lastPathComponent.utf8.count == 255)
    #expect(try Data(contentsOf: folder.appending(path: "audio.wav")) == original)
    #expect(try String(contentsOf: folder.appending(path: "transcript.txt"), encoding: .utf8)
        == "[00:00] Speaker 1: こんにちは\n[01:05] Speaker 2: 今日の議題です\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.exportRoot.path)
        == [folder.lastPathComponent])
}

@Test
func exporterRefusesSessionWithoutTranscriptAndWritesNothing() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession(activeRuns: nil)

    #expect(throws: SessionExportError.noTranscript) {
        try SessionExporter().export(session: session, to: fixture.exportRoot)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.exportRoot.path))
}

@Test
func exporterRejectsIncompletePublishedTranscriptPointersAndWritesNothing() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession(activeRuns: ActiveRuns(segmentation: "seg-run"))

    guard case .corrupted(let reason) = session.processingStatus else {
        Issue.record("expected incomplete published transcript pointers to be corrupted")
        return
    }
    #expect(throws: SessionExportError.transcriptCorrupted(reason)) {
        try SessionExporter().export(session: session, to: fixture.exportRoot)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.exportRoot.path))
}

struct ExportFixture {
    static let completeRuns = ActiveRuns(
        segmentation: "seg-run",
        asr: "asr-run",
        diarization: "diar-run"
    )

    let root: URL
    let sessionsRoot: URL
    var exportRoot: URL { root.appending(path: "exports", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        sessionsRoot = root.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func sessionURL(_ session: SavedSession) -> URL {
        session.sessionURL
    }

    func writeLiveSession(
        samples: [Float] = (0..<32_000).map { sin(Float($0) * 0.05) * 0.5 },
        activeRuns: ActiveRuns? = completeRuns,
        compacted: Bool = true,
        firstText: String = "こんにちは"
    ) async throws -> SavedSession {
        let id = UUID()
        let session = try writeManifest(id: id, source: .recording(.microphone))
        let layout = SessionLayout(sessionURL: session)
        let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: (fixtureSampleRate * 0.5) / CanonicalAudio.sampleRate, sessionURL: layout.sessionURL)
        try await writer.append(samples: samples)
        let checkpoint = try await writer.finish()
        if compacted {
            let pcm = try ProcessingTimelineReader(directory: layout.processingDirectory, checkpoint: checkpoint, sessionURL: layout.sessionURL)
            try RecordingFLAC.write(reader: pcm, to: layout.recordingFLACURL, sessionURL: layout.sessionURL)
            try SessionAudioStorageStore(layout: layout).save(.recordingFLAC(pcm.info))
            try FileManager.default.removeItem(at: layout.processingDirectory)
        }
        try await writeTranscript(sessionID: id, session: session, activeRuns: activeRuns, firstText: firstText)
        return try readable(id)
    }

    func writeImportedSession(
        originalFilename: String,
        originalBytes: Data
    ) async throws -> SavedSession {
        let id = UUID()
        let session = try writeManifest(id: id, source: .imported(originalFilename: originalFilename))
        let audio = session.appending(path: "audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: originalFilename).pathExtension
        try originalBytes.write(to: audio.appending(path: "original.\(ext)"))
        try SessionAudioStorageStore(layout: SessionLayout(sessionURL: session))
            .save(.importedOriginal(TimelineAudioInfo(committedFrames: 1_600, gapEvents: [])))
        try await writeTranscript(sessionID: id, session: session, activeRuns: Self.completeRuns)
        return try readable(id)
    }

    func summary(_ id: UUID) throws -> SavedSessionSummary {
        try #require(SavedSessionCatalog(fileManager: .default).list(sessionsRoot: sessionsRoot).first { $0.sessionID == id })
    }

    private func readable(_ id: UUID) throws -> SavedSession {
        guard case .readable(let session) = try summary(id) else {
            throw ExportFixtureError.unreadable(id)
        }
        return session
    }

    private func writeManifest(
        id: UUID,
        source: SessionSource
    ) throws -> URL {
        let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: sessionsRoot)
        return try SessionBootstrapper(fileManager: .default).createSession(
            paths: paths, sessionID: id, source: source,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private func writeTranscript(
        sessionID: UUID,
        session: URL,
        activeRuns: ActiveRuns?,
        firstText: String = "こんにちは"
    ) async throws {
        let writer = try SessionWriter(sessionURL: session)
        let segments: [(id: String, start: Int64, end: Int64, text: String, speaker: String)] = [
            ("seg-1", 0, 16_000, firstText, "speaker-a"),
            ("seg-2", 65 * 16_000, 67 * 16_000, "今日の議題です", "speaker-b"),
            ("seg-3", 70 * 16_000, 71 * 16_000, "  ", "speaker-a"),
        ]
        var pending: [SegmentTextReference] = []
        for segment in segments {
            _ = try await writer.append(EventDraft(
                eventType: "segment.created",
                sessionID: sessionID,
                segmentationRunID: "seg-run",
                segmentID: segment.id,
                sourceStartFrame: segment.start,
                sourceEndFrame: segment.end,
                payload: EmptyPayload()
            ))
            let recognized = try await writer.append(EventDraft(
                eventType: "asr.completed",
                sessionID: sessionID,
                processingRunID: "asr-run",
                segmentationRunID: "seg-run",
                segmentID: segment.id,
                payload: ASRCompletedEventPayload(
                    text: segment.text,
                    detectedLanguage: "ja",
                    provenance: RunProvenance(engine: "test", model: "test", version: "test", configuration: [:])
                )
            ))
            if ASRRecognitionOutcome(text: segment.text) == .recognized,
               activeRuns?.asr == "asr-run", activeRuns?.segmentation == "seg-run" {
                pending.append(try SegmentTextReference(
                    segmentationRunID: "seg-run", segmentID: segment.id,
                    asrRunID: "asr-run", asrEventSeq: recognized.eventSeq
                ))
            }
            _ = try await writer.append(EventDraft(
                eventType: "speaker.span",
                sessionID: sessionID,
                processingRunID: "diar-run",
                sourceStartFrame: segment.start,
                sourceEndFrame: segment.end,
                payload: SpeakerSpan(
                    speakerID: segment.speaker,
                    startFrame: segment.start,
                    endFrame: segment.end,
                    confidence: 0.9
                )
            ))
        }
        try ProcessingMetadataStore(sessionURL: session).save(ProcessingMetadata(
            finalizationAttempt: nil,
            activeRuns: activeRuns,
            pendingClauseBoundarySegments: pending,
            pendingContentPriorityClauses: []
        ))
    }

    func saveFillerAssessment(session: SavedSession, rawText: String) async throws -> SavedSession {
        let layout = SessionLayout(sessionURL: session.sessionURL)
        let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: layout.eventsURL))
        let recognized = try EventLogLine.decode(recovered.lines)
            .filter { $0.header.eventType == "asr.completed" }
            .map { line -> (source: SegmentTextReference, text: String) in
                let body = try line.body(ASRCompletedBody.self)
                return (
                    try SegmentTextReference(
                        segmentationRunID: "seg-run", segmentID: body.segmentID,
                        asrRunID: "asr-run", asrEventSeq: line.header.eventSeq
                    ),
                    body.text
                )
            }
            .filter { ASRRecognitionOutcome(text: $0.text) == .recognized }
        guard recognized.count == 2, recognized[0].text == rawText else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(
                runID: "asr-run", reason: "fixture ASR sources do not match the boundary assessment"
            )
        }

        let boundaryRunID = "boundary-run"
        let priorityRunID = "priority-run"
        let identity = try DecisionModelIdentity(model: "fixture", modelRevision: String(repeating: "a", count: 64))
        let writer = try SessionWriter(sessionURL: session.sessionURL)
        try await writer.append(EventDraft(
            eventType: "processing.run.started",
            sessionID: session.sessionID,
            processingRunID: boundaryRunID,
            payload: ProcessingRunStartedPayload(
                stage: .clauseBoundary,
                provenance: DecisionRunProvenance.boundary(mode: "live", identity: identity)
            )
        ))

        var assembly = ClauseBoundaryAssembly(boundaryRunID: boundaryRunID)
        var clauses: [ClauseUnit] = []
        for index in recognized.indices {
            let input = recognized[index]
            let candidates = try ClauseBoundaryCandidate.candidates(in: input.text)
            let next: NextSegmentHead?
            let continuationProbability: Double?
            if index + 1 < recognized.count {
                let successor = recognized[index + 1]
                next = try NextSegmentHead(
                    source: successor.source,
                    text: String(successor.text.prefix(ClauseBoundaryPolicy.nextHeadCharacterLimit))
                )
                continuationProbability = 0.1
            } else {
                next = nil
                continuationProbability = nil
            }
            let assessment = try ClauseBoundaryAssessment(
                source: input.source,
                candidates: candidates,
                probabilities: Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, 0.1) }),
                nextHead: next,
                continuationProbability: continuationProbability,
                fillerRanges: index == 0 ? [try TextUTF16Range(start: 0, end: 2)] : [],
                request: try DecisionRequestRecord(requestID: "boundary-request-\(index + 1)", inputTokens: 1),
                sourceDecision: .assessed
            )
            try await writer.append(EventDraft(
                eventType: ClauseEventType.boundaryAssessed,
                sessionID: session.sessionID,
                processingRunID: boundaryRunID,
                payload: assessment
            ))
            let delta = try assembly.consume(ClauseAssemblyInput(
                source: input.source, text: input.text, state: .assessed(assessment)
            ))
            for clause in delta.closed {
                try await writer.append(EventDraft(
                    eventType: ClauseEventType.clauseClosed,
                    sessionID: session.sessionID,
                    processingRunID: boundaryRunID,
                    payload: clause
                ))
                clauses.append(clause)
            }
        }
        for clause in try assembly.finish().closed {
            try await writer.append(EventDraft(
                eventType: ClauseEventType.clauseClosed,
                sessionID: session.sessionID,
                processingRunID: boundaryRunID,
                payload: clause
            ))
            clauses.append(clause)
        }
        guard clauses.count == recognized.count else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(
                runID: boundaryRunID, reason: "fixture boundary run did not close every recognized source"
            )
        }
        try await writer.append(EventDraft(
            eventType: "processing.run.completed",
            sessionID: session.sessionID,
            processingRunID: boundaryRunID,
            payload: ProcessingRunCompletedPayload(
                stage: .clauseBoundary, succeeded: true, completedCount: recognized.count, failedCount: 0
            )
        ))

        try await writer.append(EventDraft(
            eventType: "processing.run.started",
            sessionID: session.sessionID,
            processingRunID: priorityRunID,
            payload: ProcessingRunStartedPayload(
                stage: .contentPriority,
                provenance: DecisionRunProvenance.priority(mode: "live", identity: identity)
            )
        ))
        let priorityRequestID = "priority-request"
        let assignments = try clauses.enumerated().map { index, clause in
            let decision = try ContentPriorityDecision(
                priority: .primary, confidence: 1.0,
                probabilities: ["PRIMARY": 1.0, "LOW_PRIORITY": 0.0]
            )
            return try ClausePriorityAssignment(
                reference: clause.reference,
                priority: .primary,
                needsRetry: false,
                decision: .classified(
                    requestID: priorityRequestID,
                    answerKey: String(format: "u%04d", index + 1),
                    response: decision
                )
            )
        }
        try await writer.append(EventDraft(
            eventType: ClauseEventType.priorityAssigned,
            sessionID: session.sessionID,
            processingRunID: priorityRunID,
            payload: try ContentPriorityAssignedPayload(
                assignments: assignments,
                request: try DecisionRequestRecord(requestID: priorityRequestID, inputTokens: 1)
            )
        ))
        try await writer.append(EventDraft(
            eventType: "processing.run.completed",
            sessionID: session.sessionID,
            processingRunID: priorityRunID,
            payload: ProcessingRunCompletedPayload(
                stage: .contentPriority, succeeded: true, completedCount: assignments.count, failedCount: 0
            )
        ))

        let metadataStore = ProcessingMetadataStore(sessionURL: session.sessionURL)
        let metadata = try #require(try metadataStore.load())
        let localRuns = try #require(metadata.activeRuns)
        try metadataStore.save(ProcessingMetadata(
            finalizationAttempt: metadata.finalizationAttempt,
            activeRuns: localRuns.withDecisionRuns(clauseBoundary: boundaryRunID, contentPriority: priorityRunID),
            pendingClauseBoundarySegments: [],
            pendingContentPriorityClauses: []
        ))
        return try readable(session.sessionID)
    }
}

private enum ExportFixtureError: Error {
    case unreadable(UUID)
}

/// A row whose whole text is one clause with `priority`, or an unsplit row when nil.
private func segment(
    _ id: String,
    startMilliseconds: Int64,
    text: String,
    fillerRanges: [TextUTF16Range],
    speakers: [(id: String, start: Int64, end: Int64)] = [],
    priority: ContentPriority? = nil,
    isDiarized: Bool = true
) throws -> MaterializedTranscriptSegment {
    let end = startMilliseconds + 1_000
    var slices: [ClauseRowSlice] = []
    if let priority {
        slices = [ClauseRowSlice(
            reference: try ClauseReference(boundaryRunID: "boundary", clauseID: "c1_0"),
            sourceRange: try TextUTF16Range(start: 0, end: text.utf16.count),
            priority: priority, needsRetry: false
        )]
    }
    return try MaterializedTranscriptSegment.fixture(
        segmentID: id,
        startMilliseconds: startMilliseconds,
        endMilliseconds: end,
        text: text,
        fillerRanges: fillerRanges,
        speakers: speakers.map {
            MaterializedSpeakerSpan(
                id: $0.id, startMilliseconds: $0.start, endMilliseconds: $0.end,
                confidence: nil, displayLabel: nil
            )
        },
        isDiarized: isDiarized,
        clauseState: priority == nil ? nil : .classified,
        clauseSlices: slices
    )
}

@Test
func transcriptTextHasExactlyTheRowsTheScreenShows() throws {
    let segments = [
        try segment("kept", startMilliseconds: 0, text: "残る発話", fillerRanges: [], speakers: [("A", 0, 1_000)]),
        try segment("empty", startMilliseconds: 1_000, text: " \n", fillerRanges: [], speakers: [("A", 1_000, 2_000)]),
        try segment(
            "conversation", startMilliseconds: 2_000, text: "別の会話", fillerRanges: [],
            speakers: [("A", 2_000, 3_000)]
        ),
        try segment(
            "low", startMilliseconds: 3_000, text: "えーと、低優先度本文",
            fillerRanges: [try TextUTF16Range(start: 0, end: 3)], speakers: [("B", 3_000, 4_000)],
            priority: .lowPriority
        ),
        try segment(
            "filler-only", startMilliseconds: 4_000, text: "えー、",
            fillerRanges: [try TextUTF16Range(start: 0, end: 2)], speakers: [("A", 4_000, 5_000)]),
    ]

    let rows = try LiveTranscriptProjection().rows(for: segments)
    let lines = try TranscriptTextRenderer.render(segments).split(separator: "\n", omittingEmptySubsequences: false)

    #expect(rows.map(\.segmentID) == ["kept", "conversation"])
    #expect(rows.map(\.text) == ["残る発話", "別の会話"])
    #expect(lines == ["[00:00] Speaker 1: 残る発話", "[00:02] Speaker 1: 別の会話", ""])
}

@Test
func mixedClausePrioritiesExportOnlyTheNonLowText() throws {
    let raw = "えー、重要。余談。"
    let ranges = [try TextUTF16Range(start: 0, end: 6), try TextUTF16Range(start: 6, end: raw.utf16.count)]
    let slices = try ranges.enumerated().map { index, range in
        ClauseRowSlice(
            reference: try ClauseReference(boundaryRunID: "boundary", clauseID: "c1_\(range.start)"),
            sourceRange: range,
            priority: index == 0 ? .primary : .lowPriority, needsRetry: false
        )
    }
    let mixed = try MaterializedTranscriptSegment.fixture(
        segmentID: "mixed", startMilliseconds: 0, endMilliseconds: 1_000,
        text: raw,
        fillerRanges: [try TextUTF16Range(start: 0, end: 2)],
        speakers: [MaterializedSpeakerSpan(id: "A", startMilliseconds: 0, endMilliseconds: 1_000, confidence: nil, displayLabel: nil)],
        isDiarized: true, clauseState: .classified, clauseSlices: slices
    )
    let row = try #require(LiveTranscriptProjection().rows(for: [mixed]).first)
    #expect(mixed.text == raw)
    #expect(row.text == "重要。")
    #expect(try TranscriptTextRenderer.render([mixed]) == "[00:00] Speaker 1: 重要。\n")
}

@Test
func transcriptTextJoinsSpeakersBelowTheEightyPercentRuleAndKeepsOneAbove() throws {
    let mixed = try segment(
        "mixed", startMilliseconds: 0, text: "会話", fillerRanges: [], speakers: [("A", 0, 600), ("B", 600, 1_000)]
    )
    let dominant = try segment(
        "dominant", startMilliseconds: 2_000, text: "講義", fillerRanges: [], speakers: [("A", 2_000, 2_850), ("B", 2_850, 3_000)]
    )

    #expect(try TranscriptTextRenderer.render([mixed, dominant])
        == "[00:00] Speaker 1 / Speaker 2: 会話\n[00:02] Speaker 1: 講義\n")
}

@Test
func transcriptTextWritesUnknownForADiarizedUtteranceWithoutSpeakers() throws {
    #expect(try TranscriptTextRenderer.render([try segment("lonely", startMilliseconds: 61_000, text: "誰か", fillerRanges: [])])
        == "[01:01] UNKNOWN: 誰か\n")
}

@Test
func transcriptTextReplacesLineBreaksSoEachUtteranceIsOneLine() throws {
    let text = "一行目\r\n二行目\n三行目\r四行目\u{2028}五行目\u{2029}六行目"
    let rendered = try TranscriptTextRenderer.render([
        try segment("multi", startMilliseconds: 0, text: text, fillerRanges: [], speakers: [("A", 0, 1_000)])
    ])

    #expect(rendered == "[00:00] Speaker 1: 一行目 二行目 三行目 四行目 五行目 六行目\n")
}

@Test
func transcriptTextRejectsAnUtteranceWithoutDiarization() {
    #expect(throws: TranscriptTextRendererError.missingSpeakerHeading(segmentID: "live")) {
        try TranscriptTextRenderer.render([try segment("live", startMilliseconds: 0, text: "暫定", fillerRanges: [], isDiarized: false)])
    }
}

@Test
func corruptProcessingMetadataBlocksExportButKeepsTheSessionReprocessable() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let written = try await fixture.writeLiveSession()
    try Data("{broken".utf8).write(to: fixture.sessionURL(written).appending(path: "processing_metadata.json"))

    let summary = try fixture.summary(written.sessionID)
    guard case .readable(let session) = summary else {
        Issue.record("expected a readable session, got \(summary)")
        return
    }

    #expect(summary.canReprocess)
    guard case .corrupted(let reason) = session.processingStatus else {
        Issue.record("expected corrupted derived results, got \(session.processingStatus)")
        return
    }
    #expect(throws: SessionExportError.transcriptCorrupted(reason)) {
        try SessionExporter().export(session: session, to: fixture.exportRoot)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.exportRoot.path))
}
