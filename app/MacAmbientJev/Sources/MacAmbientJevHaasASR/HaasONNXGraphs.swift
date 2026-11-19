import Foundation
import MacAmbientJevONNX

internal struct HaasEncodedAudio {
    let frames: [Float]
    let frameCount: Int
    static let width = 1024
}

internal final class HaasONNXGraphs {
    private let environment: ONNXEnvironment
    private let encoder: ONNXSession
    private let decoder: ONNXSession

    init(files: HaasASRModelFiles, environment: ONNXEnvironment, intraOpThreads: Int) throws {
        let encoder = try ONNXSession(
            environment: environment,
            modelURL: files.encoder,
            intraOpThreads: intraOpThreads,
            cpuMemoryArenaEnabled: true
        )
        try validateMetadata(
            encoder,
            context: "encoder",
            inputs: [
                ONNXTensorMetadata(name: "audio_signal", elementType: .float32, shape: [-1, 128, -1]),
                ONNXTensorMetadata(name: "length", elementType: .int64, shape: [-1])
            ],
            outputs: [
                ONNXTensorMetadata(name: "outputs", elementType: .float32, shape: [-1, 1024, -1]),
                ONNXTensorMetadata(name: "encoded_lengths", elementType: .int64, shape: [-1])
            ]
        )
        let decoder = try ONNXSession(
            environment: environment,
            modelURL: files.decoderJoint,
            intraOpThreads: intraOpThreads,
            cpuMemoryArenaEnabled: true
        )
        try validateMetadata(
            decoder,
            context: "decoder_joint",
            inputs: [
                ONNXTensorMetadata(name: "encoder_outputs", elementType: .float32, shape: [-1, 1024, -1]),
                ONNXTensorMetadata(name: "targets", elementType: .int32, shape: [-1, 1]),
                ONNXTensorMetadata(name: "target_length", elementType: .int32, shape: [-1]),
                ONNXTensorMetadata(name: "input_states_1", elementType: .float32, shape: [2, -1, 20480]),
                ONNXTensorMetadata(name: "input_states_2", elementType: .float32, shape: [2, -1, 20480])
            ],
            outputs: [
                ONNXTensorMetadata(name: "outputs", elementType: .float32, shape: [-1, -1, -1, 3078]),
                ONNXTensorMetadata(name: "prednet_lengths", elementType: .int32, shape: [-1]),
                ONNXTensorMetadata(name: "output_states_1", elementType: .float32, shape: [2, -1, 20480]),
                ONNXTensorMetadata(name: "output_states_2", elementType: .float32, shape: [2, -1, -1])
            ]
        )
        self.environment = environment
        self.encoder = encoder
        self.decoder = decoder
    }

    /// Transposes channel-major encoder output `enc[c*T + t]` into frame-major storage,
    /// where `T` is the returned output time stride (`shape[2]`).
    func encode(_ mel: HaasMelFeatures) throws -> HaasEncodedAudio {
        let outputs = try encoder.run(
            inputs: [
                (name: "audio_signal", tensor: .float32(shape: [1, 128, Int64(mel.paddedFrames)], values: mel.values)),
                (name: "length", tensor: .int64(shape: [1], values: [Int64(mel.validFrames)]))
            ],
            outputNames: ["outputs", "encoded_lengths"]
        )
        guard case let .float32(shape: shape, values: encoded) = outputs[0],
              case let .int64(shape: lengthShape, values: lengths) = outputs[1],
              shape.count == 3, shape[0] == 1, shape[1] == Int64(HaasEncodedAudio.width), shape[2] >= 0,
              lengthShape == [1],
              let time = Int(exactly: shape[2]), let frameCount = Int(exactly: lengths[0]),
              frameCount >= 0, frameCount <= time else {
            throw HaasASRError.unexpectedGraph("encoder returned invalid output shapes, types, or encoded length")
        }

        var frames = [Float](repeating: 0, count: frameCount * HaasEncodedAudio.width)
        for t in 0..<frameCount {
            for c in 0..<HaasEncodedAudio.width {
                frames[t * HaasEncodedAudio.width + c] = encoded[c * time + t]
            }
        }
        return HaasEncodedAudio(frames: frames, frameCount: frameCount)
    }

    func joint(_ encoded: HaasEncodedAudio) -> HaasDecoderJoint {
        HaasDecoderJoint(session: decoder, environment: environment, encoded: encoded)
    }
}

private func validateMetadata(
    _ session: ONNXSession,
    context: String,
    inputs: [ONNXTensorMetadata],
    outputs: [ONNXTensorMetadata]
) throws {
    let actualInputs: [ONNXTensorMetadata]
    let actualOutputs: [ONNXTensorMetadata]
    do {
        actualInputs = try session.inputMetadata()
        actualOutputs = try session.outputMetadata()
    } catch {
        throw HaasASRError.unexpectedGraph("\(context) metadata could not be read: \(error)")
    }
    guard actualInputs == inputs else {
        throw HaasASRError.unexpectedGraph("\(context) input metadata mismatch: \(actualInputs)")
    }
    guard actualOutputs == outputs else {
        throw HaasASRError.unexpectedGraph("\(context) output metadata mismatch: \(actualOutputs)")
    }
}
