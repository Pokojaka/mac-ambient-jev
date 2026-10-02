import AVFoundation
import Foundation
import Testing
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
func exportFolderNameUsesDateStemAndSessionPrefix() {
    let id = UUID(uuidString: "0123ABCD-0000-0000-0000-000000000000")!
    let utc = TimeZone(identifier: "UTC")!
    func summary(_ filename: String?) -> SavedSessionSummary {
        SavedSessionSummary(
            sessionID: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceKind: filename == nil ? .live : .importedFile,
            originalFilename: filename,
            audioSource: nil,
            hasActiveTranscript: true,
            processingStatus: .complete
        )
    }

    #expect(SessionExportLayout.folderName(for: summary(nil), timeZone: utc) == "2023-11-14 2213 録音 0123ABCD")
    #expect(SessionExportLayout.folderName(for: summary("定例:会議.mp3"), timeZone: utc) == "2023-11-14 2213 定例-会議 0123ABCD")
}

@Test
func exporterWritesReadableTranscriptAndFlacAudio() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let samples: [Float] = (0..<32_000).map { sin(Float($0) * 0.05) * 0.5 }
    let session = try await fixture.writeLiveSession(samples: samples)

    let folder = try SessionExporter().export(
        session: session,
        sessionsRoot: fixture.sessionsRoot,
        to: fixture.exportRoot
    )

    let transcript = try String(contentsOf: folder.appending(path: "transcript.txt"), encoding: .utf8)
    #expect(transcript == "[00:00] Speaker 1: こんにちは\n[01:05] Speaker 2: 今日の議題です\n")

    let flac = try AVAudioFile(forReading: folder.appending(path: "audio.flac"))
    #expect(flac.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatFLAC)
    #expect(flac.length == Int64(samples.count))
    #expect(flac.processingFormat.sampleRate == fixtureSampleRate)
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: flac.processingFormat,
        frameCapacity: AVAudioFrameCount(flac.length)
    ))
    try flac.read(into: buffer)
    let decoded = UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength))
    let maxError = zip(samples, decoded).map { abs($0 - $1) }.max() ?? .infinity
    #expect(decoded.count == samples.count)
    #expect(maxError <= 1.0 / Float(1 << 23))
}

@Test
func reexportReplacesTheSameFolder() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession()
    let first = try SessionExporter().export(session: session, sessionsRoot: fixture.sessionsRoot, to: fixture.exportRoot)
    try Data("stale".utf8).write(to: first.appending(path: "stale.txt"))
    try Data("edited".utf8).write(to: first.appending(path: "transcript.txt"))

    let second = try SessionExporter().export(session: session, sessionsRoot: fixture.sessionsRoot, to: fixture.exportRoot)

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
    let session = try await fixture.writeImportedSession(originalFilename: "定例会議.wav", originalBytes: original)

    let folder = try SessionExporter().export(session: session, sessionsRoot: fixture.sessionsRoot, to: fixture.exportRoot)

    #expect(folder.lastPathComponent.contains(" 定例会議 "))
    #expect(try Data(contentsOf: folder.appending(path: "audio.wav")) == original)
    #expect(FileManager.default.fileExists(atPath: folder.appending(path: "transcript.txt").path))
}

@Test
func exporterRefusesSessionWithoutTranscriptAndWritesNothing() async throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let session = try await fixture.writeLiveSession(activeRuns: ActiveRuns(segmentation: "seg-run"))

    #expect(throws: SessionExportError.noTranscript) {
        try SessionExporter().export(session: session, sessionsRoot: fixture.sessionsRoot, to: fixture.exportRoot)
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

    func sessionURL(_ session: SavedSessionSummary) -> URL {
        sessionsRoot.appending(path: session.sessionID.uuidString, directoryHint: .isDirectory)
    }

    func writeLiveSession(
        samples: [Float] = (0..<32_000).map { sin(Float($0) * 0.05) * 0.5 },
        activeRuns: ActiveRuns = completeRuns
    ) async throws -> SavedSessionSummary {
        let id = UUID()
        let session = try writeManifest(id: id, source: .live, originalFilename: nil)
        let writer = try DurableAudioWriter(
            directory: session.appending(path: "audio/processing", directoryHint: .isDirectory),
            sampleRate: fixtureSampleRate,
            channelCount: 1,
            chunkDurationSeconds: 0.5
        )
        try await writer.append(samples: samples)
        _ = try await writer.finish()
        try await writeTranscript(sessionID: id, session: session, activeRuns: activeRuns)
        return try summary(id)
    }

    func writeImportedSession(
        originalFilename: String,
        originalBytes: Data
    ) async throws -> SavedSessionSummary {
        let id = UUID()
        let session = try writeManifest(id: id, source: .importedFile, originalFilename: originalFilename)
        let audio = session.appending(path: "audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: originalFilename).pathExtension
        try originalBytes.write(to: audio.appending(path: "original.\(ext)"))
        try await writeTranscript(sessionID: id, session: session, activeRuns: Self.completeRuns)
        return try summary(id)
    }

    private func summary(_ id: UUID) throws -> SavedSessionSummary {
        try #require(SavedSessionCatalog().list(sessionsRoot: sessionsRoot).first { $0.sessionID == id })
    }

    private func writeManifest(
        id: UUID,
        source: SessionSourceKind,
        originalFilename: String?
    ) throws -> URL {
        let session = sessionsRoot.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(SessionManifest(
            sessionID: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceKind: source,
            originalFilename: originalFilename
        )).write(to: session.appending(path: "session.json"), options: .atomic)
        return session
    }

    private func writeTranscript(
        sessionID: UUID,
        session: URL,
        activeRuns: ActiveRuns
    ) async throws {
        let writer = try SessionWriter(sessionURL: session)
        let segments: [(id: String, start: Int64, end: Int64, text: String, speaker: String)] = [
            ("seg-1", 0, 16_000, "こんにちは", "speaker-a"),
            ("seg-2", 65 * 16_000, 67 * 16_000, "今日の議題です", "speaker-b"),
            ("seg-3", 70 * 16_000, 71 * 16_000, "  ", "speaker-a"),
        ]
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
            _ = try await writer.append(EventDraft(
                eventType: "asr.completed",
                sessionID: sessionID,
                processingRunID: "asr-run",
                segmentationRunID: "seg-run",
                segmentID: segment.id,
                payload: ASRCompletedEventPayload(
                    text: segment.text,
                    detectedLanguage: "ja",
                    engine: "test",
                    model: "test"
                )
            ))
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
            timelineVersion: 1, vadVersion: "vad", vadConfigHash: "hash",
            asrEngine: "qwen", asrModel: "model", asrVersion: "version",
            diarizationVersion: "diar", sceneAnalyzerVersion: 1,
            jevSchemaVersion: 1, policyVersion: 1, materializerSchemaVersion: 1,
            activeRuns: activeRuns
        ))
    }
}
