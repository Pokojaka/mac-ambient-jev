import Foundation

public enum ProcessingTimelineReaderError: Error, Equatable {
    case invalidFrameRange
    case corruptChunk(String)
    case invalidChunkIndex
    case invalidFormat
}

public struct ProcessingTimelineReader: Sendable {
    public let directory: URL
    public let checkpoint: AudioCheckpoint

    public init(directory: URL, checkpoint: AudioCheckpoint) {
        self.directory = directory
        self.checkpoint = checkpoint
    }

    public func readSamples(
        frameRange: Range<Int64>
    ) throws -> [Float] {
        guard frameRange.lowerBound >= 0,
              frameRange.lowerBound <= frameRange.upperBound,
              frameRange.upperBound <= checkpoint.committedFrames else {
            throw ProcessingTimelineReaderError.invalidFrameRange
        }

        guard !frameRange.isEmpty else { return [] }
        try validateIndex()

        let bytesPerFrame =
            MemoryLayout<Float>.size * checkpoint.channelCount

        return try readIndexed(
            frameRange: frameRange,
            bytesPerFrame: bytesPerFrame
        )
    }

    public func validateChunkFiles() throws {
        try validateIndex()
        let bytesPerFrame =
            MemoryLayout<Float>.size * checkpoint.channelCount
        var frames: Int64 = 0
        for (index, filename) in checkpoint.chunkFiles.enumerated() {
            let fileSize = try? directory.appending(path: filename)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let fileSize, fileSize > 0, fileSize % bytesPerFrame == 0,
                  checkpoint.chunkFrameCounts[index] * bytesPerFrame == fileSize else {
                throw ProcessingTimelineReaderError.corruptChunk(filename)
            }
            frames += Int64(fileSize / bytesPerFrame)
        }
        guard frames == checkpoint.committedFrames else {
            throw ProcessingTimelineReaderError.invalidChunkIndex
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
              frameCounts.reduce(Int64.zero, {
                  $0 + Int64($1)
              }) == checkpoint.committedFrames else {
            throw ProcessingTimelineReaderError.invalidChunkIndex
        }
    }

    private func readIndexed(
        frameRange: Range<Int64>,
        bytesPerFrame: Int
    ) throws -> [Float] {
        let frameCounts = checkpoint.chunkFrameCounts
        var chunkStartFrame: Int64 = 0
        var output: [Float] = []
        output.reserveCapacity(
            Int(frameRange.count) * checkpoint.channelCount
        )

        for index in checkpoint.chunkFiles.indices {
            let chunkFrameCount = Int64(frameCounts[index])
            let chunkEndFrame =
                chunkStartFrame + chunkFrameCount

            if chunkEndFrame <= frameRange.lowerBound {
                chunkStartFrame = chunkEndFrame
                continue
            }
            if chunkStartFrame >= frameRange.upperBound {
                break
            }

            let filename = checkpoint.chunkFiles[index]
            let url = directory.appending(path: filename)
            let data = try Data(contentsOf: url)
            guard data.count
                    == Int(chunkFrameCount) * bytesPerFrame else {
                throw ProcessingTimelineReaderError.corruptChunk(
                    filename
                )
            }

            appendOverlap(
                data: data,
                chunkStartFrame: chunkStartFrame,
                chunkEndFrame: chunkEndFrame,
                requestedRange: frameRange,
                output: &output
            )

            chunkStartFrame = chunkEndFrame
        }

        guard output.count
                == Int(frameRange.count)
                    * checkpoint.channelCount else {
            throw ProcessingTimelineReaderError.invalidChunkIndex
        }
        return output
    }

    private func appendOverlap(
        data: Data,
        chunkStartFrame: Int64,
        chunkEndFrame: Int64,
        requestedRange: Range<Int64>,
        output: inout [Float]
    ) {
        let start = max(
            requestedRange.lowerBound,
            chunkStartFrame
        )
        let end = min(
            requestedRange.upperBound,
            chunkEndFrame
        )
        guard start < end else { return }

        let localStartFrame = Int(start - chunkStartFrame)
        let localFrameCount = Int(end - start)
        let sampleStart =
            localStartFrame * checkpoint.channelCount
        let sampleCount =
            localFrameCount * checkpoint.channelCount

        var samples = Array(
            repeating: Float.zero,
            count: data.count / MemoryLayout<Float>.size
        )
        _ = samples.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }

        output.append(
            contentsOf: samples[
                sampleStart..<(sampleStart + sampleCount)
            ]
        )
    }
}
