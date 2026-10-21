import Foundation
import Testing
@testable import MacAmbientJevDiarization

@Suite(.serialized) struct Community1PLDATests {
    @Test func committedAssetsMatchPinnedGraphAndSignedRhoFixtures() throws {
        let fixture = try DiarizationParityFixtures.load("plda-rho.json", as: DiarizationPLDAFixture.self)
        #expect(fixture.metadata.schemaVersion == 1)
        #expect(fixture.metadata.fluidAudioVersion == "0.15.8")
        #expect(fixture.metadata.fluidAudioRevision == "87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc")
        #expect(!fixture.metadata.inputConstruction.isEmpty)
        #expect(!fixture.metadata.comparisonRule.isEmpty)
        #expect(fixture.modelRevision == "df2625ac79a7ac6b65ad868fee6d80f320da4232")
        #expect(fixture.pldaSHA256 == "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f")
        #expect(fixture.xvectorSHA256 == "f7cd5cc16e63e2d89db052a23018ecfc47a311998ed1e9e39838fbac65048688")
        #expect(fixture.modelWeightsSHA256 == "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36")
        #expect(fixture.cases.count == 3)
        for item in fixture.cases {
            try #require(item.embeddings.shape.count == 2)
            try #require(item.embeddings.shape[1] == 256)
            try #require(item.expectedRho.shape == [item.embeddings.shape[0], 128])
        }
        #expect(fixture.cases.reduce(0) { $0 + $1.embeddings.shape[0] } == 27)

        let pldaData = try DiarizationParityFixtures.data(named: "plda-parameters.json")
        let xvectorData = try DiarizationParityFixtures.data(named: "xvector-transform.json")
        let pldaEnvelope = try JSONDecoder().decode(PLDATestAssetEnvelope.self, from: pldaData)
        let jsonPsi = try #require(pldaEnvelope.tensors["psi"])
        #expect(fixture.psi.dtype == "float64")
        #expect(fixture.psi.shape == [128])
        let fixturePsi = try fixture.psi.float64()
        let widenedJSONPsi = try jsonPsi.parityTensor().float32().map(Double.init)
        #expect(fixturePsi == widenedJSONPsi)

        try #require(fixture.referenceProjection.shape == [128, 128])
        try #require(fixture.referenceSqrtSpectrum.shape == [128])
        let referenceProjection = try fixture.referenceProjection.float32()
        let referenceSqrtSpectrum = try fixture.referenceSqrtSpectrum.float32()
        try #require(referenceProjection.count == 128 * 128)
        try #require(referenceSqrtSpectrum.count == 128)

        let coordinateSigns = try Community1Manifest.bundled().coordinateSigns
        let model = try Community1PLDA(
            pldaData: pldaData,
            xvectorData: xvectorData,
            coordinateSigns: coordinateSigns
        )
        #expect(model.phi == widenedJSONPsi)
        #expect(model.phi != model.setupEigenvalues)
        #expect(model.setupEigenvalues.count == 128)
        #expect(model.projectionRows.count == 128)
        #expect(model.projectionRows.allSatisfy { $0.count == 128 })
        #expect(model.relativeEigenResidual.isFinite)
        #expect(model.relativeEigenResidual <= 1e-12)
        #expect(model.relativeOffDiagonalResidual.isFinite)
        #expect(model.relativeOffDiagonalResidual <= 1e-12)
        #expect(model.setupEigenvalues.allSatisfy { $0 > 0 && $0.isFinite })
        for index in 1..<model.setupEigenvalues.count {
            #expect(model.setupEigenvalues[index - 1] >= model.setupEigenvalues[index])
        }

        for rowIndex in 0..<128 {
            let row = model.projectionRows[rowIndex]
            var largestCoordinate = 0
            var largestMagnitude = -1.0
            for coordinate in 0..<128 {
                let magnitude = abs(row[coordinate])
                if magnitude > largestMagnitude {
                    largestCoordinate = coordinate
                    largestMagnitude = magnitude
                }
                let expected = Double(referenceProjection[rowIndex * 128 + coordinate])
                #expect(abs(row[coordinate] - expected) <= 1e-5)
            }
            let observedSign = row[largestCoordinate] < 0 ? -1 : 1
            #expect(observedSign == coordinateSigns[rowIndex])
            let computedRoot = Float(sqrt(model.setupEigenvalues[rowIndex]))
            #expect(abs(Double(computedRoot) - Double(referenceSqrtSpectrum[rowIndex])) <= 1e-6)
        }

        for item in fixture.cases {
            #expect(item.embeddings.dtype == "float32")
            #expect(item.expectedRho.dtype == "float64")
            let embeddings = try item.embeddings.float32()
            let expectedRho = try item.expectedRho.float64()
            try #require(embeddings.count == item.embeddings.shape[0] * 256)
            try #require(expectedRho.count == item.embeddings.shape[0] * 128)

            var maximumAbsoluteError = 0.0
            for row in 0..<item.embeddings.shape[0] {
                let start = row * 256
                let rho = try model.rho(embedding: Array(embeddings[start..<(start + 256)]))
                for coordinate in 0..<128 {
                    let expected = expectedRho[row * 128 + coordinate]
                    let absoluteError = abs(rho[coordinate] - expected)
                    maximumAbsoluteError = max(maximumAbsoluteError, absoluteError)
                    #expect(absoluteError <= 1e-4, "\(item.name)[\(row),\(coordinate)] signed rho error was \(absoluteError)")
                }
            }
            print("PLDA parity \(item.name): max absolute signed rho error = \(maximumAbsoluteError)")
        }
    }

