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
    let session = try await fixture.writeLiveSession(firstText: raw)
    let layout = SessionLayout(sessionURL: session.sessionURL)
    let eventsBefore = try Data(contentsOf: layout.eventsURL)
    let transcript = try SavedTranscriptLoader.load(
        sessionURL: session.sessionURL,
        audioSource: try #require(session.audioSource)
    )
    guard case .segments(let segments) = transcript else {
        Issue.record("expected saved transcript segments")
        return
    }

    #expect(segments.first?.text == raw)
    let rows = try LiveTranscriptProjection().rows(for: segments)
    #expect(rows.first?.text == "今日は公開鍵暗号を説明します。")
    #expect(try TranscriptTextRenderer.render(segments)
        == "[00:00] Speaker 1: 今日は公開鍵暗号を説明します。\n[01:05] Speaker 2: 今日の議題です\n")
    #expect(try Data(contentsOf: layout.eventsURL) == eventsBefore)
}

@Test
func savedTranscriptLoaderRejectsAnIncompleteEventTail() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession()
    let eventsURL = SessionLayout(sessionURL: session.sessionURL).eventsURL
    var bytes = try Data(contentsOf: eventsURL)
    bytes.append(contentsOf: "{\"schema_version\":2".utf8)
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
}

private enum ExportFixtureError: Error {
    case unreadable(UUID)
}

/// A row whose whole text is one clause with `priority`, or an unsplit row when nil.
private func segment(
    _ id: String,
    startMilliseconds: Int64,
    text: String,
    speakers: [(id: String, start: Int64, end: Int64)] = [],
    scene: SceneState = .lecture,
    scopes: [AcousticScope] = [],
    priority: ContentPriority? = nil,
    isDiarized: Bool = true
) throws -> MaterializedTranscriptSegment {
    let end = startMilliseconds + 1_000
    var slices: [ClauseRowSlice] = []
    if let priority {
        let projection = try TranscriptTextProjector(detector: FillerTextSpanDetector()).project(sourceText: text)
        let range = try TextUTF16Range(start: 0, end: text.utf16.count)
        slices = [ClauseRowSlice(
            reference: try ClauseReference(boundaryRunID: "boundary", clauseID: "c1_0"),
            sourceRange: range, displayRanges: try projection.displayRanges(for: range),
            priority: priority, needsRetry: false
        )]
    }
    return try MaterializedTranscriptSegment.fixture(
        segmentID: id,
        startMilliseconds: startMilliseconds,
        endMilliseconds: end,
        text: text,
        scene: scene,
        speakers: speakers.map {
            MaterializedSpeakerSpan(
                id: $0.id, startMilliseconds: $0.start, endMilliseconds: $0.end,
                confidence: nil, displayLabel: nil
            )
        },
        scopeSpans: scopes.map {
            MaterializedScopeSpan(startMilliseconds: startMilliseconds, endMilliseconds: end, scope: $0, confidence: 0.9)
        },
        isDiarized: isDiarized,
        clauseState: priority == nil ? nil : .classified,
        clauseSlices: slices
    )
}

@Test
func transcriptTextHasExactlyTheRowsTheScreenShows() throws {
    let segments = [
        try segment("kept", startMilliseconds: 0, text: "残る発話", speakers: [("A", 0, 1_000)]),
        try segment("empty", startMilliseconds: 1_000, text: " \n", speakers: [("A", 1_000, 2_000)]),
        try segment(
            "background", startMilliseconds: 2_000, text: "遠くの会話",
            speakers: [("A", 2_000, 3_000)], scene: .discussion, scopes: [.background]
        ),
        try segment(
            "low", startMilliseconds: 3_000, text: "えーと、低優先度本文", speakers: [("B", 3_000, 4_000)],
            priority: .lowPriority
        ),
        try segment("filler-only", startMilliseconds: 4_000, text: "えー、", speakers: [("A", 4_000, 5_000)]),
    ]

    let rows = try LiveTranscriptProjection().rows(for: segments)
    let lines = try TranscriptTextRenderer.render(segments).split(separator: "\n", omittingEmptySubsequences: false)

    #expect(rows.map(\.segmentID) == ["kept", "low"])
    #expect(rows.map(\.text) == ["残る発話", "低優先度本文"])
    #expect(lines == ["[00:00] Speaker 1: 残る発話", "[00:03] Speaker 2: 低優先度本文", ""])
}

