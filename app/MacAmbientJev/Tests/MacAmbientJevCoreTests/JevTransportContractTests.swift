import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import MacAmbientJevCore

private actor ContractTransport: JevHTTPTransport {
    let data: Data
    let status: Int
    var requests: [URLRequest] = []
    init(json: String, status: Int = 200) { data = Data(json.utf8); self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func contractSource(_ segment: String, seq: UInt64) throws -> SegmentTextReference {
    try SegmentTextReference(segmentationRunID: "private-segmentation", segmentID: segment, asrRunID: "private-asr", asrEventSeq: seq)
}

private let validChoice = #"{"type":"choice","choice":"LOW_PRIORITY","confidence":0.9,"probabilities":{"PRIMARY":0.1,"LOW_PRIORITY":0.9}}"#

private func choiceEnvelope(_ answer: String, model: String = #""jev-test""#, usage: String = "{}", answersKey: String = "p0001") -> String {
    "{\"model\":\(model),\"usage\":\(usage),\"answers\":{\"\(answersKey)\":\(answer)}}"
}

@Test
func boundaryTransportUsesRawCharacterCandidatesAndPrivateMinimalState() async throws {
    let raw = "👩🏽‍💻、⟨1⟩。？！?!最後。"
    let source = try contractSource("private-current", seq: 1)
    let head = String(String(repeating: "👨‍👩‍👧‍👦", count: 60).prefix(60))
    let next = try NextSegmentHead(source: contractSource("private-next", seq: 2), text: head)
    let request = try ClauseBoundaryRequest(source: source, text: raw, next: next)
    let candidates = request.candidates
    #expect(candidates.first?.offsetUTF16 == "👩🏽‍💻、".utf16.count)
    #expect(candidates.last?.offsetUTF16 == raw.utf16.count - "最後。".utf16.count)
    var answers = candidates.map { "\"\($0.id)\":{\"type\":\"noul\",\"noul\":0.6}" }
    answers.append(#""continuation":{"type":"noul","noul":0.5}"#)
    let transport = ContractTransport(json: "{\"model\":\"jev-test\",\"usage\":{\"input_tokens\":42,\"output_tokens\":8},\"answers\":{\(answers.joined(separator: ","))}}")
    let response = try await JevClient(apiKey: "private-secret", transport: transport).assessBoundaries(request)
    #expect(response.probabilities == Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, 0.6) }))
    #expect(response.continuationProbability == 0.5)
    #expect(response.metadata.inputTokens == 42)
    #expect(response.metadata.outputTokens == 8)
    let sends = await transport.requests
    #expect(sends.count == 1)
    let sent = try #require(sends.first)
    #expect(sent.url == JevClient.endpoint)
    #expect(sent.timeoutInterval == 15)
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer private-secret")
    let bodyData = try #require(sent.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    let state = try #require(body["state"] as? [String: String])
    #expect(Set(state.keys) == ["text", "next_text"])
    #expect(state["next_text"] == head)
    let marked = try #require(state["text"])
    #expect(marked.contains("⟨1⟩"))
    for (index, _) in candidates.enumerated() { #expect(marked.contains("⟨⟨\(index + 1)⟩")) }
    let questions = try #require(body["questions"] as? [String: [String: Any]])
    #expect(Set(questions.keys) == Set(candidates.map(\.id) + ["continuation"]))
    #expect(questions.values.allSatisfy { $0["type"] as? String == "noul" })
    let encoded = String(decoding: bodyData, as: UTF8.self)
    for forbidden in ["private-current", "private-next", "private-asr", "private-segmentation", "private-secret"] { #expect(!encoded.contains(forbidden)) }
}

@Test
func terminalBoundaryOmitsSuccessorAndContinuation() async throws {
    let transport = ContractTransport(json: #"{"model":"jev-test","usage":{},"answers":{"b0001":{"type":"noul","noul":1}}}"#)
    let request = try ClauseBoundaryRequest(source: contractSource("one", seq: 1), text: "前。後。", next: nil)
    let result = try await JevClient(apiKey: "secret", transport: transport).assessBoundaries(request)
    #expect(result.continuationProbability == nil)
    #expect(result.metadata.inputTokens == nil)
    let sends = await transport.requests
    let body = try #require(JSONSerialization.jsonObject(with: sends[0].httpBody!) as? [String: Any])
    #expect((body["state"] as? [String: String]) == ["text": "前。⟨1⟩後。"])
    #expect(Set((body["questions"] as! [String: Any]).keys) == ["b0001"])
}

@Test
func fortyChoiceTargetsProduceOneResponseWithTargetKeys() async throws {
    let targets = (1...40).map { PriorityTextTarget(key: String(format: "u%04d", $0), text: "本文\($0)") }
    let answers = (1...40).map { "\"\(String(format: "p%04d", $0))\":\(validChoice)" }.joined(separator: ",")
    let transport = ContractTransport(json: "{\"model\":\"jev-test\",\"usage\":{\"input_tokens\":123},\"answers\":{\(answers)}}")
    let result = try await JevClient(apiKey: "secret", transport: transport).classifyPriorities(targets)
    #expect(Set(result.decisions.keys) == Set(targets.map(\.key)))
    #expect(result.decisions.values.allSatisfy { $0.priority == .lowPriority && $0.confidence == 0.9 && $0.probabilities == ["PRIMARY": 0.1, "LOW_PRIORITY": 0.9] })
    #expect(result.metadata.inputTokens == 123)
    #expect(result.metadata.outputTokens == nil)
    let sends = await transport.requests
    #expect(sends.count == 1)
    let body = try #require(JSONSerialization.jsonObject(with: sends[0].httpBody!) as? [String: Any])
    #expect(body["state"] as? [String: String] == Dictionary(uniqueKeysWithValues: targets.map { ($0.key, $0.text) }))
    let questions = try #require(body["questions"] as? [String: [String: Any]])
    #expect(Set(questions.keys) == Set((1...40).map { String(format: "p%04d", $0) }))
    for target in targets {
        let question = try #require(questions["p" + target.key.dropFirst()])
        #expect(question["type"] as? String == "choice")
        #expect((question["instructions"] as? String)?.contains("`\(target.key)`") == true)
    }
}

@Test
func transportPreflightRejectsInvalidTargetSetsWithoutSending() async throws {
    let transport = ContractTransport(json: "{}")
    let client = JevClient(apiKey: "secret", transport: transport)
    let invalid: [[PriorityTextTarget]] = [
        [], [.init(key: "u0001", text: " \n")], [.init(key: "source-id", text: "本文")], [.init(key: "u0000", text: "本文")],
        [.init(key: "u0001", text: "前"), .init(key: "u0001", text: "後")],
        (1...41).map { .init(key: String(format: "u%04d", $0), text: "本文") }
    ]
    for targets in invalid { await #expect(throws: JevClientError.self) { try await client.classifyPriorities(targets) } }
    let noQuestions = try ClauseBoundaryRequest(source: contractSource("one", seq: 1), text: "末尾。", next: nil)
    await #expect(throws: JevClientError.self) { try await client.assessBoundaries(noQuestions) }
    #expect(await transport.requests.isEmpty)
}

@Test(arguments: [
    #"{"type":"noul","noul":0.9}"#,
    #"{"type":"choice","choice":"OTHER","confidence":0.9,"probabilities":{"PRIMARY":0.1,"LOW_PRIORITY":0.9}}"#,
    #"{"type":"choice","choice":"PRIMARY","confidence":1.1,"probabilities":{"PRIMARY":0.1,"LOW_PRIORITY":0.9}}"#,
    #"{"type":"choice","choice":"PRIMARY","confidence":0.9,"probabilities":{"PRIMARY":-0.1,"LOW_PRIORITY":0.9}}"#,
    #"{"type":"choice","choice":"PRIMARY","confidence":0.9,"probabilities":{"PRIMARY":0.1,"LOW_PRIORITY":1.1}}"#,
    #"{"type":"choice","choice":"PRIMARY","confidence":0.9,"probabilities":{"PRIMARY":0.1}}"#,
    #"{"type":"choice","choice":"PRIMARY","confidence":0.9}"#,
    #"{"type":"choice","choice":"PRIMARY","confidence":"secret-body","probabilities":{"PRIMARY":0.1,"LOW_PRIORITY":0.9}}"#,
    #"{"type":"choice","choice":"PRIMARY","probabilities":{"PRIMARY":0.1,"LOW_PRIORITY":0.9}}"#,
    #"{"type":"choice","choice":"PRIMARY","confidence":0.9,"probabilities":{"PRIMARY":0.1,"LOW_PRIORITY":0.9,"OTHER":0}}"#,
    #"{"choice":"PRIMARY","confidence":0.9,"probabilities":{"PRIMARY":0.1,"LOW_PRIORITY":0.9}}"#
])
func choiceAnswerInvalidatesEntireRequest(_ answer: String) async {
    let client = JevClient(apiKey: "secret", transport: ContractTransport(json: choiceEnvelope(answer)))
    do {
        _ = try await client.classifyPriorities([.init(key: "u0001", text: "private-body")])
        Issue.record("Invalid answer accepted")
    } catch {
        for forbidden in ["p0001", "u0001", "private-body", "secret"] { #expect(!error.localizedDescription.contains(forbidden)) }
    }
}

@Test(arguments: [
    #"{"answers":{"p0001":ANSWER},"usage":{}}"#,
    #"{"model":"","answers":{"p0001":ANSWER},"usage":{}}"#,
    #"{"model":42,"answers":{"p0001":ANSWER},"usage":{}}"#,
    #"{"model":"jev-test","answers":{"p0001":ANSWER}}"#,
    #"{"model":"jev-test","answers":{"p0001":ANSWER},"usage":null}"#,
    #"{"model":"jev-test","answers":{"p0001":ANSWER},"usage":[]}"#,
    #"{"model":"jev-test","answers":{"p0001":ANSWER},"usage":{"input_tokens":-1}}"#,
    #"{"model":"jev-test","answers":{"p0001":ANSWER},"usage":{"output_tokens":-1}}"#,
    #"{"model":"jev-test","answers":{"p0001":ANSWER},"usage":{"input_tokens":"3"}}"#,
    #"{"model":"jev-test","answers":{"p0001":ANSWER},"usage":{"output_tokens":1.5}}"#,
    #"{"model":"jev-test","answers":{},"usage":{}}"#,
    #"{"model":"jev-test","answers":{"p0001":ANSWER,"p0002":ANSWER},"usage":{}}"#
])
func invalidResponseEnvelopeRejectsWholeBatch(_ template: String) async {
    let client = JevClient(apiKey: "secret", transport: ContractTransport(json: template.replacingOccurrences(of: "ANSWER", with: validChoice)))
    await #expect(throws: JevClientError.self) { try await client.classifyPriorities([.init(key: "u0001", text: "本文")]) }
}

@Test(arguments: [nil, #"{"type":"noul","noul":0.9}"#,
                  #"{"type":"choice","choice":"OTHER","confidence":1,"probabilities":{"PRIMARY":1,"LOW_PRIORITY":0}}"#] as [String?])
func malformedSecondChoiceRejectsTheFirstValidChoiceAndCountsOneFailedRequest(_ second: String?) async throws {
    let suffix = second.map { ",\"p0002\":\($0)" } ?? ""
    let transport = ContractTransport(json: "{\"model\":\"jev-test\",\"usage\":{\"input_tokens\":7},\"answers\":{\"p0001\":\(validChoice)\(suffix)}}")
    let counter = JevUsageCounter()
    let coordinator = JevDecisionCoordinator(
        provider: JevClient(apiKey: "secret", transport: transport), usageCounter: counter
    )
    let outcome = await coordinator.classifyPriorities([
        .init(key: "u0001", text: "先に有効"),
        .init(key: "u0002", text: "後に不正")
    ])
    guard case .failed = outcome else {
        Issue.record("Malformed batch exposed a result")
        return
    }
    let usage = await counter.snapshot()
    #expect(usage.priorityRequests.sendCount == 1)
    #expect(usage.priorityRequests.failureCount == 1)
    #expect(usage.priorityRequests.successCount == 0)
    #expect(usage.reportedInputTokens == 0)
}

@Test(arguments: [#"{"type":"noul","noul":-0.1}"#, #"{"type":"noul","noul":1.1}"#, #"{"type":"noul","noul":"0.9"}"#, #"{"type":"noul"}"#, #"{"type":"choice","noul":0.9}"#])
func invalidNoulDoesNotPublishPartialProbabilities(_ invalid: String) async throws {
    let transport = ContractTransport(json: "{\"model\":\"jev-test\",\"usage\":{},\"answers\":{\"b0001\":{\"type\":\"noul\",\"noul\":0.9},\"b0002\":\(invalid)}}")
    let request = try ClauseBoundaryRequest(source: contractSource("one", seq: 1), text: "前。中。後", next: nil)
    await #expect(throws: JevClientError.self) { try await JevClient(apiKey: "secret", transport: transport).assessBoundaries(request) }
}

@Test
func sharedCodableTypesAndCandidateCoverageRejectInvalidData() throws {
    let source = try contractSource("one", seq: 1)
    #expect(try JSONDecoder().decode(SegmentTextReference.self, from: JSONEncoder().encode(source)) == source)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(SegmentTextReference.self, from: Data(#"{"segmentation_run_id":" ","segment_id":"s","asr_run_id":"a","asr_event_seq":1}"#.utf8)) }
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ClauseBoundaryCandidate.self, from: Data(#"{"id":"b0000","offset_utf16":1}"#.utf8)) }
    #expect(throws: (any Error).self) { try JSONDecoder().decode(JevResponseMetadata.self, from: Data(#"{"model":"m","input_tokens":-1}"#.utf8)) }
    #expect(throws: (any Error).self) { try ContentPriorityDecision(priority: .primary, confidence: .nan, probabilities: ["PRIMARY": 1, "LOW_PRIORITY": 0]) }
    #expect(throws: (any Error).self) { try ContentPriorityDecision(priority: .primary, confidence: 1, probabilities: ["PRIMARY": .infinity, "LOW_PRIORITY": 0]) }
    #expect(throws: (any Error).self) { try NextSegmentHead(source: source, text: String(repeating: "😀", count: 61)) }
    #expect(throws: (any Error).self) { try ClauseBoundaryRequest(source: source, text: "😀。後", candidates: [.init(id: "b0001", offsetUTF16: 2)], next: nil) }
    #expect(throws: (any Error).self) { try ClauseBoundaryRequest(source: source, text: "前。後", candidates: [], next: nil) }
    #expect(throws: (any Error).self) { try ClauseBoundaryRequest(source: source, text: "前。後", candidates: [.init(id: "b0002", offsetUTF16: 2)], next: nil) }
    #expect(throws: (any Error).self) { try ClauseBoundaryRequest(source: source, text: "前。後", candidates: [.init(id: "b0001", offsetUTF16: 2), .init(id: "b0001", offsetUTF16: 2)], next: nil) }
}

@Test(arguments: [(0.5.nextDown, false), (0.5, false), (0.5.nextUp, true)])
func noulPolicyUsesStrictThreshold(_ probability: Double, _ expected: Bool) {
    #expect(ClauseBoundaryPolicy.acceptsBoundary(probability) == expected)
    #expect(ClauseBoundaryPolicy.acceptsContinuation(probability) == expected)
}

@Test(arguments: [false, true])
func boundaryAnswerSetMustMatchContinuationPresence(_ hasNext: Bool) async throws {
    let source = try contractSource("one", seq: 1)
    let next = hasNext ? try NextSegmentHead(source: contractSource("two", seq: 2), text: "続き") : nil
    let request = try ClauseBoundaryRequest(source: source, text: "前。後", next: next)
    let answers = hasNext
        ? #"{"b0001":{"type":"noul","noul":0.9}}"#
        : #"{"b0001":{"type":"noul","noul":0.9},"continuation":{"type":"noul","noul":0.9}}"#
    let transport = ContractTransport(json: "{\"model\":\"jev-test\",\"usage\":{},\"answers\":\(answers)}")
    await #expect(throws: JevClientError.self) { try await JevClient(apiKey: "secret", transport: transport).assessBoundaries(request) }
}

@Test
func codableProbabilityAndNextHeadValidationCannotBeBypassed() throws {
    let decision = try ContentPriorityDecision(priority: .primary, confidence: 1, probabilities: ["PRIMARY": 1, "LOW_PRIORITY": 0])
    #expect(try JSONDecoder().decode(ContentPriorityDecision.self, from: JSONEncoder().encode(decision)) == decision)
    let encoded = try JSONEncoder().encode(decision)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["confidence"] = -1
    let invalid = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ContentPriorityDecision.self, from: invalid) }
    let source = try contractSource("one", seq: 1)
    let head = try NextSegmentHead(source: source, text: "次")
    var headObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(head)) as? [String: Any])
    headObject["text"] = String(repeating: "👩🏽‍💻", count: 61)
    let invalidHead = try JSONSerialization.data(withJSONObject: headObject)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(NextSegmentHead.self, from: invalidHead) }
    #expect(throws: (any Error).self) { try JevResponseMetadata(model: " ", inputTokens: nil, outputTokens: nil) }
    #expect(throws: (any Error).self) { try JevResponseMetadata(model: "m", inputTokens: nil, outputTokens: -1) }
}
