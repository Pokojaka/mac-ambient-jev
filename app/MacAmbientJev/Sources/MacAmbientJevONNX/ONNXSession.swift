import Foundation
import CONNXRuntime

public struct ONNXRuntimeError: Error, LocalizedError, Sendable {
    public let message: String

    public var errorDescription: String? { message }
}

public enum ONNXTensor: Sendable, Equatable {
    case float32(shape: [Int64], values: [Float])
    case int64(shape: [Int64], values: [Int64])
}

private func checkedElementCount(_ shape: [Int64], context: String) throws -> Int {
    guard shape.allSatisfy({ $0 >= 0 }) else {
        throw ONNXRuntimeError(message: "\(context)の次元は0以上である必要があります。")
    }
    if shape.contains(0) {
        return 0
    }

    var count = 1
    for dimension in shape {
        let extent = Int(dimension)
        let (nextCount, overflow) = count.multipliedReportingOverflow(by: extent)
        guard !overflow else {
            throw ONNXRuntimeError(message: "\(context)の要素数がIntの範囲を超えています。")
        }
        count = nextCount
    }
    return count
}

private func checkedByteCount(elementCount: Int, elementStride: Int, context: String) throws -> Int {
    let (byteCount, overflow) = elementCount.multipliedReportingOverflow(by: elementStride)
    guard !overflow else {
        throw ONNXRuntimeError(message: "\(context)のバイト数がIntの範囲を超えています。")
    }
    return byteCount
}

private func validateTensor(
    shape: [Int64],
    valueCount: Int,
    elementStride: Int,
    context: String
) throws -> Int {
    let elementCount = try checkedElementCount(shape, context: "\(context)形状")
    guard elementCount == valueCount else {
        throw ONNXRuntimeError(message: "\(context)の要素数が形状と一致しません。")
    }
    return try checkedByteCount(elementCount: elementCount, elementStride: elementStride, context: context)
}

private extension ONNXTensor {
    func validateForRun() throws -> Int {
        switch self {
        case let .float32(shape, values):
            return try validateTensor(
                shape: shape,
                valueCount: values.count,
                elementStride: MemoryLayout<Float>.stride,
                context: "入力テンソル"
            )
        case let .int64(shape, values):
            return try validateTensor(
                shape: shape,
                valueCount: values.count,
                elementStride: MemoryLayout<Int64>.stride,
                context: "入力テンソル"
            )
        }
    }
}

private func checkStatus(
    _ status: OpaquePointer?,
    api: UnsafePointer<OrtApi>,
    context: String
) throws {
    guard let status else { return }
    defer { api.pointee.ReleaseStatus!(status) }
    guard let errorMessage = api.pointee.GetErrorMessage!(status) else {
        throw ONNXRuntimeError(message: "\(context): ONNX Runtimeからエラーメッセージが返されませんでした。")
    }
    let detail = String(cString: errorMessage)
    throw ONNXRuntimeError(message: "\(context): \(detail)")
}

/// ONNX Runtime documents `OrtEnv` as safe to share across threads, and this wrapper never mutates it.
public final class ONNXEnvironment: @unchecked Sendable {
    public static let runtimeVersion = "1.31.0"

    fileprivate let api: UnsafePointer<OrtApi>
    fileprivate let handle: OpaquePointer

    public init(loggingID: String) throws {
        guard !loggingID.isEmpty else {
            throw ONNXRuntimeError(message: "ONNX Runtimeのログ識別子を空にすることはできません。")
        }
        guard !loggingID.utf8.contains(0) else {
            throw ONNXRuntimeError(message: "ONNX Runtimeのログ識別子にNUL文字は使用できません。")
        }
        guard let apiBase = OrtGetApiBase() else {
            throw ONNXRuntimeError(message: "ONNX Runtime APIの取得に失敗しました。")
        }
        guard let versionPointer = apiBase.pointee.GetVersionString!() else {
            throw ONNXRuntimeError(message: "ONNX Runtimeのバージョン文字列を取得できませんでした。")
        }
        let loadedVersion = String(cString: versionPointer)
        guard loadedVersion == Self.runtimeVersion else {
            throw ONNXRuntimeError(
                message: "ONNX Runtimeのバージョンが一致しません。期待値 \(Self.runtimeVersion)、実際 \(loadedVersion)。"
            )
        }
        guard let runtimeAPI = apiBase.pointee.GetApi!(UInt32(ORT_API_VERSION)) else {
            throw ONNXRuntimeError(message: "要求したONNX Runtime APIバージョンを利用できません。")
        }

        var createdEnvironment: OpaquePointer?
        let environmentStatus = loggingID.withCString { loggingIDPointer in
            runtimeAPI.pointee.CreateEnv!(
                ORT_LOGGING_LEVEL_WARNING,
                loggingIDPointer,
                &createdEnvironment
            )
        }
        defer {
            if let createdEnvironment {
                runtimeAPI.pointee.ReleaseEnv!(createdEnvironment)
            }
        }
        try checkStatus(environmentStatus, api: runtimeAPI, context: "ONNX Runtime環境の作成に失敗しました")
        guard let environmentHandle = createdEnvironment else {
            throw ONNXRuntimeError(message: "ONNX Runtime環境が返されませんでした。")
        }

        try checkStatus(
            runtimeAPI.pointee.DisableTelemetryEvents!(environmentHandle),
            api: runtimeAPI,
            context: "ONNX Runtimeテレメトリーの無効化に失敗しました"
        )

        self.api = runtimeAPI
        self.handle = environmentHandle
        createdEnvironment = nil
    }

