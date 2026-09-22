import Foundation

public enum ProcessingTimelineReaderError: Error, Equatable {
    case invalidFrameRange
    case corruptChunk(String)
    case invalidChunkIndex
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

        let bytesPerFrame =
            MemoryLayout<Float>.size * checkpoint.channelCount

        if let frameCounts = checkpoint.chunkFrameCounts {
            guard frameCounts.count == checkpoint.chunkFiles.count,
                  frameCounts.allSatisfy({ $0 > 0 }),
                  frameCounts.reduce(Int64.zero, {
                      $0 + Int64($1)
                  }) == checkpoint.committedFrames else {
                throw ProcessingTimelineReaderError.invalidChunkIndex
            }

            return try readIndexed(
                frameRange: frameRange,
                bytesPerFrame: bytesPerFrame,
                frameCounts: frameCounts
            )
        }

        return try readLegacy(
            frameRange: frameRange,
            bytesPerFrame: bytesPerFrame
        )
    }

    private func readIndexed(
        frameRange: Range<Int64>,
        bytesPerFrame: Int,
        frameCounts: [Int]
    ) throws -> [Float] {
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

    /// Backward-compatible path for checkpoints written before chunkFrameCounts
    /// existed. It stats preceding chunks but only loads audio bytes for chunks
    /// that overlap the requested range.
    private func readLegacy(
        frameRange: Range<Int64>,
        bytesPerFrame: Int
    ) throws -> [Float] {
        var chunkStartFrame: Int64 = 0
        var output: [Float] = []
        output.reserveCapacity(
            Int(frameRange.count) * checkpoint.channelCount
        )

        for filename in checkpoint.chunkFiles {
            let url = directory.appending(path: filename)
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey]
            )
            guard let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize % bytesPerFrame == 0 else {
                throw ProcessingTimelineReaderError.corruptChunk(
                    filename
                )
            }

            let chunkFrameCount = Int64(
                fileSize / bytesPerFrame
            )
            let chunkEndFrame =
                chunkStartFrame + chunkFrameCount

            if chunkEndFrame > frameRange.lowerBound,
               chunkStartFrame < frameRange.upperBound {
                let data = try Data(contentsOf: url)
                guard data.count == fileSize else {
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
            }

            if chunkEndFrame >= frameRange.upperBound {
                break
            }
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
