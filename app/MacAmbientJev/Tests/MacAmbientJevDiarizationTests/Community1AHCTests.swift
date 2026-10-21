import Testing
@testable import MacAmbientJevDiarization

@Suite struct Community1AHCTests {
    @Test func matchesEveryPinnedAHCFixtureAndValidatesLinkageStructure() throws {
        let fixture = try DiarizationParityFixtures.load("ahc.json", as: DiarizationAHCFixture.self)
        #expect(fixture.cases.count == 36)

        for item in fixture.cases {
            #expect(item.threshold == Community1Profile.ahcThreshold)
            try #require(item.features.shape.count == 2)
            let pointCount = item.features.shape[0]
            let dimension = item.features.shape[1]
            try #require(pointCount > 0)
            try #require(dimension > 0)

            let values = try item.features.float64()
            #expect(values.count == pointCount * dimension)
            let vectors = (0..<pointCount).map { row in
                Array(values[(row * dimension)..<((row + 1) * dimension)])
            }
            let result = try Community1AHC.cluster(embeddingFeatures: vectors)
            #expect(result.labels == item.expectedLabels)
            #expect(result.linkage.count == pointCount - 1)
            guard result.linkage.count == pointCount - 1 else { continue }

            let shape = try Community1AHC.checkedShape(pointCount: pointCount, dimension: dimension)
            var nodeSizes = [Int](repeating: 0, count: shape.nodeCount)
            for leaf in 0..<pointCount {
                nodeSizes[leaf] = 1
            }
            var children = Set<Int>()

            for (mergeIndex, merge) in result.linkage.enumerated() {
                let newNode = pointCount + mergeIndex
                #expect(merge.left >= 0 && merge.left < newNode)
                #expect(merge.right >= 0 && merge.right < newNode)
                #expect(merge.left < merge.right)
                #expect(merge.height.isFinite)
                #expect(merge.height >= 0)
                guard merge.left >= 0, merge.left < newNode,
                      merge.right >= 0, merge.right < newNode else {
                    continue
                }

                #expect(children.insert(merge.left).inserted)
                #expect(children.insert(merge.right).inserted)
                #expect(merge.size == nodeSizes[merge.left] + nodeSizes[merge.right])
                nodeSizes[newNode] = merge.size
            }

            let root = shape.nodeCount - 1
            #expect(children.count == shape.nodeCount - 1)
            #expect(!children.contains(root))
            #expect(nodeSizes[root] == pointCount)
        }
    }

    @Test func centroidInversionUsesRootFirstCutRatherThanMonotoneHeights() throws {
        let fixture = try DiarizationParityFixtures.load("ahc.json", as: DiarizationAHCFixture.self)
        let item = try #require(fixture.cases.first { $0.name == "centroid-inversion" })
        let witness = try #require(item.inversion)
        let vectors = try ahcVectors(from: item.features)
        let result = try Community1AHC.cluster(embeddingFeatures: vectors)
        let firstMerge = try #require(result.linkage.first)
        let rootMerge = try #require(result.linkage.last)

        #expect(firstMerge.left == 0)
        #expect(firstMerge.right == 1)
        #expect(abs(firstMerge.height - witness.firstMergeDistance) <= 1e-12)
        #expect(firstMerge.height > Community1Profile.ahcThreshold)
        #expect(abs(rootMerge.height - witness.rootDistance) <= 1e-12)
        #expect(rootMerge.height < Community1Profile.ahcThreshold)
        #expect(result.labels == [0, 0, 0])
        #expect(result.labels != witness.monotoneLabels)
    }

