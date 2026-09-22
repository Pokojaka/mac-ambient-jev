import Foundation

public enum ProcessingTimelineReaderError: Error, Equatable {
    case invalidFrameRange
    case corruptChunk(String)
}

public struct ProcessingTimelineReader: Sendable {
    public let directory: URL
    public let checkpoint: AudioCheckpoint

    public init(directory: URL, checkpoint: AudioCheckpoint) {
        self.directory = directory
        self.checkpoint = checkpoint
    }

    public func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        guard frameRange.lowerBound >= 0,
              frameRange.lowerBound <= frameRange.upperBound,
              frameRange.upperBound <= checkpoint.committedFrames else {
            throw ProcessingTimelineReaderError.invalidFrameRange
        }

        guard !frameRange.isEmpty else { return [] }

        let bytesPerFrame = MemoryLayout<Float>.size * checkpoint.channelCount
        var chunkStartFrame: Int64 = 0
        var output: [Float] = []
        output.reserveCapacity(Int(frameRange.count) * checkpoint.channelCount)

        for filename in checkpoint.chunkFiles {
            let url = directory.appending(path: filename)
            let data = try Data(contentsOf: url)

            guard data.count % bytesPerFrame == 0 else {
                throw ProcessingTimelineReaderError.corruptChunk(filename)
            }

            let chunkFrameCount = Int64(data.count / bytesPerFrame)
            let chunkEndFrame = chunkStartFrame + chunkFrameCount
            let start = max(frameRange.lowerBound, chunkStartFrame)
            let end = min(frameRange.upperBound, chunkEndFrame)

            if start < end {
                let localStartFrame = Int(start - chunkStartFrame)
                let localFrameCount = Int(end - start)
                let sampleStart = localStartFrame * checkpoint.channelCount
                let sampleCount = localFrameCount * checkpoint.channelCount

                var samples = Array(
                    repeating: Float.zero,
                    count: data.count / MemoryLayout<Float>.size
                )
                _ = samples.withUnsafeMutableBytes { destination in
                    data.copyBytes(to: destination)
                }
                output.append(contentsOf: samples[sampleStart..<(sampleStart + sampleCount)])
            }

            if chunkEndFrame >= frameRange.upperBound {
                break
            }
            chunkStartFrame = chunkEndFrame
        }

        return output
    }
}
