import Foundation

// Pinned to FluidAudio 0.15.8, revision 87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc.
// Reference: OfflineDiarizerManager.swift:720-772 (active priors and posterior-weighted
// centroids) and :877-971 (cosine normalization and scoring). The portable contract
// validates inputs and fails on zero-weight active clusters rather than using manager recovery.
// https://github.com/FluidInference/FluidAudio/blob/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift
enum CentroidError: Error, CustomStringConvertible {
    case invalidInput(String)
    case numericalFailure(String)

    var description: String {
        switch self {
        case let .invalidInput(reason):
            "invalid centroid input: \(reason)"
        case let .numericalFailure(reason):
            "centroid numerical failure: \(reason)"
        }
    }
}

struct Community1CentroidResult {
    let sourceClusterIndices: [Int]
    let centroids: [[Double]]
}

enum Community1Centroids {
    static func compute(
        trainingEmbeddings: [[Double]],
        gamma: [[Double]],
        pi: [Double]
    ) throws -> Community1CentroidResult {
        let dimension = try validateTrainingEmbeddings(trainingEmbeddings)
        try validatePriors(pi, expectedCount: nil)

        guard gamma.count == trainingEmbeddings.count else {
            throw CentroidError.invalidInput("gamma row count must match training embeddings")
        }
        for (row, weights) in gamma.enumerated() {
            guard weights.count == pi.count else {
                throw CentroidError.invalidInput("gamma row \(row) width must match pi")
            }
            for (cluster, weight) in weights.enumerated() {
                guard weight.isFinite, weight >= 0 else {
                    throw CentroidError.invalidInput(
                        "gamma value at row \(row), cluster \(cluster) must be finite and nonnegative"
                    )
                }
            }
        }

        let activeClusters = try activeClusters(from: pi)
        var accumulator = CentroidAccumulator(activeClusters: activeClusters, dimension: dimension)
        // Keep every cluster's scalar accumulation in chronological row order.
        for row in trainingEmbeddings.indices {
            for (activeIndex, cluster) in activeClusters.enumerated() {
                try accumulator.add(
                    weight: gamma[row][cluster],
                    activeIndex: activeIndex,
                    cluster: cluster,
                    embedding: trainingEmbeddings[row]
                )
            }
        }
        return try accumulator.finalize()
    }

    static func compute(
        trainingEmbeddings: [[Double]],
        rhoFeatures: [[Double]],
        vbx: Community1VBxResult
    ) throws -> Community1CentroidResult {
        try Task.checkCancellation()
        let dimension = try validateTrainingEmbeddings(trainingEmbeddings)
        guard rhoFeatures.count == trainingEmbeddings.count else {
            throw CentroidError.invalidInput("rho feature row count must match training embeddings")
        }
        try validatePriors(vbx.pi, expectedCount: vbx.posterior.speakerCount)
        let active = try activeClusters(from: vbx.pi)
        var accumulator = CentroidAccumulator(activeClusters: active, dimension: dimension)

        for row in trainingEmbeddings.indices {
            try Task.checkCancellation()
            let responsibilities = try vbx.posterior.responsibilities(rho: rhoFeatures[row])
            for (activeIndex, cluster) in active.enumerated() {
                try accumulator.add(
                    weight: responsibilities[cluster],
                    activeIndex: activeIndex,
                    cluster: cluster,
                    embedding: trainingEmbeddings[row]
                )
            }
        }
        return try accumulator.finalize()
    }

    private static func validateTrainingEmbeddings(_ embeddings: [[Double]]) throws -> Int {
        guard let dimension = embeddings.first?.count else {
            throw CentroidError.invalidInput("training embeddings must be nonempty")
        }
        guard dimension > 0 else {
            throw CentroidError.invalidInput("training embedding dimension must be positive")
        }
        for (row, embedding) in embeddings.enumerated() {
            guard embedding.count == dimension else {
                throw CentroidError.invalidInput("training embedding row \(row) has inconsistent dimension")
            }
            guard embedding.allSatisfy({ $0.isFinite }) else {
                throw CentroidError.invalidInput("training embedding row \(row) contains a nonfinite value")
            }
        }
        return dimension
    }

    private static func validatePriors(_ pi: [Double], expectedCount: Int?) throws {
        guard !pi.isEmpty else {
            throw CentroidError.invalidInput("pi must be nonempty")
        }
        if let expectedCount, pi.count != expectedCount {
            throw CentroidError.invalidInput("pi count must match posterior speaker count")
        }
        for (cluster, prior) in pi.enumerated() {
            guard prior.isFinite, prior >= 0 else {
                throw CentroidError.invalidInput("pi value at cluster \(cluster) must be finite and nonnegative")
            }
        }
    }

    private static func activeClusters(from pi: [Double]) throws -> [Int] {
        let active = pi.enumerated().compactMap { cluster, prior in
            prior > Community1Profile.activePriorThreshold ? cluster : nil
        }
        guard !active.isEmpty else {
            throw CentroidError.invalidInput("pi contains no active clusters")
        }
        return active
    }

    private struct CentroidAccumulator {
        let activeClusters: [Int]
        var numerators: [[Double]]
        var denominators: [Double]

        init(activeClusters: [Int], dimension: Int) {
            self.activeClusters = activeClusters
            numerators = activeClusters.map { _ in [Double](repeating: 0, count: dimension) }
            denominators = [Double](repeating: 0, count: activeClusters.count)
        }

