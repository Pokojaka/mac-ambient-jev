import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevClauseTaggerFixtures

@Suite
struct ClauseTaggerDecisionLogicFixtureTests {
    @Test
    func replayBoundaryRequestFixtures() throws {
        let document = try ClauseTaggerRequestReplaySupport.load()
        let original = try ClauseTaggerFixtures.loadOriginal()
        #expect(document.schemaVersion == 1)
        #expect(document.backend == "coreml")
        #expect(document.computeUnits == "cpuOnly")
        #expect(document.computePrecision == "float32")
        #expect(document.encodingRevision == original.encodingRevision)
        #expect(document.modelID == original.modelID)
        #expect(document.modelRevision == original.modelRevision)
        #expect(document.tokenizerSHA256 == original.tokenizerSHA256)
        #expect(document.boundaryCases.count == 6)
        #expect(Set(document.boundaryCases.map(\.name)) == Set([
            "multi-window", "continuation", "long-continuation",
            "terminal-no-candidates", "filler", "backchannel"
        ]))
        #expect(document.boundaryCases.reduce(0) { $0 + $1.calls.count } == 10)
        guard document.boundaryCases.count == 6 else { return }

        let tokenizer = try ClauseTaggerRequestReplaySupport.tokenizer(document: document)
        var totalCalls = 0
        for fixtureCase in document.boundaryCases {
            let request = try fixtureCase.request.makeRequest()
            let boundaryInputs = try ClauseTaggerEncoding.boundaryInputs(request) {
                try tokenizer.encodePiece($0)
            }
            let continuationInput: ClauseTaggerEncodedInput?
            if request.next == nil {
                continuationInput = nil
            } else {
                continuationInput = try ClauseTaggerEncoding.continuationInput(request) {
                    try tokenizer.encodePiece($0)
                }
            }
            let expectedCallCount = boundaryInputs.count + (continuationInput == nil ? 0 : 1)
            #expect(fixtureCase.calls.count == expectedCallCount, "\(fixtureCase.name) encoding call count")
            guard fixtureCase.calls.count == expectedCallCount else { continue }

            for inputIndex in boundaryInputs.indices {
                assertEncodedInputMatches(
                    boundaryInputs[inputIndex],
                    call: fixtureCase.calls[inputIndex],
                    expectedPurpose: "boundary",
                    expectedTargetKey: nil,
                    context: "\(fixtureCase.name) boundary \(inputIndex)"
                )
            }
            if let continuationInput {
                let continuationCallIndex = boundaryInputs.count
                assertEncodedInputMatches(
                    continuationInput,
                    call: fixtureCase.calls[continuationCallIndex],
                    expectedPurpose: "continuation",
                    expectedTargetKey: nil,
                    context: "\(fixtureCase.name) continuation"
                )
            }

            let replay = ClauseTaggerRequestReplaySupport.Replay(calls: fixtureCase.calls)
            let response = try ClauseTaggerDecisionLogic.assessBoundaries(
                request,
                tokenizer: tokenizer,
                predict: { try replay.predict($0) }
            )
            try replay.requireComplete()
            totalCalls += replay.nextCallIndex

            let expectedResponse = fixtureCase.response
            #expect(response.probabilities.count == expectedResponse.probabilities.count, "\(fixtureCase.name) candidate count")
            #expect(response.probabilities.count == request.candidates.count, "\(fixtureCase.name) request candidate count")
            #expect(Set(response.probabilities.keys) == Set(expectedResponse.probabilities.keys), "\(fixtureCase.name) candidate keys")
            #expect(response.inputTokens == expectedResponse.inputTokens, "\(fixtureCase.name) input token total")
            #expect(response.fillerRanges == expectedResponse.fillerRanges, "\(fixtureCase.name) filler ranges")
            for key in expectedResponse.probabilities.keys.sorted() {
                guard let actual = response.probabilities[key],
                      let expected = expectedResponse.probabilities[key] else {
                    Issue.record("\(fixtureCase.name) missing probability for \(key)")
                    continue
                }
                #expect(actual.isFinite, "\(fixtureCase.name) actual probability \(key) is finite")
                #expect(expected.isFinite, "\(fixtureCase.name) recorded probability \(key) is finite")
                #expect(abs(actual - expected) <= 1e-3, "\(fixtureCase.name) probability \(key)")
            }
            #expect(
                (response.continuationProbability == nil) == (expectedResponse.continuationProbability == nil),
                "\(fixtureCase.name) continuation presence"
            )
            if let actual = response.continuationProbability,
               let expected = expectedResponse.continuationProbability {
                #expect(actual.isFinite, "\(fixtureCase.name) actual continuation probability is finite")
                #expect(expected.isFinite, "\(fixtureCase.name) recorded continuation probability is finite")
                #expect(abs(actual - expected) <= 1e-3, "\(fixtureCase.name) continuation probability")
            }

            let projected = try TranscriptTextProjector().project(
                sourceText: request.text,
                fillerRanges: response.fillerRanges
            ).text
            #expect(Data(projected.utf8) == Data(fixtureCase.projectedText.utf8), "\(fixtureCase.name) projected text UTF-8")
            if fixtureCase.name == "filler" {
                #expect(projected == "今日は損失関数の話をします。")
            }
        }
        #expect(totalCalls == 10)
        print("ClauseTagger boundary request fixtures: cases=\(document.boundaryCases.count), rawCalls=\(totalCalls)")
    }

    @Test
    func replayPriorityBatchFixture() throws {
        let document = try ClauseTaggerRequestReplaySupport.load()
        #expect(document.priorityBatches.count == 1)
        guard document.priorityBatches.count == 1 else { return }
        let batch = document.priorityBatches[0]
        #expect(batch.name == "truncation-batch")
        #expect(batch.targets.count == 3)
        #expect(batch.calls.count == 3)
        guard batch.targets.count == 3, batch.calls.count == 3 else { return }

        let tokenizer = try ClauseTaggerRequestReplaySupport.tokenizer(document: document)
        let targets = batch.targets.map { PriorityTextTarget(key: $0.key, text: $0.text) }
        let encodedInputs = try targets.map { target in
            try ClauseTaggerEncoding.encode(text: target.text) {
                try tokenizer.encodePiece($0)
            }
        }
        #expect(encodedInputs.count == batch.calls.count)
        guard encodedInputs.count == batch.calls.count else { return }
        for index in targets.indices {
            assertEncodedInputMatches(
                encodedInputs[index],
                call: batch.calls[index],
                expectedPurpose: "priority",
                expectedTargetKey: targets[index].key,
                context: "priority target \(targets[index].key)"
            )
        }
        if let truncatedTarget = targets.first(where: { $0.key == "u0002" }),
           let truncatedIndex = targets.firstIndex(where: { $0.key == "u0002" }) {
            #expect(encodedInputs[truncatedIndex].inputIDs.count == 192, "u0002 whole-text input is truncated to 192 tokens")
            #expect(truncatedTarget.text.utf16.count > 190, "u0002 source text exceeds the content limit")
        } else {
            Issue.record("Priority batch is missing u0002")
        }

        let replay = ClauseTaggerRequestReplaySupport.Replay(calls: batch.calls)
        let response = try ClauseTaggerDecisionLogic.classifyPriorities(
            targets,
            tokenizer: tokenizer,
            predict: { try replay.predict($0) }
        )
        try replay.requireComplete()
        let expectedDecisions = batch.response.decisions
        #expect(response.decisions.count == expectedDecisions.count)
        #expect(response.decisions.count == targets.count)
        #expect(Set(response.decisions.keys) == Set(expectedDecisions.keys))
        #expect(response.inputTokens == batch.response.inputTokens)
        for key in expectedDecisions.keys.sorted() {
            guard let actual = response.decisions[key],
                  let expected = expectedDecisions[key] else {
                Issue.record("Priority response is missing decision for \(key)")
                continue
            }
            #expect(actual.priority == expected.priority, "\(key) priority label")
            #expect(actual.probabilities.count == expected.probabilities.count, "\(key) probability count")
            #expect(Set(actual.probabilities.keys) == Set(expected.probabilities.keys), "\(key) probability keys")
            #expect(actual.confidence.isFinite, "\(key) actual confidence is finite")
            #expect(expected.confidence.isFinite, "\(key) recorded confidence is finite")
            #expect(abs(actual.confidence - expected.confidence) <= 1e-3, "\(key) confidence")
            for probabilityKey in expected.probabilities.keys.sorted() {
                guard let actualProbability = actual.probabilities[probabilityKey],
                      let expectedProbability = expected.probabilities[probabilityKey] else {
                    Issue.record("\(key) is missing probability \(probabilityKey)")
                    continue
                }
                #expect(actualProbability.isFinite, "\(key) actual \(probabilityKey) probability is finite")
                #expect(expectedProbability.isFinite, "\(key) recorded \(probabilityKey) probability is finite")
                #expect(abs(actualProbability - expectedProbability) <= 1e-3, "\(key) \(probabilityKey) probability")
            }
        }
        #expect(replay.nextCallIndex == 3)
        let boundaryRawCallCount = document.boundaryCases.reduce(0) { $0 + $1.calls.count }
        #expect(boundaryRawCallCount == 10)
        #expect(boundaryRawCallCount + replay.nextCallIndex == 13)
        print("ClauseTagger priority request fixtures: batches=1, targets=\(targets.count), rawCalls=\(replay.nextCallIndex), totalRawCalls=\(boundaryRawCallCount + replay.nextCallIndex)")
    }

    @Test
    func replayRejectsDifferentIDsExtraCallsAndUnconsumedCalls() throws {
        let document = try ClauseTaggerRequestReplaySupport.load()
        let firstCall = try #require(document.boundaryCases.first?.calls.first)
        var changedIDs = firstCall.inputIDs
        #expect(!changedIDs.isEmpty)
        guard !changedIDs.isEmpty else { return }
        changedIDs[0] += 1

        let changedReplay = ClauseTaggerRequestReplaySupport.Replay(calls: [firstCall])
        #expect(throws: ClauseTaggerRequestReplaySupport.ReplayError.self) {
            try changedReplay.predict(changedIDs)
        }

        let emptyReplay = ClauseTaggerRequestReplaySupport.Replay(calls: [])
        #expect(throws: ClauseTaggerRequestReplaySupport.ReplayError.self) {
            try emptyReplay.predict(firstCall.inputIDs)
        }

        let unconsumedReplay = ClauseTaggerRequestReplaySupport.Replay(calls: [firstCall])
        #expect(throws: ClauseTaggerRequestReplaySupport.ReplayError.self) {
            try unconsumedReplay.requireComplete()
        }

        let exactReplay = ClauseTaggerRequestReplaySupport.Replay(calls: [firstCall])
        _ = try exactReplay.predict(firstCall.inputIDs)
        try exactReplay.requireComplete()
        #expect(exactReplay.nextCallIndex == 1)
        #expect(throws: ClauseTaggerRequestReplaySupport.ReplayError.self) {
            try exactReplay.predict(firstCall.inputIDs)
        }
    }
}

private func assertEncodedInputMatches(
    _ input: ClauseTaggerEncodedInput,
    call: ClauseTaggerRequestReplaySupport.Call,
    expectedPurpose: String,
    expectedTargetKey: String?,
    context: String
) {
    #expect(call.purpose == expectedPurpose, "\(context) purpose")
    #expect(call.targetKey == expectedTargetKey, "\(context) target key")
    #expect(input.inputIDs == call.inputIDs, "\(context) input IDs")
    #expect(input.contentStartTokenIndex == call.contentStartTokenIndex, "\(context) content start")
    #expect(input.sourceTokenRanges == call.sourceTokenRanges, "\(context) source token ranges")
    #expect(
        Dictionary(uniqueKeysWithValues: input.candidateTokenIndices.map { (String($0.key), $0.value) }) == call.candidateTokenIndices,
        "\(context) candidate token indices"
    )
    #expect(input.junctionIndex == call.junctionIndex, "\(context) junction index")
    #expect(input.spanTokenIndices == call.spanTokenIndices, "\(context) span token indices")
}
