import Foundation
import Testing
@testable import MacAmbientJevCore

private struct FLACFrameFixture {
    let root: URL
    let fileURL: URL

    init(bytes: [UInt8]) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FLACFrameDecoderTests-\(UUID().uuidString)")
        fileURL = root.appending(path: "frame.flac")
        try SessionFileAccess.createDirectory(root, relativeTo: root)
        try SessionFileAccess.writeAtomically(Data(bytes), to: fileURL, relativeTo: root)
    }

    func decode(expectedFrameNumber: UInt64, firstSample: Int64, decodeSamples: Bool) throws -> FLACDecodedFrame {
        let handle = try SessionFileAccess.openHandle(fileURL, relativeTo: root)
        defer { try? handle.close() }
        return try FLACFrameDecoder.read(
            from: FLACBitReader(handle: handle),
            expectedFrameNumber: expectedFrameNumber,
            firstSample: firstSample,
            decodeSamples: decodeSamples
        )
    }

    func cleanup() {
        try? SessionFileAccess.removeIfPresent(fileURL, relativeTo: root)
        try? SessionFileAccess.removeIfPresent(root, relativeTo: root.deletingLastPathComponent())
    }
}

private struct FLACPartitionCoding {
    let parameter: Int
    let rawWidth: Int?
}

private enum FLACSubframeFixture {
    case constant(value: Int64, wastedBits: Int)
    case verbatim(samples: [Int64], wastedBits: Int)
    case fixed(order: Int, warmups: [Int64], residuals: [Int64], method: Int, partitionOrder: Int, codings: [FLACPartitionCoding], wastedBits: Int)
    case lpc(order: Int, warmups: [Int64], precision: Int, shift: Int, coefficients: [Int64], residuals: [Int64], method: Int, partitionOrder: Int, codings: [FLACPartitionCoding], wastedBits: Int)
    case reservedType(Int)

    func write(to writer: inout FLACBitWriter, blockSize: Int) {
        switch self {
        case .constant(let value, let wastedBits):
            writeSubframeHeader(type: 0, wastedBits: wastedBits, to: &writer)
            writer.writeSigned(value, bits: 16 - wastedBits)
        case .verbatim(let samples, let wastedBits):
            writeSubframeHeader(type: 1, wastedBits: wastedBits, to: &writer)
            for sample in samples {
                writer.writeSigned(sample, bits: 16 - wastedBits)
            }
        case .fixed(let order, let warmups, let residuals, let method, let partitionOrder, let codings, let wastedBits):
            writeSubframeHeader(type: 8 + order, wastedBits: wastedBits, to: &writer)
            for warmup in warmups {
                writer.writeSigned(warmup, bits: 16 - wastedBits)
            }
            writeResiduals(
                residuals,
                predictorOrder: order,
                blockSize: blockSize,
                method: method,
                partitionOrder: partitionOrder,
                codings: codings,
                to: &writer
            )
        case .lpc(let order, let warmups, let precision, let shift, let coefficients, let residuals, let method, let partitionOrder, let codings, let wastedBits):
            writeSubframeHeader(type: 31 + order, wastedBits: wastedBits, to: &writer)
            for warmup in warmups {
                writer.writeSigned(warmup, bits: 16 - wastedBits)
            }
            writer.write(UInt64(precision - 1), bits: 4)
            writer.writeSigned(Int64(shift), bits: 5)
            for coefficient in coefficients {
                writer.writeSigned(coefficient, bits: precision)
            }
            writeResiduals(
                residuals,
                predictorOrder: order,
                blockSize: blockSize,
                method: method,
                partitionOrder: partitionOrder,
                codings: codings,
                to: &writer
            )
        case .reservedType(let type):
            writeSubframeHeader(type: type, wastedBits: 0, to: &writer)
        }
    }

    private func writeSubframeHeader(type: Int, wastedBits: Int, to writer: inout FLACBitWriter) {
        writer.write(0, bits: 1)
        writer.write(UInt64(type), bits: 6)
        writer.write(wastedBits == 0 ? 0 : 1, bits: 1)
        if wastedBits > 0 {
            writer.writeUnary(UInt64(wastedBits - 1))
        }
    }
}

