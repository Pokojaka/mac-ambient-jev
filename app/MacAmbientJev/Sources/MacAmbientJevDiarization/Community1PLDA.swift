import Foundation

/// Failures while decoding or evaluating the fixed Community-1 PLDA transform.
enum Community1PLDAError: Error, CustomStringConvertible {
    case invalidAsset(asset: String, reason: String)
    case invalidOrientation(String)
    case invalidEmbedding(String)
    case numericalFailure(String)

    var description: String {
        switch self {
        case let .invalidAsset(asset, reason):
            return "Invalid PLDA asset \(asset): \(reason)"
        case let .invalidOrientation(reason):
            return "Invalid PLDA coordinate orientation: \(reason)"
        case let .invalidEmbedding(reason):
            return "Invalid PLDA embedding: \(reason)"
        case let .numericalFailure(reason):
            return "PLDA numerical failure: \(reason)"
        }
    }
}

/// Eigenvalues and column eigenvectors of a real symmetric matrix.
struct Community1PLDAEigenSystem {
    let values: [Double]
    /// Row-major square matrix; eigenvectors occupy columns.
    let vectors: [Double]
    let relativeOffDiagonalResidual: Double
}

/// Fixed-asset decoder, pyannote VBx setup, and Core ML rho graph port.
struct Community1PLDA {
    let phi: [Double]
    let setupEigenvalues: [Double]
    let projectionRows: [[Double]]
    let relativeEigenResidual: Double
    let relativeOffDiagonalResidual: Double

    private let mean1: [Float]
    private let mean2: [Float]
    private let lda: [Float]
    private let mu: [Float]
    private let projection: [Float]
    private let sqrtSpectrum: [Float]

    init(pldaData: Data, xvectorData: Data, coordinateSigns: [Int]) throws {
        guard coordinateSigns.count == Community1Profile.rhoDimensions else {
            throw Community1PLDAError.invalidOrientation(
                "expected \(Community1Profile.rhoDimensions) signs, got \(coordinateSigns.count)"
            )
        }
        guard coordinateSigns.allSatisfy({ $0 == -1 || $0 == 1 }) else {
            throw Community1PLDAError.invalidOrientation("each coordinate sign must be -1 or 1")
        }

        let pldaTensors = try Community1PLDAJSON.decode(
            pldaData,
            asset: "plda-parameters.json",
            shapes: ["mu": [128], "psi": [128], "tr": [128, 128]]
        )
        let xvectorTensors = try Community1PLDAJSON.decode(
            xvectorData,
            asset: "xvector-transform.json",
            shapes: ["mean1": [256], "mean2": [128], "lda": [256, 128]]
        )

        let parsedMu = try Community1PLDAJSON.tensor("mu", in: pldaTensors, asset: "plda-parameters.json")
        let parsedPsi = try Community1PLDAJSON.tensor("psi", in: pldaTensors, asset: "plda-parameters.json")
        let rawTransform = try Community1PLDAJSON.tensor("tr", in: pldaTensors, asset: "plda-parameters.json")
        let parsedMean1 = try Community1PLDAJSON.tensor("mean1", in: xvectorTensors, asset: "xvector-transform.json")
        let parsedMean2 = try Community1PLDAJSON.tensor("mean2", in: xvectorTensors, asset: "xvector-transform.json")
        let parsedLDA = try Community1PLDAJSON.tensor("lda", in: xvectorTensors, asset: "xvector-transform.json")

        for (index, value) in parsedPsi.enumerated() where value <= 0 {
            throw Community1PLDAError.invalidAsset(
                asset: "plda-parameters.json",
                reason: "psi[\(index)] must be positive"
            )
        }

        let setup = try Community1PLDAMath.setup(
            rawTransform: rawTransform,
            psi: parsedPsi.map(Double.init),
            coordinateSigns: coordinateSigns
        )

        self.mean1 = parsedMean1
        self.mean2 = parsedMean2
        self.lda = parsedLDA
        self.mu = parsedMu
        self.phi = parsedPsi.map(Double.init)
        self.setupEigenvalues = setup.eigenvalues
        self.projectionRows = setup.rows
        self.relativeEigenResidual = setup.relativeEigenResidual
        self.relativeOffDiagonalResidual = setup.relativeOffDiagonalResidual
        self.projection = setup.projection
        self.sqrtSpectrum = setup.sqrtSpectrum
    }

