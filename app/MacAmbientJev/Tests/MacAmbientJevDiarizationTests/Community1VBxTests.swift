import Testing
@testable import MacAmbientJevDiarization

@Suite struct Community1VBxTests {
    @Test func oneSpeakerConvergesAfterSecondEPassAndReplaysUnitPosterior() throws {
        let result = try Community1VBx.refine(
            rhoFeatures: [[1, 2], [-1, 3], [0.3, -0.2]],
            initialClusters: [0, 0, 0],
            phi: [0.8, 1.2]
        )

        #expect(result.iterationCount == 2)
        #expect(result.elbos.count == 2)
        #expect(result.elbos.allSatisfy { $0.isFinite })
        #expect(result.pi == [1])
        #expect(result.posterior.speakerCount == 1)
        #expect(result.posterior.dimension == 2)
        for rho in [[1.0, 2.0], [-1.0, 3.0], [0.3, -0.2]] {
            #expect(try result.posterior.responsibilities(rho: rho) == [1])
        }
    }

    @Test func separatedSpeakersProduceFiniteNormalizedPosteriorAndPriors() throws {
        let result = try Community1VBx.refine(
            rhoFeatures: [[-2, 0], [-1.8, 0.1], [1.8, -0.1], [2, 0]],
            initialClusters: [0, 0, 1, 1],
            phi: [1, 0.7]
        )

        #expect(result.iterationCount >= 2)
        #expect(result.iterationCount <= Community1Profile.maximumIterations)
        #expect(result.elbos.count == result.iterationCount)
        #expect(result.elbos.allSatisfy { $0.isFinite })
        #expect(result.pi.count == 2)
        #expect(result.pi.allSatisfy { $0.isFinite && $0 >= 0 })
        #expect(abs(result.pi.reduce(0, +) - 1) < 1e-12)
        #expect(result.posterior.speakerCount == 2)

        for rho in [[-2.0, 0], [-1.8, 0.1], [1.8, -0.1], [2.0, 0]] {
            let probabilities = try result.posterior.responsibilities(rho: rho)
            #expect(probabilities.count == 2)
            #expect(probabilities.allSatisfy { $0.isFinite && $0 >= 0 })
            #expect(abs(probabilities.reduce(0, +) - 1) < 1e-12)
        }
    }

    @Test func phiFloorMatchesExplicitlyClampedInput() throws {
        let rhoFeatures = [[1.0, 2.0], [-1.0, 3.0]]
        let initialClusters = [0, 1]
        let floored = try Community1VBx.refine(
            rhoFeatures: rhoFeatures,
            initialClusters: initialClusters,
            phi: [0, -1]
        )
        let explicitFloor = try Community1VBx.refine(
            rhoFeatures: rhoFeatures,
            initialClusters: initialClusters,
            phi: [1e-12, 1e-12]
        )

        #expect(floored.pi == explicitFloor.pi)
        #expect(floored.elbos == explicitFloor.elbos)
        for rho in rhoFeatures {
            #expect(try floored.posterior.responsibilities(rho: rho)
                == explicitFloor.posterior.responsibilities(rho: rho))
        }
    }

    @Test func rejectsEmptyJaggedAndNonfiniteFeatures() {
        #expect(throws: VBxError.self) {
            try Community1VBx.refine(rhoFeatures: [], initialClusters: [], phi: [1])
        }
        #expect(throws: VBxError.self) {
            try Community1VBx.refine(rhoFeatures: [[]], initialClusters: [0], phi: [])
        }
        #expect(throws: VBxError.self) {
            try Community1VBx.refine(rhoFeatures: [[1], [1, 2]], initialClusters: [0, 0], phi: [1])
        }
        #expect(throws: VBxError.self) {
            try Community1VBx.refine(rhoFeatures: [[.nan]], initialClusters: [0], phi: [1])
        }
        #expect(throws: VBxError.self) {
            try Community1VBx.refine(rhoFeatures: [[.infinity]], initialClusters: [0], phi: [1])
        }
    }

    @Test func rejectsInvalidPhiAndClusterAssignments() {
        #expect(throws: VBxError.self) {
            try Community1VBx.refine(rhoFeatures: [[1, 2]], initialClusters: [0], phi: [1])
        }
        #expect(throws: VBxError.self) {
            try Community1VBx.refine(rhoFeatures: [[1]], initialClusters: [0], phi: [.nan])
        }
        #expect(throws: VBxError.self) {
            try Community1VBx.refine(rhoFeatures: [[1]], initialClusters: [], phi: [1])
        }
        #expect(throws: VBxError.self) {
            try Community1VBx.refine(rhoFeatures: [[1]], initialClusters: [-1], phi: [1])
        }
        #expect(throws: VBxError.self) {
            try Community1VBx.refine(rhoFeatures: [[1], [2]], initialClusters: [0, 2], phi: [1])
        }
    }

    @Test func rejectsFiniteInputsWhoseArithmeticOverflows() {
        #expect(throws: VBxError.self) {
            try Community1VBx.refine(
                rhoFeatures: [[Double.greatestFiniteMagnitude]],
                initialClusters: [0],
                phi: [1]
            )
        }
    }

    @Test func cancellationPropagatesFromCurrentTask() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) {
                try Community1VBx.refine(
                    rhoFeatures: [[1, 2], [3, 4]],
                    initialClusters: [0, 0],
                    phi: [1, 1]
                )
            }
        }
        await task.value
    }
}
