import Foundation
import CONNXRuntime

func checkedElementCount(_ shape: [Int64], context: String) throws -> Int {
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

private enum ONNXValueElementType {
    case float32
    case int64
}

/// An owning handle to a float32 or int64 `OrtValue` that stays inside ONNX Runtime.
///
/// Create one from an `ONNXTensor` (one copy in), or receive one from `ONNXSession.runValues`.
/// Pass it as an input of a later run to reuse a model output without copying it through Swift.
/// A value is never mutated after creation, and ONNX Runtime only reads input values, so the
/// handle can move between threads. Use a value in one session run at a time.
public final class ONNXValue: @unchecked Sendable {
    public let shape: [Int64]

    let environment: ONNXEnvironment
    let handle: OpaquePointer
    private let elementType: ONNXValueElementType

    public init(environment: ONNXEnvironment, tensor: ONNXTensor) throws {
        let api = environment.api
        let byteCount: Int
        let elementType: ONNXValueElementType
        let shape: [Int64]
        switch tensor {
        case let .float32(tensorShape, values):
            byteCount = try validateTensor(
                shape: tensorShape,
                valueCount: values.count,
                elementStride: MemoryLayout<Float>.stride,
                context: "入力テンソル"
            )
            elementType = .float32
            shape = tensorShape
        case let .int64(tensorShape, values):
            byteCount = try validateTensor(
                shape: tensorShape,
                valueCount: values.count,
                elementStride: MemoryLayout<Int64>.stride,
                context: "入力テンソル"
            )
            elementType = .int64
            shape = tensorShape
        }

        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try checkStatus(
            api.pointee.GetAllocatorWithDefaultOptions!(&allocator),
            api: api,
            context: "ONNX Runtimeアロケーターの取得に失敗しました"
        )
        guard let allocator else {
            throw ONNXRuntimeError(message: "ONNX Runtimeアロケーターが返されませんでした。")
        }

        var createdValue: OpaquePointer?
        let createStatus = shape.withUnsafeBufferPointer { dimensions in
            api.pointee.CreateTensorAsOrtValue!(
                allocator,
                dimensions.baseAddress,
                dimensions.count,
                elementType == .float32
                    ? ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
                    : ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64,
                &createdValue
            )
        }
        defer {
            if let createdValue {
                api.pointee.ReleaseValue!(createdValue)
            }
        }
        try checkStatus(createStatus, api: api, context: "入力テンソルの作成に失敗しました")
        guard let valueHandle = createdValue else {
            throw ONNXRuntimeError(message: "入力テンソルが返されませんでした。")
        }

        switch tensor {
        case let .float32(_, values):
            try writeInputValues(values, byteCount: byteCount, to: valueHandle, api: api)
        case let .int64(_, values):
            try writeInputValues(values, byteCount: byteCount, to: valueHandle, api: api)
        }

        self.environment = environment
        self.handle = valueHandle
        self.elementType = elementType
        self.shape = shape
        createdValue = nil
    }

    /// Takes ownership of `handle` only when this initializer returns; on a throw the caller still owns it.
    init(adopting handle: OpaquePointer, environment: ONNXEnvironment) throws {
        let api = environment.api
        var isTensor: Int32 = 0
        try checkStatus(
            api.pointee.IsTensor!(handle, &isTensor),
            api: api,
            context: "ONNX Runtime出力形式の確認に失敗しました"
        )
        guard isTensor != 0 else {
            throw ONNXRuntimeError(message: "ONNX Runtime出力はテンソルではありません。")
        }

        var typeAndShape: OpaquePointer?
        let typeAndShapeStatus = api.pointee.GetTensorTypeAndShape!(handle, &typeAndShape)
        defer {
            if let typeAndShape {
                api.pointee.ReleaseTensorTypeAndShapeInfo!(typeAndShape)
            }
        }
        try checkStatus(typeAndShapeStatus, api: api, context: "出力テンソル情報の取得に失敗しました")
        guard let typeAndShape else {
            throw ONNXRuntimeError(message: "出力テンソル情報が返されませんでした。")
        }

        var nativeElementType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
        try checkStatus(
            api.pointee.GetTensorElementType!(typeAndShape, &nativeElementType),
            api: api,
            context: "出力テンソル型の取得に失敗しました"
        )
        let elementType: ONNXValueElementType
        switch nativeElementType {
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:
            elementType = .float32
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64:
            elementType = .int64
        default:
            throw ONNXRuntimeError(
                message: "サポートされない出力テンソル要素型です: \(Int32(nativeElementType.rawValue))。"
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
        _ = try checkedElementCount(shape, context: "出力テンソル形状")

        self.environment = environment
        self.handle = handle
        self.elementType = elementType
        self.shape = shape
    }

    deinit {
        environment.api.pointee.ReleaseValue!(handle)
    }

    /// Copies the whole tensor out of ONNX Runtime.
    public func tensor() throws -> ONNXTensor {
        let elementCount = try checkedElementCount(shape, context: "出力テンソル形状")
        let data = try tensorData()
        switch elementType {
        case .float32:
            return .float32(shape: shape, values: try copyOutputValues(data, count: elementCount, as: Float.self))
        case .int64:
            return .int64(shape: shape, values: try copyOutputValues(data, count: elementCount, as: Int64.self))
        }
    }

    /// Copies only the last row of a float32 tensor shaped `[1, S, V]` (`S >= 1`) and returns its `V` values.
    public func float32LastRow() throws -> [Float] {
        guard elementType == .float32 else {
            throw ONNXRuntimeError(message: "最終行の読み出しにはfloat32テンソルが必要です。")
        }
        guard shape.count == 3, shape[0] == 1, shape[1] >= 1 else {
            throw ONNXRuntimeError(
                message: "最終行の読み出しには形状[1, S, V]（S >= 1）が必要です。実際の形状: \(shape)。"
            )
        }
        _ = try checkedElementCount(shape, context: "出力テンソル形状")
        let rowLength = Int(shape[2])
        guard rowLength > 0 else { return [] }

        let lastRowOffset = (Int(shape[1]) - 1) * rowLength * MemoryLayout<Float>.stride
        return try copyOutputValues(try tensorData().map { $0 + lastRowOffset }, count: rowLength, as: Float.self)
    }

    private func tensorData() throws -> UnsafeMutableRawPointer? {
        var data: UnsafeMutableRawPointer?
        try checkStatus(
            environment.api.pointee.GetTensorMutableData!(handle, &data),
            api: environment.api,
            context: "出力テンソル領域の取得に失敗しました"
        )
        return data
    }
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