    /// Mirrors pyannote-audio 4.0.0 `vbx_setup` preprocessing and PLDA transform math.
    /// FluidAudio's Swift `PLDATransform` delegates rho inference to the `PldaRho` Core ML graph
    /// (`PLDATransform.swift:24-26,149`); this portable path spells out its Float32 graph stages.
    /// Source: https://github.com/pyannote/pyannote-audio/blob/4.0.0/src/pyannote/audio/utils/vbx.py
    func rho(embedding: [Float]) throws -> [Double] {
        guard embedding.count == Community1Profile.embeddingDimensions else {
            throw Community1PLDAError.invalidEmbedding(
                "expected \(Community1Profile.embeddingDimensions) values, got \(embedding.count)"
            )
        }
        for (index, value) in embedding.enumerated() where !value.isFinite {
            throw Community1PLDAError.invalidEmbedding("value at index \(index) is not finite")
        }

        var firstCentered = [Float](repeating: 0, count: Community1Profile.embeddingDimensions)
        for index in firstCentered.indices {
            firstCentered[index] = try Self.checked(
                embedding[index] - mean1[index],
                stage: "mean1 centering"
            )
        }
        let firstNormalized = try Self.normalize(
            firstCentered,
            squaredNormFloor: Community1Profile.pldaFirstSquaredNormFloor,
            stage: "first L2 normalization"
        )

        var projected = try Self.linear(
            input: firstNormalized,
            weights: lda,
            inputWidth: Community1Profile.embeddingDimensions,
            outputWidth: Community1Profile.rhoDimensions,
            weightsAreOutputMajor: false,
            stage: "x-vector LDA"
        )
        for index in projected.indices {
            let scaled = try Self.checked(
                projected[index] * Community1Profile.pldaFirstTransformScale,
                stage: "sqrt(256) scale"
            )
            projected[index] = try Self.checked(scaled - mean2[index], stage: "mean2 centering")
        }

        let secondNormalized = try Self.normalize(
            projected,
            squaredNormFloor: Community1Profile.pldaSecondSquaredNormFloor,
            stage: "second L2 normalization"
        )
        var centered = [Float](repeating: 0, count: Community1Profile.rhoDimensions)
        for index in centered.indices {
            let scaled = try Self.checked(
                secondNormalized[index] * Community1Profile.pldaSecondTransformScale,
                stage: "sqrt(128) scale"
            )
            centered[index] = try Self.checked(scaled - mu[index], stage: "PLDA mean centering")
        }

        var result = try Self.linear(
            input: centered,
            weights: projection,
            inputWidth: Community1Profile.rhoDimensions,
            outputWidth: Community1Profile.rhoDimensions,
            weightsAreOutputMajor: true,
            stage: "setup projection"
        )
        for index in result.indices {
            result[index] = try Self.checked(
                result[index] * sqrtSpectrum[index],
                stage: "setup spectrum scale"
            )
        }
        return result.map(Double.init)
    }

    private static func normalize(_ vector: [Float], squaredNormFloor: Float, stage: String) throws -> [Float] {
        var squaredNorm: Float = 0
        for (index, value) in vector.enumerated() {
            let square = value * value
            guard square.isFinite else {
                throw Community1PLDAError.numericalFailure(
                    "non-finite Float during \(stage) square at \(index)"
                )
            }
            squaredNorm = squaredNorm + square
            guard squaredNorm.isFinite else {
                throw Community1PLDAError.numericalFailure("non-finite Float during \(stage) squared norm")
            }
        }
        let clippedSquaredNorm = min(max(squaredNorm, squaredNormFloor), Float.greatestFiniteMagnitude)
        let norm = try checked(sqrt(clippedSquaredNorm), stage: "\(stage) square root")
        guard norm > 0 else {
            throw Community1PLDAError.numericalFailure("\(stage) produced a nonpositive norm")
        }
        var normalized = [Float](repeating: 0, count: vector.count)
        for index in vector.indices {
            normalized[index] = try checked(vector[index] / norm, stage: "\(stage) division")
        }
        return normalized
    }

