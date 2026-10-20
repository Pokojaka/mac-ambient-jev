import Foundation
import MacAmbientJevCore
import MacAmbientJevPipeline

/// Supports recorded audio only; SessionAudioReaders explicitly rejects imported originals.
struct RecordingTestAudioHandling: SessionProcessingAudioHandling {
    func open(
        _ source: SessionAudioSource,
        layout: SessionLayout,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> any TimelineAudioReading {
        try SessionAudioReaders.open(source, layout: layout)
    }

    func compactRecording(layout: SessionLayout) async throws {
        _ = try RecordingAudioCompactor(interrupt: nil).compact(layout: layout)
    }

    func exportDiarizationAudio(
        reader: any TimelineAudioReading,
        to destinationURL: URL,
        sessionURL: URL
    ) throws {
        // The fake diarizer in orchestration tests does not read this explicit marker. Real CAF
        // export integration remains covered by Mac tests.
        try SessionFileAccess.createDirectory(destinationURL.deletingLastPathComponent(), relativeTo: sessionURL)
        try SessionFileAccess.writeAtomically(
            Data("テスト用の話者分離入力".utf8),
            to: destinationURL,
            relativeTo: sessionURL
        )
    }
}
