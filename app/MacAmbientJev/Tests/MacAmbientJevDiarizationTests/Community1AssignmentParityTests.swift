import Testing
@testable import MacAmbientJevDiarization

@Suite struct Community1AssignmentParityTests {
    private let expectedVersion = "0.15.8"
    private let expectedRevision = "87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc"

    @Test func fixtureMetadataCountsAndNamesMatchPinnedSchema() throws {
        let fixture = try DiarizationParityFixtures.load(
            "assignment.json",
            as: DiarizationAssignmentFixture.self
        )
        #expect(fixture.metadata.schemaVersion == 1)
        #expect(fixture.metadata.fluidAudioVersion == expectedVersion)
        #expect(fixture.metadata.fluidAudioRevision == expectedRevision)
        #expect(!fixture.metadata.inputConstruction.isEmpty)
        #expect(!fixture.metadata.comparisonRule.isEmpty)
        #expect(fixture.scoreCases.count == 257)
        #expect(fixture.exhaustiveBinary.count == 12)
        #expect(fixture.exhaustiveBinary.reduce(0) { $0 + $1.expectedAssignments.count } == 5_050)
        #expect(fixture.centroidCases.count == 9)
        #expect(fixture.embeddingCases.count == 21)

        let scoreNames = fixture.scoreCases.map(\.name)
        let centroidNames = fixture.centroidCases.map(\.name)
        let embeddingNames = fixture.embeddingCases.map(\.name)
        #expect(Set(scoreNames).count == scoreNames.count)
        #expect(Set(centroidNames).count == centroidNames.count)
        #expect(Set(embeddingNames).count == embeddingNames.count)
        let allNames = scoreNames + centroidNames + embeddingNames
        #expect(Set(allNames).count == allNames.count)
        #expect(fixture.scoreCases.allSatisfy { !$0.construction.isEmpty })
        #expect(fixture.centroidCases.allSatisfy { !$0.construction.isEmpty })
        #expect(fixture.embeddingCases.allSatisfy { !$0.construction.isEmpty })

        for rows in 1...3 {
            for columns in 1...40 {
                #expect(scoreNames.filter { $0 == "random-continuous-r\(rows)-k\(columns)" }.count == 1)
                #expect(scoreNames.filter { $0 == "random-tied-r\(rows)-k\(columns)" }.count == 1)
            }
        }
        for requiredName in [
            "augmenting-path-equal-ties",
            "identical-zero-rows-columns-r1-k4",
            "sub-micro-score-differences",
            "half-micro-rounding-next-down",
            "half-micro-rounding-exact",
            "half-micro-rounding-next-up",
            "nonfinite-mixed-cells",
            "nonfinite-all-cells-rows-greater-than-columns",
            "nonfinite-all-cells-columns-greater-than-rows",
        ] {
            #expect(scoreNames.contains(requiredName))
        }
    }

    @Test func scoreCasesMatchExactAssignmentsAndQuantizationBoundaries() throws {
        let fixture = try DiarizationParityFixtures.load(
            "assignment.json",
            as: DiarizationAssignmentFixture.self
        )
        for item in fixture.scoreCases {
            try #require(item.scores.shape.count == 2, "Score matrix must be two-dimensional: \(item.name)")
            let rows = item.scores.shape[0]
            let columns = item.scores.shape[1]
            try #require((1...3).contains(rows), "Score row count must be 1...3: \(item.name)")
            try #require((1...40).contains(columns), "Score column count must be 1...40: \(item.name)")
            let scores = try item.scores.float64Matrix(nonfinite: item.nonfinite)
            try #require(item.expectedAssignments.count == rows, "Expected assignment count must match rows: \(item.name)")
            let actual = try Community1Assignment.assign(scores: scores)
            #expect(actual.count == rows)
            #expect(actual == item.expectedAssignments)

            let assignedClusters = item.expectedAssignments.filter { $0 != -2 }
            #expect(assignedClusters.allSatisfy { $0 >= 0 && $0 < columns })
            #expect(Set(assignedClusters).count == assignedClusters.count)
        }

        let subMicro = try #require(fixture.scoreCases.first { $0.name == "sub-micro-score-differences" })
        #expect(try subMicro.scores.float64Matrix(nonfinite: subMicro.nonfinite) == [[-0.4e-6, 0]])
        #expect(subMicro.expectedAssignments == [0])
        for (name, delta, expected) in [
            ("half-micro-rounding-next-down", Double(0.5e-6).nextDown, [0]),
            ("half-micro-rounding-exact", 0.5e-6, [1]),
            ("half-micro-rounding-next-up", Double(0.5e-6).nextUp, [1]),
        ] {
            let item = try #require(fixture.scoreCases.first { $0.name == name })
            #expect(item.scores.shape == [1, 2])
            #expect(try item.scores.float64Matrix(nonfinite: item.nonfinite) == [[-delta, 0]])
            #expect(item.expectedAssignments == expected)
        }
    }

    @Test func exhaustiveBinaryCasesMatchEveryRowMajorMask() throws {
        let fixture = try DiarizationParityFixtures.load(
            "assignment.json",
            as: DiarizationAssignmentFixture.self
        )
        var seenShapes: Set<String> = []
        for item in fixture.exhaustiveBinary {
            try #require((1...3).contains(item.rows), "Binary row count must be 1...3")
            try #require((1...4).contains(item.columns), "Binary column count must be 1...4")
            let shape = "\(item.rows)x\(item.columns)"
            #expect(seenShapes.insert(shape).inserted)
            let maskCount = 1 << (item.rows * item.columns)
            try #require(item.expectedAssignments.count == maskCount, "Binary fixture must store every mask for \(shape)")
            for mask in 0..<maskCount {
                let scores = (0..<item.rows).map { row in
                    (0..<item.columns).map { column in
                        Double((mask >> (row * item.columns + column)) & 1)
                    }
                }
                let actual = try Community1Assignment.assign(scores: scores)
                #expect(actual == item.expectedAssignments[mask])
            }
        }
        #expect(seenShapes.count == 12)
    }