    /// Row-major weights are output-major, as in the Core ML linear operation.
    private static func linear(
        input: [Float],
        weights: [Float],
        inputWidth: Int,
        outputWidth: Int,
        weightsAreOutputMajor: Bool,
        stage: String
    ) throws -> [Float] {
        guard input.count == inputWidth, weights.count == inputWidth * outputWidth else {
            throw Community1PLDAError.numericalFailure("\(stage) matrix dimensions are inconsistent")
        }
        var output = [Float](repeating: 0, count: outputWidth)
        for row in 0..<outputWidth {
            var sum: Float = 0
            for column in 0..<inputWidth {
                let weightIndex = weightsAreOutputMajor ? row * inputWidth + column : column * outputWidth + row
                let product = input[column] * weights[weightIndex]
                guard product.isFinite else {
                    throw Community1PLDAError.numericalFailure("non-finite Float during \(stage) product")
                }
                sum = sum + product
                guard sum.isFinite else {
                    throw Community1PLDAError.numericalFailure("non-finite Float during \(stage) accumulation")
                }
            }
            output[row] = sum
        }
        return output
    }

    private static func checked(_ value: Float, stage: String) throws -> Float {
        guard value.isFinite else {
            throw Community1PLDAError.numericalFailure("non-finite Float during \(stage)")
        }
        return value
    }
}

private enum Community1PLDAJSON {
    private struct Envelope: Decodable {
        let tensors: [String: Tensor]
    }

    private struct Tensor: Decodable {
        let shape: [Int]
        let dtype: String
        let layout: String
        let data_base64: String
    }

    static func decode(_ data: Data, asset: String, shapes: [String: [Int]]) throws -> [String: [Float]] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw Community1PLDAError.invalidAsset(asset: asset, reason: "invalid JSON tensor envelope: \(error.localizedDescription)")
        }
        guard Set(envelope.tensors.keys) == Set(shapes.keys) else {
            let actual = envelope.tensors.keys.sorted().joined(separator: ", ")
            let expected = shapes.keys.sorted().joined(separator: ", ")
            throw Community1PLDAError.invalidAsset(
                asset: asset,
                reason: "tensor names must be exactly [\(expected)], got [\(actual)]"
            )
        }

        var decoded: [String: [Float]] = [:]
        for name in shapes.keys.sorted() {
            guard let tensor = envelope.tensors[name] else {
                throw Community1PLDAError.invalidAsset(asset: asset, reason: "missing tensor \(name)")
            }
            let expectedShape = shapes[name]!
            guard tensor.shape == expectedShape else {
                throw Community1PLDAError.invalidAsset(
                    asset: asset,
                    reason: "tensor \(name) shape must be \(expectedShape), got \(tensor.shape)"
                )
            }
            guard tensor.dtype == "float32" else {
                throw Community1PLDAError.invalidAsset(asset: asset, reason: "tensor \(name) dtype must be float32")
            }
            guard tensor.layout == "row-major" else {
                throw Community1PLDAError.invalidAsset(asset: asset, reason: "tensor \(name) layout must be row-major")
            }
            guard let bytes = Data(base64Encoded: tensor.data_base64), bytes.base64EncodedString() == tensor.data_base64 else {
                throw Community1PLDAError.invalidAsset(asset: asset, reason: "tensor \(name) has malformed or noncanonical base64")
            }
            let elementCount = expectedShape.reduce(1, *)
            guard bytes.count == elementCount * MemoryLayout<UInt32>.size else {
                throw Community1PLDAError.invalidAsset(
                    asset: asset,
                    reason: "tensor \(name) byte count must be \(elementCount * 4), got \(bytes.count)"
                )
            }
            var values = [Float](repeating: 0, count: elementCount)
            for index in values.indices {
                let offset = index * 4
                let bits = UInt32(bytes[offset])
                    | (UInt32(bytes[offset + 1]) << 8)
                    | (UInt32(bytes[offset + 2]) << 16)
                    | (UInt32(bytes[offset + 3]) << 24)
                let value = Float(bitPattern: bits)
                guard value.isFinite else {
                    throw Community1PLDAError.invalidAsset(
                        asset: asset,
                        reason: "tensor \(name)[\(index)] is not finite"
                    )
                }
                values[index] = value
            }
            decoded[name] = values
        }
        return decoded
    }

    static func tensor(_ name: String, in tensors: [String: [Float]], asset: String) throws -> [Float] {
        guard let value = tensors[name] else {
            throw Community1PLDAError.invalidAsset(asset: asset, reason: "missing tensor \(name)")
        }
        return value
    }
}