    deinit {
        api.pointee.ReleaseEnv!(handle)
    }
}

public final class ONNXSession {
    private let environment: ONNXEnvironment
    private let session: OpaquePointer

    public init(environment: ONNXEnvironment, modelURL: URL, intraOpThreads: Int) throws {
        guard intraOpThreads > 0, let nativeThreadCount = Int32(exactly: intraOpThreads) else {
            throw ONNXRuntimeError(message: "ONNX Runtimeの演算スレッド数はInt32の正数である必要があります。")
        }
        guard modelURL.isFileURL else {
            throw ONNXRuntimeError(message: "モデルURLはファイルURLである必要があります。")
        }

        let runtimeAPI = environment.api
        var options: OpaquePointer?
        let optionsStatus = runtimeAPI.pointee.CreateSessionOptions!(&options)
        defer {
            if let options {
                runtimeAPI.pointee.ReleaseSessionOptions!(options)
            }
        }
        try checkStatus(optionsStatus, api: runtimeAPI, context: "ONNX Runtimeセッション設定の作成に失敗しました")
        guard let options else {
            throw ONNXRuntimeError(message: "ONNX Runtimeセッション設定が返されませんでした。")
        }

        try checkStatus(
            runtimeAPI.pointee.SetIntraOpNumThreads!(options, nativeThreadCount),
            api: runtimeAPI,
            context: "ONNX Runtimeの演算スレッド数設定に失敗しました"
        )
        try checkStatus(
            runtimeAPI.pointee.SetInterOpNumThreads!(options, 1),
            api: runtimeAPI,
            context: "ONNX Runtimeの並列スレッド数設定に失敗しました"
        )

        var createdSession: OpaquePointer?
        defer {
            if let createdSession {
                runtimeAPI.pointee.ReleaseSession!(createdSession)
            }
        }
        try modelURL.withUnsafeFileSystemRepresentation { nativePath in
            guard let nativePath else {
                throw ONNXRuntimeError(message: "モデルURLのファイルシステムパスを取得できませんでした。")
            }
            #if os(Windows)
            let widePath = Array(String(cString: nativePath).utf16) + [0]
            let sessionStatus = widePath.withUnsafeBufferPointer { pathBuffer in
                runtimeAPI.pointee.CreateSession!(
                    environment.handle,
                    pathBuffer.baseAddress,
                    options,
                    &createdSession
                )
            }
            #else
            let sessionStatus = runtimeAPI.pointee.CreateSession!(
                environment.handle,
                nativePath,
                options,
                &createdSession
            )
            #endif
            try checkStatus(sessionStatus, api: runtimeAPI, context: "ONNXモデルのセッション作成に失敗しました")
        }
        guard let sessionHandle = createdSession else {
            throw ONNXRuntimeError(message: "ONNX Runtimeセッションが返されませんでした。")
        }

        self.environment = environment
        self.session = sessionHandle
        createdSession = nil
    }

    deinit {
        environment.api.pointee.ReleaseSession!(session)
    }

