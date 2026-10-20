import Foundation

struct FLACMD5 {
    private static let roundConstants: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    private static let rotationAmounts: [Int] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private var state: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
    private var words = [UInt32](repeating: 0, count: 16)
    private var buffer: [UInt8] = []
    private var byteCount: UInt64 = 0
    private var isFinalized = false

    init() {}

    mutating func update(_ bytes: [UInt8]) {
        precondition(!isFinalized, "FLAC MD5 は確定後に更新できません")
        byteCount &+= UInt64(bytes.count)

        var inputOffset = 0
        if !buffer.isEmpty {
            let bytesNeeded = 64 - buffer.count
            let copiedCount = min(bytesNeeded, bytes.count)
            if copiedCount > 0 {
                buffer.append(contentsOf: bytes[0..<copiedCount])
                inputOffset = copiedCount
            }
            if buffer.count == 64 {
                processBlock(buffer, offset: 0)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        while inputOffset + 64 <= bytes.count {
            processBlock(bytes, offset: inputOffset)
            inputOffset += 64
        }

        if inputOffset < bytes.count {
            buffer.append(contentsOf: bytes[inputOffset..<bytes.count])
        }
    }

    mutating func update(samples: [Int16]) {
        precondition(!isFinalized, "FLAC MD5 は確定後に更新できません")

        var bytes: [UInt8] = []
        bytes.reserveCapacity(2_048)
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
            if bytes.count == 2_048 {
                update(bytes)
                bytes.removeAll(keepingCapacity: true)
            }
        }
        if !bytes.isEmpty {
            update(bytes)
        }
    }

    mutating func finalize() -> [UInt8] {
        precondition(!isFinalized, "FLAC MD5 は複数回確定できません")
        let messageBitCount = byteCount &* 8

        var padding: [UInt8] = [0x80]
        let zeroCount = buffer.count < 56 ? 55 - buffer.count : 119 - buffer.count
        if zeroCount > 0 {
            padding.append(contentsOf: repeatElement(0, count: zeroCount))
        }
        for shift in stride(from: 0, through: 56, by: 8) {
            padding.append(UInt8(truncatingIfNeeded: messageBitCount >> shift))
        }
        update(padding)
        isFinalized = true

        var digest: [UInt8] = []
        digest.reserveCapacity(16)
        for word in state {
            for shift in stride(from: 0, through: 24, by: 8) {
                digest.append(UInt8(truncatingIfNeeded: word >> shift))
            }
        }
        return digest
    }

    private mutating func processBlock(_ bytes: [UInt8], offset: Int) {
        for index in 0..<16 {
            let byteOffset = offset + index * 4
            words[index] = UInt32(bytes[byteOffset])
                | (UInt32(bytes[byteOffset + 1]) << 8)
                | (UInt32(bytes[byteOffset + 2]) << 16)
                | (UInt32(bytes[byteOffset + 3]) << 24)
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]

        for step in 0..<64 {
            let function: UInt32
            let wordIndex: Int
            switch step {
            case 0..<16:
                function = (b & c) | (~b & d)
                wordIndex = step
            case 16..<32:
                function = (d & b) | (~d & c)
                wordIndex = (5 * step + 1) % 16
            case 32..<48:
                function = b ^ c ^ d
                wordIndex = (3 * step + 5) % 16
            default:
                function = c ^ (b | ~d)
                wordIndex = (7 * step) % 16
            }

            let sum = a &+ function &+ Self.roundConstants[step] &+ words[wordIndex]
            let rotation = Self.rotationAmounts[step]
            let rotated = (sum << rotation) | (sum >> (32 - rotation))
            a = d
            d = c
            c = b
            b = b &+ rotated
        }

        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
    }
}
