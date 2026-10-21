import Foundation
import Testing
import MacAmbientJevCore

@Suite
struct ClauseTaggerDecisionLogicTests {
    @Test
    func priorityTargetValidationPreventsInference() throws {
        let document = try ClauseTaggerRequestReplaySupport.load()
        let tokenizer = try ClauseTaggerRequestReplaySupport.tokenizer(document: document)
        var inferenceCalls = 0

        func assertInvalidTargets(_ targets: [PriorityTextTarget]) throws {
            do {
                _ = try ClauseTaggerDecisionLogic.classifyPriorities(
                    targets,
                    tokenizer: tokenizer,
                    predict: { inputIDs in
                        inferenceCalls += 1
                        return makePrediction(inputCount: inputIDs.count, priority: [0.5, 0.5])
                    }
                )
                Issue.record("Expected invalidTargets for \(targets.map(\.key))")
            } catch ClauseValidationError.invalidTargets {
            } catch {
                Issue.record("Expected invalidTargets, received \(error)")
            }
            #expect(inferenceCalls == 0)
        }

        try assertInvalidTargets([])
        try assertInvalidTargets((1...41).map {
            PriorityTextTarget(key: String(format: "u%04d", $0), text: "本文")
        })
        try assertInvalidTargets([
            PriorityTextTarget(key: "u0001", text: "本文"),
            PriorityTextTarget(key: "u0001", text: "別の本文")
        ])

        for key in ["", "u0000", "u000", "u00001", "U0001", "u０００１", "u00a1"] {
            try assertInvalidTargets([PriorityTextTarget(key: key, text: "本文")])
        }
        try assertInvalidTargets([PriorityTextTarget(key: "u0001", text: " \t\n ")])
        #expect(inferenceCalls == 0)
    }

