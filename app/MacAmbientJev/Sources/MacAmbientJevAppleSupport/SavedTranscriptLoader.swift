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
        guard let metadata = try ProcessingMetadataStore(
            sessionURL: layout.sessionURL
        ).load(), let activeRuns = metadata.activeRuns, activeRuns.asr != nil else {
            return .unavailable
        }

        guard let timeline = try audioSource.timeline else {
            return .unavailable
        }

        let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: layout.eventsURL))
        guard !recovered.droppedIncompleteTail else {
            throw EventLogTranscriptReaderError.unreadableLine(index: recovered.lines.count)
        }
        let lines = recovered.lines
        _ = try JevRetryAnalyzer().retryTargets(lines: lines, metadata: metadata)
        let events = try EventLogTranscriptReader().events(
            lines: lines,
            activeRuns: activeRuns
        )
        return .segments(
            try TranscriptMaterializer(sampleRate: timeline.sampleRate)
                .materialize(events: events, activeRuns: activeRuns)
        )
    }
}
