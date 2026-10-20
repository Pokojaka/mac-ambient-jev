import Foundation
import MacAmbientJevCore
import MacAmbientJevAppleSupport
import MacAmbientJevPipeline

public extension SessionProcessingEngines {
    /// Creates the production engines used by the app and command-line tools.
    static func production(paths: AppPaths) -> SessionProcessingEngines {
        SessionProcessingEngines(
            asr: NativeQwen3ASREngine(modelStore: ModelStore(paths: paths)),
            diarization: FluidOfflineDiarizationEngine(paths: paths),
            finalTranscriptVAD: FluidFinalTranscriptVADSegmenter()
        )
    }
}

public struct MacSessionProcessingAudio: SessionProcessingAudioHandling {
    public init() {}

    /// An import is read only through the timeline built for this run, which finalization removes.
    public func open(
        _ source: SessionAudioSource,
        layout: SessionLayout,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> any TimelineAudioReading {
        guard case .importedOriginal(let originalURL, _) = source else {
            return try SessionAudioReaders.open(source, layout: layout)
        }
        await onStatus(UserFacingStatus.convertingTimeline.text)
        let checkpoint = try await AudioFileTimelineBuilder()
            .build(from: originalURL, into: layout.processingDirectory, sessionURL: layout.sessionURL)
        let reader = try ProcessingTimelineReader(
            directory: layout.processingDirectory,
            checkpoint: checkpoint,
            sessionURL: layout.sessionURL
        )
        try reader.validateAudio()
        try SessionAudioStorageStore(layout: layout).save(.importedOriginal(reader.info))
        return reader
    }

    public func compactRecording(layout: SessionLayout) async throws {
        _ = try await Task.detached {
            try RecordingAudioCompactor(interrupt: nil).compact(layout: layout)
        }.value
    }

    public func exportDiarizationAudio(
        reader: any TimelineAudioReading,
        to destinationURL: URL,
        sessionURL: URL
    ) throws {
        try ProcessingTimelineAudioExporter(
            framesPerBuffer: max(1, Int64(reader.info.sampleRate.rounded()))
        ).export(reader: reader, to: destinationURL, sessionURL: sessionURL)
    }
}