    @Test
    func priorityTiesAndConfidence() throws {
        let document = try ClauseTaggerRequestReplaySupport.load()
        let tokenizer = try ClauseTaggerRequestReplaySupport.tokenizer(document: document)
        let targets = [
            PriorityTextTarget(key: "u0001", text: "一つ目の本文"),
            PriorityTextTarget(key: "u0002", text: "二つ目の本文"),
            PriorityTextTarget(key: "u0003", text: "三つ目の本文")
        ]
        let vectors = [[0.5, 0.5], [0.2, 0.8], [0.75, 0.25]]
        var inferenceCalls = 0
        var actualInputTokens = 0

        let response = try ClauseTaggerDecisionLogic.classifyPriorities(
            targets,
            tokenizer: tokenizer,
            predict: { inputIDs in
                let index = inferenceCalls
                inferenceCalls += 1
                actualInputTokens += inputIDs.count
                return makePrediction(inputCount: inputIDs.count, priority: vectors[index])
            }
        )

        #expect(inferenceCalls == 3)
        #expect(response.inputTokens == actualInputTokens)
        #expect(response.decisions.count == 3)
        let expected = [
            ("u0001", ContentPriority.primary, [0.5, 0.5]),
            ("u0002", ContentPriority.lowPriority, [0.2, 0.8]),
            ("u0003", ContentPriority.primary, [0.75, 0.25])
        ]
        for (key, priority, probabilities) in expected {
            let decision = try #require(response.decisions[key])
            #expect(decision.priority == priority)
            #expect(decision.confidence == 2 * max(probabilities[0], probabilities[1]) - 1)
            #expect(decision.probabilities == [
                "PRIMARY": probabilities[0],
                "LOW_PRIORITY": probabilities[1]
            ])
        }
    }

    @Test
    func malformedPredictionsThrow() throws {
        let document = try ClauseTaggerRequestReplaySupport.load()
        let tokenizer = try ClauseTaggerRequestReplaySupport.tokenizer(document: document)
        let source = try SegmentTextReference(
            segmentationRunID: "decision-logic-run",
            segmentID: "s0001",
            asrRunID: "decision-logic-asr",
            asrEventSeq: 1
        )
        let nextSource = try SegmentTextReference(
            segmentationRunID: "decision-logic-run",
            segmentID: "s0002",
            asrRunID: "decision-logic-asr",
            asrEventSeq: 2
        )
        let next = try NextSegmentHead(source: nextSource, text: "明後日は晴れです")
        let request = try ClauseBoundaryRequest(
            source: source,
            text: "今日は晴れです。明日は雨です",
            next: next
        )
        let boundaryInputs = try ClauseTaggerEncoding.boundaryInputs(request) {
            try tokenizer.encodePiece($0)
        }
        #expect(boundaryInputs.count == 1)
        let encoded = try #require(boundaryInputs.first)
        let validPrediction = makePrediction(inputCount: encoded.inputIDs.count, priority: [0.5, 0.5])

        func expectInvalidOutput(_ prediction: ClauseTaggerPrediction) throws {
            do {
                _ = try ClauseTaggerDecisionLogic.assessBoundaries(
                    request,
                    tokenizer: tokenizer,
                    predict: { _ in prediction }
                )
                Issue.record("Expected invalidOutput for boundary prediction")
            } catch ClauseTaggerModelError.invalidOutput {
            } catch {
                Issue.record("Expected invalidOutput, received \(error)")
            }
        }

        let shortSpanRows = ClauseTaggerPrediction(
            boundaryProbabilities: validPrediction.boundaryProbabilities,
            spanProbabilities: Array(validPrediction.spanProbabilities.dropLast()),
            priorityProbabilities: validPrediction.priorityProbabilities
        )
        try expectInvalidOutput(shortSpanRows)

        var wrongWidthSpanRows = validPrediction.spanProbabilities
        let ownedSpanIndex = try #require(encoded.spanTokenIndices.first)
        wrongWidthSpanRows[ownedSpanIndex] = [1, 0, 0]
        try expectInvalidOutput(ClauseTaggerPrediction(
            boundaryProbabilities: validPrediction.boundaryProbabilities,
            spanProbabilities: wrongWidthSpanRows,
            priorityProbabilities: validPrediction.priorityProbabilities
        ))

        var wrongWidthBoundaryRows = validPrediction.boundaryProbabilities
        let candidateIndex = try #require(encoded.candidateTokenIndices.values.first)
        wrongWidthBoundaryRows[candidateIndex] = [1]
        try expectInvalidOutput(ClauseTaggerPrediction(
            boundaryProbabilities: wrongWidthBoundaryRows,
            spanProbabilities: validPrediction.spanProbabilities,
            priorityProbabilities: validPrediction.priorityProbabilities
        ))

        let target = [PriorityTextTarget(key: "u0001", text: "優先度を判定する本文")]
        do {
            _ = try ClauseTaggerDecisionLogic.classifyPriorities(
                target,
                tokenizer: tokenizer,
                predict: { _ in
                    ClauseTaggerPrediction(
                        boundaryProbabilities: [],
                        spanProbabilities: [],
                        priorityProbabilities: [0.5]
                    )
                }
            )
            Issue.record("Expected invalidOutput for priority head width")
        } catch ClauseTaggerModelError.invalidOutput {
        } catch {
            Issue.record("Expected invalidOutput, received \(error)")
        }

        func expectInvalidProbability(_ priority: [Double]) throws {
            do {
                _ = try ClauseTaggerDecisionLogic.classifyPriorities(
                    target,
                    tokenizer: tokenizer,
                    predict: { _ in
                        ClauseTaggerPrediction(
                            boundaryProbabilities: [],
                            spanProbabilities: [],
                            priorityProbabilities: priority
                        )
                    }
                )
                Issue.record("Expected invalidProbability for priority vector \(priority)")
            } catch ClauseValidationError.invalidProbability {
            } catch {
                Issue.record("Expected invalidProbability, received \(error)")
            }
        }

        try expectInvalidProbability([.nan, 0.5])
        try expectInvalidProbability([1.1, -0.1])
        try expectInvalidProbability([0.4, 0.4])
    }

    @Test
    func inferenceFailurePropagatesAndAbortsBatch() throws {
        let document = try ClauseTaggerRequestReplaySupport.load()
        let tokenizer = try ClauseTaggerRequestReplaySupport.tokenizer(document: document)
        let targets = [
            PriorityTextTarget(key: "u0001", text: "一つ目の本文"),
            PriorityTextTarget(key: "u0002", text: "二つ目の本文")
        ]
        let expectedError = NSError(domain: "ClauseTaggerDecisionLogicTests", code: 17)
        var inferenceCalls = 0

        do {
            _ = try ClauseTaggerDecisionLogic.classifyPriorities(
                targets,
                tokenizer: tokenizer,
                predict: { _ in
                    inferenceCalls += 1
                    throw expectedError
                }
            )
            Issue.record("Expected prediction failure")
        } catch {
            #expect((error as NSError) === expectedError)
        }
        #expect(inferenceCalls == 1)
    }

    @Test
    func cancelledBeforeInferenceSkipsBothMethods() async throws {
        let document = try ClauseTaggerRequestReplaySupport.load()
        let tokenizer = try ClauseTaggerRequestReplaySupport.tokenizer(document: document)
        let source = try SegmentTextReference(
            segmentationRunID: "decision-logic-run",
            segmentID: "s0001",
            asrRunID: "decision-logic-asr",
            asrEventSeq: 1
        )
        let request = try ClauseBoundaryRequest(
            source: source,
            text: "今日は晴れです。明日は雨です",
            next: nil
        )
        let targets = [PriorityTextTarget(key: "u0001", text: "優先度を判定する本文")]

        let boundaryTask = Task { () -> (cancelled: Bool, calls: Int, hadCurrentTask: Bool, unexpected: String?) in
            var calls = 0
            var hadCurrentTask = false
            withUnsafeCurrentTask { current in
                if let current {
                    hadCurrentTask = true
                    current.cancel()
                }
            }
            do {
                _ = try ClauseTaggerDecisionLogic.assessBoundaries(
                    request,
                    tokenizer: tokenizer,
                    predict: { inputIDs in
                        calls += 1
                        return makePrediction(inputCount: inputIDs.count, priority: [0.5, 0.5])
                    }
                )
                return (false, calls, hadCurrentTask, nil)
            } catch is CancellationError {
                return (true, calls, hadCurrentTask, nil)
            } catch {
                return (false, calls, hadCurrentTask, String(describing: error))
            }
        }
        let boundaryResult = await boundaryTask.value
        #expect(boundaryResult.hadCurrentTask)
        #expect(boundaryResult.cancelled)
        #expect(boundaryResult.calls == 0)
        #expect(boundaryResult.unexpected == nil)

        let priorityTask = Task { () -> (cancelled: Bool, calls: Int, hadCurrentTask: Bool, unexpected: String?) in
            var calls = 0
            var hadCurrentTask = false
            withUnsafeCurrentTask { current in
                if let current {
                    hadCurrentTask = true
                    current.cancel()
                }
            }
            do {
                _ = try ClauseTaggerDecisionLogic.classifyPriorities(
                    targets,
                    tokenizer: tokenizer,
                    predict: { inputIDs in
                        calls += 1
                        return makePrediction(inputCount: inputIDs.count, priority: [0.5, 0.5])
                    }
                )
                return (false, calls, hadCurrentTask, nil)
            } catch is CancellationError {
                return (true, calls, hadCurrentTask, nil)
            } catch {
                return (false, calls, hadCurrentTask, String(describing: error))
            }
        }
        let priorityResult = await priorityTask.value
        #expect(priorityResult.hadCurrentTask)
        #expect(priorityResult.cancelled)
        #expect(priorityResult.calls == 0)
        #expect(priorityResult.unexpected == nil)
    }

    @Test
    func cancellationBetweenBoundaryWindowsStopsInference() async throws {
        let document = try ClauseTaggerRequestReplaySupport.load()
        let tokenizer = try ClauseTaggerRequestReplaySupport.tokenizer(document: document)
        let fixtureCase = try #require(document.boundaryCases.first { $0.name == "multi-window" })
        let request = try fixtureCase.request.makeRequest()
        let boundaryInputs = try ClauseTaggerEncoding.boundaryInputs(request) {
            try tokenizer.encodePiece($0)
        }
        #expect(boundaryInputs.count > 1)
        guard boundaryInputs.count > 1 else { return }

        let task = Task { () -> (cancelled: Bool, calls: Int, hadCurrentTask: Bool, unexpected: String?) in
            var calls = 0
            var hadCurrentTask = false
            do {
                _ = try ClauseTaggerDecisionLogic.assessBoundaries(
                    request,
                    tokenizer: tokenizer,
                    predict: { inputIDs in
                        calls += 1
                        if calls == 1 {
                            withUnsafeCurrentTask { current in
                                if let current {
                                    hadCurrentTask = true
                                    current.cancel()
                                }
                            }
                        }
                        return makePrediction(inputCount: inputIDs.count, priority: [0.5, 0.5])
                    }
                )
                return (false, calls, hadCurrentTask, nil)
            } catch is CancellationError {
                return (true, calls, hadCurrentTask, nil)
            } catch {
                return (false, calls, hadCurrentTask, String(describing: error))
            }
        }
        let result = await task.value
        #expect(result.hadCurrentTask)
        #expect(result.cancelled)
        #expect(result.calls == 1)
        #expect(result.unexpected == nil)
    }

    @Test
    func cancellationBetweenBoundaryAndContinuationStopsInference() async throws {
        let document = try ClauseTaggerRequestReplaySupport.load()
        let tokenizer = try ClauseTaggerRequestReplaySupport.tokenizer(document: document)
        let source = try SegmentTextReference(
            segmentationRunID: "decision-logic-run",
            segmentID: "s0001",
            asrRunID: "decision-logic-asr",
            asrEventSeq: 1
        )
        let nextSource = try SegmentTextReference(
            segmentationRunID: "decision-logic-run",
            segmentID: "s0002",
            asrRunID: "decision-logic-asr",
            asrEventSeq: 2
        )
        let next = try NextSegmentHead(source: nextSource, text: "明後日は晴れです")
        let request = try ClauseBoundaryRequest(
            source: source,
            text: "今日は晴れです。明日は雨です",
            next: next
        )
        let boundaryInputs = try ClauseTaggerEncoding.boundaryInputs(request) {
            try tokenizer.encodePiece($0)
        }
        let continuationInput = try ClauseTaggerEncoding.continuationInput(request) {
            try tokenizer.encodePiece($0)
        }
        #expect(boundaryInputs.count == 1)
        #expect(continuationInput.junctionIndex != nil)
        guard boundaryInputs.count == 1, continuationInput.junctionIndex != nil else { return }

        let task = Task { () -> (cancelled: Bool, calls: Int, hadCurrentTask: Bool, unexpected: String?) in
            var calls = 0
            var hadCurrentTask = false
            do {
                _ = try ClauseTaggerDecisionLogic.assessBoundaries(
                    request,
                    tokenizer: tokenizer,
                    predict: { inputIDs in
                        calls += 1
                        withUnsafeCurrentTask { current in
                            if let current {
                                hadCurrentTask = true
                                current.cancel()
                            }
                        }
                        return makePrediction(inputCount: inputIDs.count, priority: [0.5, 0.5])
                    }
                )
                return (false, calls, hadCurrentTask, nil)
            } catch is CancellationError {
                return (true, calls, hadCurrentTask, nil)
            } catch {
                return (false, calls, hadCurrentTask, String(describing: error))
            }
        }
        let result = await task.value
        #expect(result.hadCurrentTask)
        #expect(result.cancelled)
        #expect(result.calls == 1)
        #expect(result.unexpected == nil)
    }

    @Test
    func cancellationAfterFinalBoundaryPredictionRejectsResponse() async throws {
        let document = try ClauseTaggerRequestReplaySupport.load()
        let tokenizer = try ClauseTaggerRequestReplaySupport.tokenizer(document: document)
        let source = try SegmentTextReference(
            segmentationRunID: "decision-logic-run",
            segmentID: "s0001",
            asrRunID: "decision-logic-asr",
            asrEventSeq: 1
        )
        let nextSource = try SegmentTextReference(
            segmentationRunID: "decision-logic-run",
            segmentID: "s0002",
            asrRunID: "decision-logic-asr",
            asrEventSeq: 2
        )
        let next = try NextSegmentHead(source: nextSource, text: "明後日は晴れです")
        let request = try ClauseBoundaryRequest(
            source: source,
            text: "今日は晴れです。明日は雨です",
            next: next
        )
        let boundaryInputs = try ClauseTaggerEncoding.boundaryInputs(request) {
            try tokenizer.encodePiece($0)
        }
        let continuationInput = try ClauseTaggerEncoding.continuationInput(request) {
            try tokenizer.encodePiece($0)
        }
        #expect(boundaryInputs.count == 1)
        #expect(continuationInput.junctionIndex != nil)
        guard boundaryInputs.count == 1, continuationInput.junctionIndex != nil else { return }

        let task = Task { () -> (cancelled: Bool, calls: Int, hadCurrentTask: Bool, unexpected: String?) in
            var calls = 0
            var hadCurrentTask = false
            do {
                _ = try ClauseTaggerDecisionLogic.assessBoundaries(
                    request,
                    tokenizer: tokenizer,
                    predict: { inputIDs in
                        calls += 1
                        if calls == 2 {
                            withUnsafeCurrentTask { current in
                                if let current {
                                    hadCurrentTask = true
                                    current.cancel()
                                }
                            }
                        }
                        return makePrediction(inputCount: inputIDs.count, priority: [0.5, 0.5])
                    }
                )
                return (false, calls, hadCurrentTask, nil)
            } catch is CancellationError {
                return (true, calls, hadCurrentTask, nil)
            } catch {
                return (false, calls, hadCurrentTask, String(describing: error))
            }
        }
        let result = await task.value
        #expect(result.hadCurrentTask)
        #expect(result.cancelled)
        #expect(result.calls == 2)
        #expect(result.unexpected == nil)
    }

    @Test
    func cancellationBetweenPriorityTargetsStopsInference() async throws {
        let document = try ClauseTaggerRequestReplaySupport.load()
        let tokenizer = try ClauseTaggerRequestReplaySupport.tokenizer(document: document)
        let targets = [
            PriorityTextTarget(key: "u0001", text: "一つ目の本文"),
            PriorityTextTarget(key: "u0002", text: "二つ目の本文")
        ]

        let task = Task { () -> (cancelled: Bool, calls: Int, hadCurrentTask: Bool, unexpected: String?) in
            var calls = 0
            var hadCurrentTask = false
            do {
                _ = try ClauseTaggerDecisionLogic.classifyPriorities(
                    targets,
                    tokenizer: tokenizer,
                    predict: { inputIDs in
                        calls += 1
                        if calls == 1 {
                            withUnsafeCurrentTask { current in
                                if let current {
                                    hadCurrentTask = true
                                    current.cancel()
                                }
                            }
                        }
                        return makePrediction(inputCount: inputIDs.count, priority: [0.5, 0.5])
                    }
                )
                return (false, calls, hadCurrentTask, nil)
            } catch is CancellationError {
                return (true, calls, hadCurrentTask, nil)
            } catch {
                return (false, calls, hadCurrentTask, String(describing: error))
            }
        }
        let result = await task.value
        #expect(result.hadCurrentTask)
        #expect(result.cancelled)
        #expect(result.calls == 1)
        #expect(result.unexpected == nil)
    }

    @Test
    func cancellationAfterFinalPriorityPredictionRejectsResponse() async throws {
        let document = try ClauseTaggerRequestReplaySupport.load()
        let tokenizer = try ClauseTaggerRequestReplaySupport.tokenizer(document: document)
        let targets = [PriorityTextTarget(key: "u0001", text: "一つ目の本文")]

        let task = Task { () -> (cancelled: Bool, calls: Int, hadCurrentTask: Bool, unexpected: String?) in
            var calls = 0
            var hadCurrentTask = false
            do {
                _ = try ClauseTaggerDecisionLogic.classifyPriorities(
                    targets,
                    tokenizer: tokenizer,
                    predict: { inputIDs in
                        calls += 1
                        withUnsafeCurrentTask { current in
                            if let current {
                                hadCurrentTask = true
                                current.cancel()
                            }
                        }
                        return makePrediction(inputCount: inputIDs.count, priority: [0.5, 0.5])
                    }
                )
                return (false, calls, hadCurrentTask, nil)
            } catch is CancellationError {
                return (true, calls, hadCurrentTask, nil)
            } catch {
                return (false, calls, hadCurrentTask, String(describing: error))
            }
        }
        let result = await task.value
        #expect(result.hadCurrentTask)
        #expect(result.cancelled)
        #expect(result.calls == 1)
        #expect(result.unexpected == nil)
    }
}

private func makePrediction(inputCount: Int, priority: [Double]) -> ClauseTaggerPrediction {
    ClauseTaggerPrediction(
        boundaryProbabilities: Array(repeating: [0.25, 0.75], count: inputCount),
        spanProbabilities: Array(repeating: [1, 0, 0, 0], count: inputCount),
        priorityProbabilities: priority
    )
}
