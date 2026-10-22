import Foundation
import MacAmbientJevCore

public enum PortableAudioFileImporter {
    public static func open(inputURL: URL, sessionURL: URL) async throws -> ProcessingTimelineReader {
        let imported = try AudioImporter().importFile(inputURL, into: sessionURL)
        let layout = SessionLayout(sessionURL: sessionURL)
        let checkpoint = try await PortableImportedAudioTimelineBuilder().build(
            from: imported.originalURL,
            into: layout.processingDirectory,
            sessionURL: sessionURL
        )
        let reader = try ProcessingTimelineReader(
            directory: layout.processingDirectory,
            checkpoint: checkpoint,
            sessionURL: sessionURL
        )
        try reader.validateAudio()
        let info = reader.info
        guard info.committedFrames > 0,
              info.sampleRate == CanonicalAudio.sampleRate,
              info.channelCount == CanonicalAudio.channelCount else {
            throw PortableAudioImportError.invalidTimeline
        }
        return reader
    }
}