private func writeResiduals(
    _ residuals: [Int64],
    predictorOrder: Int,
    blockSize: Int,
    method: Int,
    partitionOrder: Int,
    codings: [FLACPartitionCoding],
    to writer: inout FLACBitWriter
) {
    writer.write(UInt64(method), bits: 2)
    writer.write(UInt64(partitionOrder), bits: 4)
    let partitionCount = 1 << partitionOrder
    let samplesPerPartition = blockSize / partitionCount
    var residualIndex = 0
    for partition in 0..<partitionCount {
        let residualCount = samplesPerPartition - (partition == 0 ? predictorOrder : 0)
        let coding = codings[partition]
        let parameterBits = method == 0 ? 4 : 5
        writer.write(UInt64(coding.parameter), bits: parameterBits)
        if coding.parameter == (1 << parameterBits) - 1 {
            let rawWidth = coding.rawWidth!
            writer.write(UInt64(rawWidth), bits: 5)
            for _ in 0..<residualCount {
                writer.writeSigned(residuals[residualIndex], bits: rawWidth)
                residualIndex += 1
            }
        } else {
            let parameter = coding.parameter
            for _ in 0..<residualCount {
                let residual = residuals[residualIndex]
                residualIndex += 1
                let folded = residual >= 0 ? UInt64(residual) * 2 : UInt64(-residual) * 2 - 1
                let quotient = folded >> parameter
                writer.writeUnary(quotient)
                writer.write(folded & ((UInt64(1) << parameter) - 1), bits: parameter)
            }
        }
    }
    precondition(residualIndex == residuals.count)
}

private func canonicalFrameNumber(_ value: UInt64) -> [UInt8] {
    let lengths: [(UInt64, Int, UInt8)] = [
        (0x7f, 1, 0x00),
        (0x7ff, 2, 0xc0),
        (0xffff, 3, 0xe0),
        (0x1fffff, 4, 0xf0),
        (0x3ffffff, 5, 0xf8),
        (0x7fffffff, 6, 0xfc),
    ]
    guard let (maximum, length, prefix) = lengths.first(where: { value <= $0.0 }) else {
        preconditionFailure("frame number outside the fixed-block 31-bit range")
    }
    if length == 1 { return [UInt8(value)] }
    let payloadBits = 6 * (length - 1)
    var result = [prefix | UInt8(value >> payloadBits)]
    for continuationIndex in stride(from: length - 2, through: 0, by: -1) {
        let shift = continuationIndex * 6
        result.append(0x80 | UInt8((value >> shift) & 0x3f))
    }
    _ = maximum
    return result
}

private func makeFLACFrame(
    blockSize: Int,
    frameNumber: UInt64,
    subframe: FLACSubframeFixture,
    syncLow: UInt8 = 0xf8,
    sampleRateCode: Int = 0,
    channelAssignment: Int = 0,
    sampleDepthCode: Int = 4,
    reservedHeaderBit: Int = 0,
    frameNumberBytes: [UInt8]? = nil,
    blockSizeCode: Int = 6
) -> [UInt8] {
    var writer = FLACBitWriter()
    writer.write(0xff, bits: 8)
    writer.write(UInt64(syncLow), bits: 8)
    writer.write(UInt64((blockSizeCode << 4) | sampleRateCode), bits: 8)
    writer.write(UInt64((channelAssignment << 4) | (sampleDepthCode << 1) | reservedHeaderBit), bits: 8)
    for byte in frameNumberBytes ?? canonicalFrameNumber(frameNumber) {
        writer.write(UInt64(byte), bits: 8)
    }
    if blockSizeCode == 6 {
        writer.write(UInt64(blockSize - 1), bits: 8)
    } else if blockSizeCode == 7 {
        writer.write(UInt64((blockSize - 1) >> 8), bits: 8)
        writer.write(UInt64((blockSize - 1) & 0xff), bits: 8)
    }
    let headerCRC = FLACChecksum.crc8(writer.bytes)
    writer.write(UInt64(headerCRC), bits: 8)
    subframe.write(to: &writer, blockSize: blockSize)
    writer.align()
    var bytes = writer.bytes
    let frameCRC = FLACChecksum.crc16(bytes)
    bytes.append(UInt8(frameCRC >> 8))
    bytes.append(UInt8(truncatingIfNeeded: frameCRC))
    return bytes
}

