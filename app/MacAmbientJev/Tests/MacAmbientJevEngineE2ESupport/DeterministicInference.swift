import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

/// Deterministic inference for recording acceptance tests. Capture and durable processing stay real;
/// only model inference and live VAD output are deterministic.
public struct DeterministicInferenceProvider: EngineInferenceProviding {
    public init() {}

    public func prepare(
        settings: EngineSettings,
        onProgress: @escaping @Sendable (EngineModelProgress) -> Void
    ) async throws {
        onProgress(EngineModelProgress(stage: .validating, completed: 0, total: 1))
        try Self.validate(settings: settings)
        onProgress(EngineModelProgress(stage: .loading, completed: 1, total: 1))
    }

    public func makeInference(settings: EngineSettings) throws -> EngineInference {
        try Self.validate(settings: settings)
        return EngineInference(
            engines: SessionProcessingEngines(
                asr: DeterministicASR(),
                diarization: DeterministicDiarization(),
                finalTranscriptVAD: DeterministicFinalTranscriptVAD()
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
    case unsupportedCanonicalSampleRate(Double)
    case importedAudioUnsupported

    var errorDescription: String? {
        switch self {
        case .emptyASRInput:
            "Deterministic ASR requires nonempty audio input"
        case .unsupportedCanonicalSampleRate(let rate):
            "Deterministic diarization requires canonical audio at 16000 Hz; received \(rate) Hz"
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

private struct DeterministicDiarization: DiarizationEngine {
    let provenance = RunProvenance(
        engine: "engine-e2e-diarization", model: nil, version: "1", configuration: [:]
    )

    func prepare() async throws {}

    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] {
        guard canonicalSampleRate == CanonicalAudio.sampleRate else {
            throw DeterministicInferenceError.unsupportedCanonicalSampleRate(canonicalSampleRate)
        }
        let reader = try CanonicalCAFReader(url: fileURL, sessionURL: sessionURL)
        guard reader.sampleCount > 0 else { return [] }
        return [SpeakerSpan(
            speakerID: "Speaker 1", startFrame: 0, endFrame: reader.sampleCount, confidence: 1
        )]
    }

    func unload() async {}
}

private struct DeterministicFinalTranscriptVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(
        engine: "engine-e2e-vad", model: nil, version: "1", configuration: [:]
    )

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        guard reader.info.committedFrames > 0 else { return [] }
        return [SegmentReference(
            segmentationRunID: runID,
            segmentID: "engine_e2e_final_segment",
            startFrame: 0,
            endFrame: reader.info.committedFrames
        )]
    }
}

private struct DeterministicLiveVAD: LiveVADProcessing {
    let segmentationRunID: String

    func processAvailable(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        emptyProgress(committedFrames: checkpoint.committedFrames)
    }

    func finish(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        emptyProgress(committedFrames: checkpoint.committedFrames)
    }

    private func emptyProgress(committedFrames: Int64) -> LiveVADProgress {
        LiveVADProgress(
            emittedSegments: [], totalSegmentCount: 0,
            committedFrames: committedFrames, micSpeechLevels: []
        )
    }
}

private struct UnsupportedImportedAudioTimelineBuilder: ImportedAudioTimelineBuilding {
    func build(from sourceURL: URL, into processingDirectory: URL, sessionURL: URL) async throws -> AudioCheckpoint {
        throw DeterministicInferenceError.importedAudioUnsupported
    }
}
