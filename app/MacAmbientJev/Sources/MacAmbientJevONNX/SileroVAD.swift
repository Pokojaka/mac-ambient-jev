import Foundation

public final class SileroVAD {
    public static let frameSamples = 512
    private static let contextSamples = 64
    private static let sampleRate: Int64 = 16_000
    private static let stateShape: [Int64] = [2, 1, 128]
    private static let stateSamples = stateShape.reduce(1) { $0 * Int($1) }

    private let session: ONNXSession
    private var state = [Float](repeating: 0, count: SileroVAD.stateSamples)
    private var context = [Float](repeating: 0, count: SileroVAD.contextSamples)

    public init(environment: ONNXEnvironment, modelURL: URL, intraOpThreads: Int) throws {
        self.session = try ONNXSession(
            environment: environment,
            modelURL: modelURL,
            intraOpThreads: intraOpThreads
        )
    }

    public func speechProbability(frame: [Float]) throws -> Float {
        guard frame.count == Self.frameSamples else {
            throw ONNXRuntimeError(message: "Silero VADの入力フレームは\(Self.frameSamples)サンプルである必要があります。実際のサンプル数: \(frame.count)。")
        }
        guard frame.allSatisfy(\.isFinite) else {
            throw ONNXRuntimeError(message: "Silero VADの入力フレームに有限でない値が含まれています。")
        }

        let input = context + frame
        let outputs = try session.run(
            inputs: [
                (name: "input", tensor: .float32(shape: [1, Int64(Self.frameSamples + Self.contextSamples)], values: input)),
                (name: "state", tensor: .float32(shape: Self.stateShape, values: state)),
                (name: "sr", tensor: .int64(shape: [], values: [Self.sampleRate]))
            ],
            outputNames: ["output", "stateN"]
        )

        guard outputs.count == 2 else {
            throw ONNXRuntimeError(message: "Silero VADの出力は2個である必要があります。実際の出力数: \(outputs.count)。")
        }

        guard case let .float32(probabilityShape, probabilityValues) = outputs[0] else {
            throw ONNXRuntimeError(message: "Silero VADの確率出力はfloat32である必要があります。")
        }
        guard probabilityShape == [1, 1], probabilityValues.count == 1 else {
            throw ONNXRuntimeError(message: "Silero VADの確率出力形状は[1, 1]である必要があります。")
        }
        guard let probability = probabilityValues.first, probability.isFinite else {
            throw ONNXRuntimeError(message: "Silero VADの確率出力は有限な値である必要があります。")
        }
        guard (0...1).contains(probability) else {
            throw ONNXRuntimeError(message: "Silero VADの確率出力は0から1の範囲である必要があります。")
        }

        guard case let .float32(nextStateShape, nextState) = outputs[1] else {
            throw ONNXRuntimeError(message: "Silero VADの状態出力はfloat32である必要があります。")
        }
        guard nextStateShape == Self.stateShape, nextState.count == Self.stateSamples else {
            throw ONNXRuntimeError(message: "Silero VADの状態出力形状は\(Self.stateShape)である必要があります。")
        }
        guard nextState.allSatisfy(\.isFinite) else {
            throw ONNXRuntimeError(message: "Silero VADの状態出力に有限でない値が含まれています。")
        }

        let nextContext = Array(frame.suffix(Self.contextSamples))
        state = nextState
        context = nextContext
        return probability
    }

    public func reset() {
        state = [Float](repeating: 0, count: Self.stateSamples)
        context = [Float](repeating: 0, count: Self.contextSamples)
    }
}