private func decode(
    _ bytes: [UInt8],
    expectedFrameNumber: UInt64,
    decodeSamples: Bool
) throws -> FLACDecodedFrame {
    let fixture = try FLACFrameFixture(bytes: bytes)
    defer { fixture.cleanup() }
    return try fixture.decode(expectedFrameNumber: expectedFrameNumber, firstSample: 0, decodeSamples: decodeSamples)
}

private func expectedFixed(warmups: [Int64], residuals: [Int64], order: Int) -> [Int16] {
    let coefficients: [[Int64]] = [[], [1], [2, -1], [3, -3, 1], [4, -6, 4, -1]]
    var samples = warmups
    for residual in residuals {
        let prediction = coefficients[order].enumerated().reduce(Int64(0)) { partial, item in
            partial + item.element * samples[samples.count - item.offset - 1]
        }
        samples.append(prediction + residual)
    }
    return samples.map(Int16.init)
}

private func expectedLPC(warmups: [Int64], residuals: [Int64], coefficients: [Int64], shift: Int) -> [Int16] {
    var samples = warmups
    for residual in residuals {
        let sum = coefficients.enumerated().reduce(Int64(0)) { partial, item in
            partial + item.element * samples[samples.count - item.offset - 1]
        }
        samples.append((sum >> shift) + residual)
    }
    return samples.map(Int16.init)
}

@Test func decodesAllFixedPredictorOrdersAndLPCWithSignedCoefficientsAndArithmeticShift() throws {
    for order in 0...4 {
        let warmups = order == 0 ? [] : Array(1...order).map(Int64.init)
        let residuals = Array(repeating: Int64(1), count: 16 - order)
        let frame = makeFLACFrame(
            blockSize: 16,
            frameNumber: 0,
            subframe: .fixed(
                order: order,
                warmups: warmups,
                residuals: residuals,
                method: 0,
                partitionOrder: 0,
                codings: [FLACPartitionCoding(parameter: 0, rawWidth: nil)],
                wastedBits: 0
            )
        )
        #expect(try decode(frame, expectedFrameNumber: 0, decodeSamples: true).samples == expectedFixed(warmups: warmups, residuals: residuals, order: order))
    }

    let warmups: [Int64] = [0, -3]
    let residuals = Array(repeating: Int64(0), count: 14)
    let coefficients: [Int64] = [3, -2]
    let frame = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: .lpc(
            order: 2,
            warmups: warmups,
            precision: 4,
            shift: 2,
            coefficients: coefficients,
            residuals: residuals,
            method: 0,
            partitionOrder: 0,
            codings: [FLACPartitionCoding(parameter: 0, rawWidth: nil)],
            wastedBits: 0
        )
    )
    let actual = try decode(frame, expectedFrameNumber: 0, decodeSamples: true).samples
    #expect(actual == expectedLPC(warmups: warmups, residuals: residuals, coefficients: coefficients, shift: 2))
    #expect(actual[2] == -3)
}

@Test func decodesConstantVerbatimAndWastedBitsAcrossSubframeTypes() throws {
    let constant = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: .constant(value: -123, wastedBits: 1)
    )
    #expect(try decode(constant, expectedFrameNumber: 0, decodeSamples: true).samples == Array(repeating: -246, count: 16))

    let verbatimSamples = (0..<16).map { Int64($0 - 8) }
    let verbatim = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: .verbatim(samples: verbatimSamples, wastedBits: 1)
    )
    #expect(try decode(verbatim, expectedFrameNumber: 0, decodeSamples: true).samples == verbatimSamples.map { Int16($0 * 2) })

    let fixedWarmups: [Int64] = [2]
    let fixedResiduals = Array(repeating: Int64(1), count: 15)
    let fixed = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: .fixed(
            order: 1,
            warmups: fixedWarmups,
            residuals: fixedResiduals,
            method: 0,
            partitionOrder: 0,
            codings: [FLACPartitionCoding(parameter: 0, rawWidth: nil)],
            wastedBits: 1
        )
    )
    #expect(try decode(fixed, expectedFrameNumber: 0, decodeSamples: true).samples == expectedFixed(warmups: fixedWarmups, residuals: fixedResiduals, order: 1).map { $0 * 2 })

    let lpcWarmups: [Int64] = [-2]
    let lpcResiduals = Array(repeating: Int64(1), count: 15)
    let lpc = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: .lpc(
            order: 1,
            warmups: lpcWarmups,
            precision: 5,
            shift: 0,
            coefficients: [1],
            residuals: lpcResiduals,
            method: 0,
            partitionOrder: 0,
            codings: [FLACPartitionCoding(parameter: 0, rawWidth: nil)],
            wastedBits: 1
        )
    )
    #expect(try decode(lpc, expectedFrameNumber: 0, decodeSamples: true).samples == expectedLPC(warmups: lpcWarmups, residuals: lpcResiduals, coefficients: [1], shift: 0).map { $0 * 2 })
}

