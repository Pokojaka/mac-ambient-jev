import Foundation

/// SHA-256 of a file or byte string. Files are hashed in bounded chunks, so memory use does not
/// grow with the file size. Foundation only; the same code runs on macOS, Linux and Windows.
public enum FileSHA256 {
    static let chunkSize = 1 << 20

    public static func hexDigest(ofFileAt url: URL) throws -> String {
        try hexDigest(ofFileAt: url, chunkSize: chunkSize)
    }

    public static func hexDigest(of data: Data) -> String {
        var hasher = SHA256Hasher()
        hasher.update(data)
        return hasher.finalizeHex()
    }

    static func hexDigest(ofFileAt url: URL, chunkSize: Int) throws -> String {
        precondition(chunkSize > 0, "chunkSize must be positive")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256Hasher()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(chunk)
        }
        return hasher.finalizeHex()
    }
}

struct SHA256Hasher {
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var pending = [UInt8](repeating: 0, count: 64)
    private var pendingCount = 0
    private var totalByteCount: UInt64 = 0
    private var schedule = [UInt32](repeating: 0, count: 64)

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            totalByteCount &+= UInt64(bytes.count)
            var offset = 0
            if pendingCount > 0 {
                let take = min(64 - pendingCount, bytes.count)
                for index in 0..<take {
                    pending[pendingCount + index] = bytes[index]
                }
                pendingCount += take
                offset = take
                if pendingCount == 64 {
                    let block = pending
                    block.withUnsafeBufferPointer { compress($0, at: 0) }
                    pendingCount = 0
                }
            }
            while bytes.count - offset >= 64 {
                compress(bytes, at: offset)
                offset += 64
            }
            while offset < bytes.count {
                pending[pendingCount] = bytes[offset]
                pendingCount += 1
                offset += 1
            }
        }
    }

    mutating func finalizeHex() -> String {
        let bitLength = totalByteCount &* 8
        var tail = Data([0x80])
        let zeroCount = (119 - pendingCount) % 64
        tail.append(Data(repeating: 0, count: zeroCount))
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> shift))
        }
        update(tail)
        precondition(pendingCount == 0, "SHA-256 padding must end on a block boundary")

        let hexDigits = Array("0123456789abcdef")
        return String(state.flatMap { word in
            stride(from: 28, through: 0, by: -4).map { shift in
                hexDigits[Int((word >> shift) & 0x0f)]
            }
        })
    }

    private mutating func compress(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) {
        for index in 0..<16 {
            let position = offset + index * 4
            schedule[index] = (UInt32(bytes[position]) << 24)
                | (UInt32(bytes[position + 1]) << 16)
                | (UInt32(bytes[position + 2]) << 8)
                | UInt32(bytes[position + 3])
        }
        for index in 16..<64 {
            let x = schedule[index - 15]
            let y = schedule[index - 2]
            let sigma0 = Self.rotateRight(x, by: 7) ^ Self.rotateRight(x, by: 18) ^ (x >> 3)
            let sigma1 = Self.rotateRight(y, by: 17) ^ Self.rotateRight(y, by: 19) ^ (y >> 10)
            schedule[index] = schedule[index - 16] &+ sigma0 &+ schedule[index - 7] &+ sigma1
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]

        for index in 0..<64 {
            let sum1 = Self.rotateRight(e, by: 6) ^ Self.rotateRight(e, by: 11) ^ Self.rotateRight(e, by: 25)
            let choose = (e & f) ^ (~e & g)
            let temp1 = h &+ sum1 &+ choose &+ Self.roundConstants[index] &+ schedule[index]
            let sum0 = Self.rotateRight(a, by: 2) ^ Self.rotateRight(a, by: 13) ^ Self.rotateRight(a, by: 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = sum0 &+ majority

            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
        state[4] = state[4] &+ e
        state[5] = state[5] &+ f
        state[6] = state[6] &+ g
        state[7] = state[7] &+ h
    }

    private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]
}
