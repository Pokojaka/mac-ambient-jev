import Foundation

internal struct FLACDecodedFrame {
    let blockSize: Int
    let samples: [Int16]
    let byteCount: UInt64
}

internal enum FLACFrameDecoder {
    private static let maximumFoldedResidual: UInt64 = 0xffff_fffe
    private static let maximumFrameNumber: UInt64 = 0x7fff_ffff
    private static let fixedCoefficients: [[Int64]] = [
        [],
        [1],
        [2, -1],
        [3, -3, 1],
        [4, -6, 4, -1],
    ]

    static func read(
        from reader: FLACBitReader,
        expectedFrameNumber: UInt64,
        firstSample: Int64,
        decodeSamples: Bool
    ) throws -> FLACDecodedFrame {
        do {
            return try readFrame(
                from: reader,
                expectedFrameNumber: expectedFrameNumber,
                firstSample: firstSample,
                decodeSamples: decodeSamples
            )
        } catch let error as FLACTimelineReaderError {
            if case .decodeFailed(_, let reason) = error {
                throw FLACTimelineReaderError.decodeFailed(frame: firstSample, reason: reason)
            }
            throw error
        }
    }

    private static func readFrame(
        from reader: FLACBitReader,
        expectedFrameNumber: UInt64,
        firstSample: Int64,
        decodeSamples: Bool
    ) throws -> FLACDecodedFrame {
        guard reader.isByteAligned else {
            try fail(firstSample, "フレーム開始位置がバイト境界に揃っていません。")
        }
        let frameStart = reader.offset
        reader.beginFrame()

        var header: [UInt8] = []
        func readHeaderByte() throws -> UInt8 {
            let byte = try reader.readByte()
            header.append(byte)
            return byte
        }

        let syncHigh = try reader.readByte()
        let syncLow = try reader.readByte()
        guard syncHigh == 0xff, (syncLow & 0xfe) == 0xf8 else {
            throw FLACTimelineReaderError.badSync(offset: frameStart)
        }
        guard (syncLow & 0x01) == 0 else {
            throw FLACTimelineReaderError.unsupportedVariableBlockSize
        }
        header.append(syncHigh)
        header.append(syncLow)

        let sizeAndRate = try readHeaderByte()
        let channelAndDepth = try readHeaderByte()
        let blockSizeCode = Int(sizeAndRate >> 4)
        let sampleRateCode = Int(sizeAndRate & 0x0f)
        let channelAssignment = Int(channelAndDepth >> 4)
        let sampleDepthCode = Int((channelAndDepth >> 1) & 0x07)
        let reservedHeaderBit = channelAndDepth & 0x01
        let frameNumber = try readUTF8FrameNumber(readByte: readHeaderByte)

        let blockSizeExtra: Int?
        switch blockSizeCode {
        case 6:
            blockSizeExtra = Int(try readHeaderByte())
        case 7:
            let high = Int(try readHeaderByte())
            let low = Int(try readHeaderByte())
            blockSizeExtra = (high << 8) | low
        default:
            blockSizeExtra = nil
        }

        let sampleRateExtra: Int?
        switch sampleRateCode {
        case 12:
            sampleRateExtra = Int(try readHeaderByte())
        case 13, 14:
            let high = Int(try readHeaderByte())
            let low = Int(try readHeaderByte())
            sampleRateExtra = (high << 8) | low
        default:
            sampleRateExtra = nil
        }

        let storedHeaderCRC = try reader.readByte()
        guard FLACChecksum.crc8(header) == storedHeaderCRC else {
            throw FLACTimelineReaderError.headerCRC(offset: frameStart)
        }

        let blockSize: Int
        switch blockSizeCode {
        case 0:
            try fail(firstSample, "ブロックサイズコード0は使用できません。")
        case 1:
            blockSize = 192
        case 2...5:
            blockSize = 576 << (blockSizeCode - 2)
        case 6:
            guard let extra = blockSizeExtra else {
                try fail(firstSample, "ブロックサイズ拡張値がありません。")
            }
            blockSize = extra + 1
        case 7:
            guard let extra = blockSizeExtra else {
                try fail(firstSample, "ブロックサイズ拡張値がありません。")
            }
            blockSize = extra + 1
            guard blockSize <= 65_535 else {
                try fail(firstSample, "ブロックサイズ65536には対応していません。")
            }
        case 8...15:
            blockSize = 256 << (blockSizeCode - 8)
        default:
            try fail(firstSample, "ブロックサイズコードが不正です。")
        }

        let sampleRate: Int
        switch sampleRateCode {
        case 0:
            sampleRate = 16_000
        case 1:
            sampleRate = 88_200
        case 2:
            sampleRate = 176_400
        case 3:
            sampleRate = 192_000
        case 4:
            sampleRate = 8_000
        case 5:
            sampleRate = 16_000
        case 6:
            sampleRate = 22_050
        case 7:
            sampleRate = 24_000
        case 8:
            sampleRate = 32_000
        case 9:
            sampleRate = 44_100
        case 10:
            sampleRate = 48_000
        case 11:
            sampleRate = 96_000
        case 12:
            guard let extra = sampleRateExtra else {
                try fail(firstSample, "サンプルレート拡張値がありません。")
            }
            sampleRate = extra * 1_000
        case 13:
            guard let extra = sampleRateExtra else {
                try fail(firstSample, "サンプルレート拡張値がありません。")
            }
            sampleRate = extra
        case 14:
            guard let extra = sampleRateExtra else {
                try fail(firstSample, "サンプルレート拡張値がありません。")
            }
            sampleRate = extra * 10
        case 15:
            try fail(firstSample, "サンプルレートコード15は使用できません。")
        default:
            try fail(firstSample, "サンプルレートコードが不正です。")
        }

        guard sampleRate == 16_000 else {
            try fail(firstSample, "16 kHz以外のサンプルレートには対応していません。")
        }
        guard channelAssignment == 0 else {
            try fail(firstSample, "モノラル以外のチャンネル割り当てには対応していません。")
        }
        guard sampleDepthCode == 0 || sampleDepthCode == 4 else {
            try fail(firstSample, "16-bit以外のサンプル深度には対応していません。")
        }
        guard reservedHeaderBit == 0 else {
            try fail(firstSample, "フレームヘッダーの予約ビットが0ではありません。")
        }
        guard frameNumber == expectedFrameNumber else {
            try fail(firstSample, "フレーム番号が期待値と一致しません。")
        }

        var samples: [Int16] = []
        if decodeSamples {
            samples.reserveCapacity(blockSize)
        }

        let subframeReservedBit = try reader.read(1)
        guard subframeReservedBit == 0 else {
            try fail(firstSample, "サブフレームの予約ビットが0ではありません。")
        }
        let subframeType = Int(try reader.read(6))
        let hasWastedBits = try reader.read(1) != 0
        let wastedBits: Int
        if hasWastedBits {
            wastedBits = Int(try reader.readUnary(maximum: 14)) + 1
        } else {
            wastedBits = 0
        }
        let sampleDepth = 16 - wastedBits
        guard sampleDepth >= 1 else {
            try fail(firstSample, "無駄ビットを除いたサンプル深度が1未満です。")
        }

        switch subframeType {
        case 0:
            let value = try reader.readSigned(sampleDepth)
            if decodeSamples {
                samples.append(contentsOf: repeatElement(Int16(value), count: blockSize))
            }
        case 1:
            if decodeSamples {
                for _ in 0..<blockSize {
                    let value = try reader.readSigned(sampleDepth)
                    samples.append(Int16(value))
                }
            } else {
                for _ in 0..<blockSize {
                    _ = try reader.readSigned(sampleDepth)
                }
            }
        case 8...12:
            let order = subframeType - 8
            guard order <= blockSize else {
                try fail(firstSample, "FIXED予測次数がブロックサイズを超えています。")
            }
            for _ in 0..<order {
                let warmup = try reader.readSigned(sampleDepth)
                if decodeSamples { samples.append(Int16(warmup)) }
            }
            try readResiduals(
                from: reader,
                blockSize: blockSize,
                predictorOrder: order,
                firstSample: firstSample
            ) { residual in
                guard decodeSamples else { return }
                let prediction = try fixedPrediction(samples: samples, order: order, firstSample: firstSample)
                let reconstructed = try checkedAdd(prediction, residual, firstSample: firstSample)
                try validateReducedSample(reconstructed, depth: sampleDepth, firstSample: firstSample)
                samples.append(Int16(reconstructed))
            }
        case 32...63:
            let order = (subframeType & 0x1f) + 1
            guard order <= blockSize else {
                try fail(firstSample, "LPC予測次数がブロックサイズを超えています。")
            }
            for _ in 0..<order {
                let warmup = try reader.readSigned(sampleDepth)
                if decodeSamples { samples.append(Int16(warmup)) }
            }
            let precisionCode = Int(try reader.read(4))
            guard precisionCode != 15 else {
                try fail(firstSample, "LPC係数精度コード15は予約値です。")
            }
            let coefficientPrecision = precisionCode + 1
            let shift = try reader.readSigned(5)
            guard shift >= 0 else {
                try fail(firstSample, "LPCの負のシフト量には対応していません。")
            }
            var coefficients: [Int64] = []
            if decodeSamples {
                coefficients.reserveCapacity(order)
            }
            for _ in 0..<order {
                let coefficient = try reader.readSigned(coefficientPrecision)
                if decodeSamples { coefficients.append(coefficient) }
            }
            try readResiduals(
                from: reader,
                blockSize: blockSize,
                predictorOrder: order,
                firstSample: firstSample
            ) { residual in
                guard decodeSamples else { return }
                let prediction = try lpcPrediction(
                    samples: samples,
                    coefficients: coefficients,
                    shift: Int(shift),
                    firstSample: firstSample
                )
                let reconstructed = try checkedAdd(prediction, residual, firstSample: firstSample)
                try validateReducedSample(reconstructed, depth: sampleDepth, firstSample: firstSample)
                samples.append(Int16(reconstructed))
            }
        default:
            try fail(firstSample, "予約済みのサブフレーム形式です。")
        }

        if decodeSamples {
            guard samples.count == blockSize else {
                try fail(firstSample, "デコードしたサンプル数がブロックサイズと一致しません。")
            }
            let scale = Int64(1) << wastedBits
            for index in samples.indices {
                let (scaled, overflow) = Int64(samples[index]).multipliedReportingOverflow(by: scale)
                guard !overflow, scaled >= Int64(Int16.min), scaled <= Int64(Int16.max) else {
                    try fail(firstSample, "無駄ビット適用後のサンプルが16-bit範囲を超えています。")
                }
                samples[index] = Int16(scaled)
            }
        }

        try reader.alignRequiringZero()
        _ = try reader.readByte()
        _ = try reader.readByte()
        guard reader.frameCRC == 0 else {
            throw FLACTimelineReaderError.frameCRC(offset: frameStart)
        }

        return FLACDecodedFrame(
            blockSize: blockSize,
            samples: decodeSamples ? samples : [],
            byteCount: reader.offset - frameStart
        )
    }

