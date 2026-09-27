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

struct ExportFixture {
    static let completeRuns = ActiveRuns(
        segmentation: "seg-run",
        asr: "asr-run",
        diarization: "diar-run"
    )

    let root: URL
    let sessionsRoot: URL

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
