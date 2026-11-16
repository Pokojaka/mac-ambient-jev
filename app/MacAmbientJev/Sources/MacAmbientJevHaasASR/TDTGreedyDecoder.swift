/// A joint step returns logits and a state factory. State owns the previous token
/// (initially blank) and opaque reference-backed inference state; the factory
/// creates committed state only for emitted tokens, without copying tensors.
protocol TDTJoint {
    associatedtype State
    func initialState() throws -> State
    func step(frame: Int, state: State) throws -> (logits: [Float], stateAfterEmitting: (Int) -> State)
}

enum TDTGreedyDecoder {
    static let blank = 3072
    static let durations = [0, 1, 2, 3, 4]
    static let maxSymbolsPerFrame = 10

    static func decode<Joint: TDTJoint>(frameCount: Int, joint: Joint) throws -> [Int] {
        precondition(frameCount >= 0)
        var state = try joint.initialState()
        var frame = 0
        var lastLabelFrame = -1
        var count = 0
        var tokens: [Int] = []

        while frame < frameCount {
            var token: Int
            var t_label: Int
            var stateAfterEmitting: (Int) -> Joint.State
            repeat {
                let (logits, nextStateAfterEmitting) = try joint.step(frame: frame, state: state)
                precondition(logits.count == 3078)
                token = firstArgmax(logits[0..<3073])
                var duration = durations[firstArgmax(logits[3073..<3078])]
                if token == blank && duration == 0 { duration = 1 }
                t_label = frame
                frame += duration
                stateAfterEmitting = nextStateAfterEmitting
            } while token == blank && frame < frameCount

            if token != blank {
                tokens.append(token)
                count = t_label == lastLabelFrame ? count + 1 : 1
                lastLabelFrame = t_label
                state = stateAfterEmitting(token)
                if count >= maxSymbolsPerFrame && lastLabelFrame == frame {
                    frame += 1
                }
            }
        }
        return tokens
    }

    private static func firstArgmax(_ values: ArraySlice<Float>) -> Int {
        var bestIndex = 0
        var best = values[values.startIndex]
        for index in 1..<values.count {
            let value = values[values.startIndex + index]
            if (value.isNaN && !best.isNaN) || (!best.isNaN && value > best) {
                best = value
                bestIndex = index
            }
        }
        return bestIndex
    }
}
