import Foundation

/// Audio files that exist only while one finalization or compaction runs. The finalization
/// that creates them removes them on every outcome; launch maintenance removes what a killed
/// process left. Recording PCM is never transient: it stays authoritative until the FLAC
/// state is persisted.
public enum SessionTransientAudio {
    public static func urls(layout: SessionLayout, source: SessionSource) -> [URL] {
        var urls = [layout.derivedDirectory, layout.recordingFLACPartialURL]
        if case .imported = source {
            urls.append(layout.processingDirectory)
        }
        return urls
    }

    public static func isPresent(layout: SessionLayout, source: SessionSource) -> Bool {
        urls(layout: layout, source: source).contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func remove(layout: SessionLayout, source: SessionSource) throws {
        for url in urls(layout: layout, source: source) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Storage work a session needs regardless of whether its transcript needs recovery.
public enum SessionStorageMaintenance: String, Sendable, Equatable {
    /// Remove a stale diarization CAF, FLAC partial or import timeline.
    case removeTransients
    /// Convert a finalized PCM recording to verified FLAC, or finish removing PCM after the
    /// FLAC state was persisted. Also removes transients.
    case compactRecording

    public static func required(layout: SessionLayout, manifest: SessionManifest) throws -> SessionStorageMaintenance? {
        let storage = try SessionAudioStorageStore(layout: layout).load()
        try storage.validate(for: manifest.source)
        switch storage {
        case .recordingPCM:
            let published = try ProcessingMetadataStore(sessionURL: layout.sessionURL).load()?
                .activeRuns != nil
            if published, try layout.audioSource(for: manifest) != nil {
                return .compactRecording
            }
        case .recordingFLAC:
            if FileManager.default.fileExists(atPath: layout.processingDirectory.path) {
                return .compactRecording
            }
        case .importedOriginal:
            break
        }
        return SessionTransientAudio.isPresent(layout: layout, source: manifest.source) ? .removeTransients : nil
    }
}
