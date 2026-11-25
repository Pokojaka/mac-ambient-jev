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

    func convergeStorage(layout: SessionLayout, manifest: SessionManifest) async throws {
        if try SessionStorageMaintenance.required(layout: layout, manifest: manifest) == .compactRecording {
            _ = try RecordingAudioCompactor(interrupt: nil).compact(layout: layout)
        } else if case .recordedPCM(let checkpoint)? = try layout.audioSource(for: manifest), checkpoint.committedFrames > 0 {
            throw SessionProcessingAudioError.compactionNotRequired
        }
    }
}
