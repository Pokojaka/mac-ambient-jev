@preconcurrency import FluidAudio
import Foundation
import MacAmbientJevCore

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
        // FluidAudio schedules windows at every step strictly before EOF, including
        // overlapping tail windows even when the audio length is a window multiple.
        let finalWindowStart = sampleCount > 0
            ? ((sampleCount - 1) / config.samplesPerStep) * config.samplesPerStep
            : 0
        let paddingFrames = sampleCount > 0
            ? Int64(max(0, config.samplesPerWindow - (sampleCount - finalWindowStart)))
            : 0

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
                      span.endFrame <= totalFrames || span.endFrame - totalFrames <= paddingFrames else {
                    throw FinalTranscriptPipelineError.invalidSpeakerSpan(
                        speakerID: span.speakerID,
                        startFrame: span.startFrame,
                        endFrame: span.endFrame,
                        totalFrames: totalFrames
                    )
                }
                guard span.endFrame > totalFrames else { return span }
                return SpeakerSpan(
                    speakerID: span.speakerID,
                    startFrame: span.startFrame,
                    endFrame: totalFrames,
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