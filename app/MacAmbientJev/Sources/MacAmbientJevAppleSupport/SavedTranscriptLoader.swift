import Foundation
import MacAmbientJevCore

public enum SavedTranscript: Sendable, Equatable {
    case unavailable
    case segments([MaterializedTranscriptSegment])
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

        guard let timeline = try audioSource.timeline else {
            return .unavailable
        }

        let lines = try SessionRecovery.recoverJSONL(Data(contentsOf: layout.eventsURL)).lines
        let events = try EventLogTranscriptReader().events(
            lines: lines,
            activeRuns: activeRuns
        )
        return .segments(
            TranscriptMaterializer(sampleRate: timeline.sampleRate)
                .materialize(events: events, activeRuns: activeRuns)
        )
    }
}
