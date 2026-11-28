import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

/// Deterministic inference for recording acceptance tests. Capture and durable processing stay real;
/// only model inference and live VAD output are deterministic.
public struct DeterministicInferenceProvider: EngineInferenceProviding {
    private let usageCounter = DecisionUsageCounter()

    public init() {}

    public func prepare(
        settings: EngineSettings,
        onProgress: @escaping @Sendable (EngineModelProgress) -> Void
    ) async throws {
        onProgress(EngineModelProgress(stage: .validating, completed: 0, total: 1))
        try Self.validate(settings: settings)
        onProgress(EngineModelProgress(stage: .loading, completed: 1, total: 1))
    }

    public func decisionUsage() async throws -> DecisionUsageSnapshot {
        await usageCounter.snapshot()
    }

    public func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity {
        throw EngineAdapterError(
            code: .modelMissing,
            message: "決定論的プロバイダーにはインストール済みの発話文モデルがありません",
            recoveryAction: .prepareModels,
            details: []
        )
    }

    public func makeInference(settings: EngineSettings) throws -> EngineInference {
        try Self.validate(settings: settings)
        return EngineInference(
            engines: SessionProcessingEngines(
                asr: DeterministicASR(),
                sessionVAD: DeterministicSessionVAD()
            ),
            contentPriority: .disabled,
            timelineBuilder: UnsupportedImportedAudioTimelineBuilder(),
            makeLiveVADSession: { _, _, _, segmentationRunID in
                DeterministicLiveVAD(segmentationRunID: segmentationRunID)
            }
        )
    }

    private static func validate(settings: EngineSettings) throws {
        guard !settings.decisionsEnabled else {
            throw EngineAdapterError(
                code: .invalidSettings,
                message: "Deterministic inference does not support decisionsEnabled=true",
                recoveryAction: .replaceSettings,
                details: []
            )
        }
    }
}

private enum DeterministicInferenceError: Error, LocalizedError, Sendable {
    case emptyASRInput
    case importedAudioUnsupported

    var errorDescription: String? {
        switch self {
        case .emptyASRInput:
            "Deterministic ASR requires nonempty audio input"
        case .importedAudioUnsupported:
            "Deterministic inference supports recording acceptance tests only; imported audio is unsupported"
        }
    }
}

private struct DeterministicASR: ASREngine {
    let provenance = RunProvenance(
        engine: "engine-e2e-asr", model: nil, version: "1", configuration: [:]
    )

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        guard !input.samples.isEmpty else { throw DeterministicInferenceError.emptyASRInput }
        return ASRResult(text: "エンジンの受け入れテストです。", detectedLanguage: nil)
    }

    func unload() async {}
}

private struct DeterministicSessionVAD: SessionVADSegmenter {
    let provenance = RunProvenance(
        engine: "engine-e2e-vad", model: nil, version: "1", configuration: [:]
    )

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        deterministicSegments(runID: runID, frameCount: reader.info.committedFrames)
    }
}

/// The one segment both VADs report for a recording: all of its audio is speech. A live VAD that
/// reported none would make a stop that keeps the live worker finalize an empty transcript.
private func deterministicSegments(runID: String, frameCount: Int64) -> [SegmentReference] {
    guard frameCount > 0 else { return [] }
    return [SegmentReference(
        segmentationRunID: runID,
        segmentID: "engine_e2e_segment",
        speechRanges: [0..<frameCount]
    )]
}

private struct DeterministicLiveVAD: LiveVADProcessing {
    let segmentationRunID: String

    func processAvailable(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        LiveVADProgress(
            emittedSegments: [], totalSegmentCount: 0,
            committedFrames: checkpoint.committedFrames, micSpeechLevels: []
        )
    }

    /// Reports the segment at the end of the input, once all of it is saved.
    func finish(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        let segments = deterministicSegments(runID: segmentationRunID, frameCount: checkpoint.committedFrames)
        return LiveVADProgress(
            emittedSegments: segments, totalSegmentCount: segments.count,
            committedFrames: checkpoint.committedFrames, micSpeechLevels: []
        )
    }
}

private struct UnsupportedImportedAudioTimelineBuilder: ImportedAudioTimelineBuilding {
    func build(from sourceURL: URL, into processingDirectory: URL, sessionURL: URL) async throws -> AudioCheckpoint {
        throw DeterministicInferenceError.importedAudioUnsupported
    }
}
