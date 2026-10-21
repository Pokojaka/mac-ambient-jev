#if os(macOS)
import CoreML
import Foundation
import Testing
@testable import FluidAudio

private struct DiarizationVBxParityInput {
    let name: String
    let construction: String
    let rhoFeatures: [[Double]]
    let phi: [Double]
    let initialClusters: [Int]
    let trainingEmbeddings: [[Double]]
}

extension DiarizationParityFixtureTests {
    @Test
    func vbxMatchesFluidAudio() throws {
        let config = try DiarizationParityOracle.config()
        let cases = syntheticVBxParityCases()
            + scalarVBxParityCases()
            + [collapsedPiVBxParityCase()]
        let expectedCaseNames = (2...8).map { "synthetic-k\($0)" }
            + ["scalar-x3", "scalar-x4", "scalar-x4.5", "scalar-x5", "collapsed-pi"]
        try #require(cases.map(\.name) == expectedCaseNames, "VBx parity case order must remain fixed")

        var serializedCases: [[String: Any]] = []
        serializedCases.reserveCapacity(cases.count)
        var iterationCounts: [String: Int] = [:]
        var collapsedMinimumPi: Double?

        for fixtureCase in cases {
            let output = try runVBxParityCase(fixtureCase, config: config)
            iterationCounts[fixtureCase.name] = output.elbos.count
            if fixtureCase.name == "collapsed-pi" {
                collapsedMinimumPi = output.pi.min()
            }
            serializedCases.append(try serializeVBxParityCase(fixtureCase, output: output))
        }

        let sortedIterationCounts = iterationCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        try #require(
            iterationCounts.values.contains(20),
            "Fixed VBx inputs must include a 20-iteration result; actual iteration counts: \(sortedIterationCounts)"
        )
        try #require(
            iterationCounts.values.contains(where: { $0 < 20 }),
            "Fixed VBx inputs must include an early-converging result; actual iteration counts: \(sortedIterationCounts)"
        )
        let minimumCollapsedPi = try #require(collapsedMinimumPi)
        try #require(
            minimumCollapsedPi < 1e-7,
            "collapsed-pi must produce pi below 1e-7; actual minimum pi: \(minimumCollapsedPi)"
        )

        let fixture: [String: Any] = [
            "metadata": DiarizationParityOracle.metadata(
                inputConstruction: "Every expected value is observed from the pinned FluidAudio 0.15.8 revision 87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc VBxClustering.refine(rhoFeatures:initialClusters:) call with DiarizationParityOracle.config(). No model assets are loaded and no inference is run. PLDATransform receives a plain MLModel() only as the inert constructor holder required by its API; VBxClustering.refine reads only PLDATransform.phiParameters (VBxClustering.swift:72-77; PLDATransform.swift:17-22). The synthetic-k2 through synthetic-k8 cases use N=3*K, D=128, E=256, with labels[row]=row%K, prescribed synthetic rho features and positive decaying phi values; their stored training embeddings use the unchanged normalized synthetic embedding construction. Scalar-x3/x4/x4.5/x5 retain their fixed one-dimensional convergence-stress inputs, and collapsed-pi retains its fixed 128-dimensional collapsed-prior input. Cases are ordered synthetic-k2 through synthetic-k8, scalar-x3/x4/x4.5/x5, collapsed-pi.",
                comparisonRule: "The fixture contains only name, construction, rhoFeatures, phi, initialClusters, trainingEmbeddings, expectedGamma, expectedPi, expectedElbos, and expectedIterationCount per case. Tensor values use the existing exact IEEE-754 little-endian float64 encoding; the portable comparison tolerance for computed gamma/pi/ELBO values is maximum absolute error 1e-6, and downstream centroid comparisons use maximum absolute error 1e-9. expectedIterationCount equals expectedElbos.shape[0]. Gamma must have N rows and K columns, pi must have K entries, all outputs must be finite, and each case must execute 2 through 20 iterations. The fixed set must include both an exactly-20-iteration case and an early-converging case; collapsed-pi must have minimum pi below 1e-7. No model paths or model binaries are stored in fixture metadata."
            ),
            "cases": serializedCases,
        ]
        try DiarizationParityOracle.checkOrWrite(fixture, named: "vbx.json")
    }
}