    private static func readUTF8FrameNumber(readByte: () throws -> UInt8) throws -> UInt64 {
        let first = try readByte()
        let length: Int
        let initialMask: UInt8
        let minimumValue: UInt64
        switch first {
        case 0x00...0x7f:
            length = 1
            initialMask = 0x7f
            minimumValue = 0
        case 0xc0...0xdf:
            length = 2
            initialMask = 0x1f
            minimumValue = 0x80
        case 0xe0...0xef:
            length = 3
            initialMask = 0x0f
            minimumValue = 0x800
        case 0xf0...0xf7:
            length = 4
            initialMask = 0x07
            minimumValue = 0x1_0000
        case 0xf8...0xfb:
            length = 5
            initialMask = 0x03
            minimumValue = 0x20_0000
        case 0xfc...0xfd:
            length = 6
            initialMask = 0x01
            minimumValue = 0x400_0000
        default:
            throw FLACTimelineReaderError.decodeFailed(frame: 0, reason: "フレーム番号のUTF-8形式が不正です。")
        }

        var value = UInt64(first & initialMask)
        if length > 1 {
            for _ in 1..<length {
                let continuation = try readByte()
                guard continuation & 0xc0 == 0x80 else {
                    throw FLACTimelineReaderError.decodeFailed(frame: 0, reason: "フレーム番号の継続バイトが不正です。")
                }
                value = (value << 6) | UInt64(continuation & 0x3f)
            }
        }
        guard value >= minimumValue, value <= maximumFrameNumber else {
            throw FLACTimelineReaderError.decodeFailed(frame: 0, reason: "フレーム番号が最短形式または31-bit範囲に違反しています。")
        }
        return value
    }

