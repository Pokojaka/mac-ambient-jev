import Foundation
import Testing

@Suite
struct ClauseTaggerParityFixtureTests {
    @Test
    func comparatorRejectsObjectKeyArrayCountIDAndRangeChanges() throws {
        let baseline: [String: Any] = [
            "schema_version": 1,
            "calls": [[
                "input_ids": [6, 275, 4],
                "source_token_ranges": [NSNull(), ["start": 0, "end": 2], NSNull()]
            ]]
        ]
        expectMismatch(
            expected: baseline,
            actual: ["schema_version": 1, "calls": [["input_ids": [6, 275, 4], "extra": true]]]
        )
        expectMismatch(
            expected: baseline,
            actual: [
                "schema_version": 1,
                "calls": [["input_ids": [6, 275, 4], "source_token_ranges": [NSNull(), ["start": 0, "end": 2], NSNull()]]],
                "unexpected": 1
            ]
        )
        expectMismatch(
            expected: baseline,
            actual: [
                "schema_version": 1,
                "calls": [["input_ids": [6, 276, 4], "source_token_ranges": [NSNull(), ["start": 0, "end": 2], NSNull()]]]
            ]
        )
        expectMismatch(
            expected: baseline,
            actual: [
                "schema_version": 1,
                "calls": [["input_ids": [6, 275, 4], "source_token_ranges": [NSNull(), ["start": 0, "end": 3], NSNull()]]]
            ]
        )
    }

    @Test
    func comparatorUsesExactUnicodeScalarUTF8Bytes() throws {
        expectMismatch(expected: ["text": "é"], actual: ["text": "e\u{301}"])
    }

    @Test
    func fixtureJSONReaderPreservesLeadingBOMAndDecomposedScalars() throws {
        let text = "\u{FEFF}e\u{301}\u{FEFF}"
        for data in [
            Data("{\"text\":\"\(text)\"}".utf8),
            Data(#"{"text":"\uFEFFe\u0301\uFEFF"}"#.utf8)
        ] {
            let document = try ClauseTaggerParityFixtureSupport.jsonObject(data, name: "Unicode regression")
            let decoded = try #require(document["text"] as? String)
            #expect(Array(decoded.unicodeScalars.map(\.value)) == [0xFEFF, 0x65, 0x301, 0xFEFF])
            try ClauseTaggerParityFixtureSupport.compareJSON(expected: ["text": text], actual: document)
        }
    }

    @Test
    func comparatorAllowsOnlySmallProbabilityDifferences() throws {
        try ClauseTaggerParityFixtureSupport.compareJSON(
            expected: ["boundary_probs": [[0.4, 0.6]]],
            actual: ["boundary_probs": [[0.4005, 0.5995]]]
        )
        expectMismatch(
            expected: ["probabilities": ["b0001": 0.4]],
            actual: ["probabilities": ["b0001": 0.402]]
        )
    }

    @Test
    func comparatorRejectsNestedArrayCountInsteadOfZipTruncating() throws {
        expectMismatch(
            expected: ["span_probs": [[0.1, 0.2, 0.3, 0.4], [0.4, 0.3, 0.2, 0.1]]],
            actual: ["span_probs": [[0.1, 0.2, 0.3, 0.4]]]
        )
        expectMismatch(
            expected: ["boundary_probs": [[0.4, 0.6]]],
            actual: ["boundary_probs": [[0.4]]]
        )
    }

    @Test
    func comparatorRejectsInvalidTolerantAndExactValues() throws {
        expectMismatch(expected: ["value": true], actual: ["value": 1])
        expectMismatch(expected: ["confidence": 0.5], actual: ["confidence": Double.infinity])
        expectMismatch(
            expected: ["boundary_probs": [[0.4, 0.6]]],
            actual: ["boundary_probs": [[1.01, -0.01]]]
        )
        expectMismatch(expected: ["confidence": 0.5], actual: ["confidence": 0.5011])
        expectMismatch(
            expected: ["continuation_probability": 0.5],
            actual: ["continuation_probability": 0.5011]
        )
        expectMismatch(expected: ["input_ids": [1]], actual: ["input_ids": [1.0005]])
    }

    @Test
    func rawHeadMaximaCollectsAcrossRequestAndChecksShapes() throws {
        let expected: [String: Any] = [
            "boundary_cases": [["calls": [
                [
                    "boundary_probs": [[0.4, 0.6]],
                    "span_probs": [[0.1, 0.2, 0.3, 0.4]],
                    "priority_probs": [0.5, 0.5]
                ],
                [
                    "boundary_probs": [[0.3, 0.7]],
                    "span_probs": [[0.4, 0.3, 0.2, 0.1]],
                    "priority_probs": [0.7, 0.3]
                ]
            ]]]
        ]
        let actual: [String: Any] = [
            "boundary_cases": [["calls": [
                [
                    "boundary_probs": [[0.4005, 0.5995]],
                    "span_probs": [[0.1, 0.2, 0.3002, 0.3998]],
                    "priority_probs": [0.5001, 0.4999]
                ],
                [
                    "boundary_probs": [[0.3009, 0.6991]],
                    "span_probs": [[0.4001, 0.2999, 0.2, 0.1]],
                    "priority_probs": [0.6994, 0.3006]
                ]
            ]]]
        ]
        let maxima = try ClauseTaggerParityFixtureSupport.rawHeadMaxima(expected: expected, actual: actual)
        let boundaryMax = try #require(maxima["boundary_probs"])
        let spanMax = try #require(maxima["span_probs"])
        let priorityMax = try #require(maxima["priority_probs"])
        #expect(abs(boundaryMax - 0.0009) < 1e-12)
        #expect(abs(spanMax - 0.0002) < 1e-12)
        #expect(abs(priorityMax - 0.0006) < 1e-12)
        #expect(throws: ClauseTaggerParityFixtureSupport.FixtureError.self) {
            try ClauseTaggerParityFixtureSupport.rawHeadMaxima(
                expected: ["calls": [["span_probs": [[0.1, 0.2, 0.3, 0.4]]]]],
                actual: ["calls": [["span_probs": []]]]
            )
        }
    }