    @Test func symmetricEigenIsDeterministicAndChecksResiduals() throws {
        let matrix = [
            2.0, 1.0, 0.0,
            1.0, 2.0, 0.0,
            0.0, 0.0, 0.5,
        ]
        let first = try Community1PLDALinearAlgebra.symmetricEigen(matrix: matrix, dimension: 3)
        let second = try Community1PLDALinearAlgebra.symmetricEigen(matrix: matrix, dimension: 3)
        #expect(first.values.count == 3)
        #expect(abs(first.values[0] - 3) <= 1e-12)
        #expect(abs(first.values[1] - 1) <= 1e-12)
        #expect(abs(first.values[2] - 0.5) <= 1e-12)
        #expect(first.values[0] >= first.values[1] && first.values[1] >= first.values[2])
        #expect(first.values.map(\.bitPattern) == second.values.map(\.bitPattern))
        #expect(first.vectors.map(\.bitPattern) == second.vectors.map(\.bitPattern))
        #expect(first.relativeOffDiagonalResidual <= Community1Profile.pldaEigenRelativeTolerance)
        for column in 0..<3 {
            for row in 0..<3 {
                var product = 0.0
                for index in 0..<3 {
                    product += matrix[row * 3 + index] * first.vectors[index * 3 + column]
                }
                #expect(abs(product - first.values[column] * first.vectors[row * 3 + column]) <= 1e-12)
            }
        }
        for lhs in 0..<3 {
            for rhs in 0..<3 {
                var dot = 0.0
                for row in 0..<3 {
                    dot += first.vectors[row * 3 + lhs] * first.vectors[row * 3 + rhs]
                }
                #expect(abs(dot - (lhs == rhs ? 1.0 : 0.0)) <= 1e-12)
            }
        }

        let tied = try Community1PLDALinearAlgebra.symmetricEigen(
            matrix: [2, 0, 0, 0, 2, 0, 0, 0, 1],
            dimension: 3
        )
        #expect(tied.values == [2, 2, 1])
        #expect(tied.vectors == [1, 0, 0, 0, 1, 0, 0, 0, 1])

        let one = try Community1PLDALinearAlgebra.symmetricEigen(matrix: [7], dimension: 1)
        #expect(one.values == [7])
        #expect(one.vectors == [1])
        let zero = try Community1PLDALinearAlgebra.symmetricEigen(matrix: [0, 0, 0, 0], dimension: 2)
        #expect(zero.values == [0, 0])
        #expect(zero.vectors == [1, 0, 0, 1])

        #expect(Community1Profile.pldaEigenMaximumSweeps == 64)
        #expect(Community1Profile.pldaEigenRelativeTolerance == 1e-12)
        #expect(throws: Community1PLDAError.self) {
            _ = try Community1PLDALinearAlgebra.symmetricEigen(matrix: [], dimension: 0)
        }
        #expect(throws: Community1PLDAError.self) {
            _ = try Community1PLDALinearAlgebra.symmetricEigen(matrix: [], dimension: Int.max)
        }
        #expect(throws: Community1PLDAError.self) {
            _ = try Community1PLDALinearAlgebra.symmetricEigen(matrix: [.infinity], dimension: 1)
        }
        #expect(throws: Community1PLDAError.self) {
            _ = try Community1PLDALinearAlgebra.symmetricEigen(
                matrix: [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude,
                         Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude],
                dimension: 2
            )
        }
    }

    @Test func syntheticIdentityAssetsOrientRowsAndRhoByRequestedSigns() throws {
        let dimension = 128
        let signs = (0..<dimension).map { $0.isMultiple(of: 2) ? 1 : -1 }
        let psi = (0..<dimension).map { Float(dimension - $0) }
        let means1 = [Float](repeating: 0, count: 256)
        let means2 = [Float](repeating: 0, count: dimension)
        let meansPLDA = [Float](repeating: 0, count: dimension)
        let lda = identityLDA(scale: 1)
        let assets = try syntheticAssets(
            tr: identityMatrix(dimension),
            psi: psi,
            mean1: means1,
            mean2: means2,
            lda: lda,
            mu: meansPLDA
        )
        let model = try Community1PLDA(pldaData: assets.plda, xvectorData: assets.xvector, coordinateSigns: signs)
        for index in 0..<dimension {
            #expect(abs(model.setupEigenvalues[index] - Double(psi[index])) <= 1e-12)
        }
        for index in 0..<dimension {
            for coordinate in 0..<dimension {
                let expected = coordinate == index ? Double(signs[index]) : 0
                #expect(abs(model.projectionRows[index][coordinate] - expected) <= 1e-15)
            }
        }

        var unitEmbedding = [Float](repeating: 0, count: 256)
        unitEmbedding[0] = 1
        let rho = try model.rho(embedding: unitEmbedding)
        let expectedUnitRho = Double(sqrt(Float(128)) * sqrt(Float(128)))
        #expect(rho[0] == Double(signs[0]) * expectedUnitRho)
        for coordinate in 1..<dimension {
            #expect(rho[coordinate] == 0)
        }

        let flipped = try Community1PLDA(
            pldaData: assets.plda,
            xvectorData: assets.xvector,
            coordinateSigns: signs.map { -$0 }
        )
        let flippedRho = try flipped.rho(embedding: unitEmbedding)
        #expect(flippedRho == rho.map { -$0 })
        #expect(throws: Community1PLDAError.self) {
            _ = try model.rho(embedding: Array(repeating: 0, count: 255))
        }
        var nonfiniteEmbedding = [Float](repeating: 0, count: 256)
        nonfiniteEmbedding[0] = .nan
        #expect(throws: Community1PLDAError.self) {
            _ = try model.rho(embedding: nonfiniteEmbedding)
        }
        nonfiniteEmbedding[0] = .infinity
        #expect(throws: Community1PLDAError.self) {
            _ = try model.rho(embedding: nonfiniteEmbedding)
        }
        #expect(throws: Community1PLDAError.self) {
            _ = try model.rho(embedding: Array(repeating: Float.greatestFiniteMagnitude, count: 256))
        }
    }

    @Test func syntheticExactTieUsesLowestCoordinateForRequestedOrientation() throws {
        let dimension = 128
        var transform = identityMatrix(dimension)
        transform[0 * dimension + 0] = 1
        transform[0 * dimension + 1] = -1
        transform[1 * dimension + 0] = 1
        transform[1 * dimension + 1] = 1
        let signs = [-1] + Array(repeating: 1, count: dimension - 1)
        let assets = try syntheticAssets(
            tr: transform,
            psi: (0..<dimension).map { Float(dimension - $0) },
            mean1: [Float](repeating: 0, count: 256),
            mean2: [Float](repeating: 0, count: dimension),
            lda: identityLDA(scale: 1),
            mu: [Float](repeating: 0, count: dimension)
        )
        let model = try Community1PLDA(pldaData: assets.plda, xvectorData: assets.xvector, coordinateSigns: signs)
        let firstRow = model.projectionRows[0]
        #expect(abs(abs(firstRow[0]) - abs(firstRow[1])) <= 1e-15)
        #expect(firstRow[0] < 0)
    }

    @Test func syntheticFirstAndSecondNormalizationFloorsMatchFloatGraph() throws {
        let dimension = 128
        let psi = (0..<dimension).map { Float(dimension - $0) }
        let signs = Array(repeating: 1, count: dimension)
        let tinyScale = Float(bitPattern: 0x33800000)
        let tinyLDA = identityLDA(scale: tinyScale)
        let firstAssets = try syntheticAssets(
            tr: identityMatrix(dimension),
            psi: psi,
            mean1: [Float](repeating: 0, count: 256),
            mean2: [Float](repeating: 0, count: dimension),
            lda: tinyLDA,
            mu: [Float](repeating: 0, count: dimension)
        )
        let firstModel = try Community1PLDA(
            pldaData: firstAssets.plda,
            xvectorData: firstAssets.xvector,
            coordinateSigns: signs
        )
        #expect(tinyScale.isFinite)
        let zeroRho = try firstModel.rho(embedding: [Float](repeating: 0, count: 256))
        #expect(zeroRho.allSatisfy { $0.isFinite })
        #expect(zeroRho.allSatisfy { $0 == 0 })
        for delta in [Float(0.5e-6), Float(1e-6), Float(2e-6)] {
            var embedding = [Float](repeating: 0, count: 256)
            embedding[0] = delta
            let firstNorm = sqrt(max(delta * delta, Float(1e-12)))
            let firstNormalized = delta / firstNorm
            let projected = (firstNormalized * tinyScale) * Float(16)
            let secondNorm = sqrt(max(projected * projected, Float(1e-12)))
            let expected = ((projected / secondNorm) * sqrt(Float(128))) * sqrt(Float(128))
            let rho = try firstModel.rho(embedding: embedding)
            #expect(rho[0] == Double(expected))
            for coordinate in 1..<dimension {
                #expect(rho[coordinate] == 0)
            }
        }

        var secondMean = [Float](repeating: 0, count: dimension)
        secondMean[0] = 16
        let secondAssets = try syntheticAssets(
            tr: identityMatrix(dimension),
            psi: psi,
            mean1: [Float](repeating: 0, count: 256),
            mean2: secondMean,
            lda: identityLDA(scale: 1),
            mu: [Float](repeating: 0, count: dimension)
        )
        let secondModel = try Community1PLDA(
            pldaData: secondAssets.plda,
            xvectorData: secondAssets.xvector,
            coordinateSigns: signs
        )
        for delta in [Float(0.5e-6), Float(1e-6), Float(2e-6)] {
            var embedding = [Float](repeating: 0, count: 256)
            embedding[0] = 1
            embedding[1] = delta / Float(16)
            let firstSquaredNorm = Float(1) + embedding[1] * embedding[1]
            let firstNorm = sqrt(max(firstSquaredNorm, Float(1e-12)))
            let firstNormalized0 = Float(1) / firstNorm
            let firstNormalized1 = embedding[1] / firstNorm
            let centered0 = (firstNormalized0 * Float(16)) - Float(16)
            let centered1 = firstNormalized1 * Float(16)
            let secondSquaredNorm = centered0 * centered0 + centered1 * centered1
            let secondNorm = sqrt(max(secondSquaredNorm, Float(1e-12)))
            let secondNormalized1 = centered1 / secondNorm
            let expected = ((secondNormalized1 * sqrt(Float(128))) * sqrt(Float(127)))
            let rho = try secondModel.rho(embedding: embedding)
            #expect(rho[1] == Double(expected))
            #expect(rho[0] == 0)
        }
    }

    @Test func invalidAssetsAndCoordinateOrientationsFailBeforeSetup() throws {
        let dimension = 128
        let valid = try syntheticAssets(
            tr: identityMatrix(dimension),
            psi: (0..<dimension).map { Float(dimension - $0) },
            mean1: [Float](repeating: 0, count: 256),
            mean2: [Float](repeating: 0, count: dimension),
            lda: identityLDA(scale: 1),
            mu: [Float](repeating: 0, count: dimension)
        )
        let signs = Array(repeating: 1, count: dimension)
        #expect(throws: Community1PLDAError.self) {
            _ = try Community1PLDA(pldaData: valid.plda, xvectorData: valid.xvector, coordinateSigns: [])
        }
        var invalidSign = signs
        invalidSign[0] = 0
        #expect(throws: Community1PLDAError.self) {
            _ = try Community1PLDA(pldaData: valid.plda, xvectorData: valid.xvector, coordinateSigns: invalidSign)
        }

        let invalidPayloadCases: [(String, Data, Data)] = [
            ("empty malformed JSON", Data(), valid.xvector),
            ("missing tensors envelope", try mutateAsset(valid.plda, mutation: .removeTopLevel("tensors")), valid.xvector),
            ("missing psi tensor", try mutateAsset(valid.plda, mutation: .removeTensor("psi")), valid.xvector),
            ("missing dtype field", try mutateAsset(valid.plda, mutation: .removeField(tensor: "mu", field: "dtype")), valid.xvector),
            ("wrong shape", try mutateAsset(valid.plda, mutation: .setField(tensor: "tr", field: "shape", value: [128, 127])), valid.xvector),
            ("wrong rank", try mutateAsset(valid.plda, mutation: .setField(tensor: "tr", field: "shape", value: [16_384])), valid.xvector),
            ("negative shape", try mutateAsset(valid.plda, mutation: .setField(tensor: "tr", field: "shape", value: [128, -128])), valid.xvector),
            ("oversize shape", try mutateAsset(valid.plda, mutation: .setField(tensor: "tr", field: "shape", value: [Int.max, 128])), valid.xvector),
            ("wrong dtype", try mutateAsset(valid.plda, mutation: .setField(tensor: "mu", field: "dtype", value: "float64")), valid.xvector),
            ("wrong layout", try mutateAsset(valid.plda, mutation: .setField(tensor: "mu", field: "layout", value: "column-major")), valid.xvector),
            ("invalid base64", try mutateAsset(valid.plda, mutation: .setField(tensor: "mu", field: "data_base64", value: "%%%")), valid.xvector),
            ("wrong payload byte count", try mutateAsset(valid.plda, mutation: .setField(tensor: "mu", field: "data_base64", value: Data().base64EncodedString())), valid.xvector),
            ("NaN payload", try mutateAsset(valid.plda, mutation: .setField(tensor: "psi", field: "data_base64", value: float32Base64([Float(bitPattern: 0x7fc00000)] + Array(repeating: 128, count: 127)))), valid.xvector),
            ("positive infinity payload", try mutateAsset(valid.plda, mutation: .setField(tensor: "psi", field: "data_base64", value: float32Base64([Float(bitPattern: 0x7f800000)] + Array(repeating: 128, count: 127)))), valid.xvector),
            ("negative infinity payload", try mutateAsset(valid.plda, mutation: .setField(tensor: "psi", field: "data_base64", value: float32Base64([Float(bitPattern: 0xff800000)] + Array(repeating: 128, count: 127)))), valid.xvector),
            ("zero psi", try mutateAsset(valid.plda, mutation: .setField(tensor: "psi", field: "data_base64", value: float32Base64([0] + Array(repeating: 128, count: 127)))), valid.xvector),
            ("negative psi", try mutateAsset(valid.plda, mutation: .setField(tensor: "psi", field: "data_base64", value: float32Base64([-1] + Array(repeating: 128, count: 127)))), valid.xvector),
            ("singular transform", try mutateAsset(valid.plda, mutation: .setField(tensor: "tr", field: "data_base64", value: float32Base64(Array(repeating: 0, count: dimension * dimension)))), valid.xvector),
            ("missing xvector tensor", valid.plda, try mutateAsset(valid.xvector, mutation: .removeTensor("lda"))),
            ("xvector wrong rank", valid.plda, try mutateAsset(valid.xvector, mutation: .setField(tensor: "mean1", field: "shape", value: [256, 1]))),
        ]
        for (name, pldaData, xvectorData) in invalidPayloadCases {
            #expect(throws: Community1PLDAError.self, "\(name) must be rejected") {
                _ = try Community1PLDA(pldaData: pldaData, xvectorData: xvectorData, coordinateSigns: signs)
            }
        }
    }
}