    private static func readResiduals(
        from reader: FLACBitReader,
        blockSize: Int,
        predictorOrder: Int,
        firstSample: Int64,
        consume: (Int64) throws -> Void
    ) throws {
        let method = Int(try reader.read(2))
        guard method == 0 || method == 1 else {
            try fail(firstSample, "残差符号化方式はRiceまたはRice2でなければなりません。")
        }
        let partitionOrder = Int(try reader.read(4))
        let partitionCount = 1 << partitionOrder
        guard blockSize % partitionCount == 0 else {
            try fail(firstSample, "残差パーティション数がブロックサイズを分割しません。")
        }
        let samplesPerPartition = blockSize / partitionCount
        let hasEnoughSamples = partitionOrder == 0
            ? blockSize >= predictorOrder
            : samplesPerPartition >= predictorOrder
        guard hasEnoughSamples else {
            try fail(firstSample, "残差パーティションのサンプル数が予測次数未満です。")
        }

        let parameterBits = method == 0 ? 4 : 5
        let escapeParameter = (1 << parameterBits) - 1
        for partition in 0..<partitionCount {
            let parameter = Int(try reader.read(parameterBits))
            let residualCount = samplesPerPartition - (partition == 0 ? predictorOrder : 0)
            if parameter == escapeParameter {
                let rawWidth = Int(try reader.read(5))
                for _ in 0..<residualCount {
                    let residual = try reader.readSigned(rawWidth)
                    try consume(residual)
                }
            } else {
                let maximumQuotient = maximumFoldedResidual >> parameter
                for _ in 0..<residualCount {
                    let quotient = try reader.readUnary(maximum: maximumQuotient)
                    let remainder = parameter == 0 ? 0 : try reader.read(parameter)
                    let folded = (quotient << parameter) | remainder
                    guard folded <= maximumFoldedResidual else {
                        try fail(firstSample, "Rice残差の折り畳み値がInt32範囲を超えています。")
                    }
                    let half = Int64(folded >> 1)
                    let residual = folded & 1 == 0 ? half : -half - 1
                    try consume(residual)
                }
            }
        }
    }

