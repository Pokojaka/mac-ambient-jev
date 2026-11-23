import MacAmbientJevONNX

internal struct HaasDecoderJoint: TDTJoint {
    struct State {
        let previousToken: Int32
        let states1: ONNXValue
        let states2: ONNXValue
    }

    private let session: ONNXSession
    private let environment: ONNXEnvironment
    private let encoded: HaasEncodedAudio

    init(session: ONNXSession, environment: ONNXEnvironment, encoded: HaasEncodedAudio) {
        self.session = session
        self.environment = environment
        self.encoded = encoded
    }

    func initialState() throws -> State {
        let zeros = [Float](repeating: 0, count: 2 * 20_480)
        return State(
            previousToken: Int32(TDTGreedyDecoder.blank),
            states1: try ONNXValue(environment: environment, tensor: .float32(shape: [2, 1, 20_480], values: zeros)),
            states2: try ONNXValue(environment: environment, tensor: .float32(shape: [2, 1, 20_480], values: zeros))
        )
    }

    func step(frame: Int, state: State) throws -> (logits: [Float], stateAfterEmitting: (Int) -> State) {
        let offset = frame * HaasEncodedAudio.width
        let frameValues = Array(encoded.frames[offset..<(offset + HaasEncodedAudio.width)])
        let frameInput = try ONNXValue(
            environment: environment,
            tensor: .float32(shape: [1, Int64(HaasEncodedAudio.width), 1], values: frameValues)
        )
        let targetInput = try ONNXValue(
            environment: environment,
            tensor: .int32(shape: [1, 1], values: [state.previousToken])
        )
        let targetLength = try ONNXValue(
            environment: environment,
            tensor: .int32(shape: [1], values: [1])
        )
        let outputs = try session.runValues(
            inputs: [
                (name: "encoder_outputs", value: frameInput),
                (name: "targets", value: targetInput),
                (name: "target_length", value: targetLength),
                (name: "input_states_1", value: state.states1),
                (name: "input_states_2", value: state.states2)
            ],
            outputNames: ["outputs", "output_states_1", "output_states_2"]
        )
        let logitsTensor = try outputs[0].tensor()
        guard case let .float32(shape: logitsShape, values: logits) = logitsTensor,
              logitsShape == [1, 1, 1, 3078],
              outputs[1].shape == [2, 1, 20_480],
              outputs[2].shape == [2, 1, 20_480] else {
            throw HaasASRError.unexpectedGraph("decoder_joint returned invalid logits or recurrent-state shapes/types")
        }
        let nextStates1 = outputs[1]
        let nextStates2 = outputs[2]
        return (logits, { token in
            State(previousToken: Int32(token), states1: nextStates1, states2: nextStates2)
        })
    }
}
