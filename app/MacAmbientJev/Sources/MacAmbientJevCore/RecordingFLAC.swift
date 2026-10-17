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

    /// Writes exact committed frames without padding. The caller validates the source reader.
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

        while frameStart < totalFrames {
            let count = Int(min(Int64(blockFrames), totalFrames - frameStart))
            let frameEnd = frameStart + Int64(count)
            let range = frameStart..<frameEnd
            let sourceSamples = try reader.readSamples(frameRange: range)
            guard sourceSamples.count == count else {
                throw RecordingFLACError.sourceLengthMismatch(expected: count, actual: sourceSamples.count)
            }

            var samples: [Int16] = []
            samples.reserveCapacity(count)
            for (index, sample) in sourceSamples.enumerated() {
                guard let quantized = quantize16(sample) else {
                    throw RecordingFLACError.nonFiniteSample(frame: frameStart + Int64(index))
                }
                samples.append(quantized)
            }
            md5.update(samples: samples)

            let frame = encodeFrame(samples: samples, frameNumber: frameNumber)
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
        case fixed(order: Int, partitionOrder: Int, parameters: [Int], residuals: [Int64])
    }

    private struct SubframeCandidate {
        let encoding: Subframe
        let bitCount: UInt64
    }

    private static func encodeFrame(samples: [Int16], frameNumber: UInt64) -> [UInt8] {
        let subframe = encodeSubframe(samples)
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

    private static func encodeSubframe(_ samples: [Int16]) -> [UInt8] {
        let candidate = bestSubframe(for: samples)
        var writer = FLACBitWriter()
        switch candidate.encoding {
        case .constant(let sample):
            writer.write(0, bits: 8)
            writer.writeSigned(Int64(sample), bits: 16)
        case .verbatim:
            writer.write(0x02, bits: 8)
            for sample in samples { writer.writeSigned(Int64(sample), bits: 16) }
        case .fixed(let order, let partitionOrder, let parameters, let residuals):
            writer.write(UInt64(0x10 + order * 2), bits: 8)
            for index in 0..<order { writer.writeSigned(Int64(samples[index]), bits: 16) }
            writer.write(0, bits: 2)
            writer.write(UInt64(partitionOrder), bits: 4)
            let samplesPerPartition = samples.count / (1 << partitionOrder)
            for partition in 0..<(1 << partitionOrder) {
                let start = partition * samplesPerPartition - (partition == 0 ? 0 : order)
                let end = (partition + 1) * samplesPerPartition - order
                let parameter = parameters[partition]
                writer.write(UInt64(parameter), bits: 4)
                for residual in residuals[start..<end] {
                    let folded = fold(residual)
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

    private static func bestSubframe(for samples: [Int16]) -> SubframeCandidate {
        var best: SubframeCandidate
        if samples.allSatisfy({ $0 == samples[0] }) {
            best = SubframeCandidate(encoding: .constant(samples[0]), bitCount: 24)
        } else {
            best = SubframeCandidate(encoding: .verbatim, bitCount: UInt64(8 + samples.count * 16))
        }
        let verbatim = SubframeCandidate(encoding: .verbatim, bitCount: UInt64(8 + samples.count * 16))
        if verbatim.bitCount < best.bitCount { best = verbatim }

        for order in 0...min(4, samples.count - 1) {
            let residuals = fixedResiduals(samples, order: order)
            let folded = residuals.map(fold)
            var prefixes = [[UInt64]](repeating: [], count: 15)
            for parameter in 0...14 {
                var prefix = [UInt64](repeating: 0, count: folded.count + 1)
                for index in folded.indices {
                    prefix[index + 1] = prefix[index] + (folded[index] >> parameter)
                }
                prefixes[parameter] = prefix
            }

            for partitionOrder in 0...8 {
                let partitionCount = 1 << partitionOrder
                guard samples.count % partitionCount == 0 else { continue }
                let samplesPerPartition = samples.count / partitionCount
                guard samplesPerPartition > order else { continue }
                var parameters: [Int] = []
                parameters.reserveCapacity(partitionCount)
                var residualBitCount: UInt64 = 6
                for partition in 0..<partitionCount {
                    let start = partition * samplesPerPartition - (partition == 0 ? 0 : order)
                    let end = (partition + 1) * samplesPerPartition - order
                    let residualCount = end - start
                    var bestParameter = 0
                    var bestParameterBits = UInt64.max
                    for parameter in 0...14 {
                        let quotientSum = prefixes[parameter][end] - prefixes[parameter][start]
                        let bits = UInt64(4 + residualCount * (parameter + 1)) + quotientSum
                        if bits < bestParameterBits {
                            bestParameter = parameter
                            bestParameterBits = bits
                        }
                    }
                    parameters.append(bestParameter)
                    residualBitCount += bestParameterBits
                }

                let candidateBits = UInt64(8 + order * 16) + residualBitCount
                let candidate = SubframeCandidate(
                    encoding: .fixed(
                        order: order,
                        partitionOrder: partitionOrder,
                        parameters: parameters,
                        residuals: residuals
                    ),
                    bitCount: candidateBits
                )
                if candidate.bitCount < best.bitCount {
                    best = candidate
                }
            }
        }
        return best
    }

    private static func fixedResiduals(_ samples: [Int16], order: Int) -> [Int64] {
        let coefficients: [[Int64]] = [
            [1],
            [1, -1],
            [1, -2, 1],
            [1, -3, 3, -1],
            [1, -4, 6, -4, 1],
        ]
        var residuals: [Int64] = []
        residuals.reserveCapacity(samples.count - order)
        for index in order..<samples.count {
            var residual: Int64 = 0
            for (coefficientIndex, coefficient) in coefficients[order].enumerated() {
                residual += coefficient * Int64(samples[index - coefficientIndex])
            }
            residuals.append(residual)
        }
        return residuals
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
