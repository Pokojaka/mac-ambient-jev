@preconcurrency import FluidAudio
import Foundation
import MacAmbientJevCore
import MacAmbientJevDiarization
import MacAmbientJevPipeline

actor FluidOfflineDiarizationEngine: DiarizationEngine {
    static let version = "FluidAudio@0.15.8"
    static let configuration: OfflineDiarizerConfig = {
        var config = OfflineDiarizerConfig.default
        config.embedding.minSegmentDurationSeconds = 0.3
        return config
    }()

    nonisolated var provenance: RunProvenance {
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

    private let modelDirectory: URL
    private var manager: OfflineDiarizerManager?
    private let config = FluidOfflineDiarizationEngine.configuration

    init(paths: AppPaths) {
        self.modelDirectory = paths.modelsRoot.appending(
            path: "fluidaudio-offline-diarizer",
            directoryHint: .isDirectory
        )
    }

    func prepare() async throws {
        _ = try await preparedManager()
    }

    func unload() async {
        manager = nil
    }

    private func preparedManager() async throws -> OfflineDiarizerManager {
        if let manager { return manager }

        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        try config.validate()
        guard Double(config.segmentation.sampleRate) == CanonicalAudio.sampleRate else {
            throw CanonicalAudioError.noncanonicalFormat
        }
        let loading = OfflineDiarizerManager(config: config)
        try await loading.prepareModels(directory: modelDirectory)
        manager = loading
        return loading
    }

    func diarize(
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