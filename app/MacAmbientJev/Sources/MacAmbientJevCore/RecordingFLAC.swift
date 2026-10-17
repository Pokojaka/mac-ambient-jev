import Foundation

public enum RecordingFLACError: LocalizedError, Equatable {
    case nonFiniteSample(frame: Int64)
    case emptyRecording
    case tooManyFrames
    case sourceLengthMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .nonFiniteSample(let frame):
            "フレーム \(frame) の音声サンプルが有限値ではないため 16-bit FLAC にできません"
        case .emptyRecording:
            "録音に音声フレームがないため FLAC にできません"
        case .tooManyFrames:
            "録音のフレーム数が FLAC の上限を超えています"
        case .sourceLengthMismatch(let expected, let actual):
            "音声ソースの長さが一致しません（期待値: \(expected)、実際: \(actual)）"
        }
    }
}

/// A native 16-kHz mono 16-bit FLAC encoder for finalized timeline audio.
public enum RecordingFLAC {
    private static let blockFrames = 4_096
    private static let maximumStreamFrames: Int64 = (1 << 36) - 1
    private static let streamInfoBodySize = 34

    /// Finite samples are clamped to [-1, 1], scaled by 32768, rounded half away from zero,
    /// and clamped to Int16. -1 maps to -32768 and +1 maps to 32767.
    public static func quantize16(_ sample: Float) -> Int16? {
        guard sample.isFinite else { return nil }
        let scaled = (min(1, max(-1, sample)) * 32768).rounded()
        return Int16(min(Float(Int16.max), scaled))
    }

    /// Writes exactly committedFrames samples. The caller validates the source reader.
    public static func write(reader: any TimelineAudioReading, to url: URL, sessionURL: URL) throws {
        let totalFrames = reader.info.committedFrames
        guard totalFrames > 0 else { throw RecordingFLACError.emptyRecording }
        guard totalFrames <= maximumStreamFrames else { throw RecordingFLACError.tooManyFrames }

        let handle = try SessionFileAccess.openHandle(
            url, relativeTo: sessionURL, writable: true, create: true, exclusive: true
        )
        var closed = false
        defer {
            if !closed { try? handle.close() }
        }

        var placeholder = Array("fLaC".utf8)
        placeholder.append(contentsOf: [0x80, 0x00, 0x00, UInt8(streamInfoBodySize)])
        placeholder.append(contentsOf: repeatElement(0, count: streamInfoBodySize))
        try handle.write(contentsOf: Data(placeholder))

        var md5 = FLACMD5()
        var minimumFrameSize = Int.max
        var maximumFrameSize = 0
        var frameStart: Int64 = 0
        var frameNumber: UInt64 = 0
        var workspace = EncodingWorkspace()
        var samples: [Int16] = []
        samples.reserveCapacity(blockFrames)

        while frameStart < totalFrames {
            let count = Int(min(Int64(blockFrames), totalFrames - frameStart))
            let frameEnd = frameStart + Int64(count)
            let range = frameStart..<frameEnd
            let sourceSamples = try reader.readSamples(frameRange: range)
            guard sourceSamples.count == count else {
                throw RecordingFLACError.sourceLengthMismatch(expected: count, actual: sourceSamples.count)
            }

            samples.removeAll(keepingCapacity: true)
            for (index, sample) in sourceSamples.enumerated() {
                guard let quantized = quantize16(sample) else {
                    throw RecordingFLACError.nonFiniteSample(frame: frameStart + Int64(index))
                }
                samples.append(quantized)
            }
            md5.update(samples: samples)

            let frame = encodeFrame(samples: samples, frameNumber: frameNumber, workspace: &workspace)
            try handle.write(contentsOf: Data(frame))
            minimumFrameSize = min(minimumFrameSize, frame.count)
            maximumFrameSize = max(maximumFrameSize, frame.count)
            frameStart = frameEnd
            frameNumber += 1
        }

        let digest = md5.finalize()
        let streamInfo = makeStreamInfo(
            totalFrames: UInt64(totalFrames),
            minimumFrameSize: minimumFrameSize,
            maximumFrameSize: maximumFrameSize,
            md5: digest
        )
        try handle.seek(toOffset: 8)
        try handle.write(contentsOf: Data(streamInfo))
        try handle.synchronize()
        try handle.close()
        closed = true
    }

