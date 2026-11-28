import Foundation
import MacAmbientJevCore

public enum SavedTranscript: Sendable, Equatable {
    case unavailable
    case segments(generationID: UUID, [MaterializedTranscriptSegment])
}

public enum SavedTranscriptLoader {
    public static func load(sessionURL: URL) throws -> SavedTranscript {
        let layout = SessionLayout(sessionURL: sessionURL)
        let manifest = try layout.loadManifest()
        guard let stored = try EventLogTranscriptReader().read(
            eventsURL: layout.eventsURL,
            sessionID: manifest.sessionID
        ) else {
            return .unavailable
        }
        return .segments(
            generationID: stored.state.generation.id,
            try TranscriptMaterializer(sampleRate: stored.state.generation.sampleRate)
                .materialize(events: stored.events, activeRuns: stored.state.runs)
        )
    }
}
