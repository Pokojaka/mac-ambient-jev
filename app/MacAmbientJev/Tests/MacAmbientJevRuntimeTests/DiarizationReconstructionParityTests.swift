#if os(macOS)
import Foundation
import Testing
@testable import FluidAudio

private struct ReconstructionActivity {
    let chunkIndex: Int
    let localSpeakerIndex: Int
    let frames: Range<Int>
}

private struct ReconstructionFixtureCase {
    let name: String
    let construction: String
    let sampleCount: Int
    let clusterCount: Int
    let numFrames: Int
    let numSpeakers: Int
    let frameDuration: Double
    let chunkOffsets: [Double]
    let speakerWeights: [[[Float]]]
    let hardClusters: [[Int]]
}

private enum ReconstructionFixtureError: Error, CustomStringConvertible {
    case invalidConstruction(name: String, reason: String)
    case equalStartDifferentSpeakers(name: String, time: Float, firstID: String, secondID: String)

    var description: String {
        switch self {
        case .invalidConstruction(let name, let reason):
            return "Invalid reconstruction fixture case \(name): \(reason)"
        case .equalStartDifferentSpeakers(let name, let time, let firstID, let secondID):
            return "Ambiguous reconstruction fixture case \(name): \(firstID) and \(secondID) "
                + "start at the same Float32 time \(time)"
        }
    }
}

private func makeReconstructionCase(
    name: String,
    construction: String,
    sampleCount: Int,
    clusterCount: Int,
    numFrames: Int,
    numSpeakers: Int,
    frameDuration: Double,
    chunkOffsets: [Double],
    hardClusters: [[Int]],
    activities: [ReconstructionActivity]
) throws -> ReconstructionFixtureCase {
    guard sampleCount > 0, clusterCount > 0, numFrames > 0, numSpeakers == 3, frameDuration > 0 else {
        throw ReconstructionFixtureError.invalidConstruction(
            name: name,
            reason: "sampleCount, clusterCount, numFrames and frameDuration must be positive; numSpeakers must be 3"
        )
    }
    guard !chunkOffsets.isEmpty, chunkOffsets.count == hardClusters.count else {
        throw ReconstructionFixtureError.invalidConstruction(
            name: name,
            reason: "chunkOffsets and hardClusters must have the same positive chunk count"
        )
    }
    guard chunkOffsets.allSatisfy(\.isFinite) else {
        throw ReconstructionFixtureError.invalidConstruction(name: name, reason: "chunkOffsets must be finite")
    }
    guard hardClusters.allSatisfy({ assignments in
        assignments.count == numSpeakers
            && assignments.allSatisfy { $0 == -2 || (0..<clusterCount).contains($0) }
    }) else {
        throw ReconstructionFixtureError.invalidConstruction(
            name: name,
            reason: "each chunk must assign all three local speakers to -2 or a valid cluster index"
        )
    }

    var speakerWeights = Array(
        repeating: Array(repeating: Array(repeating: Float.zero, count: numSpeakers), count: numFrames),
        count: chunkOffsets.count
    )
    for activity in activities {
        guard chunkOffsets.indices.contains(activity.chunkIndex) else {
            throw ReconstructionFixtureError.invalidConstruction(
                name: name,
                reason: "activity chunk index \(activity.chunkIndex) is out of range"
            )
        }
        guard (0..<numSpeakers).contains(activity.localSpeakerIndex) else {
            throw ReconstructionFixtureError.invalidConstruction(
                name: name,
                reason: "activity local speaker index \(activity.localSpeakerIndex) is out of range"
            )
        }
        guard activity.frames.lowerBound >= 0,
            activity.frames.upperBound <= numFrames,
            !activity.frames.isEmpty
        else {
            throw ReconstructionFixtureError.invalidConstruction(
                name: name,
                reason: "activity range \(activity.frames) must be nonempty and within 0..<\(numFrames)"
            )
        }
        for frame in activity.frames {
            guard speakerWeights[activity.chunkIndex][frame][activity.localSpeakerIndex] == 0 else {
                throw ReconstructionFixtureError.invalidConstruction(
                    name: name,
                    reason: "activity ranges overlap for chunk \(activity.chunkIndex), "
                        + "local speaker \(activity.localSpeakerIndex), frame \(frame)"
                )
            }
            speakerWeights[activity.chunkIndex][frame][activity.localSpeakerIndex] = 1
        }
    }

    return ReconstructionFixtureCase(
        name: name,
        construction: construction,
        sampleCount: sampleCount,
        clusterCount: clusterCount,
        numFrames: numFrames,
        numSpeakers: numSpeakers,
        frameDuration: frameDuration,
        chunkOffsets: chunkOffsets,
        speakerWeights: speakerWeights,
        hardClusters: hardClusters
    )
}

