#if os(macOS)
import Foundation
import Testing
@testable import FluidAudio

private struct AHCParityInput {
    let name: String
    let construction: String
    let vectors: [[Double]]
    let labelAssertion: AHCParityLabelAssertion
    let inversion: AHCParityInversion?
}

private enum AHCParityLabelAssertion {
    case exact([Int])
    case atLeastTwoClusters
    case centroidInversion
}

private struct AHCParityInversion {
    let firstMergeDistance: Double
    let rootDistance: Double
    let monotoneLabels: [Int]
}

private struct AHCParitySplitMix64 {
    var state: UInt64

    mutating func nextSignedUniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        let result = value ^ (value >> 31)
        return 2 * Double(result >> 11) / 9_007_199_254_740_992 - 1
    }
}

extension DiarizationParityFixtureTests {
    @Test
    func ahcMatchesFluidAudio() throws {
        let config = try DiarizationParityOracle.config()
        let threshold = config.clustering.threshold
        try #require(threshold == 0.6, "The pinned validated clustering threshold must be 0.6")

        let separated = try separatedGroupsInput()
        let angularChain = angularChainInput()
        let thresholdPairs = try thresholdPairsInput()
        let centroidInversion = try centroidInversionInput()
        let inputs = [separated, angularChain, thresholdPairs, centroidInversion]

        try validateUnitVectors(separated.vectors)
        try validateUnitVectors(angularChain.vectors)
        try validateUnitVectors(thresholdPairs.vectors)
        try validateUnitVectors(centroidInversion.vectors)

        let adjacentChainDistances = try zip(angularChain.vectors, angularChain.vectors.dropFirst())
            .map { try euclideanDistance($0.0, $0.1) }
        try #require(
            adjacentChainDistances.allSatisfy { $0 < threshold },
            "Angular-chain adjacent chords must be below the threshold"
        )
        try #require(
            try euclideanDistance(angularChain.vectors[0], angularChain.vectors[3]) > threshold,
            "Angular-chain endpoint chord must exceed the threshold"
        )

        let firstPairDistance = try euclideanDistance(thresholdPairs.vectors[0], thresholdPairs.vectors[1])
        let secondPairDistance = try euclideanDistance(thresholdPairs.vectors[2], thresholdPairs.vectors[3])
        try #require(firstPairDistance < threshold, "First threshold-pair chord must be below the threshold")
        try #require(secondPairDistance > threshold, "Second threshold-pair chord must exceed the threshold")

        let inversion = try #require(centroidInversion.inversion)
        try #require(
            inversion.firstMergeDistance > threshold,
            "Inversion descendant merge must exceed the threshold"
        )
        try #require(inversion.rootDistance < threshold, "Inversion root must be below the threshold")
        try #require(
            inversion.rootDistance < inversion.firstMergeDistance,
            "Inversion root must be below its descendant merge"
        )

        var fixtureCases: [[String: Any]] = []
        fixtureCases.reserveCapacity(inputs.count)
        for input in inputs {
            let labels = AHCClustering().cluster(
                embeddingFeatures: input.vectors,
                threshold: threshold
            )
            try #require(
                labels.count == input.vectors.count,
                "FluidAudio returned a label count that does not match \(input.name)"
            )

            switch input.labelAssertion {
            case .exact(let expected):
                try #require(labels == expected, "Unexpected FluidAudio AHC labels for \(input.name)")
            case .atLeastTwoClusters:
                try #require(Set(labels).count >= 2, "Angular-chain must remain in at least two clusters")
            case .centroidInversion:
                try #require(
                    labels == [0, 0, 0],
                    "FluidAudio AHC must merge the centroid-inversion witness into one cluster; refusing to write a non-discriminating fixture"
                )
            }

            let pointCount = input.vectors.count
            let dimension = try requiredDimension(input.vectors, caseName: input.name)
            let flattened = input.vectors.flatMap { $0 }
            if let inversion = input.inversion {
                try #require(pointCount == 3 && dimension == 3, "Inversion witness requires three stored 3D vectors")
                let storedV0 = Array(flattened[0..<dimension])
                let storedV1 = Array(flattened[dimension..<(2 * dimension)])
                let storedV2 = Array(flattened[(2 * dimension)..<(3 * dimension)])
                let storedCentroid = zip(storedV0, storedV1).map { ($0.0 + $0.1) / 2 }
                let recomputedFirstMergeDistance = try euclideanDistance(storedV0, storedV1)
                let recomputedRootDistance = try euclideanDistance(storedCentroid, storedV2)
                try #require(
                    abs(inversion.firstMergeDistance - recomputedFirstMergeDistance) <= 1e-12,
                    "Stored-coordinate first-merge witness must agree within 1e-12"
                )
                try #require(
                    abs(inversion.rootDistance - recomputedRootDistance) <= 1e-12,
                    "Stored-coordinate root witness must agree within 1e-12"
                )
            }
            var fixtureCase: [String: Any] = [
                "name": input.name,
                "construction": input.construction,
                "threshold": threshold,
                "features": try DiarizationParityOracle.tensor(flattened, shape: [pointCount, dimension]),
                "expectedLabels": labels,
            ]
            if let inversion = input.inversion {
                fixtureCase["inversion"] = [
                    "firstMergeDistance": inversion.firstMergeDistance,
                    "rootDistance": inversion.rootDistance,
                    "monotoneLabels": inversion.monotoneLabels,
                ]
            }
            fixtureCases.append(fixtureCase)
        }

        let fixture: [String: Any] = [
            "metadata": DiarizationParityOracle.metadata(
                inputConstruction: "Four deterministic cases in fixed order: separated-groups, angular-chain, threshold-pairs, centroid-inversion. All vectors are constructed in Double precision; rows are validated finite, nonzero, dimension-consistent, and unit L2 norm within 1e-12. The randomized case uses SplitMix64 seed 0xC011_0000_0000_0001 and transitions state += 0x9E3779B97F4A7C15, z=(z^(z>>30))*0xBF58476D1CE4E5B9, z=(z^(z>>27))*0x94D049BB133111EB, result=z^(z>>31), with UInt64 wrapping arithmetic; signed uniform is 2*Double(result>>11)/9007199254740992-1. Generation loops are group outer 0..<3, row inner 0..<4, coordinate inner 0..<4, with one-hot group centers plus 0.01 times signed-uniform coordinate jitter, followed by explicit Double L2 normalization. Other cases use analytic unit-circle/unit-sphere constructions, with formulas documented per case.",
                comparisonRule: "For all cases, expectedLabels are obtained exclusively from FluidAudio AHCClustering().cluster(embeddingFeatures:threshold:) using the validated config.clustering.threshold (0.6); labels compare exactly after FluidAudio's first-seen remapping. Features are float64 tensors [points,dimensions], with their little-endian IEEE-754 bit payload compared byte-for-byte through the canonical generated JSON. The inversion witness is recomputed from stored vector coordinates using Double scalar squares and must agree within 1e-12; monotoneLabels is the exact comparison label vector [0,1,2]. All other fields and metadata compare exactly; no linkage values are exposed or inferred."
            ),
            "cases": fixtureCases,
        ]
        try DiarizationParityOracle.checkOrWrite(fixture, named: "ahc.json")
    }
}

