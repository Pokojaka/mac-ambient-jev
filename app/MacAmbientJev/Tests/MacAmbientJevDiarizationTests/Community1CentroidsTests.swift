import Testing
@testable import MacAmbientJevDiarization

@Suite struct Community1CentroidsTests {
    @Test func weightedMeansKeepAscendingSourceMappingAndRemainUnnormalized() throws {
        let result = try Community1Centroids.compute(
            trainingEmbeddings: [[3, 4], [-1, 2], [5, -2]],
            gamma: [[1, 0, 0.5], [3, 0, 1.5], [0, 0, 2]],
            pi: [0.4, 0, 0.2]
        )

        #expect(result.sourceClusterIndices == [0, 2])
        #expect(result.centroids.count == 2)
        #expect(result.centroids[0] == [0, 2.5])
        #expect(result.centroids[1] == [2.5, 0.25])
        #expect(result.centroids[1][0] * result.centroids[1][0]
            + result.centroids[1][1] * result.centroids[1][1] != 1)
    }

    @Test func activePriorBoundaryUsesStrictComparisonAndPreservesAscendingIndices() throws {
        let threshold = Community1Profile.activePriorThreshold
        let result = try Community1Centroids.compute(
            trainingEmbeddings: [[1, 0], [0, 1]],
            gamma: [[0, 0, 1, 3], [0, 0, 3, 1]],
            pi: [threshold.nextDown, threshold, threshold.nextUp, 0.8]
        )

        #expect(result.sourceClusterIndices == [2, 3])
        #expect(result.centroids[0] == [0.25, 0.75])
        #expect(result.centroids[1] == [0.75, 0.25])
    }

    @Test func weightedAccumulationUsesFusedMultiplyAddForNonDyadicWeights() throws {
        let weight = 0.1
        let embedding = 10.0
        #expect(weight * embedding == 1)
        let expectedNumerator = (-1.0).addingProduct(weight, embedding)
        #expect(expectedNumerator != 0)

        let result = try Community1Centroids.compute(
            trainingEmbeddings: [[-1], [embedding]],
            gamma: [[1], [weight]],
            pi: [1]
        )
        #expect(result.centroids[0][0] == expectedNumerator / (1 + weight))
        #expect(result.centroids[0][0] != 0)
    }

    @Test func streamedPosteriorCentroidsMatchMatrixFixtureComputation() throws {
        let rhoFeatures = [[-2.0], [1.0], [0.3], [-0.5], [4.0], [-1.0]]
        let vbx = try Community1VBx.refine(
            rhoFeatures: rhoFeatures,
            initialClusters: [0, 1, 0, 1, 2, 2],
            phi: [1]
        )
        let embeddings = [[3.0, 1], [-1, 2], [5, -2], [0.5, 4], [2, -3], [-4, 1]]
        let gamma = try rhoFeatures.map { try vbx.posterior.responsibilities(rho: $0) }
        let matrix = try Community1Centroids.compute(
            trainingEmbeddings: embeddings,
            gamma: gamma,
            pi: vbx.pi
        )
        let streamed = try Community1Centroids.compute(
            trainingEmbeddings: embeddings,
            rhoFeatures: rhoFeatures,
            vbx: vbx
        )

        #expect(streamed.sourceClusterIndices == matrix.sourceClusterIndices)
        #expect(streamed.centroids == matrix.centroids)
    }

    @Test func streamedComputeRejectsRowMismatchAndNonfiniteTrainingEmbeddings() throws {
        let rhoFeatures = [[-1.0], [1.0]]
        let vbx = try Community1VBx.refine(
            rhoFeatures: rhoFeatures,
            initialClusters: [0, 1],
            phi: [1]
        )
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(
                trainingEmbeddings: [[1], [2]],
                rhoFeatures: [[-1]],
                vbx: vbx
            )
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(
                trainingEmbeddings: [[1], [.infinity]],
                rhoFeatures: rhoFeatures,
                vbx: vbx
            )
        }
        #expect(throws: VBxError.self) {
            try Community1Centroids.compute(
                trainingEmbeddings: [[1], [2]],
                rhoFeatures: [[-1], [1, 2]],
                vbx: vbx
            )
        }
    }

    @Test func streamedComputePropagatesCancellation() async throws {
        let rhoFeatures = [[-1.0], [1.0]]
        let vbx = try Community1VBx.refine(
            rhoFeatures: rhoFeatures,
            initialClusters: [0, 1],
            phi: [1]
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) {
                try Community1Centroids.compute(
                    trainingEmbeddings: [[1], [2]],
                    rhoFeatures: rhoFeatures,
                    vbx: vbx
                )
            }
        }
        await task.value
    }

    @Test func cosineScoresNormalizeVectors() throws {
        let scores = try Community1Centroids.scores(
            embeddings: [[3, 4], [-1, 0]],
            centroids: [[1, 0], [0, 2]]
        )

        #expect(scores.count == 2)
        #expect(scores[0].count == 2)
        #expect(abs(scores[0][0] - 0.6) < 1e-15)
        #expect(abs(scores[0][1] - 0.8) < 1e-15)
        #expect(scores[1] == [-1, 0])
    }

    @Test func nonfiniteEmbeddingRowsProduceNaNScoresAfterDimensionValidation() throws {
        let scores = try Community1Centroids.scores(
            embeddings: [[.nan, 0], [0, .infinity], [1, 0]],
            centroids: [[1, 0], [0, 1]]
        )

        #expect(scores.count == 3)
        #expect(scores[0].count == 2)
        #expect(scores[0].allSatisfy { $0.isNaN })
        #expect(scores[1].allSatisfy { $0.isNaN })
        #expect(scores[2] == [1, 0])
        #expect(throws: CentroidError.self) {
            try Community1Centroids.scores(embeddings: [[.nan]], centroids: [[1, 0]])
        }
    }

    @Test func emptyEmbeddingRowsReturnNoScores() throws {
        #expect(try Community1Centroids.scores(embeddings: [], centroids: [[1, 0]]) == [])
    }

    @Test func computeRejectsEmptyZeroDimensionalOrJaggedTrainingEmbeddings() {
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [], gamma: [], pi: [1])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [[]], gamma: [[]], pi: [1])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [[1], [1, 2]], gamma: [[1], [1]], pi: [1])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [[.nan]], gamma: [[1]], pi: [1])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [[.infinity]], gamma: [[1]], pi: [1])
        }
    }

    @Test func computeRejectsInvalidPriorsAndGammaShapesOrValues() {
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [[1]], gamma: [[1]], pi: [])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [[1]], gamma: [[1]], pi: [-1])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [[1]], gamma: [[1]], pi: [.nan])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [[1]], gamma: [[1]], pi: [.infinity])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [[1]], gamma: [], pi: [1])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [[1]], gamma: [[1, 2]], pi: [1])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [[1]], gamma: [[-1]], pi: [1])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [[1]], gamma: [[.nan]], pi: [1])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(trainingEmbeddings: [[1]], gamma: [[.infinity]], pi: [1])
        }
    }

    @Test func computeRejectsNoActiveClusterAndActiveClustersWithoutPositiveWeight() throws {
        let threshold = Community1Profile.activePriorThreshold
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(
                trainingEmbeddings: [[1]],
                gamma: [[1, 1]],
                pi: [threshold.nextDown, threshold]
            )
        }

        let error = try #require(throws: CentroidError.self) {
            try Community1Centroids.compute(
                trainingEmbeddings: [[1], [2]],
                gamma: [[0], [0]],
                pi: [threshold.nextUp]
            )
        }
        #expect(error.description.contains("active cluster 0"))
        #expect(error.description.contains("no positive finite weight sum"))
    }

    @Test func computeRejectsWeightAndWeightedSumOverflow() {
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(
                trainingEmbeddings: [[0], [0]],
                gamma: [[.greatestFiniteMagnitude], [.greatestFiniteMagnitude]],
                pi: [1]
            )
        }

        let halfMaximum = Double.greatestFiniteMagnitude / 2
        #expect(throws: CentroidError.self) {
            try Community1Centroids.compute(
                trainingEmbeddings: [[4], [4]],
                gamma: [[halfMaximum], [halfMaximum]],
                pi: [1]
            )
        }
    }

    @Test func scoreRejectsInvalidCentroidsAndEmbeddingDimensions() {
        #expect(throws: CentroidError.self) {
            try Community1Centroids.scores(embeddings: [[1]], centroids: [])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.scores(embeddings: [[1]], centroids: [[]])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.scores(embeddings: [[1]], centroids: [[1], [1, 2]])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.scores(embeddings: [[1]], centroids: [[.nan]])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.scores(embeddings: [[1]], centroids: [[.infinity]])
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.scores(embeddings: [[1, 2]], centroids: [[1]])
        }
    }

    @Test func scoreRejectsFiniteNormArithmeticOverflow() {
        #expect(throws: CentroidError.self) {
            try Community1Centroids.scores(
                embeddings: [[1]],
                centroids: [[Double.greatestFiniteMagnitude]]
            )
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.scores(
                embeddings: [[1, 0]],
                centroids: [[1e154, 1e154]]
            )
        }
        #expect(throws: CentroidError.self) {
            try Community1Centroids.scores(
                embeddings: [[Double.greatestFiniteMagnitude]],
                centroids: [[1]]
            )
        }
    }
}
