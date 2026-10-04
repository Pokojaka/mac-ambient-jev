@preconcurrency import FluidAudio
import Foundation
import MacAmbientJevCore

actor FluidOfflineDiarizationEngine: DiarizationEngine {
    static let version = "FluidAudio@0.15.8"

    nonisolated var provenance: RunProvenance {
        RunProvenance(
            engine: "fluidaudio-offline-diarizer",
            model: Repo.diarizer.rawValue,
            version: Self.version,
            configuration: ["config": "OfflineDiarizerConfig.default"]
        )
    }

    private let modelDirectory: URL
    private var manager: OfflineDiarizerManager?

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
        let loading = OfflineDiarizerManager()
        try await loading.prepareModels(directory: modelDirectory)
        manager = loading
        return loading
    }

    func diarize(
        fileURL: URL,
        canonicalSampleRate: Double
    ) async throws -> [SpeakerSpan] {
        let manager = try await preparedManager()
        let result = try await manager.process(fileURL)
        let mapper = SpeakerSpanMapper(
            sampleRate: canonicalSampleRate
        )

        return result.segments
            .map { segment in
                mapper.map(
                    speakerID: segment.speakerId,
                    startSeconds: Double(segment.startTimeSeconds),
                    endSeconds: Double(segment.endTimeSeconds),
                    confidence: Double(segment.qualityScore)
                )
            }
            .filter { $0.endFrame > $0.startFrame }
            .sorted {
                if $0.startFrame == $1.startFrame {
                    return $0.endFrame < $1.endFrame
                }
                return $0.startFrame < $1.startFrame
            }
    }
}