@Test func decodesRice2LargeParametersEscapesAndZeroWidthEscape() throws {
    let rice2Residuals: [Int64] = [-4, 0, 15, -123, 1_000, -1_024, 5, -8, 2, 3, -2, 10, -10, 42, -42, 99]
    let rice2 = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: .fixed(
            order: 0,
            warmups: [],
            residuals: rice2Residuals,
            method: 1,
            partitionOrder: 0,
            codings: [FLACPartitionCoding(parameter: 20, rawWidth: nil)],
            wastedBits: 0
        )
    )
    #expect(try decode(rice2, expectedFrameNumber: 0, decodeSamples: true).samples == rice2Residuals.map(Int16.init))

    let zeroEscape = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: .fixed(
            order: 0,
            warmups: [],
            residuals: Array(repeating: 0, count: 16),
            method: 0,
            partitionOrder: 0,
            codings: [FLACPartitionCoding(parameter: 15, rawWidth: 0)],
            wastedBits: 0
        )
    )
    #expect(try decode(zeroEscape, expectedFrameNumber: 0, decodeSamples: true).samples == Array(repeating: 0, count: 16))

    let escapedResiduals: [Int64] = [-128, -17, -1, 0, 1, 42, 127, -64, 63, 2, -2, 11, -11, 100, -100, 5]
    let escape = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: .fixed(
            order: 0,
            warmups: [],
            residuals: escapedResiduals,
            method: 1,
            partitionOrder: 0,
            codings: [FLACPartitionCoding(parameter: 31, rawWidth: 8)],
            wastedBits: 0
        )
    )
    #expect(try decode(escape, expectedFrameNumber: 0, decodeSamples: true).samples == escapedResiduals.map(Int16.init))
}

@Test func firstRicePartitionSubtractsPredictorWarmupCount() throws {
    let warmups: [Int64] = [1, 2]
    let residuals = Array(repeating: Int64(1), count: 14)
    let frame = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: .fixed(
            order: 2,
            warmups: warmups,
            residuals: residuals,
            method: 0,
            partitionOrder: 1,
            codings: [
                FLACPartitionCoding(parameter: 0, rawWidth: nil),
                FLACPartitionCoding(parameter: 0, rawWidth: nil),
            ],
            wastedBits: 0
        )
    )
    #expect(try decode(frame, expectedFrameNumber: 0, decodeSamples: true).samples == expectedFixed(warmups: warmups, residuals: residuals, order: 2))
}

@Test func acceptsOrderTwoWhenRicePartitionsHaveTwoSamples() throws {
    let stream: [UInt8] = [
        0x66, 0x4c, 0x61, 0x43, 0x80, 0x00, 0x00, 0x22,
        0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x28, 0x00,
        0x00, 0x28, 0x03, 0xe8, 0x00, 0xf0, 0x00, 0x00,
        0x00, 0x10, 0x03, 0xbe, 0x3a, 0x3e, 0x8f, 0x1f,
        0x77, 0xbe, 0x16, 0xca, 0x4d, 0x52, 0xf6, 0x7b,
        0x37, 0x6a, 0xff, 0xf8, 0x65, 0x08, 0x00, 0x0f,
        0xd8, 0x14, 0xff, 0x9c, 0xff, 0xc1, 0x0d, 0x12,
        0x10, 0x48, 0x41, 0x00, 0x00, 0x00, 0x3e, 0x00,
        0x00, 0x00, 0x82, 0x42, 0x09, 0x00, 0x00, 0x00,
        0x0f, 0xa0, 0x00, 0x00, 0x02, 0x10, 0x48, 0x40,
        0x74, 0x6d,
    ]
    let expectedSamples = (0..<16).map { Int16(($0 * 37) % 200 - 100) }
    let fixture = try FLACFrameFixture(bytes: stream)
    defer { fixture.cleanup() }
    let info = try TimelineAudioInfo(committedFrames: 16, gapEvents: [])
    let reader = try FLACTimelineReader(url: fixture.fileURL, info: info, sessionURL: fixture.root)
    #expect(try reader.readSamples(frameRange: 0..<16) == expectedSamples.map { Float($0) / 32_768 })
    try reader.validateAudio()

    let frame = Array(stream.dropFirst(42))
    let skipped = try decode(frame, expectedFrameNumber: 0, decodeSamples: false)
    #expect(skipped.blockSize == 16)
    #expect(skipped.byteCount == UInt64(frame.count))
    #expect(skipped.samples.isEmpty)
}