private struct PLDATestAssetEnvelope: Decodable {
    let tensors: [String: PLDATestTensor]
}

private struct PLDATestTensor: Decodable {
    let dtype: String
    let shape: [Int]
    let layout: String
    let data_base64: String

    func parityTensor() -> DiarizationParityTensor {
        DiarizationParityTensor(dtype: dtype, shape: shape, littleEndianBase64: data_base64)
    }
}

private enum PLDATestAssetMutation {
    case removeTopLevel(String)
    case removeTensor(String)
    case removeField(tensor: String, field: String)
    case setField(tensor: String, field: String, value: Any)
}

private func syntheticAssets(
    tr: [Float],
    psi: [Float],
    mean1: [Float],
    mean2: [Float],
    lda: [Float],
    mu: [Float]
) throws -> (plda: Data, xvector: Data) {
    let plda = try encodePLDAAsset(tensors: [
        "tr": (shape: [128, 128], values: tr),
        "psi": (shape: [128], values: psi),
        "mu": (shape: [128], values: mu),
    ])
    let xvector = try encodePLDAAsset(tensors: [
        "mean1": (shape: [256], values: mean1),
        "mean2": (shape: [128], values: mean2),
        "lda": (shape: [256, 128], values: lda),
    ])
    return (plda, xvector)
}

