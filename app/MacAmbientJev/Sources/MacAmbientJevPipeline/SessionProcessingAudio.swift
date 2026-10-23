import Foundation
import MacAmbientJevCore

public struct SessionProcessingAudio: SessionProcessingAudioHandling {
    private let timelineBuilder: any ImportedAudioTimelineBuilding
    private let compactionOperation: @Sendable (SessionLayout) throws -> Void

    public init(timelineBuilder: any ImportedAudioTimelineBuilding) {
        self.timelineBuilder = timelineBuilder
        self.compactionOperation = { layout in
            _ = try RecordingAudioCompactor(interrupt: nil).compact(layout: layout)
        }
    }

    init(
        timelineBuilder: any ImportedAudioTimelineBuilding,
        compactionOperation: @escaping @Sendable (SessionLayout) throws -> Void
    ) {
        self.timelineBuilder = timelineBuilder
        self.compactionOperation = compactionOperation
    }

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
        let checkpoint = try await timelineBuilder.build(
            from: originalURL,
            into: layout.processingDirectory,
            sessionURL: layout.sessionURL
        )
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
        try Task.checkCancellation()
        let compactionOperation = self.compactionOperation
        // Detached does not move blocking file work off the cooperative pool; use a dedicated executor.
        let task = Task.detached(executorPreference: BlockingIOExecutor.shared) {
            try compactionOperation(layout)
        }
        try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
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
