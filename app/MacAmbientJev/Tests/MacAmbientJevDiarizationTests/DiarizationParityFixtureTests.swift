import Foundation
import Testing

@Suite struct DiarizationParityFixtureTests {
    private let expectedMetadataVersion = "0.15.8"
    private let expectedMetadataRevision = "87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc"

    @Test func fixtureResourcesHavePinnedMetadataAndBounds() throws {
        var totalBytes = 0
        for filename in DiarizationParityFixtures.filenames {
            let data = try DiarizationParityFixtures.data(named: filename)
            #expect(data.count <= 1_048_576)
            totalBytes += data.count
        }
        #expect(totalBytes <= 8 * 1_048_576)

        let parameters = try DiarizationParityFixtures.load(
            "parameters.json",
            as: DiarizationParameterFixture.self
        )
        let reconstruction = try DiarizationParityFixtures.load(
            "reconstruction.json",
            as: DiarizationReconstructionFixture.self
        )
        let ahc = try DiarizationParityFixtures.load(
            "ahc.json",
            as: DiarizationAHCFixture.self
        )
        let assignment = try DiarizationParityFixtures.load(
            "assignment.json",
            as: DiarizationAssignmentFixture.self
        )
        let vbx = try DiarizationParityFixtures.load(
            "vbx.json",
            as: DiarizationVBxFixture.self
        )
        for metadata in [
            parameters.metadata,
            reconstruction.metadata,
            ahc.metadata,
            assignment.metadata,
            vbx.metadata,
        ] {
            #expect(metadata.schemaVersion == 1)
            #expect(metadata.fluidAudioVersion == expectedMetadataVersion)
            #expect(metadata.fluidAudioRevision == expectedMetadataRevision)
            #expect(!metadata.inputConstruction.isEmpty)
            #expect(!metadata.comparisonRule.isEmpty)
        }
    }

