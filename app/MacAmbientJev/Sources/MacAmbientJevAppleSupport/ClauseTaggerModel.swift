import CoreML
import Foundation
import MacAmbientJevCore

public enum ClauseTaggerModelError: LocalizedError, Sendable {
    case unavailable(String)
    case invalidModel(String)
    case invalidInput
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "ローカル発話文モデルを利用できません: \(detail)"
        case .invalidModel(let detail):
            return "ローカル発話文モデルが不正です: \(detail)"
        case .invalidInput:
            return "ローカル発話文モデルへの入力が不正です。"
        case .invalidOutput:
            return "ローカル発話文モデルの出力が不正です。"
        }
    }
}

public struct ClauseTaggerModelIdentity: Sendable, Equatable {
    public let decisionIdentity: DecisionModelIdentity
    public let tokenizerSHA256: String

    public var modelID: String { decisionIdentity.model }
    public var revision: String { decisionIdentity.modelRevision }

    public init(modelID: String, revision: String, tokenizerSHA256: String) throws {
        let decisionIdentity: DecisionModelIdentity
        do {
            decisionIdentity = try DecisionModelIdentity(model: modelID, modelRevision: revision)
        } catch ClauseValidationError.invalidMetadata {
            throw ClauseTaggerModelError.invalidModel("モデルメタデータが発話文モデルの仕様に一致しません。")
        }
        self.decisionIdentity = decisionIdentity
        self.tokenizerSHA256 = tokenizerSHA256
    }
}

public struct ClauseTaggerPrediction: Sendable {
    public let boundaryProbabilities: [[Double]]
    public let spanProbabilities: [[Double]]
    public let priorityProbabilities: [Double]

    public init(
        boundaryProbabilities: [[Double]],
        spanProbabilities: [[Double]],
        priorityProbabilities: [Double]
    ) {
        self.boundaryProbabilities = boundaryProbabilities
        self.spanProbabilities = spanProbabilities
        self.priorityProbabilities = priorityProbabilities
    }
}

public final class ClauseTaggerModel {
    public let identity: ClauseTaggerModelIdentity

    private let model: MLModel

