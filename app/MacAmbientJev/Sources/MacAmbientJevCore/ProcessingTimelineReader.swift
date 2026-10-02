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

public struct ProcessingTimelineReader: Sendable {
    public let directory: URL
    public let checkpoint: AudioCheckpoint

    public init(directory: URL, checkpoint: AudioCheckpoint) {
        self.directory = directory
        self.checkpoint = checkpoint
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
        try validateIndex()

        let channels = checkpoint.channelCount
        var output = [Float](repeating: 0, count: Int(frameRange.count) * channels)
        var written = 0
        var chunkStartFrame: Int64 = 0
        for (index, filename) in checkpoint.chunkFiles.enumerated() {
            let chunkEndFrame = chunkStartFrame + Int64(checkpoint.chunkFrameCounts[index])
            defer { chunkStartFrame = chunkEndFrame }
            let start = max(frameRange.lowerBound, chunkStartFrame)
            let end = min(frameRange.upperBound, chunkEndFrame)
            guard start < end else {
                if chunkStartFrame >= frameRange.upperBound { break }
                continue
            }
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

    public func validateChunkFiles() throws {
        try validateIndex()
        for (index, filename) in checkpoint.chunkFiles.enumerated() {
            let size = try chunkFileSize(filename)
            guard size == checkpoint.chunkFrameCounts[index] * bytesPerFrame else {
                throw ProcessingTimelineReaderError.corruptChunk(filename)
            }
        }
    }

    private func validateIndex() throws {
        guard checkpoint.sampleFormat == .float32LE,
              (1...Int(Int16.max)).contains(checkpoint.channelCount),
              checkpoint.sampleRate.isFinite,
              checkpoint.sampleRate > 0 else {
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
        let values: URLResourceValues
        do {
            values = try directory.appending(path: filename).resourceValues(forKeys: [.fileSizeKey])
        } catch {
            throw ProcessingTimelineReaderError.unreadableChunk(filename)
        }
        guard let size = values.fileSize else {
            throw ProcessingTimelineReaderError.unreadableChunk(filename)
        }
        return size
    }

    /// Reads only the requested byte span after checking that the whole chunk has its indexed size.
    private func readChunk(
        _ filename: String, frameCount: Int, byteOffset: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: directory.appending(path: filename))
        } catch {
            throw ProcessingTimelineReaderError.unreadableChunk(filename)
        }
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
