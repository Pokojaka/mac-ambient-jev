@preconcurrency import FluidAudio
import Foundation
import MacAmbientJevCore

actor FluidOfflineDiarizationEngine: DiarizationEngine {
    private let manager: OfflineDiarizerManager
    private let modelDirectory: URL
    private var prepared = false

    init(paths: AppPaths) {
        self.manager = OfflineDiarizerManager()
        self.modelDirectory = paths.modelsRoot.appending(
            path: "fluidaudio-offline-diarizer",
            directoryHint: .isDirectory
        )
    }

    func prepare() async throws {
        guard !prepared else { return }

        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        try await manager.prepareModels(directory: modelDirectory)
        prepared = true
    }

    func diarize(
        fileURL: URL,
        canonicalSampleRate: Double
    ) async throws -> [SpeakerSpan] {
        try await prepare()

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