private func separatedGroupsInput() throws -> AHCParityInput {
    var generator = AHCParitySplitMix64(state: 0xC011_0000_0000_0001)
    var vectors: [[Double]] = []
    vectors.reserveCapacity(12)
    for group in 0..<3 {
        for _ in 0..<4 {
            var vector: [Double] = []
            vector.reserveCapacity(4)
            for coordinate in 0..<4 {
                let center = coordinate == group ? 1.0 : 0.0
                vector.append(center + 0.01 * generator.nextSignedUniform())
            }
            vectors.append(try l2Normalized(vector, context: "separated-groups"))
        }
    }
    return AHCParityInput(
        name: "separated-groups",
        construction: "Twelve 4D vectors. Seed SplitMix64 state=0xC011_0000_0000_0001; each draw advances state with wrapping +=0x9E3779B97F4A7C15, then z=(z^(z>>30)) wrapping-multiplied by 0xBF58476D1CE4E5B9, z=(z^(z>>27)) wrapping-multiplied by 0x94D049BB133111EB, and returns z^(z>>31). Map each result to signed uniform 2*Double(result>>11)/9007199254740992-1. Loop order is group outer 0..<3, row inner 0..<4, coordinate inner 0..<4. Each coordinate is the one-hot group center plus 0.01 times its next signed-uniform draw. Normalize each row explicitly in Double precision by its L2 norm.",
        vectors: vectors,
        labelAssertion: .exact([0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2]),
        inversion: nil
    )
}