private enum Community1PLDAMath {
    fileprivate struct Setup {
        let eigenvalues: [Double]
        let rows: [[Double]]
        let projection: [Float]
        let sqrtSpectrum: [Float]
        let relativeEigenResidual: Double
        let relativeOffDiagonalResidual: Double
    }

    static func setup(rawTransform: [Float], psi: [Double], coordinateSigns: [Int]) throws -> Setup {
        // FluidAudio's Swift wrapper delegates inference to Core ML (`PLDATransform.swift:149`);
        // pyannote-audio 4.0.0 `vbx_setup` defines setup as W=(trᵀtr)⁻¹, B=(trᵀdiag(1/psi)tr)⁻¹,
        // followed by the generalized eigensolve eigh(B, W). Source: https://github.com/pyannote/pyannote-audio/blob/4.0.0/src/pyannote/audio/utils/vbx.py
        let dimension = Community1Profile.rhoDimensions
        guard rawTransform.count == dimension * dimension, psi.count == dimension else {
            throw Community1PLDAError.numericalFailure("setup input dimensions are inconsistent")
        }

        let transform = rawTransform.map(Double.init)
        let gramWithin = try gram(transform: transform, weights: nil, dimension: dimension, asset: "tr.T * tr")
        let inverseWithin = try inversePositiveDefinite(gramWithin, dimension: dimension, asset: "tr.T * tr")
        let inversePsi = try psi.map { value -> Double in
            guard value.isFinite, value > 0 else {
                throw Community1PLDAError.invalidAsset(asset: "plda-parameters.json", reason: "psi values must be positive and finite")
            }
            let result = 1.0 / value
            guard result.isFinite, result > 0 else {
                throw Community1PLDAError.invalidAsset(asset: "plda-parameters.json", reason: "psi reciprocal is not finite and positive")
            }
            return result
        }
        let gramBetween = try gram(transform: transform, weights: inversePsi, dimension: dimension, asset: "tr.T * diag(1/psi) * tr")
        let inverseBetween = try inversePositiveDefinite(gramBetween, dimension: dimension, asset: "tr.T * diag(1/psi) * tr")
        let lower = try cholesky(inverseWithin, dimension: dimension, asset: "W")

        let firstSolve = try solveLower(lower, rhs: inverseBetween, dimension: dimension)
        let secondSolve = try solveLower(lower, rhs: transpose(firstSolve, dimension: dimension), dimension: dimension)
        var whitened = transpose(secondSolve, dimension: dimension)
        for row in 0..<dimension {
            for column in row..<dimension {
                let value = (whitened[row * dimension + column] + whitened[column * dimension + row]) * 0.5
                guard value.isFinite else {
                    throw Community1PLDAError.numericalFailure("whitened setup matrix is not finite")
                }
                whitened[row * dimension + column] = value
                whitened[column * dimension + row] = value
            }
        }

        let eigen = try Community1PLDALinearAlgebra.symmetricEigen(matrix: whitened, dimension: dimension)
        var eigenvectors = try solveUpperFromLowerTranspose(
            lower,
            rhs: eigen.vectors,
            dimension: dimension
        )
        let eigenvalues = eigen.values
        for index in eigenvalues.indices where !eigenvalues[index].isFinite || eigenvalues[index] <= 0 {
            throw Community1PLDAError.invalidAsset(
                asset: "tr / psi setup",
                reason: "setup eigenvalue[\(index)] must be positive and finite"
            )
        }

        let residual = try generalizedEigenResidual(
            between: inverseBetween,
            within: inverseWithin,
            eigenvectors: eigenvectors,
            eigenvalues: eigenvalues,
            dimension: dimension
        )
        guard residual.isFinite, residual <= Community1Profile.pldaEigenRelativeTolerance else {
            throw Community1PLDAError.numericalFailure(
                "relative generalized eigen residual \(residual) exceeds \(Community1Profile.pldaEigenRelativeTolerance)"
            )
        }

        var rows = [[Double]](repeating: [Double](repeating: 0, count: dimension), count: dimension)
        for rowIndex in 0..<dimension {
            var row = [Double](repeating: 0, count: dimension)
            for coordinate in 0..<dimension {
                row[coordinate] = eigenvectors[coordinate * dimension + rowIndex]
            }
            var largestIndex = 0
            var largestMagnitude = -1.0
            for coordinate in 0..<dimension {
                let magnitude = abs(row[coordinate])
                guard magnitude.isFinite else {
                    throw Community1PLDAError.numericalFailure("generalized eigenvector is not finite")
                }
                if magnitude > largestMagnitude {
                    largestMagnitude = magnitude
                    largestIndex = coordinate
                }
            }
            let canonicalSign = row[largestIndex] < 0 ? -1.0 : 1.0
            let sign = canonicalSign * Double(coordinateSigns[rowIndex])
            for coordinate in row.indices {
                row[coordinate] *= sign
                guard row[coordinate].isFinite else {
                    throw Community1PLDAError.numericalFailure("signed generalized eigenvector is not finite")
                }
            }
            rows[rowIndex] = row
        }
        eigenvectors.removeAll(keepingCapacity: false)

        var flattenedProjection = [Float](repeating: 0, count: dimension * dimension)
        var sqrtSpectrum = [Float](repeating: 0, count: dimension)
        for row in 0..<dimension {
            let root = sqrt(eigenvalues[row])
            let roundedRoot = Float(root)
            guard root.isFinite, roundedRoot.isFinite, roundedRoot > 0 else {
                throw Community1PLDAError.numericalFailure("setup square-root spectrum is not representable as Float")
            }
            sqrtSpectrum[row] = roundedRoot
            for column in 0..<dimension {
                let rounded = Float(rows[row][column])
                guard rounded.isFinite else {
                    throw Community1PLDAError.numericalFailure("setup projection is not representable as Float")
                }
                flattenedProjection[row * dimension + column] = rounded
            }
        }
        return Setup(
            eigenvalues: eigenvalues,
            rows: rows,
            projection: flattenedProjection,
            sqrtSpectrum: sqrtSpectrum,
            relativeEigenResidual: residual,
            relativeOffDiagonalResidual: eigen.relativeOffDiagonalResidual
        )
    }