    private static func fixedPrediction(
        samples: [Int16],
        order: Int,
        firstSample: Int64
    ) throws -> Int64 {
        var prediction: Int64 = 0
        for (index, coefficient) in fixedCoefficients[order].enumerated() {
            let previous = Int64(samples[samples.count - index - 1])
            let (product, multiplicationOverflow) = coefficient.multipliedReportingOverflow(by: previous)
            guard !multiplicationOverflow else {
                try fail(firstSample, "FIXED予測の積がInt64範囲を超えています。")
            }
            prediction = try checkedAdd(prediction, product, firstSample: firstSample)
        }
        return prediction
    }

    private static func lpcPrediction(
        samples: [Int16],
        coefficients: [Int64],
        shift: Int,
        firstSample: Int64
    ) throws -> Int64 {
        var sum: Int64 = 0
        for (index, coefficient) in coefficients.enumerated() {
            let previous = Int64(samples[samples.count - index - 1])
            let (product, multiplicationOverflow) = coefficient.multipliedReportingOverflow(by: previous)
            guard !multiplicationOverflow else {
                try fail(firstSample, "LPC予測の積がInt64範囲を超えています。")
            }
            sum = try checkedAdd(sum, product, firstSample: firstSample)
        }
        return sum >> shift
    }

    private static func checkedAdd(_ left: Int64, _ right: Int64, firstSample: Int64) throws -> Int64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard !overflow else {
            try fail(firstSample, "予測サンプルの加算がInt64範囲を超えています。")
        }
        return sum
    }

    private static func validateReducedSample(_ sample: Int64, depth: Int, firstSample: Int64) throws {
        let magnitude = Int64(1) << (depth - 1)
        guard sample >= -magnitude, sample < magnitude else {
            try fail(firstSample, "再構成サンプルが有効なサンプル深度を超えています。")
        }
    }

    private static func fail(_ firstSample: Int64, _ reason: String) throws -> Never {
        throw FLACTimelineReaderError.decodeFailed(frame: firstSample, reason: reason)
    }
}
