import Foundation
import MacAmbientJevCore
import MacAmbientJevONNX

/// The clause tagger graph on one ONNX Runtime CPU session.
///
/// The graph takes int64 `input_ids [1,seq]` and returns float32 `boundary_probs [1,seq,2]`,
/// `span_probs [1,seq,4]` and `priority_probs [1,2]`. The session is not thread-safe for concurrent
/// state; the owning actor serializes calls.
final class ONNXClauseTaggerModel {
    static let cpuMemoryArenaEnabled = false

    private static let inputName = "input_ids"
    private static let boundaryName = "boundary_probs"
    private static let spanName = "span_probs"
    private static let priorityName = "priority_probs"
    private static let vocabularySize = 102_400

    private let session: ONNXSession

    init(assets: ClauseTaggerAssets, intraOpThreads: Int) throws {
        let environment = try ONNXEnvironment.shared()
        session = try ONNXSession(
            environment: environment,
            modelURL: assets.modelURL,
            intraOpThreads: intraOpThreads,
            cpuMemoryArenaEnabled: Self.cpuMemoryArenaEnabled
        )
        try Self.validate(
            direction: "入力",
            actual: session.inputMetadata(),
            expected: [(Self.inputName, .int64, [1, -1])]
        )
        try Self.validate(
            direction: "出力",
            actual: session.outputMetadata(),
            expected: [
                (Self.boundaryName, .float32, [1, -1, 2]),
                (Self.spanName, .float32, [1, -1, 4]),
                (Self.priorityName, .float32, [1, 2]),
            ]
        )
    }

    func predict(inputIDs: [Int]) throws -> ClauseTaggerPrediction {
        guard (2...ClauseTaggerEncoding.maximumTokens).contains(inputIDs.count),
              inputIDs.allSatisfy({ (0..<Self.vocabularySize).contains($0) }),
              inputIDs.first == ClauseTaggerEncoding.clsTokenID,
              inputIDs.last == ClauseTaggerEncoding.sepTokenID else {
            throw ClauseTaggerModelError.invalidInput
        }
        let length = inputIDs.count
        let outputs: [ONNXTensor]
        do {
            outputs = try session.run(
                inputs: [(Self.inputName, .int64(shape: [1, Int64(length)], values: inputIDs.map(Int64.init)))],
                outputNames: [Self.boundaryName, Self.spanName, Self.priorityName]
            )
        } catch {
            throw ClauseTaggerModelError.unavailable("ONNX Runtime の推論に失敗しました: \(error.localizedDescription)")
        }
        guard outputs.count == 3,
              case let .float32(boundaryShape, boundaryValues) = outputs[0],
              case let .float32(spanShape, spanValues) = outputs[1],
              case let .float32(priorityShape, priorityValues) = outputs[2],
              boundaryShape == [1, Int64(length), 2],
              spanShape == [1, Int64(length), 4],
              priorityShape == [1, 2],
              boundaryValues.count == length * 2,
              spanValues.count == length * 4,
              priorityValues.count == 2 else {
            throw ClauseTaggerModelError.invalidOutput
        }
        return ClauseTaggerPrediction(
            boundaryProbabilities: try Self.rows(boundaryValues, width: 2),
            spanProbabilities: try Self.rows(spanValues, width: 4),
            priorityProbabilities: try Self.distribution(priorityValues[...])
        )
    }

    private static func rows(_ values: [Float], width: Int) throws -> [[Double]] {
        try stride(from: 0, to: values.count, by: width).map { start in
            try distribution(values[start..<start + width])
        }
    }

    private static func distribution(_ row: ArraySlice<Float>) throws -> [Double] {
        let values = row.map(Double.init)
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(values.reduce(0, +) - 1) <= taggerProbabilitySumTolerance else {
            throw ClauseTaggerModelError.invalidOutput
        }
        return values
    }

    private static func validate(
        direction: String,
        actual: [ONNXTensorMetadata],
        expected: [(name: String, type: ONNXTensorElementType, shape: [Int64])]
    ) throws {
        let matches = actual.count == expected.count && expected.allSatisfy { wanted in
            actual.contains { $0.name == wanted.name && $0.elementType == wanted.type && $0.shape == wanted.shape }
        }
        guard matches else {
            let found = actual.map { "\($0.name) \($0.elementType) \($0.shape)" }
            let wanted = expected.map { "\($0.name) \($0.type) \($0.shape)" }
            throw ClauseTaggerModelError.invalidModel(
                "ONNX グラフの\(direction)が仕様に一致しません。実際: \(found)、期待: \(wanted)"
            )
        }
    }
}