    private static func gram(transform: [Double], weights: [Double]?, dimension: Int, asset: String) throws -> [Double] {
        var result = [Double](repeating: 0, count: dimension * dimension)
        for row in 0..<dimension {
            for column in row..<dimension {
                var sum = 0.0
                for source in 0..<dimension {
                    let weight = weights?[source] ?? 1.0
                    sum += transform[source * dimension + row] * weight * transform[source * dimension + column]
                    guard sum.isFinite else {
                        throw Community1PLDAError.invalidAsset(asset: asset, reason: "matrix product is not finite")
                    }
                }
                result[row * dimension + column] = sum
                result[column * dimension + row] = sum
            }
        }
        return result
    }

    private static func inversePositiveDefinite(_ matrix: [Double], dimension: Int, asset: String) throws -> [Double] {
        let lower = try cholesky(matrix, dimension: dimension, asset: asset)
        var inverse = [Double](repeating: 0, count: dimension * dimension)
        for column in 0..<dimension {
            var unitColumn = [Double](repeating: 0, count: dimension)
            unitColumn[column] = 1
            let solution = try solveCholeskyVector(lower, rhs: unitColumn, dimension: dimension, asset: asset)
            for row in 0..<dimension {
                inverse[row * dimension + column] = solution[row]
            }
        }
        for row in 0..<dimension {
            for column in row..<dimension {
                let value = (inverse[row * dimension + column] + inverse[column * dimension + row]) * 0.5
                guard value.isFinite else {
                    throw Community1PLDAError.invalidAsset(asset: asset, reason: "inverse is not finite")
                }
                inverse[row * dimension + column] = value
                inverse[column * dimension + row] = value
            }
        }
        return inverse
    }