private func encodePLDAAsset(tensors: [String: (shape: [Int], values: [Float])]) throws -> Data {
    var encodedTensors: [String: [String: Any]] = [:]
    for (name, tensor) in tensors {
        encodedTensors[name] = [
            "shape": tensor.shape,
            "dtype": "float32",
            "layout": "row-major",
            "data_base64": float32Base64(tensor.values),
        ]
    }
    return try JSONSerialization.data(withJSONObject: ["tensors": encodedTensors], options: [.sortedKeys])
}

private func float32Base64(_ values: [Float]) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(values.count * 4)
    for value in values {
        let bits = value.bitPattern
        bytes.append(UInt8(truncatingIfNeeded: bits))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 16))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 24))
    }
    return Data(bytes).base64EncodedString()
}

private func identityMatrix(_ dimension: Int) -> [Float] {
    var matrix = [Float](repeating: 0, count: dimension * dimension)
    for index in 0..<dimension {
        matrix[index * dimension + index] = 1
    }
    return matrix
}

private func identityLDA(scale: Float) -> [Float] {
    var matrix = [Float](repeating: 0, count: 256 * 128)
    for index in 0..<128 {
        matrix[index * 128 + index] = scale
    }
    return matrix
}

private func mutateAsset(_ data: Data, mutation: PLDATestAssetMutation) throws -> Data {
    let decoded = try JSONSerialization.jsonObject(with: data)
    guard var root = decoded as? [String: Any] else {
        throw NSError(domain: "Community1PLDATests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic JSON root was not an object"])
    }
    switch mutation {
    case .removeTopLevel(let field):
        root.removeValue(forKey: field)
    case .removeTensor(let name):
        guard let tensorObject = root["tensors"] as? [String: Any] else {
            throw NSError(domain: "Community1PLDATests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Synthetic tensor envelope was missing"])
        }
        var tensors = tensorObject
        tensors.removeValue(forKey: name)
        root["tensors"] = tensors
    case .removeField(let tensorName, let field):
        guard let tensorObject = root["tensors"] as? [String: Any],
              let value = tensorObject[tensorName] as? [String: Any] else {
            throw NSError(domain: "Community1PLDATests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Synthetic tensor was missing"])
        }
        var tensor = value
        tensor.removeValue(forKey: field)
        var tensors = tensorObject
        tensors[tensorName] = tensor
        root["tensors"] = tensors
    case .setField(let tensorName, let field, let value):
        guard let tensorObject = root["tensors"] as? [String: Any],
              let tensorValue = tensorObject[tensorName] as? [String: Any] else {
            throw NSError(domain: "Community1PLDATests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Synthetic tensor was missing"])
        }
        var tensor = tensorValue
        tensor[field] = value
        var tensors = tensorObject
        tensors[tensorName] = tensor
        root["tensors"] = tensors
    }
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}
