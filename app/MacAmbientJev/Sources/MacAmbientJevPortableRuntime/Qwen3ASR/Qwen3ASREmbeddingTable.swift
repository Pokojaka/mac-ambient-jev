import Foundation

enum Qwen3ASREmbeddingError: Error, Equatable, CustomStringConvertible {
    case invalidDimensions(vocabSize: Int, hiddenSize: Int)
    case sizeOverflow
    case fileUnreadable(String)
    case sizeMismatch(expected: Int, actual: UInt64)
    case invalidTokenID(Int64)

    var description: String {
        switch self {
        case let .invalidDimensions(vocabSize, hiddenSize):
            "embedding dimensions must be positive: vocabSize=\(vocabSize), hiddenSize=\(hiddenSize)"
        case .sizeOverflow:
            "embedding table byte size overflows Int"
        case let .fileUnreadable(reason):
            "embedding table file cannot be read: \(reason)"
        case let .sizeMismatch(expected, actual):
            "embedding table size mismatch: expected \(expected) bytes, found \(actual)"
        case let .invalidTokenID(id):
            "token id \(id) is outside the embedding vocabulary"
        }
    }
}

struct Qwen3ASREmbeddingTable {
    let vocabSize: Int
    let hiddenSize: Int

    private let storage: Data

    init(contentsOf url: URL, vocabSize: Int, hiddenSize: Int) throws {
        guard vocabSize > 0, hiddenSize > 0 else {
            throw Qwen3ASREmbeddingError.invalidDimensions(vocabSize: vocabSize, hiddenSize: hiddenSize)
        }
        let (elementCount, elementCountOverflow) = vocabSize.multipliedReportingOverflow(by: hiddenSize)
        let (expectedByteCount, byteCountOverflow) = elementCount.multipliedReportingOverflow(by: 2)
        guard !elementCountOverflow, !byteCountOverflow else {
            throw Qwen3ASREmbeddingError.sizeOverflow
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        } catch {
            throw Qwen3ASREmbeddingError.fileUnreadable(String(describing: error))
        }
        guard let fileSize = resourceValues.fileSize, fileSize >= 0 else {
            throw Qwen3ASREmbeddingError.fileUnreadable("file size metadata is unavailable")
        }
        let actualFileSize = UInt64(fileSize)
        guard actualFileSize == UInt64(expectedByteCount) else {
            throw Qwen3ASREmbeddingError.sizeMismatch(expected: expectedByteCount, actual: actualFileSize)
        }

        let mappedData: Data
        do {
            mappedData = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw Qwen3ASREmbeddingError.fileUnreadable(String(describing: error))
        }
        guard mappedData.count == expectedByteCount else {
            throw Qwen3ASREmbeddingError.sizeMismatch(expected: expectedByteCount, actual: UInt64(mappedData.count))
        }

        self.vocabSize = vocabSize
        self.hiddenSize = hiddenSize
        storage = mappedData
    }

    func row(_ id: Int64) throws -> [Float] {
        guard id >= 0, UInt64(id) < UInt64(vocabSize) else {
            throw Qwen3ASREmbeddingError.invalidTokenID(id)
        }

        let byteOffset = Int(id) * hiddenSize * 2
        return storage.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var result: [Float] = []
            result.reserveCapacity(hiddenSize)
            for column in 0..<hiddenSize {
                let offset = byteOffset + column * 2
                let halfBits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                result.append(Self.float(fromFloat16Bits: halfBits))
            }
            return result
        }
    }

    private static func float(fromFloat16Bits bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F)
        let fraction = UInt32(bits & 0x03FF)

        let floatBits: UInt32
        switch exponent {
        case 0:
            if fraction == 0 {
                floatBits = sign
            } else {
                let leadingBit = 31 - fraction.leadingZeroBitCount
                let unbiasedExponent = leadingBit - 24
                let normalizedFraction = fraction - (UInt32(1) << leadingBit)
                floatBits = sign
                    | (UInt32(unbiasedExponent + 127) << 23)
                    | (normalizedFraction << (23 - leadingBit))
            }
        case 0x1F:
            floatBits = sign | 0x7F80_0000 | (fraction << 13)
        default:
            floatBits = sign | (UInt32(exponent + 112) << 23) | (fraction << 13)
        }
        return Float(bitPattern: floatBits)
    }
}