    private static func cholesky(_ matrix: [Double], dimension: Int, asset: String) throws -> [Double] {
        guard matrix.count == dimension * dimension else {
            throw Community1PLDAError.invalidAsset(asset: asset, reason: "matrix dimensions are inconsistent")
        }
        var lower = [Double](repeating: 0, count: dimension * dimension)
        for row in 0..<dimension {
            for column in 0...row {
                var value = matrix[row * dimension + column]
                for index in 0..<column {
                    value -= lower[row * dimension + index] * lower[column * dimension + index]
                }
                guard value.isFinite else {
                    throw Community1PLDAError.invalidAsset(asset: asset, reason: "matrix is not finite during Cholesky factorization")
                }
                if row == column {
                    guard value > 0 else {
                        throw Community1PLDAError.invalidAsset(asset: asset, reason: "matrix is singular or not positive definite")
                    }
                    lower[row * dimension + column] = sqrt(value)
                } else {
                    let quotient = value / lower[column * dimension + column]
                    guard quotient.isFinite else {
                        throw Community1PLDAError.invalidAsset(asset: asset, reason: "Cholesky factor is not finite")
                    }
                    lower[row * dimension + column] = quotient
                }
            }
        }
        return lower
    }

    private static func solveCholeskyVector(
        _ lower: [Double],
        rhs: [Double],
        dimension: Int,
        asset: String
    ) throws -> [Double] {
        var forward = [Double](repeating: 0, count: dimension)
        for row in 0..<dimension {
            var value = rhs[row]
            for column in 0..<row {
                value -= lower[row * dimension + column] * forward[column]
            }
            forward[row] = value / lower[row * dimension + row]
            guard forward[row].isFinite else {
                throw Community1PLDAError.invalidAsset(asset: asset, reason: "Cholesky solve is not finite")
            }
        }
        var solution = [Double](repeating: 0, count: dimension)
        for row in stride(from: dimension - 1, through: 0, by: -1) {
            var value = forward[row]
            for column in (row + 1)..<dimension {
                value -= lower[column * dimension + row] * solution[column]
            }
            solution[row] = value / lower[row * dimension + row]
            guard solution[row].isFinite else {
                throw Community1PLDAError.invalidAsset(asset: asset, reason: "Cholesky solve is not finite")
            }
        }
        return solution
    }

    private static func solveLower(_ lower: [Double], rhs: [Double], dimension: Int) throws -> [Double] {
        var solution = [Double](repeating: 0, count: dimension * dimension)
        for column in 0..<dimension {
            for row in 0..<dimension {
                var value = rhs[row * dimension + column]
                for index in 0..<row {
                    value -= lower[row * dimension + index] * solution[index * dimension + column]
                }
                value /= lower[row * dimension + row]
                guard value.isFinite else {
                    throw Community1PLDAError.numericalFailure("forward Cholesky solve is not finite")
                }
                solution[row * dimension + column] = value
            }
        }
        return solution
    }

