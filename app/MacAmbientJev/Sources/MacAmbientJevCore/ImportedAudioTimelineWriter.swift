import Foundation

public actor ImportedAudioTimelineWriter {
    private let converter: any CanonicalAudioConverting
    private let writer: DurableAudioWriter
    private var finishedCheckpoint: AudioCheckpoint?
    private var terminalError: (any Error)?

    public init(
        directory: URL,
        sessionURL: URL,
        converter: any CanonicalAudioConverting
    ) throws {
        self.converter = converter
        try SessionFileAccess.removeIfPresent(directory, relativeTo: sessionURL)
        self.writer = try DurableAudioWriter(
            directory: directory,
            chunkDurationSeconds: 5,
            sessionURL: sessionURL
        )
    }

    public func append(mono: [Float]) async throws {
        if let terminalError { throw terminalError }
        guard finishedCheckpoint == nil else { throw CanonicalAudioError.alreadyFinished }

        do {
            try await writer.append(samples: converter.convert(mono: mono))
        } catch {
            terminalError = error
            throw error
        }
    }

    public func finish() async throws -> AudioCheckpoint {
        if let finishedCheckpoint { return finishedCheckpoint }
        if let terminalError { throw terminalError }

        do {
            try await writer.append(samples: converter.finish())
            let checkpoint = try await writer.finish()
            finishedCheckpoint = checkpoint
            return checkpoint
        } catch {
            terminalError = error
            throw error
        }
    }
}

public enum ImportedAudioPCM {
    public static func downmix(
        frameCount: Int,
        channelCount: Int,
        sample: (Int, Int) -> Float
    ) throws -> [Float] {
        guard frameCount >= 0, channelCount > 0 else {
            throw CanonicalAudioError.invalidSourceFormat
        }

        var mono: [Float] = []
        mono.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                let value = sample(frame, channel)
                guard value.isFinite else { throw CanonicalAudioError.invalidSamples }
                sum += value
                guard sum.isFinite else { throw CanonicalAudioError.invalidSamples }
            }
            let average = sum / Float(channelCount)
            guard average.isFinite else { throw CanonicalAudioError.invalidSamples }
            mono.append(average)
        }
        return mono
    }
}
