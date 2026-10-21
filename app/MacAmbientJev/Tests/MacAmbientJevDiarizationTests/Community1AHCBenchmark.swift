import Foundation
import Testing
@testable import MacAmbientJevDiarization

/// Benchmarks the fixed Community-1 AHC profile (cut 0.6) using the pinned
/// FluidAudio 0.15.8 vector-heap implementation (O(ND)); the source anchor is
/// https://github.com/FluidInference/FluidAudio/blob/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FastClusterWrapper/fastcluster_internal.hpp.
/// The implementation uses a root-first threshold cut, not a monotone-height
/// shortcut. Generated eight-speaker clusters are synthetic and do not claim to
/// represent embeddings produced by a real model.
@Suite struct Community1AHCBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_AMBIENT_JEV_RUN_AHC_BENCHMARK"] == "1"), .timeLimit(.minutes(10)))
    func clusteredEmbeddings() throws {
        #if DEBUG
        throw Community1AHCBenchmarkError.invalidCount("Community1AHCBenchmark requires -c release")
        #else
        let countVariable = "MAC_AMBIENT_JEV_AHC_BENCHMARK_N"
        guard let countText = ProcessInfo.processInfo.environment[countVariable] else {
            throw Community1AHCBenchmarkError.invalidCount("\(countVariable) is required when MAC_AMBIENT_JEV_RUN_AHC_BENCHMARK is enabled")
        }
        guard let pointCount = Int(countText) else {
            throw Community1AHCBenchmarkError.invalidCount("\(countVariable) must be a positive Int multiple of 160; got '\(countText)'")
        }
        guard pointCount > 0, pointCount.isMultiple(of: 160) else {
            throw Community1AHCBenchmarkError.invalidCount("\(countVariable) must be a positive Int multiple of 160; got '\(countText)'")
        }

        let dimension = Community1Profile.embeddingDimensions
        try #require(dimension == 256, "Community1Profile.embeddingDimensions must remain 256 for this benchmark")
        _ = try Community1AHC.checkedShape(pointCount: pointCount, dimension: dimension)

        let clock = ContinuousClock()
        let generationStart = clock.now
        var generator = Community1AHCBenchmarkSplitMix64(state: 0xA8C0_1600_0256_0008)
        var centers = [[Double]]()
        centers.reserveCapacity(8)
        for centerIndex in 0..<8 {
            try Task.checkCancellation()
            var center = [Double]()
            center.reserveCapacity(dimension)
            for _ in 0..<dimension {
                center.append(generator.nextSignedUniform())
            }
            centers.append(try unitNormalize(center, context: "center \(centerIndex)"))
        }

        var input = [[Double]]()
        input.reserveCapacity(pointCount)
        for rowIndex in 0..<pointCount {
            try Task.checkCancellation()
            let speaker = (rowIndex / 20) % 8
            var row = [Double]()
            row.reserveCapacity(dimension)
            for coordinateIndex in 0..<dimension {
                row.append(centers[speaker][coordinateIndex] + 0.025 * generator.nextSignedUniform())
            }
            input.append(try unitNormalize(row, context: "row \(rowIndex)"))
        }
        let generationEnd = clock.now
        let generationSeconds = seconds(generationStart.duration(to: generationEnd))

        let ahcStart = clock.now
        let result = try Community1AHC.cluster(embeddingFeatures: input)
        let ahcEnd = clock.now
        let ahcSeconds = seconds(ahcStart.duration(to: ahcEnd))
        withExtendedLifetime(input) {}

        let expectedLabels = (0..<pointCount).map { ($0 / 20) % 8 }
        #expect(result.labels == expectedLabels)
        #expect(result.linkage.count == pointCount - 1)
        #expect(Set(result.labels).count == 8)
        let root = try #require(result.linkage.last, "AHC must return a root merge for N > 1")
        #expect(root.size == pointCount)
        #expect(result.linkage.allSatisfy { $0.height.isFinite })

        print("AHC_BENCHMARK {\"N\":\(pointCount),\"D\":\(dimension),\"speakers\":8,\"input_generation_seconds\":\(generationSeconds),\"ahc_seconds\":\(ahcSeconds),\"merges\":\(result.linkage.count),\"cluster_count\":\(Set(result.labels).count)}")
        #endif
    }
}

private enum Community1AHCBenchmarkError: Error, CustomStringConvertible {
    case invalidCount(String)
    case invalidVector(String)

    var description: String {
        switch self {
        case let .invalidCount(message):
            return "Invalid AHC benchmark count: \(message)"
        case let .invalidVector(message):
            return "Invalid generated AHC benchmark vector: \(message)"
        }
    }
}

private struct Community1AHCBenchmarkSplitMix64 {
    var state: UInt64

    mutating func nextSignedUniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return 2 * Double((value ^ (value >> 31)) >> 11) / 9_007_199_254_740_992 - 1
    }
}

private func unitNormalize(_ values: [Double], context: String) throws -> [Double] {
    var squaredNorm = 0.0
    for value in values {
        guard value.isFinite else {
            throw Community1AHCBenchmarkError.invalidVector("\(context) contains a nonfinite coordinate")
        }
        squaredNorm += value * value
        guard squaredNorm.isFinite else {
            throw Community1AHCBenchmarkError.invalidVector("\(context) has a nonfinite squared norm")
        }
    }
    guard squaredNorm > 0 else {
        throw Community1AHCBenchmarkError.invalidVector("\(context) has a zero squared norm")
    }

    let scale = 1.0 / sqrt(squaredNorm)
    let normalized = values.map { $0 * scale }
    guard normalized.allSatisfy(\.isFinite) else {
        throw Community1AHCBenchmarkError.invalidVector("\(context) normalized to a nonfinite coordinate")
    }
    return normalized
}

private func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
}