    private static func solveUpperFromLowerTranspose(
        _ lower: [Double],
        rhs: [Double],
        dimension: Int
    ) throws -> [Double] {
        var solution = [Double](repeating: 0, count: dimension * dimension)
        for column in 0..<dimension {
            for row in stride(from: dimension - 1, through: 0, by: -1) {
                var value = rhs[row * dimension + column]
                for index in (row + 1)..<dimension {
                    value -= lower[index * dimension + row] * solution[index * dimension + column]
                }
                value /= lower[row * dimension + row]
                guard value.isFinite else {
                    throw Community1PLDAError.numericalFailure("generalized eigenvector solve is not finite")
                }
                solution[row * dimension + column] = value
            }
        }
        return solution
    }

    private static func generalizedEigenResidual(
        between: [Double],
        within: [Double],
        eigenvectors: [Double],
        eigenvalues: [Double],
        dimension: Int
    ) throws -> Double {
        var residualSquared = 0.0
        var betweenSquared = 0.0
        var eigenWithinSquared = 0.0
        for column in 0..<dimension {
            for row in 0..<dimension {
                var bValue = 0.0
                var wValue = 0.0
                for index in 0..<dimension {
                    let vectorValue = eigenvectors[index * dimension + column]
                    bValue += between[row * dimension + index] * vectorValue
                    wValue += within[row * dimension + index] * vectorValue
                }
                let scaledW = eigenvalues[column] * wValue
                let difference = bValue - scaledW
                residualSquared += difference * difference
                betweenSquared += bValue * bValue
                eigenWithinSquared += scaledW * scaledW
            }
        }
        guard residualSquared.isFinite, betweenSquared.isFinite, eigenWithinSquared.isFinite else {
            throw Community1PLDAError.numericalFailure("generalized eigen residual is not finite")
        }
        let denominator = sqrt(betweenSquared) + sqrt(eigenWithinSquared)
        guard denominator > 0, denominator.isFinite else {
            throw Community1PLDAError.numericalFailure("generalized eigen residual has a nonpositive scale")
        }
        return sqrt(residualSquared) / denominator
    }

    private static func transpose(_ matrix: [Double], dimension: Int) -> [Double] {
        var result = [Double](repeating: 0, count: matrix.count)
        for row in 0..<dimension {
            for column in 0..<dimension {
                result[column * dimension + row] = matrix[row * dimension + column]
            }
        }
        return result
    }
}

