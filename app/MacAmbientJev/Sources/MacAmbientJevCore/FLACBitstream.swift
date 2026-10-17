import Foundation

public enum FLACTimelineReaderError: LocalizedError, Equatable {
    case unreadable(String)
    case notCanonicalFLAC16
    case invalidStreamInfo
    case lengthMismatch(expected: Int64, actual: Int64)
    case decodedFrameCountMismatch(expected: Int64, decoded: Int64)
    case decodeFailed(frame: Int64, reason: String)
    case sampleMismatch(frame: Int64)
    case badSync(offset: UInt64)
    case unsupportedVariableBlockSize
    case headerCRC(offset: UInt64)
    case frameCRC(offset: UInt64)
    case truncated(offset: UInt64)
    case trailingGarbage(offset: UInt64)
    case md5Mismatch

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            return "FLACファイルを読み込めません: \(reason)"
        case .notCanonicalFLAC16:
            return "正規形式の16-bit FLACではありません。"
        case .invalidStreamInfo:
            return "FLACのSTREAMINFOが無効です。"
        case .lengthMismatch(let expected, let actual):
            return "FLACの長さが一致しません（期待値: \(expected)、実際: \(actual)）。"
        case .decodedFrameCountMismatch(let expected, let decoded):
            return "FLACのデコード済みフレーム数が一致しません（期待値: \(expected)、実際: \(decoded)）。"
        case .decodeFailed(let frame, let reason):
            return "FLACフレーム\(frame)をデコードできません: \(reason)"
        case .sampleMismatch(let frame):
            return "FLACフレーム\(frame)のサンプルが一致しません。"
        case .badSync(let offset):
            return "FLACの同期コードが不正です（オフセット: \(offset)）。"
        case .unsupportedVariableBlockSize:
            return "可変ブロックサイズのFLACには対応していません。"
        case .headerCRC(let offset):
            return "FLACヘッダーのCRCが不正です（オフセット: \(offset)）。"
        case .frameCRC(let offset):
            return "FLACフレームのCRCが不正です（オフセット: \(offset)）。"
        case .truncated(let offset):
            return "FLACデータが途中で終わっています（オフセット: \(offset)）。"
        case .trailingGarbage(let offset):
            return "FLAC末尾に不正なデータがあります（オフセット: \(offset)）。"
        case .md5Mismatch:
            return "FLACのMD5チェックサムが一致しません。"
        }
    }
}

internal enum FLACChecksum {
    private static let crc8Table: [UInt8] = (0...255).map { index in
        var value = UInt8(index)
        for _ in 0..<8 {
            value = (value & 0x80) == 0 ? value << 1 : (value << 1) ^ 0x07
        }
        return value
    }

    private static let crc16Table: [UInt16] = (0...255).map { index in
        var value = UInt16(index) << 8
        for _ in 0..<8 {
            value = (value & 0x8000) == 0 ? value << 1 : (value << 1) ^ 0x8005
        }
        return value
    }

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc = Self.crc8Table[Int(crc ^ byte)]
        }
        return crc
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc = Self.updateCRC16(crc, byte: byte)
        }
        return crc
    }

    static func updateCRC16(_ crc: UInt16, byte: UInt8) -> UInt16 {
        let index = Int((crc >> 8) ^ UInt16(byte))
        return Self.crc16Table[index] ^ (crc << 8)
    }
}

internal struct FLACBitWriter {
    private(set) var bytes: [UInt8] = []
    private(set) var bitCount = 0

    init() {}

    mutating func write(_ value: UInt64, bits: Int) {
        precondition((0...64).contains(bits), "FLACのビット幅は0から64でなければなりません。")
        guard bits > 0 else { return }

        var remaining = bits
        while remaining > 0 {
            let bitOffset = bitCount & 7
            let chunkBits = min(remaining, 8 - bitOffset)
            if bitOffset == 0 {
                bytes.append(0)
            }
            let shift = remaining - chunkBits
            let mask = UInt64((1 << chunkBits) - 1)
            let chunk = UInt8((value >> shift) & mask)
            bytes[bytes.count - 1] |= chunk << (8 - bitOffset - chunkBits)
            bitCount += chunkBits
            remaining -= chunkBits
        }
    }

    mutating func writeSigned(_ value: Int64, bits: Int) {
        precondition((0...64).contains(bits), "FLACのビット幅は0から64でなければなりません。")
        write(UInt64(bitPattern: value), bits: bits)
    }

    mutating func writeUnary(_ zeros: UInt64) {
        precondition(zeros < UInt64(Int.max - bitCount), "単項値が書き込み容量を超えています。")
        appendZeroBits(zeros)
        write(1, bits: 1)
    }

    mutating func align() {
        let paddingBits = (8 - (bitCount & 7)) & 7
        appendZeroBits(UInt64(paddingBits))
    }

    private mutating func appendZeroBits(_ count: UInt64) {
        guard count > 0 else { return }
        var remaining = count

        let bitOffset = bitCount & 7
        if bitOffset != 0 {
            let available = UInt64(8 - bitOffset)
            let filled = min(remaining, available)
            bitCount += Int(filled)
            remaining -= filled
        }

        let completeBytes = remaining / 8
        if completeBytes > 0 {
            let byteCount = Int(completeBytes)
            bytes.append(contentsOf: repeatElement(0, count: byteCount))
            bitCount += byteCount * 8
            remaining %= 8
        }

        if remaining > 0 {
            bytes.append(0)
            bitCount += Int(remaining)
        }
    }
}