private func reconstruct(
    _ fixtureCase: ReconstructionFixtureCase,
    config: OfflineDiarizerConfig
) -> [TimedSpeakerSegment] {
    OfflineReconstruction(config: config).buildSegments(
        segmentation: SegmentationOutput(
            logProbs: [],
            speakerWeights: fixtureCase.speakerWeights,
            numChunks: fixtureCase.chunkOffsets.count,
            numFrames: fixtureCase.numFrames,
            numSpeakers: fixtureCase.numSpeakers,
            chunkOffsets: fixtureCase.chunkOffsets,
            frameDuration: fixtureCase.frameDuration
        ),
        hardClusters: fixtureCase.hardClusters,
        centroids: Array(repeating: [0.0], count: fixtureCase.clusterCount),
        spanEmbedder: nil
    )
}

private func assertNoEqualStartAcrossSpeakers(
    _ segments: [TimedSpeakerSegment],
    caseName: String
) throws {
    for firstIndex in segments.indices {
        for secondIndex in segments.indices where secondIndex > firstIndex {
            let first = segments[firstIndex]
            let second = segments[secondIndex]
            guard first.speakerId != second.speakerId,
                first.startTimeSeconds.bitPattern == second.startTimeSeconds.bitPattern
            else {
                continue
            }
            throw ReconstructionFixtureError.equalStartDifferentSpeakers(
                name: caseName,
                time: first.startTimeSeconds,
                firstID: first.speakerId,
                secondID: second.speakerId
            )
        }
    }
}

