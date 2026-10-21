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

    @Test func quantizationHalfBoundariesAndNonfiniteRanking() throws {
        let halfUnit = 0.5e-6
        #expect(try Community1Assignment.assign(scores: [[-halfUnit.nextDown, 0]]) == [0])
        #expect(try Community1Assignment.assign(scores: [[-halfUnit, 0]]) == [1])
        #expect(try Community1Assignment.assign(scores: [[-halfUnit.nextUp, 0]]) == [1])

        #expect(try Community1Assignment.assign(scores: [[.nan, 1], [.infinity, 0]]) == [1, 0])
        #expect(try Community1Assignment.assign(scores: [[.nan, .infinity], [-.infinity, .nan]]) == [0, 1])
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

    @Test func exhaustiveBinaryMatricesMatchBruteForceObjective() throws {
        for rows in 1...3 {
            for columns in 1...4 {
                let matrixCount = 1 << (rows * columns)
                for mask in 0..<matrixCount {
                    let scores = (0..<rows).map { row in
                        (0..<columns).map { column in
                            Double((mask >> (row * columns + column)) & 1)
                        }
                    }
                    let actual = try Community1Assignment.assign(scores: scores)
                    #expect(quantizedObjective(scores: scores, assignment: actual)
                        == bruteForceMinimumObjective(scores: scores))
                }
            }
        }
    }
}

private func quantizedCosts(scores: [[Double]]) -> [[Int]] {
    let finite = scores.flatMap { $0 }.filter { $0.isFinite }
    let maximum = finite.max() ?? 0
    let minimum = finite.min() ?? 0
    let sentinel = minimum - 1
    return scores.map { row in
        row.map { score in
            let rankedScore = score.isFinite ? score : sentinel
            let difference = max(0, maximum - rankedScore)
            return Int((difference * Community1Profile.hungarianQuantization)
                .rounded(.toNearestOrAwayFromZero))
        }
    }
}

private func quantizedObjective(scores: [[Double]], assignment: [Int]) -> Int {
    let costs = quantizedCosts(scores: scores)
    return scores.indices.reduce(into: 0) { total, row in
        let column = assignment[row]
        if column >= 0 {
            total += costs[row][column]
        }
    }
}

private func bruteForceMinimumObjective(scores: [[Double]]) -> Int {
    let rows = scores.count
    let columns = scores[0].count
    let costs = quantizedCosts(scores: scores)
    let targetAssignments = min(rows, columns)
    var best = Int.max

    func search(row: Int, assignedCount: Int, used: [Bool], total: Int) {
        if row == rows {
            if assignedCount == targetAssignments {
                best = min(best, total)
            }
            return
        }
        let remainingRows = rows - row - 1
        if assignedCount + remainingRows >= targetAssignments {
            search(row: row + 1, assignedCount: assignedCount, used: used, total: total)
        }
        if assignedCount < targetAssignments {
            for column in 0..<columns where !used[column] {
                var nextUsed = used
                nextUsed[column] = true
                search(
                    row: row + 1,
                    assignedCount: assignedCount + 1,
                    used: nextUsed,
                    total: total + costs[row][column]
                )
            }
        }
    }

    search(row: 0, assignedCount: 0, used: [Bool](repeating: false, count: columns), total: 0)
    return best
}
