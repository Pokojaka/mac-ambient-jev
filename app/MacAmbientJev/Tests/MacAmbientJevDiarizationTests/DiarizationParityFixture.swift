import Foundation

enum DiarizationParityFixtureError: Error, CustomStringConvertible {
    case invalidFilename(String)
    case missingResource(String)
    case resourceSizeUnavailable(String)
    case resourceTooLarge(String, Int)
    case invalidTensor(field: String, reason: String)

    var description: String {
        switch self {
        case .invalidFilename(let name):
            return "Unrecognized diarization parity fixture filename: \(name)"
        case .missingResource(let name):
            return "Diarization parity fixture resource is missing: \(name)"
        case .resourceSizeUnavailable(let name):
            return "Could not determine the size of diarization parity fixture: \(name)"
        case .resourceTooLarge(let name, let size):
            return "Diarization parity fixture \(name) is \(size) bytes; maximum is 1048576 bytes"
        case .invalidTensor(let field, let reason):
            return "Invalid diarization parity tensor field \(field): \(reason)"
        }
    }
}

struct DiarizationParityMetadata: Decodable {
    let schemaVersion: Int
    let fluidAudioVersion: String
    let fluidAudioRevision: String
    let inputConstruction: String
    let comparisonRule: String
}

struct DiarizationParityTensor: Decodable {
    let dtype: String
    let shape: [Int]
    let littleEndianBase64: String

    func float32() throws -> [Float] {
        let bytes = try validatedBytes(expectedDtype: "float32", bytesPerElement: 4)
        let byteValues = [UInt8](bytes)
        let valueCount = byteValues.count / 4
        var values: [Float] = []
        values.reserveCapacity(valueCount)

        for valueIndex in 0..<valueCount {
            let offset = valueIndex * 4
            let bits = UInt32(byteValues[offset])
                | (UInt32(byteValues[offset + 1]) << 8)
                | (UInt32(byteValues[offset + 2]) << 16)
                | (UInt32(byteValues[offset + 3]) << 24)
            let value = Float(bitPattern: bits)
            guard value.isFinite else {
                throw DiarizationParityFixtureError.invalidTensor(
                    field: "littleEndianBase64",
                    reason: "float32 value at index \(valueIndex) is not finite"
                )
            }
            values.append(value)
        }
        return values
    }

    func float64() throws -> [Double] {
        let bytes = try validatedBytes(expectedDtype: "float64", bytesPerElement: 8)
        let byteValues = [UInt8](bytes)
        let valueCount = byteValues.count / 8
        var values: [Double] = []
        values.reserveCapacity(valueCount)

        for valueIndex in 0..<valueCount {
            let offset = valueIndex * 8
            let bits = UInt64(byteValues[offset])
                | (UInt64(byteValues[offset + 1]) << 8)
                | (UInt64(byteValues[offset + 2]) << 16)
                | (UInt64(byteValues[offset + 3]) << 24)
                | (UInt64(byteValues[offset + 4]) << 32)
                | (UInt64(byteValues[offset + 5]) << 40)
                | (UInt64(byteValues[offset + 6]) << 48)
                | (UInt64(byteValues[offset + 7]) << 56)
            let value = Double(bitPattern: bits)
            guard value.isFinite else {
                throw DiarizationParityFixtureError.invalidTensor(
                    field: "littleEndianBase64",
                    reason: "float64 value at index \(valueIndex) is not finite"
                )
            }
            values.append(value)
        }
        return values
    }

    func float64Matrix(nonfinite patches: [DiarizationNonfinitePatch]) throws -> [[Double]] {
        guard shape.count == 2 else {
            throw DiarizationParityFixtureError.invalidTensor(
                field: "shape",
                reason: "float64 matrix must have exactly two dimensions"
            )
        }
        guard shape[0] > 0, shape[1] > 0 else {
            throw DiarizationParityFixtureError.invalidTensor(
                field: "shape",
                reason: "float64 matrix dimensions must be positive"
            )
        }

        var values = try float64()
        var patchedIndices: Set<Int> = []
        for patch in patches {
            guard patch.index >= 0, patch.index < values.count else {
                throw DiarizationParityFixtureError.invalidTensor(
                    field: "nonfinite",
                    reason: "patch index \(patch.index) is outside the flattened matrix"
                )
            }
            guard patchedIndices.insert(patch.index).inserted else {
                throw DiarizationParityFixtureError.invalidTensor(
                    field: "nonfinite",
                    reason: "patch index \(patch.index) is duplicated"
                )
            }
            guard values[patch.index] == 0 else {
                throw DiarizationParityFixtureError.invalidTensor(
                    field: "nonfinite",
                    reason: "patch index \(patch.index) must contain base value 0"
                )
            }
            switch patch.kind {
            case .nan:
                values[patch.index] = .nan
            case .positiveInfinity:
                values[patch.index] = .infinity
            case .negativeInfinity:
                values[patch.index] = -.infinity
            }
        }

        let columns = shape[1]
        return (0..<shape[0]).map { row in
            Array(values[(row * columns)..<((row + 1) * columns)])
        }
    }