    public init(packageURL: URL) throws {
        let fileManager = FileManager.default
        guard packageURL.pathExtension == "mlpackage",
              fileManager.fileExists(atPath: packageURL.path),
              fileManager.isReadableFile(atPath: packageURL.path) else {
            throw ClauseTaggerModelError.unavailable(".mlpackage が見つからないか、読み込めません。")
        }
        let packageValues: URLResourceValues
        do {
            packageValues = try packageURL.resourceValues(forKeys: [.isDirectoryKey])
        } catch {
            throw ClauseTaggerModelError.unavailable(".mlpackage の属性を確認できません。")
        }
        guard packageValues.isDirectory == true else {
            throw ClauseTaggerModelError.unavailable("モデルは .mlpackage ディレクトリである必要があります。")
        }
        let modelFileURL = packageURL.appending(path: "Data/com.apple.CoreML/model.mlmodel")
        guard fileManager.isReadableFile(atPath: modelFileURL.path) else {
            throw ClauseTaggerModelError.unavailable(".mlpackage 内のモデルを読み込めません。")
        }

        let compiledURL: URL
        do {
            compiledURL = try MLModel.compileModel(at: packageURL)
        } catch {
            throw ClauseTaggerModelError.unavailable("Core ML モデルをコンパイルできません。")
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let loadedModel: MLModel
        do {
            loadedModel = try MLModel(contentsOf: compiledURL, configuration: configuration)
        } catch {
            let loadFailure = error.localizedDescription
            do {
                try Self.removeCompiledModel(at: compiledURL)
            } catch {
                throw ClauseTaggerModelError.invalidModel(
                    "Core ML モデルを読み込めませんでした（\(loadFailure)）。一時コンパイル済みモデルの削除にも失敗しました（\(error.localizedDescription)）。"
                )
            }
            throw ClauseTaggerModelError.invalidModel("Core ML モデルを読み込めません: \(loadFailure)")
        }

        do {
            try Self.removeCompiledModel(at: compiledURL)
        } catch {
            throw ClauseTaggerModelError.invalidModel(
                "読み込み後の一時コンパイル済みモデルを削除できません: \(error.localizedDescription)"
            )
        }

        let validatedIdentity = try Self.validateModel(loadedModel)
        model = loadedModel
        identity = validatedIdentity
    }

    public func predict(inputIDs: [Int]) throws -> ClauseTaggerPrediction {
        guard (2...ClauseTaggerEncoding.maximumTokens).contains(inputIDs.count),
              inputIDs.allSatisfy({ (0..<102_400).contains($0) }),
              inputIDs.first == ClauseTaggerEncoding.clsTokenID,
              inputIDs.last == ClauseTaggerEncoding.sepTokenID else {
            throw ClauseTaggerModelError.invalidInput
        }

        let input: MLMultiArray
        do {
            input = try MLMultiArray(
                shape: [1, inputIDs.count].map { NSNumber(value: $0) },
                dataType: .int32
            )
        } catch {
            throw ClauseTaggerModelError.invalidInput
        }
        for (index, tokenID) in inputIDs.enumerated() {
            input[[NSNumber(value: 0), NSNumber(value: index)]] = NSNumber(value: Int32(tokenID))
        }

        let prediction: MLFeatureProvider
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: ["input_ids": input])
            prediction = try model.prediction(from: provider)
        } catch {
            throw ClauseTaggerModelError.invalidOutput
        }
        guard prediction.featureNames == Set(["boundary_probs", "span_probs", "priority_probs"]),
              let boundaryArray = Self.float32Array(named: "boundary_probs", in: prediction),
              let spanArray = Self.float32Array(named: "span_probs", in: prediction),
              let priorityArray = Self.float32Array(named: "priority_probs", in: prediction),
              Self.shape(of: boundaryArray) == [1, inputIDs.count, 2],
              Self.shape(of: spanArray) == [1, inputIDs.count, 4],
              Self.shape(of: priorityArray) == [1, 2] else {
            throw ClauseTaggerModelError.invalidOutput
        }

        let boundaryProbabilities = try Self.rows(from: boundaryArray, length: inputIDs.count, width: 2)
        let spanProbabilities = try Self.rows(from: spanArray, length: inputIDs.count, width: 4)
        let priorityProbabilities = try Self.vector(from: priorityArray, width: 2)

