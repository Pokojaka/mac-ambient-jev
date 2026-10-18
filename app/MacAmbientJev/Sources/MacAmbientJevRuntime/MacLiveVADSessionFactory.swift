import Foundation
import MacAmbientJevCore
import MacAmbientJevPipeline

public enum MacLiveVADSessionFactory {
    public static func make(
        processingDirectory: URL,
        sessionURL: URL,
        initialCheckpoint: AudioCheckpoint,
        measureMicInputLevels: Bool,
        segmentationRunID: String
    ) async throws -> LiveVADSession {
        let engine = try await FluidVADSegmentationEngine.make(
            segmentationRunID: segmentationRunID,
            canonicalSampleRate: initialCheckpoint.sampleRate,
            measureMicInputLevels: measureMicInputLevels
        )
        return LiveVADSession(
            segmentationRunID: segmentationRunID,
            processingDirectory: processingDirectory,
            sessionURL: sessionURL,
            processor: VADTimelineProcessor(engine: engine),
            initialCommittedFrames: initialCheckpoint.committedFrames
        )
    }
}