private func syntheticVBxParityCases() -> [DiarizationVBxParityInput] {
    (2...8).map { clusterCount in
        let rowCount = clusterCount * 3
        let dimension = 128
        let embeddingDimension = 256
        let labels = (0..<rowCount).map { $0 % clusterCount }
        let rhoFeatures = (0..<rowCount).map { row in
            (0..<dimension).map { coordinate in
                let center = coordinate % clusterCount == labels[row] ? 4.0 : -0.75
                let jitter = Double((row * 13 + coordinate * 7) % 11 - 5) * 0.025
                return center + jitter
            }
        }
        let phi = (0..<dimension).map { 0.05 + 4.0 * exp(-Double($0) / 24.0) }
        let trainingEmbeddings = normalizedSyntheticEmbeddings(
            labels: labels,
            embeddingDimension: embeddingDimension
        )
        return DiarizationVBxParityInput(
            name: "synthetic-k\(clusterCount)",
            construction: "N=\(rowCount), D=128, E=256, K=\(clusterCount); labels[row]=row%K. rho[row,d]=(d%K==label ? 4.0 : -0.75)+Double((row*13+d*7)%11-5)*0.025; phi[d]=0.05+4.0*exp(-Double(d)/24.0). Raw training values are Float32-rounded sin(Double((label+1)*(d+1))*0.17)+Double((row+d)%5-2)*0.01; their Double L2 norm is computed from those widened Float32 values, normalized coordinates are rounded to Float32, then widened to Double.",
            rhoFeatures: rhoFeatures,
            phi: phi,
            initialClusters: labels,
            trainingEmbeddings: trainingEmbeddings
        )
    }
}

private func normalizedSyntheticEmbeddings(labels: [Int], embeddingDimension: Int) -> [[Double]] {
    labels.enumerated().map { row, label in
        let floatRoundedValues: [Float] = (0..<embeddingDimension).map { (coordinate: Int) -> Float in
            let phase: Double = Double((label + 1) * (coordinate + 1)) * 0.17
            let wave: Double = sin(phase)
            let jitter: Double = Double((row + coordinate) % 5 - 2) * 0.01
            return Float(wave + jitter)
        }
        let squaredNorm = floatRoundedValues.reduce(0.0) { partial, value in
            partial + Double(value) * Double(value)
        }
        let norm = sqrt(squaredNorm)
        return floatRoundedValues.map { Double(Float(Double($0) / norm)) }
    }
}

private func scalarVBxParityCases() -> [DiarizationVBxParityInput] {
    [3.0, 4.0, 4.5, 5.0].map { magnitude in
        let rowCount = 60
        let labels = (0..<rowCount).map { $0 < 30 ? 0 : 1 }
        let rhoFeatures = (0..<rowCount).map { row in
            [row < 30 ? -magnitude : magnitude]
        }
        let trainingEmbeddings = (0..<rowCount).map { row in
            (0..<8).map { coordinate in
                Double(Float((row < 30 ? -1.0 : 1.0) + Double(coordinate) * 0.01))
            }
        }
        let caseName = magnitude.rounded(.towardZero) == magnitude
            ? "scalar-x\(Int(magnitude))"
            : "scalar-x\(magnitude)"
        return DiarizationVBxParityInput(
            name: caseName,
            construction: "N=60, D=1, E=8, K=2; rows 0..<30 use label 0 and rho=-\(magnitude), rows 30..<60 use label 1 and rho=\(magnitude); phi=[1]. training[row,d]=Double(Float((row<30 ? -1.0 : 1.0)+Double(d)*0.01)). This is a fixed convergence-stress candidate, not an output-selected search.",
            rhoFeatures: rhoFeatures,
            phi: [1.0],
            initialClusters: labels,
            trainingEmbeddings: trainingEmbeddings
        )
    }
}

private func collapsedPiVBxParityCase() -> DiarizationVBxParityInput {
    let rowCount = 16
    let embeddingDimension = 256
    let labels = (0..<rowCount).map { $0 < 15 ? 0 : 1 }
    let rhoFeatures = Array(repeating: Array(repeating: 3.0, count: 128), count: rowCount)
    let trainingEmbeddings = (0..<rowCount).map { row in
        (0..<embeddingDimension).map { coordinate in
            Double(Float(sin(Double((row + 1) * (coordinate + 1)) * 0.07)))
        }
    }
    return DiarizationVBxParityInput(
        name: "collapsed-pi",
        construction: "N=16, D=128, E=256, K=2; every rho coordinate is 3.0; phi is 128 copies of 1.0; initial labels are fifteen 0s followed by one 1. training[row,d]=Double(Float(sin(Double((row+1)*(d+1))*0.07))). Exercises the log-prior floor and an inactive centroid.",
        rhoFeatures: rhoFeatures,
        phi: Array(repeating: 1.0, count: 128),
        initialClusters: labels,
        trainingEmbeddings: trainingEmbeddings
    )
}