        return ClauseTaggerPrediction(
            boundaryProbabilities: boundaryProbabilities,
            spanProbabilities: spanProbabilities,
            priorityProbabilities: priorityProbabilities
        )
    }

    private static func removeCompiledModel(at compiledURL: URL) throws {
        guard compiledURL.pathExtension == "mlmodelc" else {
            throw ClauseTaggerModelError.invalidModel("一時コンパイル済みモデルの削除対象は .mlmodelc ディレクトリではありません。")
        }

        let values: URLResourceValues
        do {
            values = try compiledURL.resourceValues(forKeys: [.isDirectoryKey])
        } catch {
            throw ClauseTaggerModelError.unavailable(
                "一時コンパイル済みモデルの属性を確認できません: \(error.localizedDescription)"
            )
        }
        guard values.isDirectory == true else {
            throw ClauseTaggerModelError.invalidModel("一時コンパイル済みモデルの削除対象はディレクトリではありません。")
        }

        do {
            try FileManager.default.removeItem(at: compiledURL)
        } catch {
            throw ClauseTaggerModelError.unavailable(
                "一時コンパイル済みモデルを削除できません: \(error.localizedDescription)"
            )
        }
    }

    private static func validateModel(_ model: MLModel) throws -> ClauseTaggerModelIdentity {
        let description = model.modelDescription
        guard Set(description.inputDescriptionsByName.keys) == Set(["input_ids"]),
              let input = description.inputDescriptionsByName["input_ids"],
              input.type == .multiArray,
              let inputConstraint = input.multiArrayConstraint,
              inputConstraint.dataType == .int32,
              inputConstraint.shape.count == 2,
              inputConstraint.shape[0].intValue == 1,
              Self.supportsSequenceLengths(inputConstraint.shapeConstraint) else {
            throw ClauseTaggerModelError.invalidModel(
                "入力は int32 の rank-2 input_ids で、batch=1 と sequence length 2...192 を受け入れる必要があります。"
            )
        }
        let expectedOutputs: Set<String> = ["boundary_probs", "span_probs", "priority_probs"]
        guard Set(description.outputDescriptionsByName.keys) == expectedOutputs,
              expectedOutputs.allSatisfy({ name in
                  guard let feature = description.outputDescriptionsByName[name] else { return false }
                  return feature.type == .multiArray && feature.multiArrayConstraint?.dataType == .float32
              }) else {
            throw ClauseTaggerModelError.invalidModel("出力名と型が発話文モデルの仕様に一致しません。")
        }

        guard let creatorMetadata = description.metadata[.creatorDefinedKey] as? [String: Any],
              let modelID = creatorMetadata["model_id"] as? String,
              let revision = creatorMetadata["model_revision"] as? String,
              let trainingStatus = creatorMetadata["training_status"] as? String,
              let tokenizerSHA256 = creatorMetadata["tokenizer_sha256"] as? String,
              let unitPolicy = creatorMetadata["unit_policy"] as? String,
              let encodingRevision = creatorMetadata["encoding_revision"] as? String,
              modelID == "sbintuitions/modernbert-ja-30m-multitagger",
              trainingStatus == "trained",
              Self.isLowercaseHex(tokenizerSHA256, length: 64),
              unitPolicy == "btsj-utterance-sentence",
              encodingRevision == "1" else {
            throw ClauseTaggerModelError.invalidModel("モデルメタデータが発話文モデルの仕様に一致しません。")
        }

        return try ClauseTaggerModelIdentity(
            modelID: modelID,
            revision: revision,
            tokenizerSHA256: tokenizerSHA256
        )
    }

    private static func supportsSequenceLengths(_ constraint: MLMultiArrayShapeConstraint) -> Bool {
        let ranges = constraint.sizeRangeForDimension
        guard constraint.type == .range,
              ranges.count == 2 else {
            return false
        }

        let batchRange = ranges[0].rangeValue
        let sequenceRange = ranges[1].rangeValue
        return range(batchRange, covers: 1, through: 1)
            && range(sequenceRange, covers: 2, through: 192)
    }

    private static func range(_ range: NSRange, covers lowerBound: Int, through upperBound: Int) -> Bool {
        guard range.length > 0, range.location <= lowerBound else { return false }
        let (exclusiveUpperBound, overflow) = range.location.addingReportingOverflow(range.length)
        return !overflow && exclusiveUpperBound > upperBound
    }

    private static func isLowercaseHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func float32Array(named name: String, in provider: MLFeatureProvider) -> MLMultiArray? {
        guard let value = provider.featureValue(for: name),
              value.type == .multiArray,
              let array = value.multiArrayValue,
              array.dataType == .float32 else {
            return nil
        }
        return array
    }

    private static func shape(of array: MLMultiArray) -> [Int] {
        array.shape.map(\.intValue)
    }

    private static func rows(from array: MLMultiArray, length: Int, width: Int) throws -> [[Double]] {
        var result: [[Double]] = []
        result.reserveCapacity(length)
        for position in 0..<length {
            result.append(try row(from: array, position: position, width: width))
        }
        return result
    }

    private static func row(from array: MLMultiArray, position: Int, width: Int) throws -> [Double] {
        let values = (0..<width).map { label in
            array[[NSNumber(value: 0), NSNumber(value: position), NSNumber(value: label)]].doubleValue
        }
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(values.reduce(0, +) - 1) <= taggerProbabilitySumTolerance else {
            throw ClauseTaggerModelError.invalidOutput
        }
        return values
    }

    private static func vector(from array: MLMultiArray, width: Int) throws -> [Double] {
        let values = (0..<width).map { label in
            array[[NSNumber(value: 0), NSNumber(value: label)]].doubleValue
        }
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(values.reduce(0, +) - 1) <= taggerProbabilitySumTolerance else {
            throw ClauseTaggerModelError.invalidOutput
        }
        return values
    }
}