    private func validatedBytes(expectedDtype: String, bytesPerElement: Int) throws -> Data {
        guard dtype == expectedDtype else {
            throw DiarizationParityFixtureError.invalidTensor(
                field: "dtype",
                reason: "expected \(expectedDtype), got \(dtype)"
            )
        }
        guard !shape.isEmpty else {
            throw DiarizationParityFixtureError.invalidTensor(
                field: "shape",
                reason: "must contain at least one dimension"
            )
        }
        guard !shape.contains(where: { $0 < 0 }) else {
            throw DiarizationParityFixtureError.invalidTensor(
                field: "shape",
                reason: "dimensions must be nonnegative"
            )
        }

        var elementCount = 0
        if !shape.contains(0) {
            elementCount = 1
            for dimension in shape {
                let (product, overflow) = elementCount.multipliedReportingOverflow(by: dimension)
                guard !overflow else {
                    throw DiarizationParityFixtureError.invalidTensor(
                        field: "shape",
                        reason: "dimension product overflows Int"
                    )
                }
                elementCount = product
            }
        }
        let (expectedByteCount, byteCountOverflow) = elementCount.multipliedReportingOverflow(by: bytesPerElement)
        guard !byteCountOverflow else {
            throw DiarizationParityFixtureError.invalidTensor(
                field: "shape",
                reason: "byte size overflows Int"
            )
        }

        guard let bytes = Data(base64Encoded: littleEndianBase64, options: []),
              bytes.base64EncodedString() == littleEndianBase64 else {
            throw DiarizationParityFixtureError.invalidTensor(
                field: "littleEndianBase64",
                reason: "must be canonical standard base64"
            )
        }
        guard bytes.count == expectedByteCount else {
            throw DiarizationParityFixtureError.invalidTensor(
                field: "littleEndianBase64",
                reason: "decoded byte count is \(bytes.count), expected \(expectedByteCount) for shape \(shape)"
            )
        }
        return bytes
    }
}

struct DiarizationParameterFixture: Decodable {
    let metadata: DiarizationParityMetadata
    let numeric: [String: Double]
    let fixed: [String: String]
}

struct DiarizationReconstructionFixture: Decodable {
    let metadata: DiarizationParityMetadata
    let cases: [DiarizationReconstructionCase]
}

struct DiarizationReconstructionCase: Decodable {
    let name: String
    let construction: String
    let sampleCount: Int
    let clusterCount: Int
    let numFrames: Int
    let numSpeakers: Int
    let frameDuration: Double
    let chunkOffsets: DiarizationParityTensor
    let speakerWeights: DiarizationParityTensor
    let hardClusters: [[Int]]
    let expectedSpeakerIDs: [String]
    let expectedSegments: DiarizationParityTensor
}

struct DiarizationAHCFixture: Decodable {
    let metadata: DiarizationParityMetadata
    let cases: [DiarizationAHCCase]
}

struct DiarizationAHCCase: Decodable {
    let name: String
    let construction: String
    let threshold: Double
    let features: DiarizationParityTensor
    let expectedLabels: [Int]
    let inversion: DiarizationAHCInversion?
}

struct DiarizationAHCInversion: Decodable {
    let firstMergeDistance: Double
    let rootDistance: Double
    let monotoneLabels: [Int]
}

enum DiarizationNonfiniteKind: String, Decodable {
    case nan
    case positiveInfinity
    case negativeInfinity
}

struct DiarizationNonfinitePatch: Decodable {
    let index: Int
    let kind: DiarizationNonfiniteKind
}

struct DiarizationAssignmentFixture: Decodable {
    let metadata: DiarizationParityMetadata
    let scoreCases: [DiarizationAssignmentScoreCase]
    let exhaustiveBinary: [DiarizationAssignmentBinaryCase]
    let centroidCases: [DiarizationAssignmentCentroidCase]
    let embeddingCases: [DiarizationAssignmentEmbeddingCase]
}

struct DiarizationAssignmentScoreCase: Decodable {
    let name: String
    let construction: String
    let scores: DiarizationParityTensor
    let nonfinite: [DiarizationNonfinitePatch]
    let expectedAssignments: [Int]
}

struct DiarizationAssignmentBinaryCase: Decodable {
    let rows: Int
    let columns: Int
    let expectedAssignments: [[Int]]
}

struct DiarizationAssignmentCentroidCase: Decodable {
    let name: String
    let construction: String
    let trainingEmbeddings: DiarizationParityTensor
    let gamma: DiarizationParityTensor
    let pi: DiarizationParityTensor
    let expectedSourceClusterIndices: [Int]
    let expectedCentroids: DiarizationParityTensor
}

struct DiarizationAssignmentEmbeddingCase: Decodable {
    let name: String
    let construction: String
    let embeddings: DiarizationParityTensor
    let nonfinite: [DiarizationNonfinitePatch]
    let activeSlots: [Int]
    let centroids: DiarizationParityTensor
    let expectedAssignments: [Int]
}

enum DiarizationParityFixtures {
    static let filenames = ["parameters.json", "reconstruction.json", "ahc.json", "assignment.json"]

    static func data(named name: String) throws -> Data {
        guard filenames.contains(name) else {
            throw DiarizationParityFixtureError.invalidFilename(name)
        }
        guard let resourceDirectory = Bundle.module.resourceURL?.appendingPathComponent("Resources", isDirectory: true) else {
            throw DiarizationParityFixtureError.missingResource(name)
        }
        let url = resourceDirectory.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DiarizationParityFixtureError.missingResource(name)
        }
        guard let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw DiarizationParityFixtureError.resourceSizeUnavailable(name)
        }
        guard fileSize <= 1_048_576 else {
            throw DiarizationParityFixtureError.resourceTooLarge(name, fileSize)
        }
        let contents = try Data(contentsOf: url)
        guard contents.count <= 1_048_576 else {
            throw DiarizationParityFixtureError.resourceTooLarge(name, contents.count)
        }
        return contents
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data(named: name))
    }
}