    @Test func centroidCasesMatchExactComputedBitsAndActiveSources() throws {
        let fixture = try DiarizationParityFixtures.load(
            "assignment.json",
            as: DiarizationAssignmentFixture.self
        )
        for item in fixture.centroidCases {
            try #require(item.trainingEmbeddings.shape.count == 2, "Training embeddings must be a matrix: \(item.name)")
            try #require(item.gamma.shape.count == 2, "Gamma must be a matrix: \(item.name)")
            try #require(item.expectedCentroids.shape.count == 2, "Expected centroids must be a matrix: \(item.name)")
            let trainingShape = item.trainingEmbeddings.shape
            let gammaShape = item.gamma.shape
            let centroidShape = item.expectedCentroids.shape
            try #require(item.pi.shape.count == 1 && item.pi.shape[0] > 0, "Pi must be a nonempty vector: \(item.name)")
            try #require(trainingShape[0] > 0 && trainingShape[1] > 0, "Training dimensions must be positive: \(item.name)")
            try #require(gammaShape == [trainingShape[0], item.pi.shape[0]], "Gamma dimensions must match training rows and pi: \(item.name)")
            try #require(centroidShape[1] == trainingShape[1], "Centroid dimension must match training embeddings: \(item.name)")

            let training = try item.trainingEmbeddings.float64Matrix(nonfinite: [])
            let gamma = try item.gamma.float64Matrix(nonfinite: [])
            let pi = try item.pi.float64()
            let expectedCentroids = try item.expectedCentroids.float64Matrix(nonfinite: [])
            let activeSources = pi.enumerated().compactMap { index, prior in
                prior > Community1Profile.activePriorThreshold ? index : nil
            }
            #expect(activeSources == item.expectedSourceClusterIndices)
            let result = try Community1Centroids.compute(trainingEmbeddings: training, gamma: gamma, pi: pi)
            #expect(result.sourceClusterIndices == item.expectedSourceClusterIndices)
            #expect(result.centroids.map { $0.map(\.bitPattern) } == expectedCentroids.map { $0.map(\.bitPattern) })
        }
    }

    @Test func embeddingCasesMatchThreeSlotAssignments() throws {
        let fixture = try DiarizationParityFixtures.load(
            "assignment.json",
            as: DiarizationAssignmentFixture.self
        )
        for item in fixture.embeddingCases {
            try #require(item.embeddings.shape.count == 2, "Embedding tensor must be a matrix: \(item.name)")
            try #require(item.centroids.shape.count == 2, "Centroid tensor must be a matrix: \(item.name)")
            let embeddingShape = item.embeddings.shape
            let centroidShape = item.centroids.shape
            try #require(embeddingShape[0] == 3 && embeddingShape[1] > 0, "Embeddings must contain three positive-dimensional rows: \(item.name)")
            try #require(centroidShape[0] >= 2 && centroidShape[1] == embeddingShape[1], "Constrained centroids must match embedding dimensions and have K >= 2: \(item.name)")
            try #require(item.expectedAssignments.count == 3, "Expected assignments must contain three local slots: \(item.name)")
            try #require(
                item.activeSlots == item.activeSlots.sorted()
                    && Set(item.activeSlots).count == item.activeSlots.count
                    && item.activeSlots.allSatisfy { (0..<3).contains($0) },
                "Active slots must be a sorted, unique subset of 0..<3: \(item.name)"
            )

            let storedEmbeddings = try item.embeddings.float64Matrix(nonfinite: item.nonfinite)
            let centroids = try item.centroids.float64Matrix(nonfinite: [])
            var embeddings = [[Double]?](repeating: nil, count: 3)
            for slot in item.activeSlots {
                embeddings[slot] = storedEmbeddings[slot]
            }
            let actual = try Community1Assignment.assign(embeddings: embeddings, centroids: centroids)
            #expect(actual == item.expectedAssignments)
        }
    }

    @Test func malformedFloat64MatricesAndPatchesFailFast() {
        let zero = DiarizationParityTensor(dtype: "float64", shape: [1, 1], littleEndianBase64: "AAAAAAAAAAA=")
        let one = DiarizationParityTensor(dtype: "float64", shape: [1, 1], littleEndianBase64: "AAAAAAAA8D8=")

        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try DiarizationParityTensor(dtype: "float64", shape: [1], littleEndianBase64: "AAAAAAAAAAA=")
                .float64Matrix(nonfinite: [])
        }
        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try DiarizationParityTensor(dtype: "float64", shape: [1, 0], littleEndianBase64: "")
                .float64Matrix(nonfinite: [])
        }
        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try zero.float64Matrix(nonfinite: [
                DiarizationNonfinitePatch(index: 0, kind: .nan),
                DiarizationNonfinitePatch(index: 0, kind: .positiveInfinity),
            ])
        }
        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try zero.float64Matrix(nonfinite: [DiarizationNonfinitePatch(index: 1, kind: .nan)])
        }
        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try one.float64Matrix(nonfinite: [DiarizationNonfinitePatch(index: 0, kind: .nan)])
        }
    }
}