        mutating func add(weight: Double, activeIndex: Int, cluster: Int, embedding: [Double]) throws {
            guard weight > 0 else { return }
            denominators[activeIndex] += weight
            guard denominators[activeIndex].isFinite else {
                throw CentroidError.numericalFailure("weight sum overflowed for cluster \(cluster)")
            }
            for coordinate in embedding.indices {
                numerators[activeIndex][coordinate] = numerators[activeIndex][coordinate]
                    .addingProduct(weight, embedding[coordinate])
                guard numerators[activeIndex][coordinate].isFinite else {
                    throw CentroidError.numericalFailure(
                        "weighted sum overflowed for cluster \(cluster), coordinate \(coordinate)"
                    )
                }
            }
        }

        func finalize() throws -> Community1CentroidResult {
            var centroids: [[Double]] = []
            centroids.reserveCapacity(activeClusters.count)
            for (activeIndex, cluster) in activeClusters.enumerated() {
                let denominator = denominators[activeIndex]
                guard denominator.isFinite, denominator > 0 else {
                    throw CentroidError.numericalFailure(
                        "active cluster \(cluster) has no positive finite weight sum"
                    )
                }
                let centroid = numerators[activeIndex].map { $0 / denominator }
                guard centroid.allSatisfy({ $0.isFinite }) else {
                    throw CentroidError.numericalFailure(
                        "division produced a nonfinite centroid for cluster \(cluster)"
                    )
                }
                // Keep weighted means unnormalized; cosine scoring normalizes them later.
                centroids.append(centroid)
            }
            return Community1CentroidResult(sourceClusterIndices: activeClusters, centroids: centroids)
        }
    }

    static func scores(embeddings: [[Double]], centroids: [[Double]]) throws -> [[Double]] {
        guard let dimension = centroids.first?.count else {
            throw CentroidError.invalidInput("centroids must be nonempty")
        }
        guard dimension > 0 else {
            throw CentroidError.invalidInput("centroid dimension must be positive")
        }
        for (index, centroid) in centroids.enumerated() {
            guard centroid.count == dimension else {
                throw CentroidError.invalidInput("centroid \(index) has inconsistent dimension")
            }
            guard centroid.allSatisfy({ $0.isFinite }) else {
                throw CentroidError.invalidInput("centroid \(index) contains a nonfinite value")
            }
        }
        for (index, embedding) in embeddings.enumerated() {
            guard embedding.count == dimension else {
                throw CentroidError.invalidInput("embedding \(index) dimension does not match centroids")
            }
        }

        var normalizedCentroids: [[Double]] = []
        normalizedCentroids.reserveCapacity(centroids.count)
        for (index, centroid) in centroids.enumerated() {
            normalizedCentroids.append(try normalize(centroid, context: "centroid \(index)"))
        }

        var result: [[Double]] = []
        result.reserveCapacity(embeddings.count)
        for (index, embedding) in embeddings.enumerated() {
            guard embedding.allSatisfy({ $0.isFinite }) else {
                result.append([Double](repeating: .nan, count: centroids.count))
                continue
            }
            let normalizedEmbedding = try normalize(embedding, context: "embedding \(index)")
            var row: [Double] = []
            row.reserveCapacity(normalizedCentroids.count)
            for (centroidIndex, centroid) in normalizedCentroids.enumerated() {
                row.append(try dot(
                    normalizedEmbedding,
                    centroid,
                    context: "embedding \(index), centroid \(centroidIndex)"
                ))
            }
            result.append(row)
        }
        return result
    }

    private static func normalize(_ vector: [Double], context: String) throws -> [Double] {
        var sumSquares = 0.0
        for (index, value) in vector.enumerated() {
            let square = value * value
            guard square.isFinite else {
                throw CentroidError.numericalFailure("norm overflowed for \(context) at coordinate \(index)")
            }
            sumSquares += square
            guard sumSquares.isFinite else {
                throw CentroidError.numericalFailure("norm accumulation overflowed for \(context)")
            }
        }
        // FluidAudio OfflineDiarizerManager.swift:927-929 returns zero vectors unchanged.
        guard sumSquares > 0 else { return vector }

        let scale = 1.0 / sqrt(sumSquares)
        guard scale.isFinite else {
            throw CentroidError.numericalFailure("normalization scale is nonfinite for \(context)")
        }
        var normalized: [Double] = []
        normalized.reserveCapacity(vector.count)
        for (index, value) in vector.enumerated() {
            let scaled = value * scale
            guard scaled.isFinite else {
                throw CentroidError.numericalFailure(
                    "normalization overflowed for \(context) at coordinate \(index)"
                )
            }
            normalized.append(scaled)
        }
        return normalized
    }

    private static func dot(_ lhs: [Double], _ rhs: [Double], context: String) throws -> Double {
        var result = 0.0
        for index in lhs.indices {
            let product = lhs[index] * rhs[index]
            guard product.isFinite else {
                throw CentroidError.numericalFailure("dot product overflowed for \(context) at coordinate \(index)")
            }
            result += product
            guard result.isFinite else {
                throw CentroidError.numericalFailure("dot product accumulation overflowed for \(context)")
            }
        }
        return result
    }
}