    @Test
    func requiredModelDirectoryRejectsInvalidExplicitEnvironmentDictionaries() throws {
        #expect(throws: ClauseTaggerParityFixtureSupport.FixtureError.self) {
            try ClauseTaggerParityFixtureSupport.requiredModelDirectory(environment: [:])
        }
        #expect(throws: ClauseTaggerParityFixtureSupport.FixtureError.self) {
            try ClauseTaggerParityFixtureSupport.requiredModelDirectory(
                environment: ["CLAUSE_TAGGER_MODEL_DIRECTORY": ""]
            )
        }
        #expect(throws: ClauseTaggerParityFixtureSupport.FixtureError.self) {
            try ClauseTaggerParityFixtureSupport.requiredModelDirectory(
                environment: ["CLAUSE_TAGGER_MODEL_DIRECTORY": "relative/model"]
            )
        }
        let missingDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("missing-model-directory-\(UUID().uuidString)", isDirectory: true)
            .path
        #expect(throws: ClauseTaggerParityFixtureSupport.FixtureError.self) {
            try ClauseTaggerParityFixtureSupport.requiredModelDirectory(
                environment: ["CLAUSE_TAGGER_MODEL_DIRECTORY": missingDirectory]
            )
        }
        #expect(throws: ClauseTaggerParityFixtureSupport.FixtureError.self) {
            try ClauseTaggerParityFixtureSupport.requiredModelDirectory(
                environment: ["CLAUSE_TAGGER_MODEL_DIRECTORY": #filePath]
            )
        }
    }

    @Test
    func requiredModelDirectoryAcceptsExistingSourceDirectoryWithoutLoadingModel() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let resolved = try ClauseTaggerParityFixtureSupport.requiredModelDirectory(
            environment: ["CLAUSE_TAGGER_MODEL_DIRECTORY": sourceDirectory.path]
        )
        #expect(resolved == sourceDirectory.resolvingSymlinksInPath())
    }

    @Test(.enabled(if: ClauseTaggerParityFixtureSupport.testIsEnabled))
    func capturesOrChecksRealMacGoldenFixturesWhenEnabled() async throws {
        try await ClauseTaggerParityFixtureSupport.run()
    }

    private func expectMismatch(
        expected: Any,
        actual: Any,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            try ClauseTaggerParityFixtureSupport.compareJSON(expected: expected, actual: actual)
            Issue.record("A deliberately changed fixture unexpectedly compared equal.", sourceLocation: sourceLocation)
        } catch is ClauseTaggerParityFixtureSupport.FixtureError {
            return
        } catch {
            Issue.record("The comparator threw an unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }
}
