import Foundation
import Testing
import MacAmbientJevONNX

struct ONNXSessionTests {
    private let environment: ONNXEnvironment

    init() throws {
        environment = try ONNXEnvironment.shared()
    }

    @Test
    func namedInputsAndRequestedOutputsPreserveExactValuesAcrossRuns() throws {
        let session = try makeSession(modelURL: fixtureURL(named: "affine"), intraOpThreads: 1)
        let modelOrderedInputs = fixtureInputs(sampleRate: 1)
        let inputs = [modelOrderedInputs[2], modelOrderedInputs[1], modelOrderedInputs[0]]

        let firstOutput = try session.run(
            inputs: inputs,
            outputNames: ["sr_out", "y", "ids_out"]
        )
        #expect(firstOutput == [
            .int64(shape: [], values: [1]),
            .float32(shape: [1, 4], values: [-3, 0, 1, 7.5]),
            .int64(shape: [1, 3], values: [9_007_199_254_740_994, -4, 43]),
        ])

        let secondOutput = try session.run(
            inputs: fixtureInputs(sampleRate: 2),
            outputNames: ["sr_out", "y", "ids_out"]
        )
        #expect(secondOutput == [
            .int64(shape: [], values: [2]),
            .float32(shape: [1, 4], values: [-2, 1, 2, 8.5]),
            .int64(shape: [1, 3], values: [9_007_199_254_740_994, -4, 43]),
        ])
    }

    @Test(arguments: [true, false])
    func cpuMemoryArenaModesPreserveAffineSessionBehavior(cpuMemoryArenaEnabled: Bool) throws {
        let session = try ONNXSession(
            environment: environment,
            modelURL: fixtureURL(named: "affine"),
            intraOpThreads: 1,
            cpuMemoryArenaEnabled: cpuMemoryArenaEnabled
        )
        #expect(try session.inputMetadata() == [
            ONNXTensorMetadata(name: "x", elementType: .float32, shape: [1, 4]),
            ONNXTensorMetadata(name: "ids", elementType: .int64, shape: [1, 3]),
            ONNXTensorMetadata(name: "sr", elementType: .int64, shape: []),
        ])

        let output = try session.run(inputs: fixtureInputs(sampleRate: 1), outputNames: ["y"])
        #expect(output == [.float32(shape: [1, 4], values: [-3, 0, 1, 7.5])])
    }

    @Test
    func inputAndOutputMetadataPreserveGraphOrderTypesAndShapes() throws {
        let affineSession = try makeSession(modelURL: fixtureURL(named: "affine"), intraOpThreads: 1)
        #expect(try affineSession.inputMetadata() == [
            ONNXTensorMetadata(name: "x", elementType: .float32, shape: [1, 4]),
            ONNXTensorMetadata(name: "ids", elementType: .int64, shape: [1, 3]),
            ONNXTensorMetadata(name: "sr", elementType: .int64, shape: []),
        ])

        let unsupportedOutputMessage = onnxErrorMessage {
            _ = try affineSession.outputMetadata()
        }
        #expect(unsupportedOutputMessage.contains("出力"))
        #expect(unsupportedOutputMessage.contains("positive"))
        #expect(unsupportedOutputMessage.contains("9"))

        let cacheSession = try makeSession(modelURL: fixtureURL(named: "cache"), intraOpThreads: 1)
        #expect(try cacheSession.inputMetadata() == [
            ONNXTensorMetadata(name: "past", elementType: .float32, shape: [1, -1, 2]),
            ONNXTensorMetadata(name: "step", elementType: .float32, shape: [1, 1, 2]),
            ONNXTensorMetadata(name: "count", elementType: .int64, shape: [1]),
        ])
        #expect(try cacheSession.outputMetadata() == [
            ONNXTensorMetadata(name: "present", elementType: .float32, shape: [1, -1, 2]),
            ONNXTensorMetadata(name: "count_out", elementType: .int64, shape: [1]),
        ])
    }

    @Test
    func sharedEnvironmentSurvivesSessionRelease() throws {
        let pair = try makeSessionPair(modelURL: fixtureURL(named: "affine"))
        #expect(pair.environment.value === (try ONNXEnvironment.shared()))

        var retainedSession: ONNXSession? = pair.second
        pair.first = nil
        #expect(pair.environment.value === (try ONNXEnvironment.shared()))

        let output = try #require(retainedSession).run(
            inputs: fixtureInputs(sampleRate: 1),
            outputNames: ["y"]
        )
        #expect(output == [.float32(shape: [1, 4], values: [-3, 0, 1, 7.5])])

        retainedSession = nil
        pair.second = nil
        #expect(pair.environment.value === (try ONNXEnvironment.shared()))
    }

    @Test
    func wrongInputShapeReportsJapaneseRuntimeContextAndORTDimensions() throws {
        let session = try makeSession(modelURL: fixtureURL(named: "affine"), intraOpThreads: 1)
        let validInputs = fixtureInputs(sampleRate: 1)
        let wrongShape: ONNXTensor = .float32(
            shape: [2, 2],
            values: [-2, -0.5, 0, 3.25]
        )
        var inputs = validInputs
        inputs[0] = (name: "x", tensor: wrongShape)

        let message = onnxErrorMessage {
            _ = try session.run(inputs: inputs, outputNames: ["y"])
        }
        #expect(message.hasPrefix("ONNXモデルの実行に失敗しました"))
        #expect(message.localizedCaseInsensitiveContains("dimensions"))
    }

    @Test
    func missingModelReportsJapaneseSessionContextAndORTFailure() throws {
        let missingModelURL = FileManager.default.temporaryDirectory
            .appending(path: "存在しない-\(UUID().uuidString).onnx")

        let message = onnxErrorMessage {
            _ = try makeSession(modelURL: missingModelURL, intraOpThreads: 1)
        }
        #expect(message.contains("ONNXモデルのセッション作成に失敗しました"))
        #expect(message.localizedCaseInsensitiveContains("failed"))
    }

    @Test
    func unicodeModelDirectoryAndFilenameLoadAndRun() throws {
        let sourceURL = try fixtureURL(named: "affine")
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appending(path: "onnx-日本語-😀-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            do {
                try fileManager.removeItem(at: temporaryDirectory)
            } catch {
                Issue.record("一時ディレクトリを削除できませんでした: \(error)")
            }
        }

        let modelURL = temporaryDirectory.appending(path: "変換モデル-😀-\(UUID().uuidString).onnx")
        try fileManager.copyItem(at: sourceURL, to: modelURL)
        let session = try makeSession(modelURL: modelURL, intraOpThreads: 1)
        let outputs = try session.run(
            inputs: fixtureInputs(sampleRate: 1),
            outputNames: ["y", "ids_out", "sr_out"]
        )
        #expect(outputs == [
            .float32(shape: [1, 4], values: [-3, 0, 1, 7.5]),
            .int64(shape: [1, 3], values: [9_007_199_254_740_994, -4, 43]),
            .int64(shape: [], values: [1]),
        ])
    }

    @Test
    func unsupportedOutputTypeFailsAndSessionRemainsReusable() throws {
        let session = try makeSession(modelURL: fixtureURL(named: "affine"), intraOpThreads: 1)
        let message = onnxErrorMessage {
            _ = try session.run(
                inputs: fixtureInputs(sampleRate: 1),
                outputNames: ["y", "positive"]
            )
        }
        #expect(message == "サポートされない出力テンソル要素型です: 9。")

        let outputs = try session.run(
            inputs: fixtureInputs(sampleRate: 1),
            outputNames: ["y", "ids_out", "sr_out"]
        )
        #expect(outputs == [
            .float32(shape: [1, 4], values: [-3, 0, 1, 7.5]),
            .int64(shape: [1, 3], values: [9_007_199_254_740_994, -4, 43]),
            .int64(shape: [], values: [1]),
        ])
    }

    @Test
    func zeroExtentInputsReachRuntimeForBothElementTypes() throws {
        let session = try makeSession(modelURL: fixtureURL(named: "affine"), intraOpThreads: 1)
        let validInputs = fixtureInputs(sampleRate: 1)

        var floatZeroExtentInputs = validInputs
        floatZeroExtentInputs[0] = (name: "x", tensor: .float32(shape: [0, 4], values: []))
        let floatMessage = onnxErrorMessage {
            _ = try session.run(inputs: floatZeroExtentInputs, outputNames: ["y"])
        }
        #expect(floatMessage.hasPrefix("ONNXモデルの実行に失敗しました"))

        var int64ZeroExtentInputs = validInputs
        int64ZeroExtentInputs[1] = (name: "ids", tensor: .int64(shape: [0, 3], values: []))
        let int64Message = onnxErrorMessage {
            _ = try session.run(inputs: int64ZeroExtentInputs, outputNames: ["y"])
        }
        #expect(int64Message.hasPrefix("ONNXモデルの実行に失敗しました"))
    }

    @Test
    func rawEnumCasesAreValidatedBeforeRuntimeInputCreation() throws {
        let session = try makeSession(modelURL: fixtureURL(named: "affine"), intraOpThreads: 1)
        let validInputs = fixtureInputs(sampleRate: 1)
        let invalidFloatShape: ONNXTensor = .float32(shape: [-1], values: [])
        var invalidFloatShapeInputs = validInputs
        invalidFloatShapeInputs[0] = (name: "x", tensor: invalidFloatShape)
        #expect(throws: ONNXRuntimeError.self) {
            _ = try session.run(inputs: invalidFloatShapeInputs, outputNames: ["y"])
        }

        let overflowingFloatShape: ONNXTensor = .float32(shape: [Int64.max, 2], values: [])
        var overflowingFloatShapeInputs = validInputs
        overflowingFloatShapeInputs[0] = (name: "x", tensor: overflowingFloatShape)
        #expect(throws: ONNXRuntimeError.self) {
            _ = try session.run(inputs: overflowingFloatShapeInputs, outputNames: ["y"])
        }

        let invalidFloatCount: ONNXTensor = .float32(shape: [1, 4], values: [1])
        var invalidFloatCountInputs = validInputs
        invalidFloatCountInputs[0] = (name: "x", tensor: invalidFloatCount)
        #expect(throws: ONNXRuntimeError.self) {
            _ = try session.run(inputs: invalidFloatCountInputs, outputNames: ["y"])
        }

        let invalidInt64Shape: ONNXTensor = .int64(shape: [-1], values: [])
        var invalidInt64ShapeInputs = validInputs
        invalidInt64ShapeInputs[1] = (name: "ids", tensor: invalidInt64Shape)
        #expect(throws: ONNXRuntimeError.self) {
            _ = try session.run(inputs: invalidInt64ShapeInputs, outputNames: ["y"])
        }

        let overflowingInt64Shape: ONNXTensor = .int64(shape: [Int64.max, 2], values: [])
        var overflowingInt64ShapeInputs = validInputs
        overflowingInt64ShapeInputs[1] = (name: "ids", tensor: overflowingInt64Shape)
        #expect(throws: ONNXRuntimeError.self) {
            _ = try session.run(inputs: overflowingInt64ShapeInputs, outputNames: ["y"])
        }

        let invalidInt64Count: ONNXTensor = .int64(shape: [1, 3], values: [1, 2])
        var invalidInt64CountInputs = validInputs
        invalidInt64CountInputs[1] = (name: "ids", tensor: invalidInt64Count)
        #expect(throws: ONNXRuntimeError.self) {
            _ = try session.run(inputs: invalidInt64CountInputs, outputNames: ["y"])
        }
    }

    @Test
    func invalidInputAndOutputNamesFailWithExactErrors() throws {
        let session = try makeSession(modelURL: fixtureURL(named: "affine"), intraOpThreads: 1)
        let validInputs = fixtureInputs(sampleRate: 1)

        var emptyInputName = validInputs
        emptyInputName[0] = (name: "", tensor: validInputs[0].tensor)
        #expect(onnxErrorMessage {
            _ = try session.run(inputs: emptyInputName, outputNames: ["y"])
        } == "入出力名を空にすることはできません。")

        var nulInputName = validInputs
        nulInputName[0] = (name: "x\0invalid", tensor: validInputs[0].tensor)
        #expect(onnxErrorMessage {
            _ = try session.run(inputs: nulInputName, outputNames: ["y"])
        } == "入出力名にNUL文字は使用できません。")

        var duplicateInputName = validInputs
        duplicateInputName[1] = (name: "x", tensor: validInputs[1].tensor)
        #expect(onnxErrorMessage {
            _ = try session.run(inputs: duplicateInputName, outputNames: ["y"])
        } == "入力名を重複させることはできません。")

        #expect(onnxErrorMessage {
            _ = try session.run(inputs: validInputs, outputNames: [""])
        } == "入出力名を空にすることはできません。")
        #expect(onnxErrorMessage {
            _ = try session.run(inputs: validInputs, outputNames: ["y\0invalid"])
        } == "入出力名にNUL文字は使用できません。")
        #expect(onnxErrorMessage {
            _ = try session.run(inputs: validInputs, outputNames: [])
        } == "出力名を1つ以上指定する必要があります。")
    }

    @Test
    func missingAndUnknownInputsReportORTFailuresAndSessionRemainsReusable() throws {
        let session = try makeSession(modelURL: fixtureURL(named: "affine"), intraOpThreads: 1)
        let validInputs = fixtureInputs(sampleRate: 1)
        let runContext = "ONNXモデルの実行に失敗しました"

        let missingInputMessage = onnxErrorMessage {
            _ = try session.run(inputs: Array(validInputs.dropLast()), outputNames: ["y"])
        }
        #expect(missingInputMessage.hasPrefix(runContext))
        #expect(missingInputMessage.localizedCaseInsensitiveContains("missing"))

        var unknownNameInputs = validInputs
        unknownNameInputs[0] = (name: "unknown", tensor: validInputs[0].tensor)
        let unknownNameMessage = onnxErrorMessage {
            _ = try session.run(inputs: unknownNameInputs, outputNames: ["y"])
        }
        #expect(unknownNameMessage.hasPrefix(runContext))
        #expect(unknownNameMessage.localizedCaseInsensitiveContains("unknown"))

        let output = try session.run(
            inputs: fixtureInputs(sampleRate: 1),
            outputNames: ["y"]
        )
        #expect(output == [.float32(shape: [1, 4], values: [-3, 0, 1, 7.5])])
    }

    @Test
    func invalidThreadCountsAndNonFileModelURLAreRejected() throws {
        let modelURL = try fixtureURL(named: "affine")
        for threadCount in [0, -1, Int.max] {
            let message = onnxErrorMessage {
                _ = try makeSession(modelURL: modelURL, intraOpThreads: threadCount)
            }
            #expect(message.contains("Int32"))
            #expect(message.contains("正数"))
        }

        let nonFileURL = try #require(URL(string: "https://example.com/affine.onnx"))
        #expect(onnxErrorMessage {
            _ = try makeSession(modelURL: nonFileURL, intraOpThreads: 1)
        } == "モデルURLはファイルURLである必要があります。")
    }

    private func makeSession(modelURL: URL, intraOpThreads: Int) throws -> ONNXSession {
        try ONNXSession(
            environment: environment,
            modelURL: modelURL,
            intraOpThreads: intraOpThreads,
            cpuMemoryArenaEnabled: true
        )
    }
}