@Test func acceptsOrderTwoWithoutResidualsWhenUnpartitionedBlockMatchesOrder() throws {
    let warmups: [Int64] = [-17, 30]
    let frame = makeFLACFrame(
        blockSize: 2,
        frameNumber: 0,
        subframe: .fixed(
            order: 2,
            warmups: warmups,
            residuals: [],
            method: 0,
            partitionOrder: 0,
            codings: [FLACPartitionCoding(parameter: 0, rawWidth: nil)],
            wastedBits: 0
        )
    )
    let decoded = try decode(frame, expectedFrameNumber: 0, decodeSamples: true)
    let skipped = try decode(frame, expectedFrameNumber: 0, decodeSamples: false)
    #expect(decoded.samples == warmups.map(Int16.init))
    #expect(skipped.blockSize == 2)
    #expect(skipped.byteCount == UInt64(frame.count))
    #expect(skipped.samples.isEmpty)
}

@Test func skipModeConsumesAndChecksTheSameFrameWithoutRetainingSamples() throws {
    let residuals: [Int64] = [1, -2, 0, 3, -4, 0, 5, -6, 0, 7, -8, 0, 9, -10, 0, 11]
    let frame = makeFLACFrame(
        blockSize: 16,
        frameNumber: 3,
        subframe: .fixed(
            order: 0,
            warmups: [],
            residuals: residuals,
            method: 0,
            partitionOrder: 0,
            codings: [FLACPartitionCoding(parameter: 0, rawWidth: nil)],
            wastedBits: 0
        )
    )
    let decoded = try decode(frame, expectedFrameNumber: 3, decodeSamples: true)
    let skipped = try decode(frame, expectedFrameNumber: 3, decodeSamples: false)
    #expect(skipped.blockSize == decoded.blockSize)
    #expect(skipped.byteCount == decoded.byteCount)
    #expect(skipped.byteCount == UInt64(frame.count))
    #expect(skipped.samples.isEmpty)
}

@Test func acceptsCanonicalMultibyteFrameNumberAndRejectsOverlongEncoding() throws {
    let multibyte = makeFLACFrame(
        blockSize: 16,
        frameNumber: 128,
        subframe: .constant(value: 7, wastedBits: 0)
    )
    #expect(try decode(multibyte, expectedFrameNumber: 128, decodeSamples: true).samples == Array(repeating: 7, count: 16))

    let overlong = makeFLACFrame(
        blockSize: 16,
        frameNumber: 1,
        subframe: .constant(value: 7, wastedBits: 0),
        frameNumberBytes: [0xc0, 0x81]
    )
    #expect(throws: FLACTimelineReaderError.self) {
        try decode(overlong, expectedFrameNumber: 1, decodeSamples: true)
    }

    let malformedContinuation = makeFLACFrame(
        blockSize: 16,
        frameNumber: 1,
        subframe: .constant(value: 7, wastedBits: 0),
        frameNumberBytes: [0xc2, 0x41]
    )
    #expect(throws: FLACTimelineReaderError.self) {
        try decode(malformedContinuation, expectedFrameNumber: 1, decodeSamples: true)
    }
}