extension DiarizationParityFixtureTests {
    @Test
    func reconstructionMatchesFluidAudio() throws {
        let frameDuration589 = 10.0 / 589.0
        let cases = try [
            makeReconstructionCase(
                name: "overlap-exclusive",
                construction: "One chunk, 589 frames at 10/589 seconds per frame, offset 0, sampleCount 160000. "
                    + "Assignments are [0,1,-2]. All unlisted weights are zero; local speaker 0 is one on "
                    + "0..<200 and local speaker 1 is one on 100..<300.",
                sampleCount: 160_000,
                clusterCount: 2,
                numFrames: 589,
                numSpeakers: 3,
                frameDuration: frameDuration589,
                chunkOffsets: [0],
                hardClusters: [[0, 1, -2]],
                activities: [
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 0..<200),
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 1, frames: 100..<300),
                ]
            ),
            makeReconstructionCase(
                name: "exclusive-trim-short",
                construction: "One chunk, 589 frames at 10/589 seconds per frame, offset 0, sampleCount 160000. "
                    + "Assignments are [0,1,-2]. All unlisted weights are zero; local speaker 0 is one on "
                    + "0..<200 and local speaker 1 is one on 100..<210.",
                sampleCount: 160_000,
                clusterCount: 2,
                numFrames: 589,
                numSpeakers: 3,
                frameDuration: frameDuration589,
                chunkOffsets: [0],
                hardClusters: [[0, 1, -2]],
                activities: [
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 0..<200),
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 1, frames: 100..<210),
                ]
            ),
            makeReconstructionCase(
                name: "unassigned-local",
                construction: "One chunk, 589 frames at 10/589 seconds per frame, offset 0, sampleCount 160000. "
                    + "Assignments are [0,-2,-2]. All unlisted weights are zero; local speaker 0 is one on "
                    + "0..<100 and unassigned local speaker 1 is one on 140..<240.",
                sampleCount: 160_000,
                clusterCount: 1,
                numFrames: 589,
                numSpeakers: 3,
                frameDuration: frameDuration589,
                chunkOffsets: [0],
                hardClusters: [[0, -2, -2]],
                activities: [
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 0..<100),
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 1, frames: 140..<240),
                ]
            ),
            makeReconstructionCase(
                name: "duplicate-cluster",
                construction: "One chunk, 589 frames at 10/589 seconds per frame, offset 0, sampleCount 160000. "
                    + "Assignments are [0,0,-2]. All unlisted weights are zero; local speaker 0 is one on "
                    + "0..<100 and local speaker 1 is one on 50..<150.",
                sampleCount: 160_000,
                clusterCount: 1,
                numFrames: 589,
                numSpeakers: 3,
                frameDuration: frameDuration589,
                chunkOffsets: [0],
                hardClusters: [[0, 0, -2]],
                activities: [
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 0..<100),
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 1, frames: 50..<150),
                ]
            ),
            makeReconstructionCase(
                name: "count-half-even-zero",
                construction: "Two chunks of 589 frames at 10/589 seconds per frame, offsets [0,2], sampleCount "
                    + "192000. Assignments are [0,-2,-2] in both chunks. All unlisted weights are zero; chunk 0 "
                    + "local speaker 0 is one on 0..<589 and chunk 1 is silent. The 0.5 mean count in the "
                    + "overlap tests nearest-even rounding to zero.",
                sampleCount: 192_000,
                clusterCount: 1,
                numFrames: 589,
                numSpeakers: 3,
                frameDuration: frameDuration589,
                chunkOffsets: [0, 2],
                hardClusters: [[0, -2, -2], [0, -2, -2]],
                activities: [
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 0..<589),
                ]
            ),
            makeReconstructionCase(
                name: "count-half-even-two",
                construction: "Two chunks of 589 frames at 10/589 seconds per frame, offsets [0,2], sampleCount "
                    + "192000. Assignments are [0,1,-2] in both chunks. All unlisted weights are zero; chunk 0 "
                    + "local speaker 0 is one on 0..<589; chunk 1 local speaker 0 is one on 0..<471 and local "
                    + "speaker 1 is one on 0..<589. The 1.5 overlap mean tests nearest-even rounding to two.",
                sampleCount: 192_000,
                clusterCount: 2,
                numFrames: 589,
                numSpeakers: 3,
                frameDuration: frameDuration589,
                chunkOffsets: [0, 2],
                hardClusters: [[0, 1, -2], [0, 1, -2]],
                activities: [
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 0..<589),
                    ReconstructionActivity(chunkIndex: 1, localSpeakerIndex: 0, frames: 0..<471),
                    ReconstructionActivity(chunkIndex: 1, localSpeakerIndex: 1, frames: 0..<589),
                ]
            ),
            makeReconstructionCase(
                name: "count-half-even-two-from-2.5",
                construction: "Two chunks of 589 frames at 10/589 seconds per frame, offsets [0,2], sampleCount "
                    + "192000. Assignments are [0,1,2] in both chunks. All unlisted weights are zero; chunk 0 "
                    + "local speaker 0 is one on 0..<589 and local speaker 1 on 50..<589; chunk 1 local "
                    + "speakers 0 and 1 are one on 0..<471 and local speaker 2 on 0..<589. This deliberately "
                    + "permits triple-local activity to isolate reconstruction's 2.5 nearest-even count rounding; "
                    + "it is not a seven-class model output.",
                sampleCount: 192_000,
                clusterCount: 3,
                numFrames: 589,
                numSpeakers: 3,
                frameDuration: frameDuration589,
                chunkOffsets: [0, 2],
                hardClusters: [[0, 1, 2], [0, 1, 2]],
                activities: [
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 0..<589),
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 1, frames: 50..<589),
                    ReconstructionActivity(chunkIndex: 1, localSpeakerIndex: 0, frames: 0..<471),
                    ReconstructionActivity(chunkIndex: 1, localSpeakerIndex: 1, frames: 0..<471),
                    ReconstructionActivity(chunkIndex: 1, localSpeakerIndex: 2, frames: 0..<589),
                ]
            ),
            makeReconstructionCase(
                name: "gap-edge-float-below",
                construction: "One chunk, 200 frames at 0.01 seconds per frame, offset 0, sampleCount 32000. "
                    + "Assignments are [0,-2,-2]. All unlisted weights are zero; local speaker 0 is one on "
                    + "0..<25 and 35..<75. The nominal 0.10-second gap is below the threshold after Float32 "
                    + "boundary conversion.",
                sampleCount: 32_000,
                clusterCount: 1,
                numFrames: 200,
                numSpeakers: 3,
                frameDuration: 0.01,
                chunkOffsets: [0],
                hardClusters: [[0, -2, -2]],
                activities: [
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 0..<25),
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 35..<75),
                ]
            ),
            makeReconstructionCase(
                name: "gap-edge-float-above",
                construction: "One chunk, 200 frames at 0.01 seconds per frame, offset 0, sampleCount 32000. "
                    + "Assignments are [0,-2,-2]. All unlisted weights are zero; local speaker 0 is one on "
                    + "0..<100 and 110..<160. The nominal 0.10-second gap is above the threshold after Float32 "
                    + "boundary conversion.",
                sampleCount: 32_000,
                clusterCount: 1,
                numFrames: 200,
                numSpeakers: 3,
                frameDuration: 0.01,
                chunkOffsets: [0],
                hardClusters: [[0, -2, -2]],
                activities: [
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 0..<100),
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 110..<160),
                ]
            ),
            makeReconstructionCase(
                name: "gap-below",
                construction: "One chunk, 200 frames at 0.01 seconds per frame, offset 0, sampleCount 32000. "
                    + "Assignments are [0,-2,-2]. All unlisted weights are zero; local speaker 0 is one on "
                    + "0..<100 and 109..<159, producing a 0.09-second gap.",
                sampleCount: 32_000,
                clusterCount: 1,
                numFrames: 200,
                numSpeakers: 3,
                frameDuration: 0.01,
                chunkOffsets: [0],
                hardClusters: [[0, -2, -2]],
                activities: [
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 0..<100),
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 109..<159),
                ]
            ),
            makeReconstructionCase(
                name: "gap-above",
                construction: "One chunk, 200 frames at 0.01 seconds per frame, offset 0, sampleCount 32000. "
                    + "Assignments are [0,-2,-2]. All unlisted weights are zero; local speaker 0 is one on "
                    + "0..<100 and 111..<161, producing a 0.11-second gap.",
                sampleCount: 32_000,
                clusterCount: 1,
                numFrames: 200,
                numSpeakers: 3,
                frameDuration: 0.01,
                chunkOffsets: [0],
                hardClusters: [[0, -2, -2]],
                activities: [
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 0..<100),
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 111..<161),
                ]
            ),
            makeReconstructionCase(
                name: "subminimum",
                construction: "One chunk, 589 frames at 10/589 seconds per frame, offset 0, sampleCount 160000. "
                    + "Assignments are [0,-2,-2]. All unlisted weights are zero; local speaker 0 is one on "
                    + "0..<17, a span shorter than the configured 0.3-second minimum.",
                sampleCount: 160_000,
                clusterCount: 1,
                numFrames: 589,
                numSpeakers: 3,
                frameDuration: frameDuration589,
                chunkOffsets: [0],
                hardClusters: [[0, -2, -2]],
                activities: [
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 0..<17),
                ]
            ),
            makeReconstructionCase(
                name: "final-padded-past-eof",
                construction: "Two chunks of 589 frames at 10/589 seconds per frame, offsets [0,2], sampleCount "
                    + "33000 (2.0625 seconds at 16000 Hz). Assignments are [0,-2,-2] in both chunks. All "
                    + "weights for local speaker 0 are one on 0..<589 in both chunks; all other weights are zero. "
                    + "The second supplied chunk extends the reconstructed segment to 12 seconds on the timeline, "
                    + "beyond the 2.0625-second EOF.",
                sampleCount: 33_000,
                clusterCount: 1,
                numFrames: 589,
                numSpeakers: 3,
                frameDuration: frameDuration589,
                chunkOffsets: [0, 2],
                hardClusters: [[0, -2, -2], [0, -2, -2]],
                activities: [
                    ReconstructionActivity(chunkIndex: 0, localSpeakerIndex: 0, frames: 0..<589),
                    ReconstructionActivity(chunkIndex: 1, localSpeakerIndex: 0, frames: 0..<589),
                ]
            ),
        ]

        let config = try DiarizationParityOracle.config()
        var diagnosticConfig = config
        diagnosticConfig.embedding.minSegmentDurationSeconds = 0
        diagnosticConfig.postProcessing.exclusiveSegments = false

        var serializedCases: [[String: Any]] = []
        for fixtureCase in cases {
            let diagnosticSegments = reconstruct(fixtureCase, config: diagnosticConfig)
            try assertNoEqualStartAcrossSpeakers(diagnosticSegments, caseName: fixtureCase.name)

            let segments = reconstruct(fixtureCase, config: config)
            try assertReconstructionSemantics(segments, for: fixtureCase)
            let expectedSegments = segments.flatMap { segment in
                [segment.startTimeSeconds, segment.endTimeSeconds, segment.qualityScore]
            }
            serializedCases.append([
                "name": fixtureCase.name,
                "construction": fixtureCase.construction,
                "sampleCount": fixtureCase.sampleCount,
                "clusterCount": fixtureCase.clusterCount,
                "numFrames": fixtureCase.numFrames,
                "numSpeakers": fixtureCase.numSpeakers,
                "frameDuration": fixtureCase.frameDuration,
                "chunkOffsets": try DiarizationParityOracle.tensor(
                    fixtureCase.chunkOffsets,
                    shape: [fixtureCase.chunkOffsets.count]
                ),
                "speakerWeights": try DiarizationParityOracle.tensor(
                    fixtureCase.speakerWeights.flatMap { $0.flatMap { $0 } },
                    shape: [fixtureCase.chunkOffsets.count, fixtureCase.numFrames, fixtureCase.numSpeakers]
                ),
                "hardClusters": fixtureCase.hardClusters,
                "expectedSpeakerIDs": segments.map(\.speakerId),
                "expectedSegments": try DiarizationParityOracle.tensor(
                    expectedSegments,
                    shape: [segments.count, 3]
                ),
            ])
        }

        let fixture: [String: Any] = [
            "metadata": DiarizationParityOracle.metadata(
                inputConstruction: "Golden outputs come directly from FluidAudio 0.15.8 OfflineReconstruction "
                    + "(OfflineReconstruction.swift:24-29,69-103,145-174,187-237,359-495). Each case supplies "
                    + "SegmentationOutput.logProbs=[], binary Float32 speakerWeights, explicit chunkOffsets and "
                    + "frameDuration, hardClusters, and three local speakers. centroids is a fixed array of "
                    + "clusterCount copies of [0.0] only because buildSegments derives its cluster count and "
                    + "attaches embeddings; embeddings are not part of this oracle output. spanEmbedder is nil. "
                    + "sampleCount is fixture metadata only: buildSegments accepts neither sampleCount nor clip EOF, "
                    + "so the final-padded-past-eof case intentionally preserves its overrun.",
                comparisonRule: "Exact ordered parity: speaker IDs are stored separately in segment order; each "
                    + "expectedSegments row is the raw Float32 [startTimeSeconds,endTimeSeconds,qualityScore] "
                    + "bit pattern encoded by the existing little-endian tensor helper; input speakerWeights are "
                    + "Float32 bit patterns and chunkOffsets are Float64 bit patterns. sampleCount is metadata only "
                    + "and does not participate in reconstruction or EOF clipping. All golden cases have unique "
                    + "start times across different speaker IDs. A diagnostic run with minSegmentDurationSeconds=0 "
                    + "and exclusiveSegments=false rejects equal-start cases before any golden is written; such "
                    + "dictionary/set-order cases are excluded because FluidAudio does not define cross-speaker "
                    + "ordering for equal starts.",
            ),
            "cases": serializedCases,
        ]
        try DiarizationParityOracle.checkOrWrite(fixture, named: "reconstruction.json")
    }
}

