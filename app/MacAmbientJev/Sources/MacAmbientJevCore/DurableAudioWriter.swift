import Foundation

public enum DurableAudioWriterError: Error, Equatable {
    case invalidChannelSampleCount
}

public struct AudioCheckpoint: Codable, Sendable, Equatable {
    public let committedFrames: Int64
    public let sampleRate: Double
    public let channelCount: Int
    public let chunkFiles: [String]
}

public actor DurableAudioWriter {
    public let directory: URL
    public let sampleRate: Double
    public let channelCount: Int
    public let chunkDurationSeconds: Double

    private let framesPerChunk: Int
    private var pendingSamples: [Float] = []
    private var committedFrames: Int64 = 0
    private var chunkFiles: [String] = []
    private var nextChunkIndex = 0

    public init(
        directory: URL,
        sampleRate: Double,
        channelCount: Int,
        chunkDurationSeconds: Double = 5
    ) throws {
        precondition(sampleRate > 0)
        precondition(channelCount > 0)
        precondition(chunkDurationSeconds > 0)
        self.directory = directory
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.chunkDurationSeconds = chunkDurationSeconds
        self.framesPerChunk = max(1, Int((sampleRate * chunkDurationSeconds).rounded(.down)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func append(samples: [Float]) throws {
        guard samples.count % channelCount == 0 else {
            throw DurableAudioWriterError.invalidChannelSampleCount
        }
        pendingSamples.append(contentsOf: samples)
        try flushFullChunks()
    }

    public func checkpoint() throws -> AudioCheckpoint {
        try flushPendingChunk()
        return AudioCheckpoint(
            committedFrames: committedFrames,
            sampleRate: sampleRate,
            channelCount: channelCount,
            chunkFiles: chunkFiles
        )
    }

    public func finish() throws -> AudioCheckpoint {
        try checkpoint()
    }

    private func flushFullChunks() throws {
        let samplesPerChunk = framesPerChunk * channelCount
        while pendingSamples.count >= samplesPerChunk {
            let samples = Array(pendingSamples.prefix(samplesPerChunk))
            try writeChunk(samples)
            pendingSamples.removeFirst(samplesPerChunk)
        }
    }

    private func flushPendingChunk() throws {
        guard !pendingSamples.isEmpty else { return }
        let samples = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        try writeChunk(samples)
    }

    private func writeChunk(_ samples: [Float]) throws {
        let filename = String(format: "chunk-%06d.f32le", nextChunkIndex)
        let url = directory.appending(path: filename)
        let data = samples.withUnsafeBytes { Data($0) }
        try data.write(to: url, options: .atomic)

        let frames = samples.count / channelCount
        committedFrames += Int64(frames)
        chunkFiles.append(filename)
        nextChunkIndex += 1
    }
}