@Test func rejectsBadSyncVariableBlocksAndNoncanonicalOrReservedHeaderFields() throws {
    let subframe = FLACSubframeFixture.constant(value: 0, wastedBits: 0)
    let badSync = makeFLACFrame(blockSize: 16, frameNumber: 0, subframe: subframe, syncLow: 0xf6)
    #expect(throws: FLACTimelineReaderError.self) { try decode(badSync, expectedFrameNumber: 0, decodeSamples: true) }

    let variableBlock = makeFLACFrame(blockSize: 16, frameNumber: 0, subframe: subframe, syncLow: 0xf9)
    #expect(throws: FLACTimelineReaderError.self) { try decode(variableBlock, expectedFrameNumber: 0, decodeSamples: true) }

    let reservedHeader = makeFLACFrame(blockSize: 16, frameNumber: 0, subframe: subframe, reservedHeaderBit: 1)
    #expect(throws: FLACTimelineReaderError.self) { try decode(reservedHeader, expectedFrameNumber: 0, decodeSamples: true) }

    let unsupportedRate = makeFLACFrame(blockSize: 16, frameNumber: 0, subframe: subframe, sampleRateCode: 4)
    #expect(throws: FLACTimelineReaderError.self) { try decode(unsupportedRate, expectedFrameNumber: 0, decodeSamples: true) }

    let unsupportedDepth = makeFLACFrame(blockSize: 16, frameNumber: 0, subframe: subframe, sampleDepthCode: 3)
    #expect(throws: FLACTimelineReaderError.self) { try decode(unsupportedDepth, expectedFrameNumber: 0, decodeSamples: true) }

    let reservedType = makeFLACFrame(blockSize: 16, frameNumber: 0, subframe: .reservedType(2))
    #expect(throws: FLACTimelineReaderError.self) { try decode(reservedType, expectedFrameNumber: 0, decodeSamples: true) }

    let streamInfoFormat = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: subframe,
        sampleRateCode: 0,
        sampleDepthCode: 0
    )
    #expect(try decode(streamInfoFormat, expectedFrameNumber: 0, decodeSamples: true).samples.count == 16)
}

@Test func rejectsMalformedResidualMethodIllegalWastedDepthAndNegativeLPCShift() throws {
    let malformedResidual = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: .fixed(
            order: 0,
            warmups: [],
            residuals: Array(repeating: 0, count: 16),
            method: 2,
            partitionOrder: 0,
            codings: [FLACPartitionCoding(parameter: 0, rawWidth: nil)],
            wastedBits: 0
        )
    )
    #expect(throws: FLACTimelineReaderError.self) { try decode(malformedResidual, expectedFrameNumber: 0, decodeSamples: true) }

    let illegalWastedDepth = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: .constant(value: 0, wastedBits: 16)
    )
    #expect(throws: FLACTimelineReaderError.self) { try decode(illegalWastedDepth, expectedFrameNumber: 0, decodeSamples: true) }

    let negativeShift = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: .lpc(
            order: 1,
            warmups: [1],
            precision: 5,
            shift: -1,
            coefficients: [1],
            residuals: Array(repeating: 0, count: 15),
            method: 0,
            partitionOrder: 0,
            codings: [FLACPartitionCoding(parameter: 0, rawWidth: nil)],
            wastedBits: 0
        )
    )
    #expect(throws: FLACTimelineReaderError.self) { try decode(negativeShift, expectedFrameNumber: 0, decodeSamples: true) }
}

@Test func headerAndFrameCRCsAndTruncationAreMandatory() throws {
    let original = makeFLACFrame(
        blockSize: 16,
        frameNumber: 0,
        subframe: .constant(value: 0, wastedBits: 0)
    )
    var badHeaderCRC = original
    badHeaderCRC[6] ^= 1
    #expect(throws: FLACTimelineReaderError.self) { try decode(badHeaderCRC, expectedFrameNumber: 0, decodeSamples: true) }

    var badFrameCRC = original
    badFrameCRC[badFrameCRC.count - 1] ^= 1
    #expect(throws: FLACTimelineReaderError.self) { try decode(badFrameCRC, expectedFrameNumber: 0, decodeSamples: true) }

    let truncated = Array(original.dropLast())
    #expect(throws: FLACTimelineReaderError.self) { try decode(truncated, expectedFrameNumber: 0, decodeSamples: true) }
}

@Test func rejectsUncommonBlockSize65536() throws {
    let frame = makeFLACFrame(
        blockSize: 65_536,
        frameNumber: 0,
        subframe: .constant(value: 0, wastedBits: 0),
        blockSizeCode: 7
    )
    #expect(throws: FLACTimelineReaderError.self) { try decode(frame, expectedFrameNumber: 0, decodeSamples: false) }
}