    private enum Subframe {
        case constant(Int16)
        case verbatim
        case fixed(order: Int, partitionOrder: Int)
    }

    private struct EncodingWorkspace {
        var residuals = [Int64](repeating: 0, count: RecordingFLAC.blockFrames)
        var foldedResiduals = [UInt64](repeating: 0, count: RecordingFLAC.blockFrames)
        var absoluteResidualSums = [UInt64](repeating: 0, count: 256)
        var negativeResidualCounts = [UInt64](repeating: 0, count: 256)
        var quotientSums = [UInt64](repeating: 0, count: 14 * 256)
        var candidateParameters = [Int](repeating: 0, count: 256)
        var bestParameters = [Int](repeating: 0, count: 256)
    }

    private static let fixedCoefficients: [[Int64]] = [
        [1],
        [1, -1],
        [1, -2, 1],
        [1, -3, 3, -1],
        [1, -4, 6, -4, 1],
    ]

    private static func encodeFrame(
        samples: [Int16],
        frameNumber: UInt64,
        workspace: inout EncodingWorkspace
    ) -> [UInt8] {
        let subframe = encodeSubframe(samples, workspace: &workspace)
        var header: [UInt8] = [0xff, 0xf8]
        let blockSizeCode: UInt8
        if samples.count == blockFrames {
            blockSizeCode = 12
        } else if samples.count <= 256 {
            blockSizeCode = 6
        } else {
            blockSizeCode = 7
        }
        header.append((blockSizeCode << 4) | 5)
        header.append(0x08)
        header.append(contentsOf: utf8Integer(frameNumber))
        if blockSizeCode == 6 {
            header.append(UInt8(samples.count - 1))
        } else if blockSizeCode == 7 {
            let storedCount = UInt16(samples.count - 1)
            header.append(UInt8(truncatingIfNeeded: storedCount >> 8))
            header.append(UInt8(truncatingIfNeeded: storedCount))
        }
        header.append(FLACChecksum.crc8(header))

        var frame = header
        frame.append(contentsOf: subframe)
        let checksum = FLACChecksum.crc16(frame)
        frame.append(UInt8(truncatingIfNeeded: checksum >> 8))
        frame.append(UInt8(truncatingIfNeeded: checksum))
        return frame
    }

    private static func utf8Integer(_ value: UInt64) -> [UInt8] {
        precondition(value <= 0x7fff_ffff)
        if value <= 0x7f { return [UInt8(value)] }
        if value <= 0x7ff {
            return [UInt8(0xc0 | (value >> 6)), UInt8(0x80 | (value & 0x3f))]
        }
        if value <= 0xffff {
            return [
                UInt8(0xe0 | (value >> 12)),
                UInt8(0x80 | ((value >> 6) & 0x3f)),
                UInt8(0x80 | (value & 0x3f)),
            ]
        }
        if value <= 0x1f_ffff {
            return [
                UInt8(0xf0 | (value >> 18)),
                UInt8(0x80 | ((value >> 12) & 0x3f)),
                UInt8(0x80 | ((value >> 6) & 0x3f)),
                UInt8(0x80 | (value & 0x3f)),
            ]
        }
        if value <= 0x3ff_ffff {
            return [
                UInt8(0xf8 | (value >> 24)),
                UInt8(0x80 | ((value >> 18) & 0x3f)),
                UInt8(0x80 | ((value >> 12) & 0x3f)),
                UInt8(0x80 | ((value >> 6) & 0x3f)),
                UInt8(0x80 | (value & 0x3f)),
            ]
        }
        return [
            UInt8(0xfc | (value >> 30)),
            UInt8(0x80 | ((value >> 24) & 0x3f)),
            UInt8(0x80 | ((value >> 18) & 0x3f)),
            UInt8(0x80 | ((value >> 12) & 0x3f)),
            UInt8(0x80 | ((value >> 6) & 0x3f)),
            UInt8(0x80 | (value & 0x3f)),
        ]
    }

