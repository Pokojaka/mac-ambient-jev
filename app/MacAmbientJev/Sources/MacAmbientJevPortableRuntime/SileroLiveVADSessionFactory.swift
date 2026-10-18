import Foundation
import MacAmbientJevCore
import MacAmbientJevONNX
import MacAmbientJevPipeline

public enum SileroLiveVADSessionFactory {
    public static func make(
        environment: ONNXEnvironment,
        modelURL: URL,
        intraOpThreads: Int,
        processingDirectory: URL,
        sessionURL: URL,
        initialCheckpoint: AudioCheckpoint,
        measureMicInputLevels: Bool,
        segmentationRunID: String
    ) throws -> LiveVADSession {
        let engine = try SileroVADSegmentationEngine(
            environment: environment,
            modelURL: modelURL,
            intraOpThreads: intraOpThreads,
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
