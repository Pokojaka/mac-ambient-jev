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
}