    private static func encodeSubframe(
        _ samples: [Int16],
        workspace: inout EncodingWorkspace
    ) -> [UInt8] {
        let subframe = bestSubframe(for: samples, workspace: &workspace)
        var writer = FLACBitWriter()
        switch subframe {
        case .constant(let sample):
            writer.write(0, bits: 8)
            writer.writeSigned(Int64(sample), bits: 16)
        case .verbatim:
            writer.write(0x02, bits: 8)
            for sample in samples { writer.writeSigned(Int64(sample), bits: 16) }
        case .fixed(let order, let partitionOrder):
            fixedResiduals(samples, order: order, workspace: &workspace)
            writer.write(UInt64(0x10 + order * 2), bits: 8)
            for index in 0..<order { writer.writeSigned(Int64(samples[index]), bits: 16) }
            writer.write(0, bits: 2)
            writer.write(UInt64(partitionOrder), bits: 4)
            let samplesPerPartition = samples.count / (1 << partitionOrder)
            for partition in 0..<(1 << partitionOrder) {
                let start = partition * samplesPerPartition - (partition == 0 ? 0 : order)
                let end = (partition + 1) * samplesPerPartition - order
                let parameter = workspace.bestParameters[partition]
                writer.write(UInt64(parameter), bits: 4)
                for residualIndex in start..<end {
                    let folded = fold(workspace.residuals[residualIndex])
                    writer.writeUnary(folded >> parameter)
                    if parameter > 0 {
                        writer.write(folded & ((UInt64(1) << parameter) - 1), bits: parameter)
                    }
                }
            }
        }
        writer.align()
        return writer.bytes
    }

