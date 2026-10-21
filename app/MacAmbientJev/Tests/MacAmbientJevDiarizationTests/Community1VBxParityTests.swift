import Testing
@testable import MacAmbientJevDiarization

@Suite
struct Community1VBxParityTests {
    @Test
    func streamedVBxMatchesFluidAudioFixture() throws {
        let fixture = try DiarizationParityFixtures.load("vbx.json", as: DiarizationVBxFixture.self)
        let expectedCaseNames = (2...8).map { "synthetic-k\($0)" }
            + ["scalar-x3", "scalar-x4", "scalar-x4.5", "scalar-x5", "collapsed-pi"]
        try #require(fixture.cases.map(\.name) == expectedCaseNames, "VBx fixture case order and names must remain fixed")

        var containsTwentyIterations = false
        var containsEarlyConvergence = false

        for fixtureCase in fixture.cases {
            let rhoTensor = fixtureCase.rhoFeatures
            let phiTensor = fixtureCase.phi
            let trainingTensor = fixtureCase.trainingEmbeddings
            let gammaTensor = fixtureCase.expectedGamma
            let piTensor = fixtureCase.expectedPi
            let elbosTensor = fixtureCase.expectedElbos

            #expect(rhoTensor.dtype == "float64", "\(fixtureCase.name): rhoFeatures dtype must be float64")
            #expect(phiTensor.dtype == "float64", "\(fixtureCase.name): phi dtype must be float64")
            #expect(trainingTensor.dtype == "float64", "\(fixtureCase.name): trainingEmbeddings dtype must be float64")
            #expect(gammaTensor.dtype == "float64", "\(fixtureCase.name): expectedGamma dtype must be float64")
            #expect(piTensor.dtype == "float64", "\(fixtureCase.name): expectedPi dtype must be float64")
            #expect(elbosTensor.dtype == "float64", "\(fixtureCase.name): expectedElbos dtype must be float64")

            try #require(rhoTensor.shape.count == 2, "\(fixtureCase.name): rhoFeatures must be a matrix")
            try #require(phiTensor.shape.count == 1, "\(fixtureCase.name): phi must be a vector")
            try #require(trainingTensor.shape.count == 2, "\(fixtureCase.name): trainingEmbeddings must be a matrix")
            try #require(gammaTensor.shape.count == 2, "\(fixtureCase.name): expectedGamma must be a matrix")
            try #require(piTensor.shape.count == 1, "\(fixtureCase.name): expectedPi must be a vector")
            try #require(elbosTensor.shape.count == 1, "\(fixtureCase.name): expectedElbos must be a vector")

            let rowCount = rhoTensor.shape[0]
            let dimension = rhoTensor.shape[1]
            let embeddingDimension = trainingTensor.shape[1]
            let clusterCount = Set(fixtureCase.initialClusters).count
            try #require(rowCount > 0, "\(fixtureCase.name): N must be positive")
            try #require(dimension > 0, "\(fixtureCase.name): D must be positive")
            try #require(embeddingDimension > 0, "\(fixtureCase.name): E must be positive")
            try #require((2...8).contains(clusterCount), "\(fixtureCase.name): K must be between 2 and 8")
            try #require(fixtureCase.initialClusters.count == rowCount, "\(fixtureCase.name): labels count must equal N")
            try #require(
                Set(fixtureCase.initialClusters) == Set(0..<clusterCount),
                "\(fixtureCase.name): labels must use exactly 0..<K"
            )
            try #require((2...20).contains(fixtureCase.expectedIterationCount), "\(fixtureCase.name): iterations must be between 2 and 20")

            try #require(phiTensor.shape == [dimension], "\(fixtureCase.name): phi shape must be [D]")
            try #require(
                trainingTensor.shape == [rowCount, embeddingDimension],
                "\(fixtureCase.name): trainingEmbeddings shape must be [N,E]"
            )
            try #require(gammaTensor.shape == [rowCount, clusterCount], "\(fixtureCase.name): expectedGamma shape must be [N,K]")
            try #require(piTensor.shape == [clusterCount], "\(fixtureCase.name): expectedPi shape must be [K]")
            try #require(
                elbosTensor.shape == [fixtureCase.expectedIterationCount],
                "\(fixtureCase.name): expectedElbos shape must match expectedIterationCount"
            )

            if fixtureCase.name.hasPrefix("synthetic-") {
                #expect(dimension == 128 && embeddingDimension == 256, "\(fixtureCase.name): synthetic dimensions must be D=128 and E=256")
            } else if fixtureCase.name.hasPrefix("scalar-") {
                #expect(dimension == 1 && embeddingDimension == 8, "\(fixtureCase.name): scalar dimensions must be D=1 and E=8")
            } else {
                #expect(fixtureCase.name == "collapsed-pi", "Unexpected VBx case \(fixtureCase.name)")
                #expect(dimension == 128 && embeddingDimension == 256, "collapsed-pi dimensions must be D=128 and E=256")
            }

            let rhoFeatures = try rhoTensor.float64Matrix(nonfinite: [])
            let phi = try phiTensor.float64()
            let trainingEmbeddings = try trainingTensor.float64Matrix(nonfinite: [])
            let expectedGamma = try gammaTensor.float64Matrix(nonfinite: [])
            let expectedPi = try piTensor.float64()
            let expectedElbos = try elbosTensor.float64()

            try #require(rhoFeatures.count == rowCount && rhoFeatures.allSatisfy { $0.count == dimension }, "\(fixtureCase.name): decoded rhoFeatures shape must be [N,D]")
            try #require(phi.count == dimension, "\(fixtureCase.name): decoded phi count must be D")
            try #require(trainingEmbeddings.count == rowCount && trainingEmbeddings.allSatisfy { $0.count == embeddingDimension }, "\(fixtureCase.name): decoded trainingEmbeddings shape must be [N,E]")
            try #require(expectedGamma.count == rowCount && expectedGamma.allSatisfy { $0.count == clusterCount }, "\(fixtureCase.name): decoded expectedGamma shape must be [N,K]")
            try #require(expectedPi.count == clusterCount, "\(fixtureCase.name): decoded expectedPi count must be K")
            try #require(expectedElbos.count == fixtureCase.expectedIterationCount, "\(fixtureCase.name): decoded expectedElbos count must match expectedIterationCount")
            #expect(phi.allSatisfy { $0 > 0 }, "\(fixtureCase.name): phi values must be positive")
            #expect(expectedGamma.flatMap { $0 }.allSatisfy { $0 >= 0 }, "\(fixtureCase.name): expected gamma values must be nonnegative")
            #expect(expectedPi.allSatisfy { $0 >= 0 }, "\(fixtureCase.name): expected pi values must be nonnegative")
            for row in expectedGamma {
                #expect(abs(row.reduce(0, +) - 1.0) <= 1e-12, "\(fixtureCase.name): each expected gamma row must sum to one")
            }
            #expect(abs(expectedPi.reduce(0, +) - 1.0) <= 1e-12, "\(fixtureCase.name): expected pi must sum to one")

            let result = try Community1VBx.refine(
                rhoFeatures: rhoFeatures,
                initialClusters: fixtureCase.initialClusters,
                phi: phi
            )
            try #require(result.pi.count == clusterCount, "\(fixtureCase.name): replayed pi count must be K")
            try #require(result.elbos.count == expectedElbos.count, "\(fixtureCase.name): replayed ELBO count must match the fixture")
            #expect(result.iterationCount == fixtureCase.expectedIterationCount, "\(fixtureCase.name): iteration count differs from the fixture")
            #expect(result.pi.allSatisfy { $0.isFinite && $0 >= 0 }, "\(fixtureCase.name): replayed pi must be finite and nonnegative")
            #expect(abs(result.pi.reduce(0, +) - 1.0) <= 1e-12, "\(fixtureCase.name): replayed pi must sum to one")
            #expect(result.elbos.allSatisfy { $0.isFinite }, "\(fixtureCase.name): replayed ELBO values must be finite")

            var maxGammaError = 0.0
            for row in 0..<rowCount {
                let replayedGamma = try result.posterior.responsibilities(rho: rhoFeatures[row])
                try #require(replayedGamma.count == clusterCount, "\(fixtureCase.name): replayed gamma row must have K entries")
                #expect(replayedGamma.allSatisfy { $0.isFinite && $0 >= 0 }, "\(fixtureCase.name): replayed gamma values must be finite and nonnegative")
                #expect(abs(replayedGamma.reduce(0, +) - 1.0) <= 1e-12, "\(fixtureCase.name): replayed gamma row must sum to one")
                for cluster in 0..<clusterCount {
                    maxGammaError = max(maxGammaError, abs(replayedGamma[cluster] - expectedGamma[row][cluster]))
                }
            }

            var maxPiError = 0.0
            for cluster in 0..<clusterCount {
                maxPiError = max(maxPiError, abs(result.pi[cluster] - expectedPi[cluster]))
            }

            var maxElboError = 0.0
            for iteration in expectedElbos.indices {
                maxElboError = max(maxElboError, abs(result.elbos[iteration] - expectedElbos[iteration]))
            }

            // synthetic-k7/k8 gamma comparisons guard that saved posterior replay uses the final E-step input prior, not post-update pi; do not run another E/M iteration.
            #expect(maxGammaError <= 1e-6, "\(fixtureCase.name): maximum gamma error is \(maxGammaError), expected <= 1e-6")
            #expect(maxPiError <= 1e-6, "\(fixtureCase.name): maximum pi error is \(maxPiError), expected <= 1e-6")
            #expect(maxElboError <= 1e-6, "\(fixtureCase.name): maximum ELBO error is \(maxElboError), expected <= 1e-6")

            let baselineCentroids = try Community1Centroids.compute(
                trainingEmbeddings: trainingEmbeddings,
                gamma: expectedGamma,
                pi: expectedPi
            )
            let streamedCentroids = try Community1Centroids.compute(
                trainingEmbeddings: trainingEmbeddings,
                rhoFeatures: rhoFeatures,
                vbx: result
            )
            #expect(
                streamedCentroids.sourceClusterIndices == baselineCentroids.sourceClusterIndices,
                "\(fixtureCase.name): streamed centroid source cluster indices differ from the fixture-gamma baseline"
            )
            try #require(
                streamedCentroids.centroids.count == baselineCentroids.centroids.count,
                "\(fixtureCase.name): streamed and baseline centroid row counts must match"
            )
            var maxCentroidError = 0.0
            for row in baselineCentroids.centroids.indices {
                try #require(
                    streamedCentroids.centroids[row].count == baselineCentroids.centroids[row].count,
                    "\(fixtureCase.name): streamed and baseline centroid row shapes must match at row \(row)"
                )
                for coordinate in baselineCentroids.centroids[row].indices {
                    maxCentroidError = max(
                        maxCentroidError,
                        abs(streamedCentroids.centroids[row][coordinate] - baselineCentroids.centroids[row][coordinate])
                    )
                }
            }
            #expect(maxCentroidError <= 1e-9, "\(fixtureCase.name): maximum centroid error is \(maxCentroidError), expected <= 1e-9")

            containsTwentyIterations = containsTwentyIterations || fixtureCase.expectedIterationCount == 20
            containsEarlyConvergence = containsEarlyConvergence || fixtureCase.expectedIterationCount < 20
            if fixtureCase.name == "collapsed-pi" {
                let minimumExpectedPi = try #require(expectedPi.min(), "collapsed-pi: expected pi must be nonempty")
                #expect(minimumExpectedPi < 1e-7, "collapsed-pi: minimum expected pi is \(minimumExpectedPi), expected < 1e-7")
                #expect(streamedCentroids.sourceClusterIndices == [0], "collapsed-pi: streamed active source indices must be [0]")
            }

            print(
                "VBx parity \(fixtureCase.name): max gamma error=\(maxGammaError), "
                    + "pi error=\(maxPiError), ELBO error=\(maxElboError), centroid error=\(maxCentroidError)"
            )
        }

        #expect(containsTwentyIterations, "VBx fixture must include a 20-iteration case")
        #expect(containsEarlyConvergence, "VBx fixture must include an early-converging case")
    }
}
