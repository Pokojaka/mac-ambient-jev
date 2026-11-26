import Foundation
import MacAmbientJevCore

public enum SessionProcessingAudioError: LocalizedError, Equatable {
    case compactionNotRequired

    public var errorDescription: String? {
        "完了した録音が PCM のまま FLAC 化の対象になっていません"
    }
}

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

    /// Runs the storage step the launch maintenance predicate asks for. A drained recording that the
    /// predicate does not ask to compact is an error, not a skip.
    public func convergeStorage(layout: SessionLayout, manifest: SessionManifest) async throws {
        let needsCompaction = try await runBlocking {
            if try SessionStorageMaintenance.required(layout: layout, manifest: manifest) == .compactRecording {
                return true
            }
            if case .recordedPCM(let checkpoint)? = try layout.audioSource(for: manifest), checkpoint.committedFrames > 0 {
                throw SessionProcessingAudioError.compactionNotRequired
            }
            return false
        }
        if needsCompaction { try await compactRecording(layout: layout) }
    }

    func compactRecording(layout: SessionLayout) async throws {
        let compactionOperation = self.compactionOperation
        try await runBlocking { try compactionOperation(layout) }
    }

    private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        // Detached does not move blocking file work off the cooperative pool; use a dedicated executor.
        let task = Task.detached(executorPreference: BlockingIOExecutor.shared) { try work() }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }
}
