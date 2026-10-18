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

/// ONNX Runtime documents `OrtEnv` as safe to share across threads, and this wrapper never mutates it.
public final class ONNXEnvironment: @unchecked Sendable {
    public static let runtimeVersion = "1.31.0"

    let api: UnsafePointer<OrtApi>
    let handle: OpaquePointer

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
    /// come from this session's environment. Input values are only read, so an output value can be
    /// passed straight back as the next run's input.
    public func runValues(
        inputs: [(name: String, value: ONNXValue)],
        outputNames: [String]
    ) throws -> [ONNXValue] {
        guard !outputNames.isEmpty else {
            throw ONNXRuntimeError(message: "出力名を1つ以上指定する必要があります。")
        }
        var inputNameSet = Set<String>()
        for (name, value) in inputs {
            guard !name.isEmpty else {
                throw ONNXRuntimeError(message: "入出力名を空にすることはできません。")
            }
            guard !name.utf8.contains(0) else {
                throw ONNXRuntimeError(message: "入出力名にNUL文字は使用できません。")
            }
            guard inputNameSet.insert(name).inserted else {
                throw ONNXRuntimeError(message: "入力名を重複させることはできません。")
            }
            guard value.environment === environment else {
                throw ONNXRuntimeError(message: "入力値 \(name) は別のONNX Runtime環境で作成されています。")
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
            results.append(try ONNXValue(adopting: outputValue, environment: environment))
            outputValues[index] = nil
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
