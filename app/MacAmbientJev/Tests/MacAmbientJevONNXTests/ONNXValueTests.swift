import Foundation
import Testing
import MacAmbientJevONNX

struct ONNXValueTests {
    private let environment: ONNXEnvironment

    init() throws {
        environment = try ONNXEnvironment.shared()
    }

    @Test
    func outputValuesChainAsInputsAcrossRunsWithoutReadingThemBack() throws {
        let session = try makeCacheSession()
        var past = try ONNXValue(environment: environment, tensor: .float32(shape: [1, 0, 2], values: []))
        var count = try ONNXValue(environment: environment, tensor: .int64(shape: [1], values: [10]))

        for step in 1...4 {
            let stepValue = try ONNXValue(
                environment: environment,
                tensor: .float32(shape: [1, 1, 2], values: [Float(step), Float(-step)])
            )
            let outputs = try session.runValues(
                inputs: [(name: "past", value: past), (name: "step", value: stepValue), (name: "count", value: count)],
                outputNames: ["present", "count_out"]
            )
            past = outputs[0]
            count = outputs[1]
            #expect(past.shape == [1, Int64(step), 2])
            #expect(count.shape == [1])
        }

        #expect(try past.tensor() == .float32(shape: [1, 4, 2], values: [1, -1, 2, -2, 3, -3, 4, -4]))
        #expect(try count.tensor() == .int64(shape: [1], values: [14]))
    }

    @Test
    func tensorRunAndValueRunAgree() throws {
        let session = try makeCacheSession()
        let past: ONNXTensor = .float32(shape: [1, 2, 2], values: [1, 2, 3, 4])
        let step: ONNXTensor = .float32(shape: [1, 1, 2], values: [5, 6])
        let count: ONNXTensor = .int64(shape: [1], values: [7])

        let copied = try session.run(
            inputs: [(name: "past", tensor: past), (name: "step", tensor: step), (name: "count", tensor: count)],
            outputNames: ["present", "count_out"]
        )
        let values = try session.runValues(
            inputs: [
                (name: "past", value: try ONNXValue(environment: environment, tensor: past)),
                (name: "step", value: try ONNXValue(environment: environment, tensor: step)),
                (name: "count", value: try ONNXValue(environment: environment, tensor: count)),
            ],
            outputNames: ["present", "count_out"]
        )
        #expect(copied == [.float32(shape: [1, 3, 2], values: [1, 2, 3, 4, 5, 6]), .int64(shape: [1], values: [8])])
        #expect(try values.map { try $0.tensor() } == copied)
    }

    @Test
    func lastRowEqualsTheLastRowOfTheFullReadout() throws {
        let session = try makeCacheSession()
        let past = try ONNXValue(
            environment: environment,
            tensor: .float32(shape: [1, 3, 2], values: [1, 2, 3, 4, 5, 6])
        )
        let step = try ONNXValue(environment: environment, tensor: .float32(shape: [1, 1, 2], values: [7.5, -8.5]))
        let count = try ONNXValue(environment: environment, tensor: .int64(shape: [1], values: [0]))
        let present = try session.runValues(
            inputs: [(name: "past", value: past), (name: "step", value: step), (name: "count", value: count)],
            outputNames: ["present"]
        )[0]

        guard case let .float32(shape, values) = try present.tensor() else {
            Issue.record("float32テンソルが必要です。")
            return
        }
        let rowLength = Int(shape[2])
        let rowCount = Int(shape[1])
        #expect(try present.float32LastRow() == Array(values[(rowCount - 1) * rowLength ..< rowCount * rowLength]))
        #expect(try present.float32LastRow() == [7.5, -8.5])
        #expect(try past.float32LastRow() == [5, 6])
    }