private func angularChainInput() -> AHCParityInput {
    let angles = [0.0, 0.31, 0.62, 0.93]
    let vectors = angles.map { angle in [cos(angle), sin(angle)] }
    return AHCParityInput(
        name: "angular-chain",
        construction: "Four analytic deterministic 2D unit vectors [cos(a),sin(a)] for angles [0,0.31,0.62,0.93] radians; no random draws. Adjacent chord lengths are below the configured 0.6 cut while the endpoint chord exceeds it, creating a near-threshold neighbor chain that can behave differently under centroid linkage than single linkage.",
        vectors: vectors,
        labelAssertion: .atLeastTwoClusters,
        inversion: nil
    )
}

private func thresholdPairsInput() throws -> AHCParityInput {
    let firstChord = 0.5999
    let firstCosine = 1 - (firstChord * firstChord) / 2
    let firstSine = sqrt(1 - firstCosine * firstCosine)
    let secondChord = 0.6001
    let secondCosine = 1 - (secondChord * secondChord) / 2
    let secondSine = sqrt(1 - secondCosine * secondCosine)
    let vectors = [
        [1.0, 0, 0, 0],
        [firstCosine, firstSine, 0, 0],
        [0.0, 0, 1, 0],
        [0.0, 0, secondCosine, secondSine],
    ]
    try validateUnitVectors(vectors)
    return AHCParityInput(
        name: "threshold-pairs",
        construction: "Four 4D unit vectors in two orthogonal coordinate planes. Pair 0/1 is [1,0,0,0] and [c,s,0,0], where c=1-(0.5999^2)/2 and s=sqrt(1-c^2), giving chord 0.5999. Pair 2/3 is [0,0,1,0] and [0,0,c2,s2], where c2=1-(0.6001^2)/2 and s2=sqrt(1-c2^2), giving chord 0.6001. Orthogonal planes separate the pairs.",
        vectors: vectors,
        labelAssertion: .exact([0, 0, 1, 2]),
        inversion: nil
    )
}

private func centroidInversionInput() throws -> AHCParityInput {
    let d01 = 0.62
    let d02 = 0.63
    let d12 = 0.64
    let v0 = [1.0, 0, 0]
    let x1 = 1 - (d01 * d01) / 2
    let y1 = sqrt(1 - x1 * x1)
    let v1 = [x1, y1, 0.0]
    let x2 = 1 - (d02 * d02) / 2
    let y2 = (1 - (d12 * d12) / 2 - x1 * x2) / y1
    let z2 = sqrt(1 - x2 * x2 - y2 * y2)
    let v2 = [x2, y2, z2]
    let vectors = [v0, v1, v2]
    try validateUnitVectors(vectors)

    let actualD01 = try euclideanDistance(v0, v1)
    let actualD02 = try euclideanDistance(v0, v2)
    let actualD12 = try euclideanDistance(v1, v2)
    guard actualD01 > 0.6, actualD01 < actualD02, actualD02 > 0.6,
        actualD02 < actualD12, actualD12 > 0.6
    else {
        throw DiarizationParityOracleError.invalidTensor(
            "centroid-inversion: stored-coordinate leaf distances must be ordered d01 < d02 < d12 and all exceed 0.6"
        )
    }
    let centroid01 = zip(v0, v1).map { ($0.0 + $0.1) / 2 }
    let rootDistance = try euclideanDistance(centroid01, v2)
    let witness = AHCParityInversion(
        firstMergeDistance: actualD01,
        rootDistance: rootDistance,
        monotoneLabels: [0, 1, 2]
    )
    return AHCParityInput(
        name: "centroid-inversion",
        construction: "Three analytic unit 3D points from scalene chord distances d01=0.62, d02=0.63, d12=0.64: v0=[1,0,0]; x1=1-d01^2/2, y1=sqrt(1-x1^2), v1=[x1,y1,0]; x2=1-d02^2/2, y2=(1-d12^2/2-x1*x2)/y1, z2=sqrt(1-x2^2-y2^2), v2=[x2,y2,z2]. Recompute distances with Double scalar squares from the actual stored coordinates: the unique first pair is 0/1, all three leaf distances exceed 0.6, but the centroid ([v0+v1]/2)-to-v2 root distance is below both 0.6 and the first merge distance. A monotone maximum-descendant-height cut at 0.6 would accept no merge and yield [0,1,2]. FluidAudio confirmation is required to be exactly [0,0,0]; this is an analytic witness, not guessed linkage data. AHCClustering.swift:150-188 starts its cut traversal at the root and accepts a node whose distance is within threshold despite the descendant-height inversion.",
        vectors: vectors,
        labelAssertion: .centroidInversion,
        inversion: witness
    )
}