private func assertReconstructionSemantics(
    _ segments: [TimedSpeakerSegment],
    for fixtureCase: ReconstructionFixtureCase
) throws {
    switch fixtureCase.name {
    case "overlap-exclusive":
        try #require(segments.count == 2)
        try #require(segments[0].speakerId == "S1")
        try #require(segments[0].startTimeSeconds == 0)
        try #require(segments[1].speakerId == "S2")
        try #require(segments[1].startTimeSeconds == segments[0].endTimeSeconds)
        try #require(segments[1].startTimeSeconds > 0)
        try #require(segments[1].qualityScore > 0 && segments[1].qualityScore < 1)
    case "exclusive-trim-short":
        try #require(segments.map(\.speakerId) == ["S1"])
    case "unassigned-local":
        try #require(segments.map(\.speakerId) == ["S1", "S1"])
        try #require(segments.count == 2)
        try #require(segments[0].qualityScore == 1)
        try #require(segments[1].qualityScore == 0)
    case "duplicate-cluster":
        try #require(segments.map(\.speakerId) == ["S1"])
        let segment = try #require(segments.first)
        try #require(segment.qualityScore == 1)
    case "count-half-even-zero":
        try #require(segments.map(\.speakerId) == ["S1"])
        let segment = try #require(segments.first)
        try #require(segment.endTimeSeconds == Float(118.0 * fixtureCase.frameDuration))
        try #require(segment.endTimeSeconds < 10)
    case "count-half-even-two":
        try #require(segments.map(\.speakerId) == ["S1", "S2"])
        try #require(segments.count == 2)
        try #require(segments[1].startTimeSeconds == segments[0].endTimeSeconds)
        try #require(segments[1].qualityScore > 0 && segments[1].qualityScore < 1)
    case "count-half-even-two-from-2.5":
        try #require(segments.map(\.speakerId) == ["S1", "S3"])
        try #require(segments.allSatisfy { $0.qualityScore == 1 })
    case "gap-edge-float-below":
        try #require(segments.count == 1)
        let segment = try #require(segments.first)
        try #require(segment.startTimeSeconds == 0)
        try #require(segment.endTimeSeconds == Float(0.75))
    case "gap-edge-float-above":
        try #require(segments.count == 2)
    case "gap-below":
        try #require(segments.count == 1)
    case "gap-above":
        try #require(segments.count == 2)
    case "subminimum":
        try #require(segments.isEmpty)
    case "final-padded-past-eof":
        try #require(segments.count == 1)
        let segment = try #require(segments.first)
        try #require(segment.endTimeSeconds > Float(Double(fixtureCase.sampleCount) / 16_000.0))
        try #require(abs(Double(segment.endTimeSeconds) - 12.0) < 0.01)
    default:
        throw ReconstructionFixtureError.invalidConstruction(
            name: fixtureCase.name,
            reason: "unexpected semantic assertion case"
        )
    }
}
#endif
