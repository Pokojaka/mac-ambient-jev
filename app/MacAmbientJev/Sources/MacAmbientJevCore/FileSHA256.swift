import CSHA256
import Foundation

/// SHA-256 of a file or byte string. Files are hashed in bounded chunks, so memory use does not
/// grow with the file size. Foundation streaming and portable C compression run on macOS, Linux and
/// Windows.
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
                    block.withUnsafeBufferPointer { compressBlocks($0, blockCount: 1) }
                    pendingCount = 0
                }
            }
            let blockCount = (bytes.count - offset) / 64
            if blockCount > 0 {
                let endOffset = offset + blockCount * 64
                compressBlocks(
                    UnsafeBufferPointer(rebasing: bytes[offset..<endOffset]),
                    blockCount: blockCount
                )
                offset = endOffset
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

    private mutating func compressBlocks(_ bytes: UnsafeBufferPointer<UInt8>, blockCount: Int) {
        precondition(blockCount > 0, "blockCount must be positive")
        precondition(bytes.count >= blockCount * 64, "bytes must contain all complete blocks")
        guard let baseAddress = bytes.baseAddress else {
            preconditionFailure("bytes must have a base address")
        }
        state.withUnsafeMutableBufferPointer {
            msj_sha256_compress_blocks($0.baseAddress!, baseAddress, blockCount)
        }
    }
}
