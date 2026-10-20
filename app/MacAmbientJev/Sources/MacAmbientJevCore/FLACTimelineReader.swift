import Foundation

/// Reads exact committed frames from a pinned FLAC stream.
public final class FLACTimelineReader: TimelineAudioReading, @unchecked Sendable {
    public let url: URL
    public let info: TimelineAudioInfo

    private struct StreamMetadata {
        let firstAudioOffset: UInt64
        let minimumBlockSize: Int
        let maximumBlockSize: Int
        let minimumFrameSize: UInt32
        let maximumFrameSize: UInt32
        let totalFrames: Int64
        let md5: [UInt8]
    }

    private struct FrameRecord {
        let offset: UInt64
        let firstSample: Int64
        let blockSize: Int
        let byteCount: UInt64
    }

    private let handle: FileHandle
    private let streamMetadata: StreamMetadata
    private var frameIndex: [FrameRecord]?
    private let lock = NSLock()

    public init(url: URL, info: TimelineAudioInfo, sessionURL: URL) throws {
        let handle: FileHandle
        do {
            handle = try SessionFileAccess.openHandle(url, relativeTo: sessionURL)
        } catch let error as CocoaError {
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            if underlying?.domain == NSPOSIXErrorDomain && underlying?.code == 2 {
                throw FLACTimelineReaderError.unreadable(error.localizedDescription)
            }
            throw error
        }

        do {
            let metadata = try Self.readMetadata(from: handle, expectedFrames: info.committedFrames)
            self.url = url
            self.info = info
            self.handle = handle
            self.streamMetadata = metadata
            self.frameIndex = nil
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    public func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        guard frameRange.lowerBound >= 0,
              frameRange.lowerBound <= frameRange.upperBound,
              frameRange.upperBound <= info.committedFrames else {
            throw ProcessingTimelineReaderError.invalidFrameRange
        }
        guard !frameRange.isEmpty else { return [] }

        let records = try ensureFrameIndex()
        let requestedCount = Int(frameRange.upperBound - frameRange.lowerBound)
        var output: [Float] = []
        output.reserveCapacity(requestedCount)

        var recordIndex = firstRecord(intersecting: frameRange.lowerBound, in: records)
        guard recordIndex < records.count else {
            throw FLACTimelineReaderError.decodeFailed(
                frame: frameRange.lowerBound,
                reason: "FLACフレーム索引に要求範囲がありません。"
            )
        }

        let firstRecord = records[recordIndex]
        let reader = FLACBitReader(handle: handle)
        try reader.seek(to: firstRecord.offset)

        while recordIndex < records.count {
            let record = records[recordIndex]
            guard record.firstSample < frameRange.upperBound else { break }
            guard reader.offset == record.offset else {
                throw FLACTimelineReaderError.decodeFailed(
                    frame: record.firstSample,
                    reason: "FLACフレームの位置が索引と一致しません。"
                )
            }

            let decoded = try FLACFrameDecoder.read(
                from: reader,
                expectedFrameNumber: UInt64(recordIndex),
                firstSample: record.firstSample,
                decodeSamples: true
            )
            try requireConsistent(decoded, with: record)

            let overlapStart = max(frameRange.lowerBound, record.firstSample)
            let overlapEnd = min(frameRange.upperBound, record.firstSample + Int64(record.blockSize))
            if overlapStart < overlapEnd {
                let sampleStart = Int(overlapStart - record.firstSample)
                let sampleEnd = Int(overlapEnd - record.firstSample)
                for sample in decoded.samples[sampleStart..<sampleEnd] {
                    output.append(Float(sample) / 32_768)
                }
            }

            if recordIndex == records.count - 1 {
                guard try reader.atEnd() else {
                    throw FLACTimelineReaderError.trailingGarbage(offset: reader.offset)
                }
            }
            recordIndex += 1
        }

        guard output.count == requestedCount else {
            throw FLACTimelineReaderError.decodeFailed(
                frame: frameRange.lowerBound,
                reason: "FLACフレーム索引から要求されたサンプル数を読み取れません。"
            )
        }
        return output
    }

    public func validateAudio() throws {
        lock.lock()
        defer { lock.unlock() }
        try validateSequentially(against: nil)
    }

    public func validateAudio(against source: any TimelineAudioReading) throws {
        if (source as AnyObject) === self {
            throw FLACTimelineReaderError.decodeFailed(
                frame: 0,
                reason: "比較元に同じ FLAC 読み取り元は指定できません"
            )
        }

        lock.lock()
        defer { lock.unlock() }

        guard source.info.committedFrames == info.committedFrames else {
            throw FLACTimelineReaderError.lengthMismatch(
                expected: info.committedFrames,
                actual: source.info.committedFrames
            )
        }
        try validateSequentially(against: source)
    }

    private func ensureFrameIndex() throws -> [FrameRecord] {
        if let frameIndex { return frameIndex }
        let records = try Self.buildFrameIndex(from: handle, metadata: streamMetadata)
        frameIndex = records
        return records
    }

    private func firstRecord(intersecting frame: Int64, in records: [FrameRecord]) -> Int {
        var lower = 0
        var upper = records.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let record = records[middle]
            let recordEnd = record.firstSample + Int64(record.blockSize)
            if recordEnd <= frame {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func validateSequentially(against source: (any TimelineAudioReading)?) throws {
        let reader = FLACBitReader(handle: handle)
        try reader.seek(to: streamMetadata.firstAudioOffset)

        var records: [FrameRecord] = []
        var digest = FLACMD5()
        var decodedFrames: Int64 = 0
        var expectedFrameNumber: UInt64 = 0
        var nominalBlockSize: Int?

        while decodedFrames < streamMetadata.totalFrames {
            if try reader.atEnd() {
                throw FLACTimelineReaderError.decodedFrameCountMismatch(
                    expected: streamMetadata.totalFrames,
                    decoded: decodedFrames
                )
            }

            let frameOffset = reader.offset
            let decoded = try FLACFrameDecoder.read(
                from: reader,
                expectedFrameNumber: expectedFrameNumber,
                firstSample: decodedFrames,
                decodeSamples: true
            )
            let isFinalBlock = try Self.validateBlock(
                decoded.blockSize,
                firstSample: decodedFrames,
                decodedFrames: decodedFrames,
                metadata: streamMetadata,
                nominalBlockSize: &nominalBlockSize
            )
            try validateFrameSize(decoded.byteCount, firstSample: decodedFrames)
            digest.update(samples: decoded.samples)

            let record = FrameRecord(
                offset: frameOffset,
                firstSample: decodedFrames,
                blockSize: decoded.blockSize,
                byteCount: decoded.byteCount
            )

            if let source {
                let blockEnd = decodedFrames + Int64(decoded.blockSize)
                let reference = try source.readSamples(frameRange: decodedFrames..<blockEnd)
                guard reference.count == decoded.blockSize else {
                    throw FLACTimelineReaderError.decodeFailed(
                        frame: decodedFrames,
                        reason: "比較元の読み取り数が一致しません（期待値: \(decoded.blockSize)、実際: \(reference.count)）。"
                    )
                }
                for (offset, sample) in reference.enumerated() {
                    let absoluteFrame = decodedFrames + Int64(offset)
                    guard let quantized = RecordingFLAC.quantize16(sample) else {
                        throw RecordingFLACError.nonFiniteSample(frame: absoluteFrame)
                    }
                    guard decoded.samples[offset] == quantized else {
                        throw FLACTimelineReaderError.sampleMismatch(frame: absoluteFrame)
                    }
                }
            }

            records.append(record)
            decodedFrames += Int64(decoded.blockSize)
            expectedFrameNumber += 1
            if isFinalBlock { break }
        }

        guard decodedFrames == info.committedFrames else {
            throw FLACTimelineReaderError.decodedFrameCountMismatch(
                expected: info.committedFrames,
                decoded: decodedFrames
            )
        }
        guard try reader.atEnd() else {
            throw FLACTimelineReaderError.trailingGarbage(offset: reader.offset)
        }
        guard digest.finalize() == streamMetadata.md5 else {
            throw FLACTimelineReaderError.md5Mismatch
        }
        frameIndex = records
    }

    private static func validateBlock(
        _ blockSize: Int,
        firstSample: Int64,
        decodedFrames: Int64,
        metadata: StreamMetadata,
        nominalBlockSize: inout Int?
    ) throws -> Bool {
        let blockSizeAsInt64 = Int64(blockSize)
        let remaining = metadata.totalFrames - decodedFrames
        guard blockSizeAsInt64 <= remaining else {
            throw FLACTimelineReaderError.decodedFrameCountMismatch(
                expected: metadata.totalFrames,
                decoded: decodedFrames + blockSizeAsInt64
            )
        }

        let isFinalBlock = blockSizeAsInt64 == remaining
        let nominalSize: Int
        if let nominalBlockSize {
            nominalSize = nominalBlockSize
        } else {
            nominalSize = blockSize
            nominalBlockSize = blockSize
        }
        guard blockSize <= metadata.maximumBlockSize,
              isFinalBlock
                ? blockSize <= nominalSize
                : blockSize == nominalSize && blockSize >= metadata.minimumBlockSize else {
            throw FLACTimelineReaderError.decodeFailed(
                frame: firstSample,
                reason: "FLACブロックサイズがSTREAMINFOの固定ブロックサイズと一致しません。"
            )
        }
        return isFinalBlock
    }

    private func validateFrameSize(_ byteCount: UInt64, firstSample: Int64) throws {
        guard (streamMetadata.minimumFrameSize == 0 || byteCount >= UInt64(streamMetadata.minimumFrameSize)),
              (streamMetadata.maximumFrameSize == 0 || byteCount <= UInt64(streamMetadata.maximumFrameSize)) else {
            throw FLACTimelineReaderError.decodeFailed(
                frame: firstSample,
                reason: "FLACフレームのバイト数がSTREAMINFOの範囲外です。"
            )
        }
    }

    private func requireConsistent(_ decoded: FLACDecodedFrame, with record: FrameRecord) throws {
        guard decoded.blockSize == record.blockSize, decoded.byteCount == record.byteCount else {
            throw FLACTimelineReaderError.decodeFailed(
                frame: record.firstSample,
                reason: "FLACフレームのサイズが索引と一致しません。"
            )
        }
        try validateFrameSize(decoded.byteCount, firstSample: record.firstSample)
    }

    private static func readMetadata(
        from handle: FileHandle,
        expectedFrames: Int64
    ) throws -> StreamMetadata {
        var offset: UInt64 = 0
        let signature = try readExactly(4, from: handle, offset: &offset)
        guard signature == Array("fLaC".utf8) else {
            throw FLACTimelineReaderError.notCanonicalFLAC16
        }

        var firstBlock = true
        var sawStreamInfo = false
        var isLastBlock = false
        var streamInfo: [UInt8]?

        while !isLastBlock {
            let header = try readExactly(4, from: handle, offset: &offset)
            isLastBlock = header[0] & 0x80 != 0
            let type = header[0] & 0x7f
            let length = (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])

            if firstBlock && type != 0 {
                throw FLACTimelineReaderError.invalidStreamInfo
            }
            firstBlock = false

            switch type {
            case 0:
                guard !sawStreamInfo, length == 34 else {
                    throw FLACTimelineReaderError.invalidStreamInfo
                }
                sawStreamInfo = true
                streamInfo = try readExactly(length, from: handle, offset: &offset)
            case 1...6:
                try skipExactly(length, from: handle, offset: &offset)
            default:
                throw FLACTimelineReaderError.invalidStreamInfo
            }
        }

        guard sawStreamInfo, let bytes = streamInfo, bytes.count == 34 else {
            throw FLACTimelineReaderError.invalidStreamInfo
        }

        let minimumBlockSize = Int(readUInt16(bytes, at: 0))
        let maximumBlockSize = Int(readUInt16(bytes, at: 2))
        let minimumFrameSize = readUInt24(bytes, at: 4)
        let maximumFrameSize = readUInt24(bytes, at: 7)
        guard minimumBlockSize >= 16,
              maximumBlockSize >= minimumBlockSize,
              maximumBlockSize <= 65_535,
              minimumFrameSize == 0 || maximumFrameSize == 0 || minimumFrameSize <= maximumFrameSize else {
            throw FLACTimelineReaderError.invalidStreamInfo
        }

        let formatAndTotal = readUInt64(bytes, at: 10)
        let sampleRate = (formatAndTotal >> 44) & 0x0f_ffff
        let channelCount = ((formatAndTotal >> 41) & 0x07) + 1
        let bitsPerSample = ((formatAndTotal >> 36) & 0x1f) + 1
        guard sampleRate == 16_000, channelCount == 1, bitsPerSample == 16 else {
            throw FLACTimelineReaderError.notCanonicalFLAC16
        }

        let totalFrames = Int64(formatAndTotal & ((UInt64(1) << 36) - 1))
        guard totalFrames == expectedFrames else {
            throw FLACTimelineReaderError.lengthMismatch(expected: expectedFrames, actual: totalFrames)
        }

        return StreamMetadata(
            firstAudioOffset: offset,
            minimumBlockSize: minimumBlockSize,
            maximumBlockSize: maximumBlockSize,
            minimumFrameSize: minimumFrameSize,
            maximumFrameSize: maximumFrameSize,
            totalFrames: totalFrames,
            md5: Array(bytes[18..<34])
        )
    }

    private static func buildFrameIndex(
        from handle: FileHandle,
        metadata: StreamMetadata
    ) throws -> [FrameRecord] {
        let reader = FLACBitReader(handle: handle)
        try reader.seek(to: metadata.firstAudioOffset)

        var records: [FrameRecord] = []
        var decodedFrames: Int64 = 0
        var expectedFrameNumber: UInt64 = 0
        var nominalBlockSize: Int?

        while decodedFrames < metadata.totalFrames {
            if try reader.atEnd() {
                throw FLACTimelineReaderError.decodedFrameCountMismatch(
                    expected: metadata.totalFrames,
                    decoded: decodedFrames
                )
            }

            let frameOffset = reader.offset
            let frame = try FLACFrameDecoder.read(
                from: reader,
                expectedFrameNumber: expectedFrameNumber,
                firstSample: decodedFrames,
                decodeSamples: false
            )
            let blockSize = Int64(frame.blockSize)
            _ = try Self.validateBlock(
                frame.blockSize,
                firstSample: decodedFrames,
                decodedFrames: decodedFrames,
                metadata: metadata,
                nominalBlockSize: &nominalBlockSize
            )
            guard (metadata.minimumFrameSize == 0 || frame.byteCount >= UInt64(metadata.minimumFrameSize)),
                  (metadata.maximumFrameSize == 0 || frame.byteCount <= UInt64(metadata.maximumFrameSize)) else {
                throw FLACTimelineReaderError.decodeFailed(
                    frame: decodedFrames,
                    reason: "FLACフレームのバイト数がSTREAMINFOの範囲外です。"
                )
            }

            records.append(FrameRecord(
                offset: frameOffset,
                firstSample: decodedFrames,
                blockSize: frame.blockSize,
                byteCount: frame.byteCount
            ))
            decodedFrames += blockSize
            expectedFrameNumber += 1
        }

        guard try reader.atEnd() else {
            throw FLACTimelineReaderError.trailingGarbage(offset: reader.offset)
        }
        return records
    }

    private static func readExactly(
        _ count: Int,
        from handle: FileHandle,
        offset: inout UInt64
    ) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(count)
        while result.count < count {
            let requested = count - result.count
            let data: [UInt8]
            do {
                data = try readFLACBytes(from: handle, upToCount: requested)
            } catch {
                throw FLACTimelineReaderError.unreadable(error.localizedDescription)
            }
            guard !data.isEmpty else {
                throw FLACTimelineReaderError.truncated(offset: offset)
            }
            result.append(contentsOf: data)
            offset += UInt64(data.count)
        }
        return result
    }

    private static func skipExactly(
        _ count: Int,
        from handle: FileHandle,
        offset: inout UInt64
    ) throws {
        var remaining = count
        while remaining > 0 {
            let chunkSize = min(remaining, 64 * 1024)
            _ = try readExactly(chunkSize, from: handle, offset: &offset)
            remaining -= chunkSize
        }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt24(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 16) | (UInt32(bytes[offset + 1]) << 8) | UInt32(bytes[offset + 2])
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in bytes[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}