    @Test func tiedNeighborLabelsMatchFixtureAndDuplicateHeapOrderMatchesSource() throws {
        let fixture = try DiarizationParityFixtures.load("ahc.json", as: DiarizationAHCFixture.self)
        let tiedNeighbors = try #require(fixture.cases.first { $0.name == "tied-neighbors" })
        let tiedNeighborResult = try Community1AHC.cluster(
            embeddingFeatures: ahcVectors(from: tiedNeighbors.features)
        )
        #expect(tiedNeighbors.expectedLabels == [0, 0, 1])
        #expect(tiedNeighborResult.labels == tiedNeighbors.expectedLabels)

        let duplicates = try Community1AHC.cluster(
            embeddingFeatures: Array(repeating: [1.0, 0.0], count: 6)
        )
        #expect(duplicates.labels == [0, 0, 0, 0, 0, 0])
        #expect(duplicates.linkage.map { [$0.left, $0.right] } == [
            [0, 1],
            [2, 6],
            [3, 7],
            [4, 8],
            [5, 9],
        ])
        #expect(duplicates.linkage.map(\.height) == [0, 0, 0, 0, 0])
        #expect(duplicates.linkage.map(\.size) == [2, 3, 4, 5, 6])
    }

    @Test func handlesSmallZeroAndScaledInputs() throws {
        let singleton = try Community1AHC.cluster(embeddingFeatures: [[3, 4]])
        #expect(singleton.labels == [0])
        #expect(singleton.linkage.isEmpty)

        let mergedPair = try Community1AHC.cluster(embeddingFeatures: [[1, 0], [1, 0]])
        #expect(mergedPair.labels == [0, 0])
        #expect(mergedPair.linkage.count == 1)
        #expect(mergedPair.linkage[0].height == 0)

        let separatedPair = try Community1AHC.cluster(embeddingFeatures: [[1, 0], [-1, 0]])
        #expect(separatedPair.labels == [0, 1])
        #expect(separatedPair.linkage.count == 1)
        #expect(separatedPair.linkage[0].height == 2)

        let zeroVectors = try Community1AHC.cluster(embeddingFeatures: [[0, 0], [0, 0]])
        #expect(zeroVectors.labels == [0, 0])
        #expect(zeroVectors.linkage[0].height == 0)

        let zeroAndUnit = try Community1AHC.cluster(embeddingFeatures: [[0, 0], [1, 0]])
        #expect(zeroAndUnit.labels == [0, 1])
        #expect(zeroAndUnit.linkage[0].height == 1)

        let scaledGeometry = try Community1AHC.cluster(embeddingFeatures: [[3, 4], [6, 8]])
        #expect(scaledGeometry.labels == [0, 0])
        #expect(abs(scaledGeometry.linkage[0].height) <= 1e-15)
    }

    @Test func rejectsMalformedNonfiniteAndOverflowingInputs() throws {
        let malformedInputs: [(features: [[Double]], expectedMessage: String)] = [
            (features: [], expectedMessage: "embedding input must not be empty"),
            (features: [[]], expectedMessage: "embedding dimension must be positive"),
            (features: [[1, 0], [1]], expectedMessage: "embedding row 1 has a ragged dimension"),
            (features: [[Double.nan]], expectedMessage: "contains a nonfinite coordinate"),
            (features: [[Double.infinity]], expectedMessage: "contains a nonfinite coordinate"),
            (features: [[-Double.infinity]], expectedMessage: "contains a nonfinite coordinate"),
        ]
        for item in malformedInputs {
            do {
                _ = try Community1AHC.cluster(embeddingFeatures: item.features)
                #expect(Bool(false), "Expected invalidInput for malformed AHC features")
            } catch let error as AHCError {
                if case let .invalidInput(message) = error {
                    #expect(message.contains(item.expectedMessage))
                } else {
                    #expect(Bool(false), "Expected invalidInput, got \(error)")
                }
            } catch {
                #expect(Bool(false), "Expected AHCError, got \(error)")
            }
        }

        do {
            _ = try Community1AHC.cluster(embeddingFeatures: [[Double.greatestFiniteMagnitude]])
            #expect(Bool(false), "Expected numericalFailure for overflowing AHC features")
        } catch let error as AHCError {
            if case let .numericalFailure(message) = error {
                #expect(message.contains("overflow"))
            } else {
                #expect(Bool(false), "Expected numericalFailure, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AHCError, got \(error)")
        }

        let underflowedNorms = try Community1AHC.cluster(embeddingFeatures: [
            [Double.leastNonzeroMagnitude, 0],
            [0, Double.leastNonzeroMagnitude],
        ])
        #expect(underflowedNorms.labels == [0, 0])
        #expect(underflowedNorms.linkage[0].height == 0)
    }

    @Test func checkedShapeRejectsOverflowBeforeAllocation() throws {
        let invalidShapes: [(pointCount: Int, dimension: Int, expectedMessage: String)] = [
            (pointCount: 0, dimension: 1, expectedMessage: "point count must be positive"),
            (pointCount: -1, dimension: 1, expectedMessage: "point count must be positive"),
            (pointCount: 1, dimension: 0, expectedMessage: "embedding dimension must be positive"),
            (pointCount: 1, dimension: -1, expectedMessage: "embedding dimension must be positive"),
            (pointCount: Int.max, dimension: 1, expectedMessage: "node count overflows Int"),
            (pointCount: 2, dimension: Int.max, expectedMessage: "coordinate count overflows Int"),
            (pointCount: 1, dimension: Int.max / 8 + 1, expectedMessage: "array byte count overflows Int"),
        ]
        for shape in invalidShapes {
            do {
                _ = try Community1AHC.checkedShape(pointCount: shape.pointCount, dimension: shape.dimension)
                #expect(Bool(false), "Expected invalidInput for checkedShape(\(shape.pointCount), \(shape.dimension))")
            } catch let error as AHCError {
                if case let .invalidInput(message) = error {
                    #expect(message.contains(shape.expectedMessage))
                } else {
                    #expect(Bool(false), "Expected invalidInput, got \(error)")
                }
            } catch {
                #expect(Bool(false), "Expected AHCError, got \(error)")
            }
        }

        let shape = try Community1AHC.checkedShape(pointCount: 3, dimension: 4)
        #expect(shape.nodeCount == 5)
        #expect(shape.coordinateCount == 20)
    }

    @Test func canceledTaskThrowsAtAHCEntry() async {
        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            _ = try Community1AHC.cluster(embeddingFeatures: [[1, 0], [0, 1]])
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

private func ahcVectors(from tensor: DiarizationParityTensor) throws -> [[Double]] {
    try #require(tensor.shape.count == 2)
    let pointCount = tensor.shape[0]
    let dimension = tensor.shape[1]
    try #require(pointCount > 0)
    try #require(dimension > 0)
    let values = try tensor.float64()
    try #require(values.count == pointCount * dimension)
    return (0..<pointCount).map { row in
        Array(values[(row * dimension)..<((row + 1) * dimension)])
    }
}
