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
        guard let dimension = trainingEmbeddings.first?.count else {
            throw CentroidError.invalidInput("training embeddings must be nonempty")
        }
        guard dimension > 0 else {
            throw CentroidError.invalidInput("training embedding dimension must be positive")
        }
        for (row, embedding) in trainingEmbeddings.enumerated() {
            guard embedding.count == dimension else {
                throw CentroidError.invalidInput("training embedding row \(row) has inconsistent dimension")
            }
            guard embedding.allSatisfy({ $0.isFinite }) else {
                throw CentroidError.invalidInput("training embedding row \(row) contains a nonfinite value")
            }
        }

        guard !pi.isEmpty else {
            throw CentroidError.invalidInput("pi must be nonempty")
        }
        for (cluster, prior) in pi.enumerated() {
            guard prior.isFinite, prior >= 0 else {
                throw CentroidError.invalidInput("pi value at cluster \(cluster) must be finite and nonnegative")
            }
        }

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

        let activeClusters = pi.enumerated().compactMap { cluster, prior in
            prior > Community1Profile.activePriorThreshold ? cluster : nil
        }
        guard !activeClusters.isEmpty else {
            throw CentroidError.invalidInput("pi contains no active clusters")
        }

        var centroids: [[Double]] = []
        centroids.reserveCapacity(activeClusters.count)
        for cluster in activeClusters {
            var numerator = [Double](repeating: 0, count: dimension)
            var denominator = 0.0

            // Posterior responsibilities weight rows in chronological scalar order.
            for row in trainingEmbeddings.indices {
                let weight = gamma[row][cluster]
                guard weight > 0 else { continue }
                denominator += weight
                guard denominator.isFinite else {
                    throw CentroidError.numericalFailure("weight sum overflowed for cluster \(cluster)")
                }
                let embedding = trainingEmbeddings[row]
                for coordinate in 0..<dimension {
                    numerator[coordinate] = numerator[coordinate].addingProduct(weight, embedding[coordinate])
                    guard numerator[coordinate].isFinite else {
                        throw CentroidError.numericalFailure(
                            "weighted sum overflowed for cluster \(cluster), coordinate \(coordinate)"
                        )
                    }
                }
            }

            guard denominator.isFinite, denominator > 0 else {
                throw CentroidError.numericalFailure("active cluster \(cluster) has no positive finite weight sum")
            }
            let centroid = numerator.map { $0 / denominator }
            guard centroid.allSatisfy({ $0.isFinite }) else {
                throw CentroidError.numericalFailure("division produced a nonfinite centroid for cluster \(cluster)")
            }
            // Keep weighted means unnormalized; cosine scoring normalizes them later.
            centroids.append(centroid)
        }

        return Community1CentroidResult(sourceClusterIndices: activeClusters, centroids: centroids)
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