private func l2Normalized(_ vector: [Double], context: String) throws -> [Double] {
    guard !vector.isEmpty else {
        throw DiarizationParityOracleError.invalidTensor("\(context): vector dimension must be positive")
    }
    var squaredNorm = 0.0
    for (index, value) in vector.enumerated() {
        guard value.isFinite else {
            throw DiarizationParityOracleError.invalidTensor("\(context): coordinate \(index) is not finite")
        }
        squaredNorm += value * value
    }
    guard squaredNorm.isFinite, squaredNorm > 0 else {
        throw DiarizationParityOracleError.invalidTensor("\(context): vector has no finite nonzero L2 norm")
    }
    let norm = sqrt(squaredNorm)
    guard norm.isFinite, norm > 0 else {
        throw DiarizationParityOracleError.invalidTensor("\(context): vector has no finite nonzero L2 norm")
    }
    return vector.map { $0 / norm }
}

private func validateUnitVectors(_ vectors: [[Double]]) throws {
    guard !vectors.isEmpty else {
        throw DiarizationParityOracleError.invalidTensor("feature tensor must contain at least one point")
    }
    guard let dimension = vectors.first?.count, dimension > 0 else {
        throw DiarizationParityOracleError.invalidTensor("feature tensor dimension must be positive")
    }
    for (rowIndex, vector) in vectors.enumerated() {
        guard vector.count == dimension else {
            throw DiarizationParityOracleError.invalidTensor(
                "row \(rowIndex) has dimension \(vector.count), expected \(dimension)"
            )
        }
        var squaredNorm = 0.0
        for (coordinate, value) in vector.enumerated() {
            guard value.isFinite else {
                throw DiarizationParityOracleError.invalidTensor(
                    "row \(rowIndex), coordinate \(coordinate) is not finite"
                )
            }
            squaredNorm += value * value
        }
        guard squaredNorm.isFinite, squaredNorm > 0 else {
            throw DiarizationParityOracleError.invalidTensor("row \(rowIndex) has no finite nonzero L2 norm")
        }
        let norm = sqrt(squaredNorm)
        guard norm.isFinite, abs(norm - 1) <= 1e-12 else {
            throw DiarizationParityOracleError.invalidTensor(
                "row \(rowIndex) L2 norm is \(norm), expected 1 within 1e-12"
            )
        }
    }
}

private func requiredDimension(_ vectors: [[Double]], caseName: String) throws -> Int {
    guard let dimension = vectors.first?.count, dimension > 0 else {
        throw DiarizationParityOracleError.invalidTensor("\(caseName): feature tensor dimension must be positive")
    }
    guard vectors.allSatisfy({ $0.count == dimension }) else {
        throw DiarizationParityOracleError.invalidTensor("\(caseName): feature tensor rows have inconsistent dimensions")
    }
    return dimension
}

private func euclideanDistance(_ lhs: [Double], _ rhs: [Double]) throws -> Double {
    guard !lhs.isEmpty, lhs.count == rhs.count else {
        throw DiarizationParityOracleError.invalidTensor(
            "distance vectors must have the same positive dimension"
        )
    }
    var squaredDistance = 0.0
    for coordinate in lhs.indices {
        guard lhs[coordinate].isFinite, rhs[coordinate].isFinite else {
            throw DiarizationParityOracleError.invalidTensor(
                "distance vectors contain a non-finite coordinate at index \(coordinate)"
            )
        }
        let difference = lhs[coordinate] - rhs[coordinate]
        squaredDistance += difference * difference
    }
    guard squaredDistance.isFinite else {
        throw DiarizationParityOracleError.invalidTensor("squared distance is not finite")
    }
    return sqrt(squaredDistance)
}
#endif