    public func run(
        inputs: [(name: String, tensor: ONNXTensor)],
        outputNames: [String]
    ) throws -> [ONNXTensor] {
        guard !outputNames.isEmpty else {
            throw ONNXRuntimeError(message: "出力名を1つ以上指定する必要があります。")
        }
        var inputNameSet = Set<String>()
        for (name, _) in inputs {
            guard !name.isEmpty else {
                throw ONNXRuntimeError(message: "入出力名を空にすることはできません。")
            }
            guard !name.utf8.contains(0) else {
                throw ONNXRuntimeError(message: "入出力名にNUL文字は使用できません。")
            }
            guard inputNameSet.insert(name).inserted else {
                throw ONNXRuntimeError(message: "入力名を重複させることはできません。")
            }
        }
        for name in outputNames {
            guard !name.isEmpty else {
                throw ONNXRuntimeError(message: "入出力名を空にすることはできません。")
            }
            guard !name.utf8.contains(0) else {
                throw ONNXRuntimeError(message: "入出力名にNUL文字は使用できません。")
            }
        }

        let inputByteCounts = try inputs.map { try $0.tensor.validateForRun() }
        let inputNameStorage = makeNameStorage(inputs.map(\.name))
        let outputNameStorage = makeNameStorage(outputNames)
        let api = environment.api

        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try checkStatus(
            api.pointee.GetAllocatorWithDefaultOptions!(&allocator),
            api: api,
            context: "ONNX Runtimeアロケーターの取得に失敗しました"
        )
        guard let allocator else {
            throw ONNXRuntimeError(message: "ONNX Runtimeアロケーターが返されませんでした。")
        }

        var inputValues = [OpaquePointer?](repeating: nil, count: inputs.count)
        defer {
            for inputValue in inputValues {
                if let inputValue {
                    api.pointee.ReleaseValue!(inputValue)
                }
            }
        }
        for index in inputs.indices {
            let tensor = inputs[index].tensor
            let inputValue: OpaquePointer
            switch tensor {
            case let .float32(shape, values):
                inputValue = try createInputValue(
                    shape: shape,
                    values: values,
                    byteCount: inputByteCounts[index],
                    elementType: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                    allocator: allocator,
                    api: api
                )
            case let .int64(shape, values):
                inputValue = try createInputValue(
                    shape: shape,
                    values: values,
                    byteCount: inputByteCounts[index],
                    elementType: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64,
                    allocator: allocator,
                    api: api
                )
            }
            inputValues[index] = inputValue
        }

        var outputValues = [OpaquePointer?](repeating: nil, count: outputNames.count)
        defer {
            for outputValue in outputValues {
                if let outputValue {
                    api.pointee.ReleaseValue!(outputValue)
                }
            }
        }
        let runStatus = try inputNameStorage.bytes.withUnsafeBufferPointer { inputNameBuffer in
            try outputNameStorage.bytes.withUnsafeBufferPointer { outputNameBuffer in
                guard inputs.isEmpty || inputNameBuffer.baseAddress != nil else {
                    throw ONNXRuntimeError(message: "入力名の領域を取得できませんでした。")
                }
                guard let outputNameBase = outputNameBuffer.baseAddress else {
                    throw ONNXRuntimeError(message: "出力名の領域を取得できませんでした。")
                }

                var inputNamePointers: [UnsafePointer<CChar>?] = []
                if let inputNameBase = inputNameBuffer.baseAddress {
                    for offset in inputNameStorage.offsets {
                        inputNamePointers.append(inputNameBase.advanced(by: offset))
                    }
                }
                let outputNamePointers = outputNameStorage.offsets.map {
                    Optional(outputNameBase.advanced(by: $0))
                }

                return inputNamePointers.withUnsafeBufferPointer { inputNamePointerBuffer in
                    inputValues.withUnsafeBufferPointer { inputValueBuffer in
                        outputNamePointers.withUnsafeBufferPointer { outputNamePointerBuffer in
                            outputValues.withUnsafeMutableBufferPointer { outputValueBuffer in
                                api.pointee.Run!(
                                    session,
                                    nil,
                                    inputNamePointerBuffer.baseAddress,
                                    inputValueBuffer.baseAddress,
                                    inputs.count,
                                    outputNamePointerBuffer.baseAddress,
                                    outputNames.count,
                                    outputValueBuffer.baseAddress
                                )
                            }
                        }
                    }
                }
            }
        }
        try checkStatus(runStatus, api: api, context: "ONNXモデルの実行に失敗しました")

        var results: [ONNXTensor] = []
        results.reserveCapacity(outputNames.count)
        for index in outputNames.indices {
            guard let outputValue = outputValues[index] else {
                throw ONNXRuntimeError(message: "ONNX Runtime出力が返されませんでした: \(outputNames[index])")
            }
            results.append(try readOutputValue(outputValue, api: api))
        }
        return results
    }
}

private struct NameStorage {
    let bytes: [CChar]
    let offsets: [Int]
}

private func makeNameStorage(_ names: [String]) -> NameStorage {
    var bytes: [CChar] = []
    var offsets: [Int] = []
    for name in names {
        offsets.append(bytes.count)
        bytes.append(contentsOf: name.utf8CString)
    }
    return NameStorage(bytes: bytes, offsets: offsets)
}

private func createInputValue<Element>(
    shape: [Int64],
    values: [Element],
    byteCount: Int,
    elementType: ONNXTensorElementDataType,
    allocator: UnsafeMutablePointer<OrtAllocator>,
    api: UnsafePointer<OrtApi>
) throws -> OpaquePointer {
    var createdValue: OpaquePointer?
    let createStatus = shape.withUnsafeBufferPointer { dimensions in
        api.pointee.CreateTensorAsOrtValue!(
            allocator,
            dimensions.baseAddress,
            dimensions.count,
            elementType,
            &createdValue
        )
    }
    defer {
        if let createdValue {
            api.pointee.ReleaseValue!(createdValue)
        }
    }
    try checkStatus(createStatus, api: api, context: "入力テンソルの作成に失敗しました")
    guard let inputValueHandle = createdValue else {
        throw ONNXRuntimeError(message: "入力テンソルが返されませんでした。")
    }

    try writeInputValues(values, byteCount: byteCount, to: inputValueHandle, api: api)
    let inputValue = inputValueHandle
    createdValue = nil
    return inputValue
}