    private static func bestSubframe(
        for samples: [Int16],
        workspace: inout EncodingWorkspace
    ) -> Subframe {
        var bestEncoding: Subframe
        var bestBitCount: UInt64
        if samples.allSatisfy({ $0 == samples[0] }) {
            bestEncoding = .constant(samples[0])
            bestBitCount = 24
        } else {
            bestEncoding = .verbatim
            bestBitCount = UInt64(8 + samples.count * 16)
        }
        var bestFixedOrder: Int?
        var bestPartitionOrder = 0

        for order in 0...min(4, samples.count - 1) {
            fixedResiduals(samples, order: order, workspace: &workspace)

            var finestPartitionOrder: Int?
            for partitionOrder in stride(from: 8, through: 0, by: -1) {
                let partitionCount = 1 << partitionOrder
                guard samples.count % partitionCount == 0 else { continue }
                guard samples.count / partitionCount >= order else { continue }
                finestPartitionOrder = partitionOrder
                break
            }
            guard let finestPartitionOrder else {
                preconditionFailure("FIXED 予測には有効な残差パーティションが必要です")
            }

            // Build exact statistics at the finest partition, then pair-merge them in place for each coarser level.
            // Absolute sums and negative counts recover k=0, but k=1...14 quotient sums must be accumulated exactly
            // because absolute sums alone cannot determine Rice costs.
            let finestPartitionCount = 1 << finestPartitionOrder
            let finestSamplesPerPartition = samples.count / finestPartitionCount
            for partition in 0..<finestPartitionCount {
                let start = partition * finestSamplesPerPartition - (partition == 0 ? 0 : order)
                let end = (partition + 1) * finestSamplesPerPartition - order
                var absoluteSum: UInt64 = 0
                var negativeCount: UInt64 = 0
                for residualIndex in start..<end {
                    let residual = workspace.residuals[residualIndex]
                    absoluteSum += UInt64(residual < 0 ? -residual : residual)
                    if residual < 0 { negativeCount += 1 }
                    workspace.foldedResiduals[residualIndex] = fold(residual)
                }
                workspace.absoluteResidualSums[partition] = absoluteSum
                workspace.negativeResidualCounts[partition] = negativeCount
                for parameter in 1...14 {
                    var quotientSum: UInt64 = 0
                    for residualIndex in start..<end {
                        quotientSum += workspace.foldedResiduals[residualIndex] >> parameter
                    }
                    workspace.quotientSums[(parameter - 1) * 256 + partition] = quotientSum
                }
            }

            for partitionOrder in stride(from: finestPartitionOrder, through: 0, by: -1) {
                let partitionCount = 1 << partitionOrder
                let samplesPerPartition = samples.count / partitionCount
                var residualBitCount: UInt64 = 6
                for partition in 0..<partitionCount {
                    let residualCount = samplesPerPartition - (partition == 0 ? order : 0)
                    var bestParameter = 0
                    var bestParameterBits = UInt64.max
                    for parameter in 0...14 {
                        let quotientSum: UInt64
                        if parameter == 0 {
                            quotientSum = 2 * workspace.absoluteResidualSums[partition]
                                - workspace.negativeResidualCounts[partition]
                        } else {
                            quotientSum = workspace.quotientSums[(parameter - 1) * 256 + partition]
                        }
                        let bits = UInt64(4 + residualCount * (parameter + 1)) + quotientSum
                        if bits < bestParameterBits {
                            bestParameter = parameter
                            bestParameterBits = bits
                        }
                    }
                    workspace.candidateParameters[partition] = bestParameter
                    residualBitCount += bestParameterBits
                }

                let candidateBitCount = UInt64(8 + order * 16) + residualBitCount
                let isCheaper = candidateBitCount < bestBitCount
                let isLowerPartitionTie = candidateBitCount == bestBitCount
                    && bestFixedOrder == order
                    && partitionOrder < bestPartitionOrder
                if isCheaper || isLowerPartitionTie {
                    bestEncoding = .fixed(order: order, partitionOrder: partitionOrder)
                    bestBitCount = candidateBitCount
                    bestFixedOrder = order
                    bestPartitionOrder = partitionOrder
                    for partition in 0..<partitionCount {
                        workspace.bestParameters[partition] = workspace.candidateParameters[partition]
                    }
                }

                if partitionOrder > 0 {
                    let mergedCount = partitionCount / 2
                    for partition in 0..<mergedCount {
                        let left = partition * 2
                        let right = left + 1
                        workspace.absoluteResidualSums[partition] =
                            workspace.absoluteResidualSums[left] + workspace.absoluteResidualSums[right]
                        workspace.negativeResidualCounts[partition] =
                            workspace.negativeResidualCounts[left] + workspace.negativeResidualCounts[right]
                        for parameter in 0..<14 {
                            let offset = parameter * 256
                            workspace.quotientSums[offset + partition] =
                                workspace.quotientSums[offset + left] + workspace.quotientSums[offset + right]
                        }
                    }
                }
            }
        }
        return bestEncoding
    }

    private static func fixedResiduals(
        _ samples: [Int16],
        order: Int,
        workspace: inout EncodingWorkspace
    ) {
        for index in order..<samples.count {
            var residual: Int64 = 0
            for (coefficientIndex, coefficient) in fixedCoefficients[order].enumerated() {
                residual += coefficient * Int64(samples[index - coefficientIndex])
            }
            workspace.residuals[index - order] = residual
        }
    }

    private static func fold(_ residual: Int64) -> UInt64 {
        residual < 0 ? UInt64(-residual) * 2 - 1 : UInt64(residual) * 2
    }

    private static func makeStreamInfo(
        totalFrames: UInt64,
        minimumFrameSize: Int,
        maximumFrameSize: Int,
        md5: [UInt8]
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(streamInfoBodySize)
        appendBigEndian(UInt64(blockFrames), byteCount: 2, to: &bytes)
        appendBigEndian(UInt64(blockFrames), byteCount: 2, to: &bytes)
        appendBigEndian(UInt64(minimumFrameSize), byteCount: 3, to: &bytes)
        appendBigEndian(UInt64(maximumFrameSize), byteCount: 3, to: &bytes)
        let formatAndTotal = (UInt64(16_000) << 44) | (UInt64(0) << 41) | (UInt64(15) << 36) | totalFrames
        appendBigEndian(formatAndTotal, byteCount: 8, to: &bytes)
        bytes.append(contentsOf: md5)
        return bytes
    }

    private static func appendBigEndian(_ value: UInt64, byteCount: Int, to bytes: inout [UInt8]) {
        for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
