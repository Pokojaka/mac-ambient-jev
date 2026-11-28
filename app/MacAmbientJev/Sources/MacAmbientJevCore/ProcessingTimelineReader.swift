import Foundation

public enum ProcessingTimelineReaderError: LocalizedError, Equatable {
    case invalidFrameRange
    case corruptChunk(String)
    case unreadableChunk(String)
    case invalidChunkIndex
    case invalidFormat

    public var errorDescription: String? {
        switch self {
        case .invalidFrameRange:
            "要求された範囲が保存済み音声の長さを超えています"
        case .corruptChunk(let filename):
            "保存済み音声の断片 \(filename) が壊れています"
        case .unreadableChunk(let filename):
            "保存済み音声の断片 \(filename) を読み込めません"
        case .invalidChunkIndex:
            "保存済み音声の断片一覧が録音の長さと一致しません"
        case .invalidFormat:
            "保存済み音声の形式が正しくありません"
        }
    }
}

/// Reads the durable PCM chunks of a recording or an import timeline.
public struct ProcessingTimelineReader: TimelineAudioReading {
    public let directory: URL
    private let sessionURL: URL
    public let checkpoint: AudioCheckpoint
    public let info: TimelineAudioInfo
    private let chunkStarts: [Int64]

    public init(directory: URL, checkpoint: AudioCheckpoint, sessionURL: URL) throws {
        self.directory = directory
        self.sessionURL = sessionURL
        self.checkpoint = checkpoint
        self.info = try checkpoint.info
        try Self.validateIndex(checkpoint)
        var starts: [Int64] = [0]
        starts.reserveCapacity(checkpoint.chunkFrameCounts.count + 1)
        for count in checkpoint.chunkFrameCounts {
            starts.append(starts[starts.count - 1] + Int64(count))
        }
        self.chunkStarts = starts
    }

    private var bytesPerFrame: Int {
        MemoryLayout<Float>.size * checkpoint.channelCount
    }

    public func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        guard frameRange.lowerBound >= 0,
              frameRange.lowerBound <= frameRange.upperBound,
              frameRange.upperBound <= checkpoint.committedFrames else {
            throw ProcessingTimelineReaderError.invalidFrameRange
        }
        guard !frameRange.isEmpty else { return [] }
        var low = 0
        var high = checkpoint.chunkFiles.count
        while low < high {
            let middle = low + (high - low) / 2
            if chunkStarts[middle + 1] <= frameRange.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }

        let channels = checkpoint.channelCount
        var output = [Float](repeating: 0, count: Int(frameRange.count) * channels)
        var written = 0
        for index in low..<checkpoint.chunkFiles.count {
            let chunkStartFrame = chunkStarts[index]
            if chunkStartFrame >= frameRange.upperBound { break }
            let filename = checkpoint.chunkFiles[index]
            let start = max(frameRange.lowerBound, chunkStartFrame)
            let end = min(frameRange.upperBound, chunkStarts[index + 1])
            let byteCount = Int(end - start) * bytesPerFrame
            try output.withUnsafeMutableBytes { destination in
                try readChunk(
                    filename, frameCount: checkpoint.chunkFrameCounts[index],
                    byteOffset: Int(start - chunkStartFrame) * bytesPerFrame,
                    into: UnsafeMutableRawBufferPointer(
                        rebasing: destination[(written * MemoryLayout<Float>.size)...]
                            .prefix(byteCount)
                    )
                )
            }
            written += Int(end - start) * channels
        }
        guard written == output.count else {
            throw ProcessingTimelineReaderError.invalidChunkIndex
        }
        return output
    }

    public func validateAudio() throws {
        for (index, filename) in checkpoint.chunkFiles.enumerated() {
            let size = try chunkFileSize(filename)
            guard size == checkpoint.chunkFrameCounts[index] * bytesPerFrame else {
                throw ProcessingTimelineReaderError.corruptChunk(filename)
            }
        }
    }

    private static func validateIndex(_ checkpoint: AudioCheckpoint) throws {
        guard checkpoint.sampleFormat == CanonicalAudio.sampleFormat,
              checkpoint.channelCount == CanonicalAudio.channelCount,
              checkpoint.sampleRate == CanonicalAudio.sampleRate else {
            throw ProcessingTimelineReaderError.invalidFormat
        }
        let frameCounts = checkpoint.chunkFrameCounts
        guard checkpoint.hasPlainUniqueChunkFiles,
              frameCounts.count == checkpoint.chunkFiles.count,
              frameCounts.allSatisfy({ (1...Int(Int32.max)).contains($0) }),
              frameCounts.reduce(Int64.zero, { $0 + Int64($1) }) == checkpoint.committedFrames else {
            throw ProcessingTimelineReaderError.invalidChunkIndex
        }
    }

    private func chunkFileSize(_ filename: String) throws -> Int {
        do {
            return try SessionFileAccess.fileSize(directory.appending(path: filename), relativeTo: sessionURL)
        } catch let error as CocoaError where (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOENT) {
            throw ProcessingTimelineReaderError.unreadableChunk(filename)
        }
    }

    /// Reads only the requested byte span after checking that the whole chunk has its indexed size.
    private func readChunk(
        _ filename: String, frameCount: Int, byteOffset: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) throws {
        let handle: FileHandle
        do {
            handle = try SessionFileAccess.openHandle(directory.appending(path: filename), relativeTo: sessionURL)
        } catch let error as CocoaError {
            if (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOENT) {
                throw ProcessingTimelineReaderError.unreadableChunk(filename)
            }
            throw error
        } catch {
            throw ProcessingTimelineReaderError.unreadableChunk(filename)
        }
        defer { try? handle.close() }
        let data: Data?
        do {
            guard try handle.seekToEnd() == UInt64(frameCount * bytesPerFrame) else {
                throw ProcessingTimelineReaderError.corruptChunk(filename)
            }
            try handle.seek(toOffset: UInt64(byteOffset))
            data = try handle.read(upToCount: destination.count)
            try handle.close()
        } catch let error as ProcessingTimelineReaderError {
            throw error
        } catch {
            throw ProcessingTimelineReaderError.unreadableChunk(filename)
        }
        guard let data, data.count == destination.count else {
            throw ProcessingTimelineReaderError.corruptChunk(filename)
        }
        data.copyBytes(to: destination)
    }
}