    @Test func malformedDataAndUnknownFilenamesFailFast() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                DiarizationParameterFixture.self,
                from: Data("{".utf8)
            )
        }
        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try DiarizationParityFixtures.load(
                "unknown.json",
                as: DiarizationParameterFixture.self
            )
        }
        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try DiarizationParityFixtures.data(named: "parameters.JSON")
        }
    }

    @Test func tensorDecodingPreservesLittleEndianBitsAndEmptyOutput() throws {
        let float32Bytes: [UInt8] = [
            0x00, 0x00, 0x80, 0x3F,
            0x00, 0x00, 0x00, 0xC0,
            0x00, 0x00, 0x80, 0x3E,
        ]
        let float32 = try parityTensor(dtype: "float32", shape: [3], bytes: float32Bytes).float32()
        #expect(float32.map(\.bitPattern) == [0x3F800000, 0xC0000000, 0x3E800000])

        let float64Bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xD0, 0x3F,
        ]
        let float64 = try parityTensor(dtype: "float64", shape: [3], bytes: float64Bytes).float64()
        #expect(float64.map(\.bitPattern) == [
            0x3FF0000000000000,
            0xC000000000000000,
            0x3FD0000000000000,
        ])

        let emptyFloat32 = try parityTensor(dtype: "float32", shape: [0, 3], bytes: []).float32()
        let emptyFloat64 = try parityTensor(dtype: "float64", shape: [0, 3], bytes: []).float64()
        #expect(emptyFloat32.isEmpty)
        #expect(emptyFloat64.isEmpty)
    }

    @Test func invalidTensorEncodingsThrow() {
        let fourZeroBytes: [UInt8] = [0, 0, 0, 0]
        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try parityTensor(dtype: "int32", shape: [1], bytes: fourZeroBytes).float32()
        }
        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try parityTensor(dtype: "float32", shape: [], bytes: []).float32()
        }
        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try parityTensor(dtype: "float32", shape: [1, -1], bytes: []).float32()
        }
        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try parityTensor(dtype: "float32", shape: [Int.max, 2], bytes: []).float32()
        }
        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try parityTensor(dtype: "float64", shape: [Int.max], bytes: []).float64()
        }

        let invalidBase64 = DiarizationParityTensor(
            dtype: "float32",
            shape: [1],
            littleEndianBase64: "%%%"
        )
        #expect(throws: DiarizationParityFixtureError.self) { _ = try invalidBase64.float32() }
        let noncanonicalBase64 = DiarizationParityTensor(
            dtype: "float32",
            shape: [1],
            littleEndianBase64: "AB=="
        )
        #expect(throws: DiarizationParityFixtureError.self) { _ = try noncanonicalBase64.float32() }

        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try parityTensor(dtype: "float32", shape: [1], bytes: [0, 0, 0, 0, 0, 0, 0, 0]).float32()
        }
        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try parityTensor(dtype: "float32", shape: [1], bytes: [0x00, 0x00, 0x80, 0x7F]).float32()
        }
        #expect(throws: DiarizationParityFixtureError.self) {
            _ = try parityTensor(
                dtype: "float64",
                shape: [1],
                bytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x7F]
            ).float64()
        }
    }

    @Test func reconstructionFixturesHaveValidStructure() throws {
        let fixture = try DiarizationParityFixtures.load(
            "reconstruction.json",
            as: DiarizationReconstructionFixture.self
        )
        let expectedNames: Set<String> = [
            "overlap-exclusive",
            "exclusive-trim-short",
            "unassigned-local",
            "duplicate-cluster",
            "count-half-even-zero",
            "count-half-even-two",
            "count-half-even-two-from-2.5",
            "gap-edge-float-below",
            "gap-edge-float-above",
            "gap-below",
            "gap-above",
            "subminimum",
            "final-padded-past-eof",
        ]
        #expect(fixture.cases.count == expectedNames.count)
        #expect(Set(fixture.cases.map(\.name)) == expectedNames)

        for item in fixture.cases {
            #expect(item.sampleCount > 0)
            #expect(item.clusterCount > 0)
            #expect(item.numFrames > 0)
            #expect(item.numSpeakers == 3)

            let chunkCount = item.hardClusters.count
            #expect(chunkCount > 0)
            #expect(item.chunkOffsets.dtype == "float64")
            #expect(item.chunkOffsets.shape == [chunkCount])
            let offsets = try item.chunkOffsets.float64()
            #expect(offsets.count == chunkCount)

            #expect(item.speakerWeights.dtype == "float32")
            #expect(item.speakerWeights.shape == [chunkCount, item.numFrames, 3])
            let weights = try item.speakerWeights.float32()
            #expect(weights.allSatisfy { $0 == 0 || $0 == 1 })

            #expect(item.hardClusters.count == chunkCount)
            for assignments in item.hardClusters {
                #expect(assignments.count == item.numSpeakers)
                for assignment in assignments {
                    #expect(assignment == -2 || (assignment >= 0 && assignment < item.clusterCount))
                }
            }

            #expect(item.expectedSegments.dtype == "float32")
            #expect(item.expectedSegments.shape == [item.expectedSpeakerIDs.count, 3])
            let segments = try item.expectedSegments.float32()
            #expect(segments.count == item.expectedSpeakerIDs.count * 3)
            for speakerID in item.expectedSpeakerIDs {
                #expect(speakerID.hasPrefix("S"))
                let digits = String(speakerID.dropFirst())
                #expect(!digits.isEmpty)
                #expect(digits.allSatisfy { $0 >= "0" && $0 <= "9" })
                if let speakerNumber = Int(digits) {
                    #expect(speakerNumber >= 1)
                    #expect(speakerNumber <= item.clusterCount)
                } else {
                    #expect(Bool(false), "Speaker ID must contain a numeric cluster index: \(speakerID)")
                }
            }

            var previousStart: Float?
            var previousEnd: Float?
            for segmentIndex in 0..<item.expectedSpeakerIDs.count {
                let offset = segmentIndex * 3
                let start = segments[offset]
                let end = segments[offset + 1]
                let quality = segments[offset + 2]
                #expect(start >= 0)
                #expect(end > start)
                #expect(end - start >= Float(0.3))
                #expect(quality >= 0 && quality <= 1)
                if let previousStart {
                    #expect(start >= previousStart)
                }
                if let previousEnd {
                    #expect(start >= previousEnd)
                }
                previousStart = start
                previousEnd = end
            }
        }

        let subminimum = try #require(fixture.cases.first { $0.name == "subminimum" })
        #expect(subminimum.expectedSpeakerIDs.isEmpty)
        #expect(subminimum.expectedSegments.shape == [0, 3])
        #expect(try subminimum.expectedSegments.float32().isEmpty)

        let paddedTail = try #require(fixture.cases.first { $0.name == "final-padded-past-eof" })
        let paddedSegments = try paddedTail.expectedSegments.float32()
        let eofSeconds = Float(paddedTail.sampleCount) / 16_000
        let segmentEnds = stride(from: 1, to: paddedSegments.count, by: 3).map { paddedSegments[$0] }
        #expect(segmentEnds.contains { $0 > eofSeconds })
    }

    @Test func ahcFixturesHaveValidStructureAndInversionWitness() throws {
        let fixture = try DiarizationParityFixtures.load("ahc.json", as: DiarizationAHCFixture.self)
        let expectedNames: Set<String> = [
            "separated-groups",
            "angular-chain",
            "threshold-pairs",
            "centroid-inversion",
        ]
        #expect(fixture.cases.count == expectedNames.count)
        #expect(Set(fixture.cases.map(\.name)) == expectedNames)

        for item in fixture.cases {
            #expect(item.features.dtype == "float64")
            #expect(item.features.shape.count == 2)
            guard item.features.shape.count == 2 else { continue }
            let rowCount = item.features.shape[0]
            let dimension = item.features.shape[1]
            #expect(rowCount > 0)
            #expect(dimension > 0)
            #expect(item.threshold == 0.6)

            let features = try item.features.float64()
            #expect(features.count == rowCount * dimension)
            #expect(item.expectedLabels.count == rowCount)
            for row in 0..<rowCount {
                var normSquared = 0.0
                for column in 0..<dimension {
                    let value = features[row * dimension + column]
                    normSquared += value * value
                }
                #expect(abs(normSquared.squareRoot() - 1) <= 1e-12)
            }

            var firstSeenLabels: [Int] = []
            for label in item.expectedLabels {
                #expect(label >= 0)
                if label >= 0 && !firstSeenLabels.contains(label) {
                    #expect(label == firstSeenLabels.count)
                    firstSeenLabels.append(label)
                }
            }

            if item.name == "centroid-inversion" {
                #expect(item.features.shape == [3, 3])
                #expect(item.expectedLabels == [0, 0, 0])
                guard let witness = item.inversion else {
                    #expect(Bool(false), "centroid-inversion requires its numeric witness")
                    continue
                }
                #expect(witness.monotoneLabels == [0, 1, 2])
                #expect(witness.firstMergeDistance > 0.6)
                #expect(witness.rootDistance < 0.6)
                #expect(witness.rootDistance < witness.firstMergeDistance)

                let vectors = (0..<3).map { row in
                    (0..<3).map { column in features[row * 3 + column] }
                }
                let firstPairDistance = scalarDistance(vectors[0], vectors[1])
                let centroid01 = (0..<3).map { (vectors[0][$0] + vectors[1][$0]) / 2.0 }
                let rootDistance = scalarDistance(centroid01, vectors[2])
                #expect(abs(firstPairDistance - witness.firstMergeDistance) <= 1e-12)
                #expect(abs(rootDistance - witness.rootDistance) <= 1e-12)
                #expect(scalarDistance(vectors[0], vectors[1]) > 0.6)
                #expect(scalarDistance(vectors[0], vectors[2]) > 0.6)
                #expect(scalarDistance(vectors[1], vectors[2]) > 0.6)
            } else {
                #expect(item.inversion == nil)
            }
        }
    }
}

private func parityTensor(dtype: String, shape: [Int], bytes: [UInt8]) -> DiarizationParityTensor {
    DiarizationParityTensor(
        dtype: dtype,
        shape: shape,
        littleEndianBase64: Data(bytes).base64EncodedString()
    )
}

private func scalarDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
    var squaredDistance = 0.0
    for index in lhs.indices {
        let delta = lhs[index] - rhs[index]
        squaredDistance += delta * delta
    }
    return squaredDistance.squareRoot()
}
