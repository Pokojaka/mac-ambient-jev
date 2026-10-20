import Foundation

/// Identity of the pinned model file. `scripts/fetch_silero_vad.py` downloads it and verifies
/// the SHA-256; `scripts/test_fetch_silero_vad.py` checks that these values equal the script's.
public enum SileroVADModel {
    static let revision = "5cd7945676eb32225748052e2e6a0580e4686a08"
    static let filename = "silero_vad_16k_op15.onnx"
    static let sha256 = "7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49"

    public static func validate(at modelURL: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: modelURL)
        } catch {
            throw SileroVADModelValidationError.unreadable(
                path: modelURL.path,
                reason: error.localizedDescription
            )
        }

        let actual = sha256Digest(data)
        guard actual == sha256 else {
            throw SileroVADModelValidationError.hashMismatch(expected: sha256, actual: actual)
        }
    }

    static func sha256Digest(_ data: Data) -> String {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> shift))
        }

        var hash: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]

        for blockStart in stride(from: 0, to: message.count, by: 64) {
            var schedule = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let offset = blockStart + index * 4
                schedule[index] = (UInt32(message[offset]) << 24)
                    | (UInt32(message[offset + 1]) << 16)
                    | (UInt32(message[offset + 2]) << 8)
                    | UInt32(message[offset + 3])
            }
            for index in 16..<64 {
                let x = schedule[index - 15]
                let y = schedule[index - 2]
                let sigma0 = rotateRight(x, by: 7) ^ rotateRight(x, by: 18) ^ (x >> 3)
                let sigma1 = rotateRight(y, by: 17) ^ rotateRight(y, by: 19) ^ (y >> 10)
                schedule[index] = schedule[index - 16] &+ sigma0 &+ schedule[index - 7] &+ sigma1
            }

            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]

            for index in 0..<64 {
                let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choose = (e & f) ^ (~e & g)
                let temp1 = h &+ sum1 &+ choose &+ Self.roundConstants[index] &+ schedule[index]
                let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
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

            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
        }

        let hexDigits = Array("0123456789abcdef")
        return String(hash.flatMap { word in
            stride(from: 28, through: 0, by: -4).map { shift in
                hexDigits[Int((word >> shift) & 0x0f)]
            }
        })
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

enum SileroVADModelValidationError: Error, LocalizedError {
    case unreadable(path: String, reason: String)
    case hashMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(path, reason):
            return "Silero モデルを読み込めません: \(path) (\(reason))"
        case let .hashMismatch(expected, actual):
            return "Silero モデルの SHA-256 が一致しません: expected=\(expected), actual=\(actual)"
        }
    }
}
