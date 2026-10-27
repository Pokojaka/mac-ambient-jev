import Testing
@testable import MacAmbientJevDiarization

@Suite(.serialized) struct Community1AssignmentTests {
    @Test func rectangularAssignmentAndStrictTieOrder() throws {
        #expect(try Community1Assignment.assign(scores: []) == [])
        #expect(try Community1Assignment.assign(scores: [[1, 1, 1], [1, 1, 1], [1, 1, 1]]) == [0, 1, 2])
        #expect(try Community1Assignment.assign(scores: [[1], [1], [1]]) == [0, -2, -2])
        #expect(try Community1Assignment.assign(scores: [[1, 1, 1]]) == [0])
        #expect(try Community1Assignment.assign(scores: [[0.9, 0.8], [0.85, 0]]) == [1, 0])
    }

    @Test func optionalSlotsAreScoredAndMappedBack() throws {
        let mapped = try Community1Assignment.assign(
            embeddings: [[-1, 0], nil, [1, 0]],
            centroids: [[1, 0], [-1, 0]]
        )
        #expect(mapped == [1, -2, 0])

        let oneCluster = try Community1Assignment.assign(
            embeddings: [[1, 0], [1, 0], nil],
            centroids: [[1, 0]]
        )
        #expect(oneCluster == [0, -2, -2])

        let allInactive = try Community1Assignment.assign(
            embeddings: [nil, nil, nil],
            centroids: [[1, 0], [0, 1]]
        )
        #expect(allInactive == [-2, -2, -2])
    }

    @Test func zeroVectorsAndNonfiniteEmbeddingsUseCentroidScoringContract() throws {
        let zeroVector = try Community1Assignment.assign(
            embeddings: [[0, 0], nil, nil],
            centroids: [[1, 0], [0, 1]]
        )
        #expect(zeroVector == [0, -2, -2])

        let nonfiniteEmbedding = try Community1Assignment.assign(
            embeddings: [[.infinity, 0], nil, nil],
            centroids: [[1, 0], [0, 1]]
        )
        #expect(nonfiniteEmbedding == [0, -2, -2])
    }

    @Test func invalidShapesDimensionsAndCostsFailExplicitly() throws {
        #expect(throws: AssignmentError.self) {
            try Community1Assignment.assign(scores: [[1], [1, 2]])
        }
        #expect(throws: AssignmentError.self) {
            try Community1Assignment.assign(scores: [[], []])
        }
        #expect(throws: AssignmentError.self) {
            try Community1Assignment.assign(scores: [[1], [1], [1], [1]])
        }
        #expect(try Community1Assignment.assign(scores: [[-Double.greatestFiniteMagnitude]]) == [0])
        #expect(throws: AssignmentError.self) {
            try Community1Assignment.assign(scores: [[-Double.greatestFiniteMagnitude, .nan]])
        }
        #expect(throws: AssignmentError.self) {
            try Community1Assignment.assign(scores: [[Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude]])
        }

        let quantizationError = try #require(throws: AssignmentError.self) {
            try Community1Assignment.assign(scores: [[Double.greatestFiniteMagnitude, 0]])
        }
        #expect(quantizationError.description.contains("score quantization overflowed"))
        #expect(throws: AssignmentError.self) {
            try Community1Assignment.assign(scores: [[1e12, 0]])
        }
        #expect(throws: AssignmentError.self) {
            try Community1Assignment.assign(embeddings: [[1, 0], nil], centroids: [[1, 0]])
        }
        #expect(throws: CentroidError.self) {
            try Community1Assignment.assign(embeddings: [nil, nil, nil], centroids: [])
        }
        #expect(throws: CentroidError.self) {
            try Community1Assignment.assign(
                embeddings: [[1, 0], nil, nil],
                centroids: [[1, 0], [1]]
            )
        }
        #expect(throws: CentroidError.self) {
            try Community1Assignment.assign(
                embeddings: [[1, 0], nil, nil],
                centroids: [[1, 0, 0]]
            )
        }
    }

    @Test func manyClustersUseRectangularStorageAndKeepDistinctOptima() throws {
        let columns = 5_000
        let preferredColumns = [4_201, 7, 3_017]
        var scores = [[Double]](repeating: [Double](repeating: 0, count: columns), count: 3)
        for row in scores.indices {
            scores[row][preferredColumns[row]] = 1
        }
        #expect(try Community1Assignment.assign(scores: scores) == preferredColumns)
    }

}