@Test
func mixedClausePrioritiesKeepTheWholeCleanedTextInExport() throws {
    let raw = "えー、重要。余談。"
    let projection = try TranscriptTextProjector(detector: FillerTextSpanDetector()).project(sourceText: raw)
    let ranges = [try TextUTF16Range(start: 0, end: 6), try TextUTF16Range(start: 6, end: raw.utf16.count)]
    let slices = try ranges.enumerated().map { index, range in
        ClauseRowSlice(
            reference: try ClauseReference(boundaryRunID: "boundary", clauseID: "c1_\(range.start)"),
            sourceRange: range, displayRanges: try projection.displayRanges(for: range),
            priority: index == 0 ? .primary : .lowPriority, needsRetry: false
        )
    }
    let mixed = try MaterializedTranscriptSegment.fixture(
        segmentID: "mixed", startMilliseconds: 0, endMilliseconds: 1_000,
        text: raw, scene: .lecture,
        speakers: [MaterializedSpeakerSpan(id: "A", startMilliseconds: 0, endMilliseconds: 1_000, confidence: nil, displayLabel: nil)],
        scopeSpans: [], isDiarized: true, clauseState: .classified, clauseSlices: slices
    )
    let row = try #require(LiveTranscriptProjection().rows(for: [mixed]).first)
    #expect(row.text == "重要。余談。")
    #expect(row.textFragments == [
        TranscriptTextFragment(text: "重要。", style: .normal),
        TranscriptTextFragment(text: "余談。", style: .lowPriority)
    ])
    #expect(!row.shouldCollapseRow)
    #expect(try TranscriptTextRenderer.render([mixed]) == "[00:00] Speaker 1: 重要。余談。\n")
}

@Test
func transcriptTextJoinsSpeakersBelowTheEightyPercentRuleAndKeepsOneAbove() throws {
    let mixed = try segment(
        "mixed", startMilliseconds: 0, text: "会話", speakers: [("A", 0, 600), ("B", 600, 1_000)]
    )
    let dominant = try segment(
        "dominant", startMilliseconds: 2_000, text: "講義", speakers: [("A", 2_000, 2_850), ("B", 2_850, 3_000)]
    )

    #expect(try TranscriptTextRenderer.render([mixed, dominant])
        == "[00:00] Speaker 1 / Speaker 2: 会話\n[00:02] Speaker 1: 講義\n")
}

@Test
func transcriptTextWritesUnknownForADiarizedUtteranceWithoutSpeakers() throws {
    #expect(try TranscriptTextRenderer.render([try segment("lonely", startMilliseconds: 61_000, text: "誰か")])
        == "[01:01] UNKNOWN: 誰か\n")
}

@Test
func transcriptTextReplacesLineBreaksSoEachUtteranceIsOneLine() throws {
    let text = "一行目\r\n二行目\n三行目\r四行目\u{2028}五行目\u{2029}六行目"
    let rendered = try TranscriptTextRenderer.render([
        try segment("multi", startMilliseconds: 0, text: text, speakers: [("A", 0, 1_000)])
    ])

    #expect(rendered == "[00:00] Speaker 1: 一行目 二行目 三行目 四行目 五行目 六行目\n")
}

@Test
func transcriptTextRejectsAnUtteranceWithoutDiarization() {
    #expect(throws: TranscriptTextRendererError.missingSpeakerHeading(segmentID: "live")) {
        try TranscriptTextRenderer.render([try segment("live", startMilliseconds: 0, text: "暫定", isDiarized: false)])
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
