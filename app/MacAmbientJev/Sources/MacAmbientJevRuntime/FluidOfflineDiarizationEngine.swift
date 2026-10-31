@preconcurrency import FluidAudio
import Foundation
import MacAmbientJevCore
import MacAmbientJevDiarization
import MacAmbientJevPipeline

public actor FluidOfflineDiarizationEngine: DiarizationEngine {
    static let version = "FluidAudio@0.15.8"
    static let configuration: OfflineDiarizerConfig = {
        var config = OfflineDiarizerConfig.default
        config.embedding.minSegmentDurationSeconds = 0.3
        return config
    }()

    public nonisolated var provenance: RunProvenance {
        RunProvenance(
            engine: "fluidaudio-offline-diarizer",
            model: Repo.diarizer.rawValue,
            version: Self.version,
            configuration: [
                "config": "OfflineDiarizerConfig.default",
                "embedding.min_segment_duration_seconds": String(Self.configuration.embedding.minSegmentDurationSeconds)
            ]
        )
    }

    private let models: MacModelStore
    private var manager: OfflineDiarizerManager?
    private let config = FluidOfflineDiarizationEngine.configuration

    public init(models: MacModelStore) {
        self.models = models
    }

    public func prepare() async throws {
        _ = try await preparedManager()
    }

    public func unload() async {
        manager = nil
    }

    private func preparedManager() async throws -> OfflineDiarizerManager {
        if let manager { return manager }

        try config.validate()
        guard Double(config.segmentation.sampleRate) == CanonicalAudio.sampleRate else {
            throw CanonicalAudioError.noncanonicalFormat
        }
        let directory = try await models.verifiedDirectory(.diarization)
        let loading = OfflineDiarizerManager(config: config)
        loading.initialize(models: try await FluidModelLoading.diarizerModels(from: directory))
        manager = loading
        return loading
    }

    public func diarize(
        fileURL: URL,
        canonicalSampleRate: Double,
        sessionURL: URL
    ) async throws -> [SpeakerSpan] {
        guard canonicalSampleRate == CanonicalAudio.sampleRate else { throw CanonicalAudioError.noncanonicalFormat }
        let started = Date()
        let source = try CanonicalCAFAudioSource(fileURL: fileURL, sessionURL: sessionURL)
        let loadingSeconds = Date().timeIntervalSince(started)
        let manager = try await preparedManager()
        let result = try await manager.process(audioSource: source, audioLoadingSeconds: loadingSeconds, progressCallback: nil)
        return try Self.mapSegments(
            result.segments,
            sampleCount: source.sampleCount,
            config: config
        )
    }

    static func mapSegments(
        _ segments: [TimedSpeakerSegment],
        sampleCount: Int,
        config: OfflineDiarizerConfig
    ) throws -> [SpeakerSpan] {
        let mapper = SpeakerSpanMapper(
            sampleRate: Double(config.segmentation.sampleRate)
        )
        let totalFrames = Int64(sampleCount)

        return try segments
            .map { segment in
                let span = mapper.map(
                    speakerID: segment.speakerId,
                    startSeconds: Double(segment.startTimeSeconds),
                    endSeconds: Double(segment.endTimeSeconds),
                    confidence: Double(segment.qualityScore)
                )
                guard span.startFrame >= 0,
                      span.startFrame < totalFrames,
                      span.endFrame > span.startFrame,
                      let endFrame = DiarizationFinalWindowPadding.clampedEndFrame(
                          span.endFrame,
                          sampleCount: totalFrames,
                          windowSamples: Int64(config.samplesPerWindow),
                          stepSamples: Int64(config.samplesPerStep)
                      ) else {
                    throw FinalTranscriptPipelineError.invalidSpeakerSpan(
                        speakerID: span.speakerID,
                        startFrame: span.startFrame,
                        endFrame: span.endFrame,
                        totalFrames: totalFrames
                    )
                }
                if endFrame == span.endFrame { return span }
                return SpeakerSpan(
                    speakerID: span.speakerID,
                    startFrame: span.startFrame,
                    endFrame: endFrame,
                    confidence: span.confidence
                )
            }
            .sorted {
                if $0.startFrame == $1.startFrame {
                    return $0.endFrame < $1.endFrame
                }
                return $0.startFrame < $1.startFrame
            }
    }
}