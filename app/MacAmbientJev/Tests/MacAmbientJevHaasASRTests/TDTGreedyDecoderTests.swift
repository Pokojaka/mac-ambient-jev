import Testing
@testable import MacAmbientJevHaasASR

private struct DecoderState: Equatable {
    let previousToken: Int
    let generation: Int
}

private struct ScriptKey: Hashable {
    let frame: Int
    let previousToken: Int
}

private enum ScriptError: Error { case missing }

private final class ScriptedJoint: TDTJoint {
    typealias State = DecoderState
    let script: [ScriptKey: [Float]]
    private(set) var committedTokens: [Int] = []
    private(set) var received: [(Int, DecoderState)] = []

    init(_ script: [ScriptKey: [Float]]) { self.script = script }
    func initialState() throws -> DecoderState {
        DecoderState(previousToken: TDTGreedyDecoder.blank, generation: 0)
    }
    func step(frame: Int, state: DecoderState) throws -> (logits: [Float], stateAfterEmitting: (Int) -> DecoderState) {
        received.append((frame, state))
        guard let logits = script[ScriptKey(frame: frame, previousToken: state.previousToken)] else {
            throw ScriptError.missing
        }
        return (logits, { token in
            self.committedTokens.append(token)
            return DecoderState(previousToken: token, generation: state.generation + 1)
        })
    }
}

private func decision(_ token: Int, _ duration: Int) -> [Float] {
    var logits = [Float](repeating: -1, count: 3078)
    logits[token] = 1
    logits[3073 + duration] = 1
    return logits
}

struct TDTGreedyDecoderTests {
    @Test(arguments: 0...4)
    func blankDurationsAdvanceByDurationOrOne(_ duration: Int) throws {
        let nextFrame = max(1, duration)
        let blank = TDTGreedyDecoder.blank
        let joint = ScriptedJoint([
            ScriptKey(frame: 0, previousToken: blank): decision(blank, duration),
            ScriptKey(frame: nextFrame, previousToken: blank): decision(blank, 4)
        ])
        #expect(try TDTGreedyDecoder.decode(frameCount: 5, joint: joint).isEmpty)
        #expect(joint.received.map { $0.0 } == [0, nextFrame])
        #expect(joint.committedTokens.isEmpty)
    }

    @Test(arguments: [0, 1])
    func tenEmissionsRespectDurationAdvanceAtFrameCap(_ tenthDuration: Int) throws {
        var script: [ScriptKey: [Float]] = [:]
        var previous = TDTGreedyDecoder.blank
        for token in 1...20 {
            let frame = token <= 10 ? 0 : 1
            let duration = token == 10 ? tenthDuration : 0
            script[ScriptKey(frame: frame, previousToken: previous)] = decision(token, duration)
            previous = token
        }
        let joint = ScriptedJoint(script)
        #expect(try TDTGreedyDecoder.decode(frameCount: 2, joint: joint) == Array(1...20))
        #expect(joint.received.map { $0.0 } == Array(repeating: 0, count: 10) + Array(repeating: 1, count: 10))
    }

    @Test
    func emittedStateCommitsEvenWhenDurationJumpsPastEnd() throws {
        let blank = TDTGreedyDecoder.blank
        let joint = ScriptedJoint([ScriptKey(frame: 0, previousToken: blank): decision(42, 4)])
        #expect(try TDTGreedyDecoder.decode(frameCount: 2, joint: joint) == [42])
        #expect(joint.committedTokens == [42])
        #expect(joint.received.map { $0.0 } == [0])
    }

    @Test
    func tokenAndDurationTiesChooseLowestIndex() throws {
        var tied = [Float](repeating: -1, count: 3078)
        tied[3] = 8
        tied[4] = 8
        tied[3073] = 8
        tied[3075] = 8
        let joint = ScriptedJoint([
            ScriptKey(frame: 0, previousToken: TDTGreedyDecoder.blank): tied,
            ScriptKey(frame: 0, previousToken: 3): decision(8, 1)
        ])
        #expect(try TDTGreedyDecoder.decode(frameCount: 1, joint: joint) == [3, 8])
        #expect(joint.received.map { $0.0 } == [0, 0])
    }

    @Test
    func blankKeepsStateAndLabelsResetCountAfterFrameSkip() throws {
        let blank = TDTGreedyDecoder.blank
        var script: [ScriptKey: [Float]] = [:]
        var previous = blank
        for token in 40...48 {
            script[ScriptKey(frame: 0, previousToken: previous)] = decision(token, 0)
            previous = token
        }
        script[ScriptKey(frame: 0, previousToken: previous)] = decision(blank, 1)
        for token in 49...50 {
            script[ScriptKey(frame: 1, previousToken: previous)] = decision(token, 0)
            previous = token
        }
        script[ScriptKey(frame: 1, previousToken: previous)] = decision(51, 1)
        let joint = ScriptedJoint(script)
        #expect(try TDTGreedyDecoder.decode(frameCount: 2, joint: joint) == Array(40...51))
        let expectedStates = (0..<9).map { generation in
            DecoderState(previousToken: generation == 0 ? blank : 39 + generation, generation: generation)
        } + [
            DecoderState(previousToken: 48, generation: 9),
            DecoderState(previousToken: 48, generation: 9),
            DecoderState(previousToken: 49, generation: 10),
            DecoderState(previousToken: 50, generation: 11)
        ]
        #expect(joint.received.map { $0.0 } == Array(repeating: 0, count: 10) + Array(repeating: 1, count: 3))
        #expect(joint.received.map { $0.1 } == expectedStates)
        #expect(joint.committedTokens == Array(40...51))
    }
}