private func writeInputValues<Element>(
    _ values: [Element],
    byteCount: Int,
    to inputValue: OpaquePointer,
    api: UnsafePointer<OrtApi>
) throws {
    var inputData: UnsafeMutableRawPointer?
    try checkStatus(
        api.pointee.GetTensorMutableData!(inputValue, &inputData),
        api: api,
        context: "入力テンソル領域の取得に失敗しました"
    )
    guard !values.isEmpty else { return }
    guard let inputData else {
        throw ONNXRuntimeError(message: "入力テンソル領域を取得できませんでした。")
    }
    try values.withUnsafeBufferPointer { sourceBuffer in
        guard let source = sourceBuffer.baseAddress else {
            throw ONNXRuntimeError(message: "入力テンソル領域を取得できませんでした。")
        }
        inputData.copyMemory(from: UnsafeRawPointer(source), byteCount: byteCount)
    }
}

private func readOutputValue(_ outputValue: OpaquePointer, api: UnsafePointer<OrtApi>) throws -> ONNXTensor {
    var isTensor: Int32 = 0
    try checkStatus(
        api.pointee.IsTensor!(outputValue, &isTensor),
        api: api,
        context: "ONNX Runtime出力形式の確認に失敗しました"
    )
    guard isTensor != 0 else {
        throw ONNXRuntimeError(message: "ONNX Runtime出力はテンソルではありません。")
    }

    var typeAndShape: OpaquePointer?
    let typeAndShapeStatus = api.pointee.GetTensorTypeAndShape!(outputValue, &typeAndShape)
    defer {
        if let typeAndShape {
            api.pointee.ReleaseTensorTypeAndShapeInfo!(typeAndShape)
        }
    }
    try checkStatus(typeAndShapeStatus, api: api, context: "出力テンソル情報の取得に失敗しました")
    guard let typeAndShape else {
        throw ONNXRuntimeError(message: "出力テンソル情報が返されませんでした。")
    }

    var elementType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
    try checkStatus(
        api.pointee.GetTensorElementType!(typeAndShape, &elementType),
        api: api,
        context: "出力テンソル型の取得に失敗しました"
    )
    guard elementType == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
            || elementType == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 else {
        throw ONNXRuntimeError(
            message: "サポートされない出力テンソル要素型です: \(Int32(elementType.rawValue))。"
        )
    }

    var dimensionCount = 0
    try checkStatus(
        api.pointee.GetDimensionsCount!(typeAndShape, &dimensionCount),
        api: api,
        context: "出力テンソル次元数の取得に失敗しました"
    )
    var shape = [Int64](repeating: 0, count: dimensionCount)
    let dimensionsStatus = shape.withUnsafeMutableBufferPointer { dimensions in
        api.pointee.GetDimensions!(typeAndShape, dimensions.baseAddress, dimensions.count)
    }
    try checkStatus(dimensionsStatus, api: api, context: "出力テンソル形状の取得に失敗しました")
    let elementCount = try checkedElementCount(shape, context: "出力テンソル形状")

    var outputData: UnsafeMutableRawPointer?
    try checkStatus(
        api.pointee.GetTensorMutableData!(outputValue, &outputData),
        api: api,
        context: "出力テンソル領域の取得に失敗しました"
    )

    if elementType == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT {
        let values = try copyOutputValues(outputData, count: elementCount, as: Float.self)
        return .float32(shape: shape, values: values)
    }

    let values = try copyOutputValues(outputData, count: elementCount, as: Int64.self)
    return .int64(shape: shape, values: values)
}

private func copyOutputValues<Element: ExpressibleByIntegerLiteral>(
    _ outputData: UnsafeMutableRawPointer?,
    count: Int,
    as type: Element.Type
) throws -> [Element] {
    var values = [Element](repeating: 0, count: count)
    guard count > 0 else { return values }
    guard let outputData else {
        throw ONNXRuntimeError(message: "出力テンソル領域を取得できませんでした。")
    }
    let source = outputData.assumingMemoryBound(to: Element.self)
    try values.withUnsafeMutableBufferPointer { destination in
        guard let destinationBase = destination.baseAddress else {
            throw ONNXRuntimeError(message: "出力テンソル領域を取得できませんでした。")
        }
        destinationBase.update(from: source, count: count)
    }
    return values
}