/// Deterministic cyclic Jacobi eigensolver exposed for focused synthetic tests.
enum Community1PLDALinearAlgebra {
    static func symmetricEigen(matrix: [Double], dimension: Int) throws -> Community1PLDAEigenSystem {
        let (elementCount, overflow) = dimension.multipliedReportingOverflow(by: dimension)
        guard !overflow, dimension > 0, matrix.count == elementCount else {
            throw Community1PLDAError.numericalFailure("symmetric eigensolver matrix dimensions are invalid")
        }
        guard matrix.allSatisfy(\.isFinite) else {
            throw Community1PLDAError.numericalFailure("symmetric eigensolver input is not finite")
        }

        var values = matrix
        for row in 0..<dimension {
            for column in row..<dimension {
                let average = (values[row * dimension + column] + values[column * dimension + row]) * 0.5
                guard average.isFinite else {
                    throw Community1PLDAError.numericalFailure("symmetric eigensolver symmetrization overflowed")
                }
                values[row * dimension + column] = average
                values[column * dimension + row] = average
            }
        }
        var vectors = [Double](repeating: 0, count: dimension * dimension)
        for index in 0..<dimension {
            vectors[index * dimension + index] = 1
        }

        var residual = try relativeOffDiagonal(values, dimension: dimension)
        var converged = residual <= Community1Profile.pldaEigenRelativeTolerance
        if !converged {
            for _ in 0..<Community1Profile.pldaEigenMaximumSweeps {
                values.withUnsafeMutableBufferPointer { a in
                    vectors.withUnsafeMutableBufferPointer { v in
                        for p in 0..<dimension {
                            for q in (p + 1)..<dimension {
                                let offDiagonal = a[p * dimension + q]
                                if offDiagonal == 0 {
                                    continue
                                }
                                let halfDifference = (a[q * dimension + q] - a[p * dimension + p]) * 0.5
                                let t: Double
                                if abs(halfDifference) > abs(offDiagonal) {
                                    let ratio = offDiagonal / halfDifference
                                    t = ratio / (1 + hypot(1, ratio))
                                } else {
                                    let tau = halfDifference / offDiagonal
                                    t = tau >= 0
                                        ? 1 / (tau + hypot(1, tau))
                                        : -1 / (-tau + hypot(1, tau))
                                }
                                let cosine = 1 / sqrt(1 + t * t)
                                let sine = t * cosine
                                let pp = a[p * dimension + p]
                                let qq = a[q * dimension + q]
                                a[p * dimension + p] = pp - t * offDiagonal
                                a[q * dimension + q] = qq + t * offDiagonal
                                a[p * dimension + q] = 0
                                a[q * dimension + p] = 0
                                for index in 0..<dimension where index != p && index != q {
                                    let ip = a[index * dimension + p]
                                    let iq = a[index * dimension + q]
                                    let newIP = cosine * ip - sine * iq
                                    let newIQ = sine * ip + cosine * iq
                                    a[index * dimension + p] = newIP
                                    a[p * dimension + index] = newIP
                                    a[index * dimension + q] = newIQ
                                    a[q * dimension + index] = newIQ
                                }
                                for row in 0..<dimension {
                                    let vp = v[row * dimension + p]
                                    let vq = v[row * dimension + q]
                                    v[row * dimension + p] = cosine * vp - sine * vq
                                    v[row * dimension + q] = sine * vp + cosine * vq
                                }
                            }
                        }
                    }
                }
                guard values.allSatisfy(\.isFinite), vectors.allSatisfy(\.isFinite) else {
                    throw Community1PLDAError.numericalFailure("Jacobi sweep produced a non-finite value")
                }
                residual = try relativeOffDiagonal(values, dimension: dimension)
                if residual <= Community1Profile.pldaEigenRelativeTolerance {
                    converged = true
                    break
                }
            }
        }
        guard converged else {
            throw Community1PLDAError.numericalFailure(
                "cyclic Jacobi eigensolver did not converge in \(Community1Profile.pldaEigenMaximumSweeps) sweeps; relative off-diagonal residual is \(residual)"
            )
        }

        let originalIndices = Array(0..<dimension)
        let sortedIndices = originalIndices.sorted { lhs, rhs in
            let left = values[lhs * dimension + lhs]
            let right = values[rhs * dimension + rhs]
            if left == right {
                return lhs < rhs
            }
            return left > right
        }
        var sortedValues = [Double](repeating: 0, count: dimension)
        var sortedVectors = [Double](repeating: 0, count: dimension * dimension)
        for (newColumn, oldColumn) in sortedIndices.enumerated() {
            sortedValues[newColumn] = values[oldColumn * dimension + oldColumn]
            for row in 0..<dimension {
                sortedVectors[row * dimension + newColumn] = vectors[row * dimension + oldColumn]
            }
        }
        return Community1PLDAEigenSystem(
            values: sortedValues,
            vectors: sortedVectors,
            relativeOffDiagonalResidual: residual
        )
    }

    private static func relativeOffDiagonal(_ matrix: [Double], dimension: Int) throws -> Double {
        var offDiagonalSquared = 0.0
        var totalSquared = 0.0
        for row in 0..<dimension {
            for column in 0..<dimension {
                let value = matrix[row * dimension + column]
                totalSquared += value * value
                if row != column {
                    offDiagonalSquared += value * value
                }
            }
        }
        guard offDiagonalSquared.isFinite, totalSquared.isFinite else {
            throw Community1PLDAError.numericalFailure("eigensolver residual calculation overflowed")
        }
        if totalSquared == 0 {
            return 0
        }
        return sqrt(offDiagonalSquared / totalSquared)
    }
}