private final class WeakONNXEnvironment {
    weak var value: ONNXEnvironment?

    init(_ value: ONNXEnvironment) {
        self.value = value
    }
}

private final class SessionPair {
    var first: ONNXSession?
    var second: ONNXSession?
    let environment: WeakONNXEnvironment

    init(first: ONNXSession, second: ONNXSession, environment: WeakONNXEnvironment) {
        self.first = first
        self.second = second
        self.environment = environment
    }
}

private func fixtureURL(named name: String) throws -> URL {
    try #require(Bundle.module.url(
        forResource: name,
        withExtension: "onnx",
        subdirectory: "Resources"
    ))
}

private func fixtureInputs(sampleRate: Int64) -> [(name: String, tensor: ONNXTensor)] {
    let floatValues: [Float] = [-2, -0.5, 0, 3.25]
    let identifierValues: [Int64] = [9_007_199_254_740_993, -5, 42]
    return [
        (name: "x", tensor: .float32(shape: [1, 4], values: floatValues)),
        (name: "ids", tensor: .int64(shape: [1, 3], values: identifierValues)),
        (name: "sr", tensor: .int64(shape: [], values: [sampleRate])),
    ]
}

private func makeSessionPair(modelURL: URL) throws -> SessionPair {
    let environment = try ONNXEnvironment.shared()
    let first = try ONNXSession(
        environment: environment,
        modelURL: modelURL,
        intraOpThreads: 1,
        cpuMemoryArenaEnabled: true
    )
    let second = try ONNXSession(
        environment: environment,
        modelURL: modelURL,
        intraOpThreads: 2,
        cpuMemoryArenaEnabled: true
    )
    return SessionPair(
        first: first,
        second: second,
        environment: WeakONNXEnvironment(environment)
    )
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