internal final class FLACBitReader {
    private static let bufferCapacity = 64 * 1024

    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private var bufferPosition = 0
    private var currentByte: UInt8 = 0
    private var bitsRemaining = 0
    private var tracksFrameCRC = false
    private(set) var offset: UInt64 = 0
    private(set) var frameCRC: UInt16 = 0

    init(handle: FileHandle) {
        self.handle = handle
    }

    var isByteAligned: Bool { bitsRemaining == 0 }

    func seek(to position: UInt64) throws {
        do {
            try handle.seek(toOffset: position)
        } catch {
            throw FLACTimelineReaderError.unreadable(error.localizedDescription)
        }
        buffer.removeAll(keepingCapacity: true)
        bufferPosition = 0
        currentByte = 0
        bitsRemaining = 0
        offset = position
        frameCRC = 0
        tracksFrameCRC = false
    }

    func readByte() throws -> UInt8 {
        guard isByteAligned else {
            throw FLACTimelineReaderError.decodeFailed(frame: 0, reason: "バイト境界に揃っていません。")
        }
        return try consumeByte()
    }

    func readBytes(_ count: Int) throws -> [UInt8] {
        precondition(count >= 0, "FLACのバイト数は負数にできません。")
        guard isByteAligned else {
            throw FLACTimelineReaderError.decodeFailed(frame: 0, reason: "バイト境界に揃っていません。")
        }
        var result: [UInt8] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try consumeByte())
        }
        return result
    }

    func read(_ bits: Int) throws -> UInt64 {
        precondition((0...64).contains(bits), "FLACのビット幅は0から64でなければなりません。")
        var value: UInt64 = 0
        var remaining = bits
        while remaining > 0 {
            if bitsRemaining == 0 {
                currentByte = try consumeByte()
                bitsRemaining = 8
            }
            let chunkBits = min(remaining, bitsRemaining)
            let chunkShift = bitsRemaining - chunkBits
            let mask = UInt8((1 << chunkBits) - 1)
            let chunk = (currentByte >> chunkShift) & mask
            value = (value << chunkBits) | UInt64(chunk)
            bitsRemaining -= chunkBits
            remaining -= chunkBits
        }
        return value
    }

    func readSigned(_ bits: Int) throws -> Int64 {
        precondition((0...64).contains(bits), "FLACのビット幅は0から64でなければなりません。")
        let rawValue = try read(bits)
        guard bits > 0 else { return 0 }
        if bits == 64 { return Int64(bitPattern: rawValue) }
        let signBit = UInt64(1) << (bits - 1)
        guard rawValue & signBit != 0 else { return Int64(rawValue) }
        return Int64(bitPattern: rawValue | (~UInt64(0) << bits))
    }

    func readUnary(maximum: UInt64) throws -> UInt64 {
        var zeros: UInt64 = 0
        while true {
            if bitsRemaining == 0 {
                currentByte = try consumeByte()
                bitsRemaining = 8
            }

            let remainingBits = bitsRemaining
            let unconsumedBits = currentByte << (8 - remainingBits)
            let leadingZeros = min(remainingBits, unconsumedBits.leadingZeroBitCount)
            let allowedZeros = maximum - zeros
            if UInt64(leadingZeros) > allowedZeros {
                bitsRemaining -= Int(allowedZeros + 1)
                throw FLACTimelineReaderError.decodeFailed(frame: 0, reason: "Unary値が許容上限を超えています。")
            }
            zeros += UInt64(leadingZeros)

            if leadingZeros < remainingBits {
                bitsRemaining -= leadingZeros + 1
                return zeros
            }
            bitsRemaining = 0
        }
    }

    func alignRequiringZero() throws {
        guard bitsRemaining > 0 else { return }
        let paddingMask = UInt8((1 << bitsRemaining) - 1)
        let paddingIsZero = currentByte & paddingMask == 0
        bitsRemaining = 0
        guard paddingIsZero else {
            throw FLACTimelineReaderError.decodeFailed(frame: 0, reason: "バイト境界のパディングビットが0ではありません。")
        }
    }

    func atEnd() throws -> Bool {
        guard isByteAligned else { return false }
        try refillIfNeeded()
        return bufferPosition == buffer.count
    }

    func beginFrame() {
        precondition(isByteAligned, "フレームCRCはバイト境界で開始しなければなりません。")
        frameCRC = 0
        tracksFrameCRC = true
    }

    private func consumeByte() throws -> UInt8 {
        try refillIfNeeded()
        guard bufferPosition < buffer.count else {
            throw FLACTimelineReaderError.truncated(offset: offset)
        }
        let byte = buffer[bufferPosition]
        bufferPosition += 1
        offset += 1
        if tracksFrameCRC {
            frameCRC = FLACChecksum.updateCRC16(frameCRC, byte: byte)
        }
        return byte
    }

    private func refillIfNeeded() throws {
        guard bufferPosition == buffer.count else { return }
        do {
            buffer = try readFLACBytes(from: handle, upToCount: Self.bufferCapacity)
            bufferPosition = 0
        } catch {
            throw FLACTimelineReaderError.unreadable(error.localizedDescription)
        }
    }
}

/// Darwin's `FileHandle.read` returns autoreleased `Data`; without a pool per read, a full pass over a
/// long recording keeps every chunk alive until the caller's outer pool drains.
func readFLACBytes(from handle: FileHandle, upToCount count: Int) throws -> [UInt8] {
    #if canImport(ObjectiveC)
    try autoreleasepool { try handle.read(upToCount: count).map(Array.init) ?? [] }
    #else
    try handle.read(upToCount: count).map(Array.init) ?? []
    #endif
}