    @Test
    func lastRowRejectsOtherTypesAndShapes() throws {
        let int64Value = try ONNXValue(environment: environment, tensor: .int64(shape: [1, 1, 2], values: [1, 2]))
        #expect(onnxErrorMessage { _ = try int64Value.float32LastRow() } == "最終行の読み出しにはfloat32テンソルが必要です。")

        for shape: [Int64] in [[2, 2], [2, 1, 2], [1, 0, 2]] {
            let count = shape.reduce(1, *)
            let value = try ONNXValue(
                environment: environment,
                tensor: .float32(shape: shape, values: [Float](repeating: 1, count: Int(count)))
            )
            #expect(onnxErrorMessage { _ = try value.float32LastRow() }.hasPrefix("最終行の読み出しには形状[1, S, V]"))
        }
    }

    @Test
    func unknownNamesAndMismatchedShapesFailWithRuntimeErrors() throws {
        let session = try makeCacheSession()
        let past = try ONNXValue(environment: environment, tensor: .float32(shape: [1, 1, 2], values: [0, 0]))
        let step = try ONNXValue(environment: environment, tensor: .float32(shape: [1, 1, 2], values: [0, 0]))
        let count = try ONNXValue(environment: environment, tensor: .int64(shape: [1], values: [0]))
        let inputs = [(name: "past", value: past), (name: "step", value: step), (name: "count", value: count)]
        let runContext = "ONNXモデルの実行に失敗しました"

        let unknownOutput = onnxErrorMessage { _ = try session.runValues(inputs: inputs, outputNames: ["missing"]) }
        #expect(unknownOutput.hasPrefix(runContext))

        var unknownInput = inputs
        unknownInput[0] = (name: "unknown", value: past)
        let unknownInputMessage = onnxErrorMessage { _ = try session.runValues(inputs: unknownInput, outputNames: ["present"]) }
        #expect(unknownInputMessage.hasPrefix(runContext))

        var wrongWidth = inputs
        wrongWidth[0] = (
            name: "past",
            value: try ONNXValue(environment: environment, tensor: .float32(shape: [1, 1, 3], values: [0, 0, 0]))
        )
        let wrongWidthMessage = onnxErrorMessage { _ = try session.runValues(inputs: wrongWidth, outputNames: ["present"]) }
        #expect(wrongWidthMessage.hasPrefix(runContext))

        var wrongType = inputs
        wrongType[2] = (name: "count", value: step)
        let wrongTypeMessage = onnxErrorMessage { _ = try session.runValues(inputs: wrongType, outputNames: ["present"]) }
        #expect(wrongTypeMessage.hasPrefix(runContext))

        let outputs = try session.runValues(inputs: inputs, outputNames: ["present"])
        #expect(outputs[0].shape == [1, 2, 2])
    }

    @Test
    func valuesFromSharedEnvironmentAccessAreAccepted() throws {
        let session = try makeCacheSession()
        let sharedEnvironment = try ONNXEnvironment.shared()
        #expect(sharedEnvironment === environment)
        let past = try ONNXValue(environment: sharedEnvironment, tensor: .float32(shape: [1, 1, 2], values: [0, 0]))
        let step = try ONNXValue(environment: environment, tensor: .float32(shape: [1, 1, 2], values: [0, 0]))
        let count = try ONNXValue(environment: environment, tensor: .int64(shape: [1], values: [0]))

        let outputs = try session.runValues(
            inputs: [(name: "past", value: past), (name: "step", value: step), (name: "count", value: count)],
            outputNames: ["present"]
        )
        #expect(try outputs[0].tensor() == .float32(shape: [1, 2, 2], values: [0, 0, 0, 0]))
    }

    private func makeCacheSession() throws -> ONNXSession {
        try ONNXSession(
            environment: environment,
            modelURL: try fixtureURL(named: "cache"),
            intraOpThreads: 1,
            cpuMemoryArenaEnabled: true
        )
    }
}

private func fixtureURL(named name: String) throws -> URL {
    try #require(Bundle.module.url(
        forResource: name,
        withExtension: "onnx",
        subdirectory: "Resources"
    ))
}

private func onnxErrorMessage(_ operation: () throws -> Void) -> String {
    do {
        try operation()
        Issue.record("ONNX Runtimeエラーが必要です。")
    } catch let error as ONNXRuntimeError {
        return error.message
    } catch {
        Issue.record("ONNX Runtimeエラーではありません: \(error)")
    }
    return ""
}
