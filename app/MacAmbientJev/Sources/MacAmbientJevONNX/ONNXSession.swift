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

public enum ONNXTensorElementType: Sendable, Equatable {
    case float32
    case int64
}

public struct ONNXTensorMetadata: Sendable, Equatable {
    public let name: String
    public let elementType: ONNXTensorElementType
    public let shape: [Int64]

    public init(name: String, elementType: ONNXTensorElementType, shape: [Int64]) {
        self.name = name
        self.elementType = elementType
        self.shape = shape
    }
}

func checkStatus(
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

/// The shared environment lives for the process lifetime; its initialization result, including failure, is cached.
/// Provider registration mutations on it are serialized by `providers`.
public final class ONNXEnvironment: @unchecked Sendable {
    public static let runtimeVersion = "1.31.0"

    private static let sharedResult: Result<ONNXEnvironment, Error> = Result { try ONNXEnvironment() }

    let api: UnsafePointer<OrtApi>
    let handle: OpaquePointer
    public let providers: ONNXProviderRegistry

    /// Returns the process-wide ONNX Runtime environment.
    /// Initialization is attempted once; any failure is cached for the process lifetime.
    public static func shared() throws -> ONNXEnvironment {
        try sharedResult.get()
    }

    private init() throws {
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
        let environmentStatus = "MacAmbientJev".withCString { loggingIDPointer in
            runtimeAPI.pointee.CreateEnv!(
                ORT_LOGGING_LEVEL_WARNING,
                loggingIDPointer,
                &createdEnvironment
            )
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
        self.providers = ONNXProviderRegistry(api: runtimeAPI, environment: environmentHandle)
    }
}

public final class ONNXSession {
    public static let interOpThreads: Int32 = 1

    private let environment: ONNXEnvironment
    private let session: OpaquePointer
    private let providerLease: ONNXProviderLease?

    /// Explicitly selects ONNX Runtime's CPU allocator arena without changing memory patterns or other session tuning.
    public convenience init(
        environment: ONNXEnvironment,
        modelURL: URL,
        intraOpThreads: Int,
        cpuMemoryArenaEnabled: Bool
    ) throws {
        try self.init(
            environment: environment, modelURL: modelURL, intraOpThreads: intraOpThreads,
            cpuMemoryArenaEnabled: cpuMemoryArenaEnabled, providerDevice: nil)
    }

    public convenience init(
        environment: ONNXEnvironment,
        modelURL: URL,
        intraOpThreads: Int,
        cpuMemoryArenaEnabled: Bool,
        device: ONNXProviderDevice
    ) throws {
        try self.init(
            environment: environment, modelURL: modelURL, intraOpThreads: intraOpThreads,
            cpuMemoryArenaEnabled: cpuMemoryArenaEnabled, providerDevice: device)
    }

    private init(
        environment: ONNXEnvironment,
        modelURL: URL,
        intraOpThreads: Int,
        cpuMemoryArenaEnabled: Bool,
        providerDevice: ONNXProviderDevice?
    ) throws {
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
            runtimeAPI.pointee.SetInterOpNumThreads!(options, Self.interOpThreads),
            api: runtimeAPI,
            context: "ONNX Runtimeの並列スレッド数設定に失敗しました"
        )
        let cpuMemoryArenaStatus = cpuMemoryArenaEnabled
            ? runtimeAPI.pointee.EnableCpuMemArena!(options)
            : runtimeAPI.pointee.DisableCpuMemArena!(options)
        try checkStatus(
            cpuMemoryArenaStatus,
            api: runtimeAPI,
            context: "ONNX RuntimeのCPUメモリアリーナ設定に失敗しました"
        )
        if let providerDevice {
            self.providerLease = try environment.providers.acquire(device: providerDevice, options: options)
        } else {
            self.providerLease = nil
        }

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

    public func inputMetadata() throws -> [ONNXTensorMetadata] {
        try metadata(direction: .input)
    }

    public func outputMetadata() throws -> [ONNXTensorMetadata] {
        try metadata(direction: .output)
    }

    private func metadata(direction: ONNXMetadataDirection) throws -> [ONNXTensorMetadata] {
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

        var count = 0
        let countStatus: OpaquePointer?
        switch direction {
        case .input:
            countStatus = api.pointee.SessionGetInputCount!(session, &count)
        case .output:
            countStatus = api.pointee.SessionGetOutputCount!(session, &count)
        }
        try checkStatus(
            countStatus,
            api: api,
            context: "ONNX Runtimeの\(direction.label)数の取得に失敗しました"
        )

        var metadata: [ONNXTensorMetadata] = []
        metadata.reserveCapacity(count)
        for index in 0..<count {
            var allocatedName: UnsafeMutablePointer<CChar>?
            let nameStatus: OpaquePointer?
            switch direction {
            case .input:
                nameStatus = api.pointee.SessionGetInputName!(session, index, allocator, &allocatedName)
            case .output:
                nameStatus = api.pointee.SessionGetOutputName!(session, index, allocator, &allocatedName)
            }
            let name: String = try {
                defer {
                    if let allocatedName {
                        allocator.pointee.Free!(allocator, allocatedName)
                    }
                }
                try checkStatus(
                    nameStatus,
                    api: api,
                    context: "ONNX Runtimeの\(direction.label)名の取得に失敗しました"
                )
                guard let allocatedName else {
                    throw ONNXRuntimeError(
                        message: "ONNX Runtimeの\(direction.label)名が返されませんでした。"
                    )
                }
                return String(cString: allocatedName)
            }()

            var typeInfo: OpaquePointer?
            let typeInfoStatus: OpaquePointer?
            switch direction {
            case .input:
                typeInfoStatus = api.pointee.SessionGetInputTypeInfo!(session, index, &typeInfo)
            case .output:
                typeInfoStatus = api.pointee.SessionGetOutputTypeInfo!(session, index, &typeInfo)
            }
            defer {
                if let typeInfo {
                    api.pointee.ReleaseTypeInfo!(typeInfo)
                }
            }
            try checkStatus(
                typeInfoStatus,
                api: api,
                context: "ONNX Runtimeの\(direction.label) \(name) の型情報取得に失敗しました"
            )
            guard let typeInfo else {
                throw ONNXRuntimeError(
                    message: "ONNX Runtimeの\(direction.label) \(name) の型情報が返されませんでした。"
                )
            }

            var tensorInfo: OpaquePointer?
            try checkStatus(
                api.pointee.CastTypeInfoToTensorInfo!(typeInfo, &tensorInfo),
                api: api,
                context: "ONNX Runtimeの\(direction.label) \(name) のテンソル型情報取得に失敗しました"
            )
            guard let tensorInfo else {
                throw ONNXRuntimeError(
                    message: "ONNX Runtimeの\(direction.label) \(name) はテンソルではありません。"
                )
            }

            var nativeElementType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
            try checkStatus(
                api.pointee.GetTensorElementType!(tensorInfo, &nativeElementType),
                api: api,
                context: "ONNX Runtimeの\(direction.label) \(name) のテンソル要素型取得に失敗しました"
            )
            let elementType: ONNXTensorElementType
            switch nativeElementType {
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:
                elementType = .float32
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64:
                elementType = .int64
            default:
                throw ONNXRuntimeError(
                    message: "ONNX Runtimeの\(direction.label) \(name) はサポートされないテンソル要素型です: \(Int32(nativeElementType.rawValue))。"
                )
            }

            var dimensionCount = 0
            try checkStatus(
                api.pointee.GetDimensionsCount!(tensorInfo, &dimensionCount),
                api: api,
                context: "ONNX Runtimeの\(direction.label) \(name) の次元数取得に失敗しました"
            )
            var shape = [Int64](repeating: 0, count: dimensionCount)
            let dimensionsStatus = shape.withUnsafeMutableBufferPointer { dimensions in
                api.pointee.GetDimensions!(tensorInfo, dimensions.baseAddress, dimensions.count)
            }
            try checkStatus(
                dimensionsStatus,
                api: api,
                context: "ONNX Runtimeの\(direction.label) \(name) の形状取得に失敗しました"
            )
            metadata.append(ONNXTensorMetadata(name: name, elementType: elementType, shape: shape))
        }
        return metadata
    }

    /// Runs the model on copies of `inputs` and copies every requested output back.
    /// Use `runValues` to keep large intermediate tensors inside ONNX Runtime.
    public func run(
        inputs: [(name: String, tensor: ONNXTensor)],
        outputNames: [String]
    ) throws -> [ONNXTensor] {
        let valueInputs = try inputs.map {
            (name: $0.name, value: try ONNXValue(environment: environment, tensor: $0.tensor))
        }
        return try runValues(inputs: valueInputs, outputNames: outputNames).map { try $0.tensor() }
    }

    /// Runs the model on `inputs` without copying tensor data in or out. Every input value must
    /// come from the shared process environment. Input values are only read, so an output value can
    /// be passed straight back as the next run's input.
    public func runValues(
        inputs: [(name: String, value: ONNXValue)],
        outputNames: [String]
    ) throws -> [ONNXValue] {
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

        let inputNameStorage = makeNameStorage(inputs.map(\.name))
        let outputNameStorage = makeNameStorage(outputNames)
        let api = environment.api
        let inputValues: [OpaquePointer?] = inputs.map { $0.value.handle }

        var outputValues = [OpaquePointer?](repeating: nil, count: outputNames.count)
        defer {
            for outputValue in outputValues {
                if let outputValue {
                    api.pointee.ReleaseValue!(outputValue)
                }
            }
        }
        let runStatus = try withExtendedLifetime(inputs.map(\.value)) {
            try inputNameStorage.bytes.withUnsafeBufferPointer { inputNameBuffer in
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
        }
        try checkStatus(runStatus, api: api, context: "ONNXモデルの実行に失敗しました")

        var results: [ONNXValue] = []
        results.reserveCapacity(outputNames.count)
        for index in outputNames.indices {
            guard let outputValue = outputValues[index] else {
                throw ONNXRuntimeError(message: "ONNX Runtime出力が返されませんでした: \(outputNames[index])")
            }
            let value = try ONNXValue(adopting: outputValue, environment: environment)
            value.providerLease = providerLease
            results.append(value)
            outputValues[index] = nil
        }
        return results
    }
}

private enum ONNXMetadataDirection {
    case input
    case output

    var label: String {
        switch self {
        case .input: "入力"
        case .output: "出力"
        }
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
