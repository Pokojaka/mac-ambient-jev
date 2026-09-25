import Foundation

public enum DurableAudioWriterError: Error, Equatable {
    case invalidChannelSampleCount
    case incompatibleCheckpoint
    case corruptChunk(String)
    case checkpointFrameCountMismatch
}

public struct AudioCheckpoint: Codable, Sendable, Equatable {
    public let committedFrames: Int64
    public let sampleRate: Double
    public let channelCount: Int
    public let chunkFiles: [String]
    public let chunkFrameCounts: [Int]?

    public init(
        committedFrames: Int64,
        sampleRate: Double,
        channelCount: Int,
        chunkFiles: [String],
        chunkFrameCounts: [Int]? = nil
    ) {
        self.committedFrames = committedFrames
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.chunkFiles = chunkFiles
        self.chunkFrameCounts = chunkFrameCounts
    }
}

public actor DurableAudioWriter {
    public static let checkpointFilename = "checkpoint.json"

    public let directory: URL
    public let sampleRate: Double
    public let channelCount: Int
    public let chunkDurationSeconds: Double

    private let framesPerChunk: Int
    private var pendingSamples: [Float] = []
    private var committedFrames: Int64
    private var chunkFiles: [String]
    private var chunkFrameCounts: [Int]
    private var nextChunkIndex: Int

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
        self.framesPerChunk = max(
            1,
            Int((sampleRate * chunkDurationSeconds).rounded(.down))
        )

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let bytesPerFrame = MemoryLayout<Float>.size * channelCount
        let checkpointURL = directory.appending(
            path: Self.checkpointFilename
        )

        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            let data = try Data(contentsOf: checkpointURL)
            let checkpoint = try JSONDecoder().decode(
                AudioCheckpoint.self,
                from: data
            )

            guard checkpoint.sampleRate == sampleRate,
                  checkpoint.channelCount == channelCount else {
                throw DurableAudioWriterError.incompatibleCheckpoint
            }

            self.committedFrames = checkpoint.committedFrames
            self.chunkFiles = checkpoint.chunkFiles
            self.nextChunkIndex = checkpoint.chunkFiles.count

            if let persistedCounts = checkpoint.chunkFrameCounts,
               persistedCounts.count == checkpoint.chunkFiles.count,
               persistedCounts.allSatisfy({ $0 > 0 }) {
                let countedFrames = persistedCounts.reduce(Int64.zero) {
                    $0 + Int64($1)
                }
                guard countedFrames == checkpoint.committedFrames else {
                    throw DurableAudioWriterError.checkpointFrameCountMismatch
                }
                self.chunkFrameCounts = persistedCounts
            } else {
                var recoveredCounts: [Int] = []
                var countedFrames: Int64 = 0

                for filename in checkpoint.chunkFiles {
                    let url = directory.appending(path: filename)
                    let values = try url.resourceValues(
                        forKeys: [.fileSizeKey]
                    )
                    guard let fileSize = values.fileSize,
                          fileSize > 0,
                          fileSize % bytesPerFrame == 0 else {
                        throw DurableAudioWriterError.corruptChunk(
                            filename
                        )
                    }

                    let frames = fileSize / bytesPerFrame
                    recoveredCounts.append(frames)
                    countedFrames += Int64(frames)
                }

                guard countedFrames == checkpoint.committedFrames else {
                    throw DurableAudioWriterError.checkpointFrameCountMismatch
                }
                self.chunkFrameCounts = recoveredCounts
            }
        } else {
            self.committedFrames = 0
            self.chunkFiles = []
            self.chunkFrameCounts = []
            self.nextChunkIndex = 0
        }

        while true {
            let filename = String(
                format: "chunk-%06d.f32le",
                nextChunkIndex
            )
            let url = directory.appending(path: filename)
            guard FileManager.default.fileExists(
                atPath: url.path
            ) else {
                break
            }

            let values = try url.resourceValues(
                forKeys: [.fileSizeKey]
            )
            guard let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize % bytesPerFrame == 0 else {
                throw DurableAudioWriterError.corruptChunk(filename)
            }

            let frames = fileSize / bytesPerFrame
            committedFrames += Int64(frames)
            chunkFiles.append(filename)
            chunkFrameCounts.append(frames)
            nextChunkIndex += 1
        }

        // Persist on every initialization so legacy checkpoints without
        // chunkFrameCounts are migrated before further processing begins.
        let initialCheckpoint = AudioCheckpoint(
            committedFrames: committedFrames,
            sampleRate: sampleRate,
            channelCount: channelCount,
            chunkFiles: chunkFiles,
            chunkFrameCounts: chunkFrameCounts
        )
        let initialData = try JSONEncoder().encode(initialCheckpoint)
        try initialData.write(to: checkpointURL, options: .atomic)
    }

    public func append(samples: [Float]) throws {
        guard samples.count % channelCount == 0 else {
            throw DurableAudioWriterError.invalidChannelSampleCount
        }

        pendingSamples.append(contentsOf: samples)
        try flushFullChunks()
    }

    /// Returns only frames that have already been atomically committed as chunk files.
    ///
    /// Unlike checkpoint(), this does not flush the in-memory partial chunk. It is
    /// therefore safe to poll while capture continues without fragmenting the timeline.
    public func committedSnapshot() -> AudioCheckpoint {
        currentCheckpoint()
    }

    public func checkpoint() throws -> AudioCheckpoint {
        try flushPendingChunk()
        let checkpoint = currentCheckpoint()
        try persist(checkpoint)
        return checkpoint
    }

    public func finish() throws -> AudioCheckpoint {
        try checkpoint()
    }

    private func flushFullChunks() throws {
        let samplesPerChunk = framesPerChunk * channelCount

        while pendingSamples.count >= samplesPerChunk {
            let samples = Array(
                pendingSamples.prefix(samplesPerChunk)
            )
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
        let filename = String(
            format: "chunk-%06d.f32le",
            nextChunkIndex
        )
        let url = directory.appending(path: filename)
        let data = samples.withUnsafeBytes { Data($0) }
        try data.write(to: url, options: .atomic)

        let frames = samples.count / channelCount
        committedFrames += Int64(frames)
        chunkFiles.append(filename)
        chunkFrameCounts.append(frames)
        nextChunkIndex += 1

        try persist(currentCheckpoint())
    }

    private func currentCheckpoint() -> AudioCheckpoint {
        AudioCheckpoint(
            committedFrames: committedFrames,
            sampleRate: sampleRate,
            channelCount: channelCount,
            chunkFiles: chunkFiles,
            chunkFrameCounts: chunkFrameCounts
        )
    }

    private func persist(_ checkpoint: AudioCheckpoint) throws {
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(
            to: directory.appending(
                path: Self.checkpointFilename
            ),
            options: .atomic
        )
    }
}