private func runVBxParityCase(
    _ fixtureCase: DiarizationVBxParityInput,
    config: OfflineDiarizerConfig
) throws -> VBxOutput {
    guard let dimension = fixtureCase.rhoFeatures.first?.count, dimension > 0 else {
        throw DiarizationParityOracleError.invalidTensor("\(fixtureCase.name): rho features must have positive dimensions")
    }
    let rowCount = fixtureCase.rhoFeatures.count
    let clusterCount = Set(fixtureCase.initialClusters).count
    let embeddingDimension = fixtureCase.trainingEmbeddings.first?.count ?? 0
    try #require(rowCount > 0, "\(fixtureCase.name): rho features must contain rows")
    try #require(fixtureCase.rhoFeatures.allSatisfy { $0.count == dimension }, "\(fixtureCase.name): rho rows must have a common dimension")
    try #require(fixtureCase.phi.count == dimension, "\(fixtureCase.name): phi dimension must match rho features")
    try #require(fixtureCase.initialClusters.count == rowCount, "\(fixtureCase.name): initial cluster count must match rho rows")
    try #require(clusterCount >= 2, "\(fixtureCase.name): VBx parity requires at least two initial clusters")
    try #require(fixtureCase.trainingEmbeddings.count == rowCount, "\(fixtureCase.name): training embeddings must match rho rows")
    try #require(embeddingDimension > 0, "\(fixtureCase.name): training embeddings must have positive dimensions")
    try #require(fixtureCase.trainingEmbeddings.allSatisfy { $0.count == embeddingDimension }, "\(fixtureCase.name): training embedding rows must have a common dimension")
    try #require(fixtureCase.rhoFeatures.flatMap { $0 }.allSatisfy { $0.isFinite }, "\(fixtureCase.name): rho features must be finite")
    try #require(fixtureCase.phi.allSatisfy { $0.isFinite }, "\(fixtureCase.name): phi must be finite")
    try #require(fixtureCase.trainingEmbeddings.flatMap { $0 }.allSatisfy { $0.isFinite }, "\(fixtureCase.name): training embeddings must be finite")

    // VBxClustering.refine reads only phiParameters; this inert holder is required by PLDATransform's initializer.
    let pldaTransform = PLDATransform(pldaRhoModel: MLModel(), psi: fixtureCase.phi)
    try #require(
        pldaTransform.phiParameters == fixtureCase.phi,
        "\(fixtureCase.name): PLDATransform must expose the fixture phi parameters"
    )
    let output = VBxClustering(config: config, pldaTransform: pldaTransform).refine(
        rhoFeatures: fixtureCase.rhoFeatures,
        initialClusters: fixtureCase.initialClusters
    )
    try #require(output.numClusters == clusterCount, "\(fixtureCase.name): FluidAudio output cluster count must equal K")
    try #require(output.gamma.count == rowCount, "\(fixtureCase.name): gamma row count must equal N")
    try #require(output.gamma.allSatisfy { $0.count == clusterCount }, "\(fixtureCase.name): gamma must have K columns")
    try #require(output.pi.count == clusterCount, "\(fixtureCase.name): pi count must equal K")
    try #require((2...20).contains(output.elbos.count), "\(fixtureCase.name): FluidAudio must produce 2 through 20 ELBO values, got \(output.elbos.count)")
    try #require(output.gamma.flatMap { $0 }.allSatisfy { $0.isFinite }, "\(fixtureCase.name): gamma values must be finite")
    try #require(output.pi.allSatisfy { $0.isFinite }, "\(fixtureCase.name): pi values must be finite")
    try #require(output.elbos.allSatisfy { $0.isFinite }, "\(fixtureCase.name): ELBO values must be finite")
    try #require(output.gamma.flatMap { $0 }.allSatisfy { $0 >= 0 }, "\(fixtureCase.name): gamma values must be nonnegative")
    try #require(output.pi.allSatisfy { $0 >= 0 }, "\(fixtureCase.name): pi values must be nonnegative")
    try #require(
        output.gamma.allSatisfy { abs($0.reduce(0, +) - 1.0) <= 1e-9 },
        "\(fixtureCase.name): each gamma row must sum to one"
    )
    try #require(abs(output.pi.reduce(0, +) - 1.0) <= 1e-9, "\(fixtureCase.name): pi must sum to one")
    return output
}

private func serializeVBxParityCase(
    _ fixtureCase: DiarizationVBxParityInput,
    output: VBxOutput
) throws -> [String: Any] {
    let rowCount = fixtureCase.rhoFeatures.count
    let dimension = fixtureCase.rhoFeatures[0].count
    let clusterCount = output.pi.count
    let embeddingDimension = fixtureCase.trainingEmbeddings[0].count
    let iterationCount = output.elbos.count
    return [
        "name": fixtureCase.name,
        "construction": fixtureCase.construction,
        "rhoFeatures": try DiarizationParityOracle.tensor(
            fixtureCase.rhoFeatures.flatMap { $0 },
            shape: [rowCount, dimension]
        ),
        "phi": try DiarizationParityOracle.tensor(fixtureCase.phi, shape: [dimension]),
        "initialClusters": fixtureCase.initialClusters,
        "trainingEmbeddings": try DiarizationParityOracle.tensor(
            fixtureCase.trainingEmbeddings.flatMap { $0 },
            shape: [rowCount, embeddingDimension]
        ),
        "expectedGamma": try DiarizationParityOracle.tensor(
            output.gamma.flatMap { $0 },
            shape: [rowCount, clusterCount]
        ),
        "expectedPi": try DiarizationParityOracle.tensor(output.pi, shape: [clusterCount]),
        "expectedElbos": try DiarizationParityOracle.tensor(output.elbos, shape: [iterationCount]),
        "expectedIterationCount": iterationCount,
    ]
}
#endif
