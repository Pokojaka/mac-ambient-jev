import AVFoundation
import Foundation
import MacAmbientJevCore

public enum SavedTranscript: Sendable, Equatable {
    case unavailable
    case segments([MaterializedTranscriptSegment])
}

public enum SavedTranscriptLoaderError: Error, LocalizedError, Equatable {
    case invalidSampleRate

    public var errorDescription: String? {
        switch self {
        case .invalidSampleRate:
            "保存済み文字起こしの音声時間情報がありません"
        }
    }
}

public enum SavedTranscriptLoader {
    public static func load(
        sessionURL: URL,
        audioSource: SessionAudioSource
    ) throws -> SavedTranscript {
        let layout = SessionLayout(sessionURL: sessionURL)
        guard let activeRuns = try ProcessingMetadataStore(
            sessionURL: layout.sessionURL
        ).load()?.activeRuns, activeRuns.asr != nil else {
            return .unavailable
        }

        let sampleRate: Double
        switch audioSource {
        case .recordedTimeline(let checkpoint):
            sampleRate = checkpoint.sampleRate
        case .importedOriginal(let originalURL):
            sampleRate = try AVAudioFile(forReading: originalURL)
                .processingFormat.sampleRate
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw SavedTranscriptLoaderError.invalidSampleRate
        }

        let lines = try SessionRecovery.recoverJSONL(Data(contentsOf: layout.eventsURL)).lines
        let events = try EventLogTranscriptReader().events(
            lines: lines,
            activeRuns: activeRuns
        )
        return .segments(
            TranscriptMaterializer(sampleRate: sampleRate)
                .materialize(events: events, activeRuns: activeRuns)
        )
    }
}
