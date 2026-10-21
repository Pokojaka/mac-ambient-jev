#if os(macOS)
import Foundation
import Testing
@testable import FluidAudio

enum DiarizationParityOracleError: Error, CustomStringConvertible {
    case invalidFixtureName(String)
    case missingFixture(String)
    case fixtureTooLarge(Int)
    case invalidPackageResolved(String)
    case unsupportedEmbeddingSkipStrategy
    case invalidTensor(String)
    case invalidFixtureData(String)

    var description: String {
        switch self {
        case .invalidFixtureName(let name):
            return "Unrecognized diarization parity fixture filename: \(name)"
        case .missingFixture(let name):
            return "Diarization parity fixture is missing: \(name)"
        case .fixtureTooLarge(let size):
            return "Diarization parity fixture is \(size) bytes; maximum is 1048576 bytes"
        case .invalidPackageResolved(let reason):
            return "Could not validate the FluidAudio pin in Package.resolved: \(reason)"
        case .unsupportedEmbeddingSkipStrategy:
            return "Diarization parity parameters require FluidAudio embedding skip strategy .none"
        case .invalidTensor(let reason):
            return "Invalid diarization parity tensor: \(reason)"
        case .invalidFixtureData(let reason):
            return "Invalid diarization parity fixture: \(reason)"
        }
    }
}

enum DiarizationParityOracle {
    static let version = "0.15.8"
    static let revision = "87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc"
    private static let fixtureNames = ["parameters.json", "reconstruction.json", "ahc.json", "assignment.json", "vbx.json", "plda-rho.json"]
    private static let maximumFixtureBytes = 1_048_576
    private static let pldaRhoDesignContractAbsoluteError = 1e-4 // The PLDA rho design contract permits this absolute error.

    private struct DecodedPLDARho {
        let dtype: String
        let values: [Double]
    }

    static func config() throws -> OfflineDiarizerConfig {
        try validateFluidAudioPin()
        var config = OfflineDiarizerConfig.default
        config.embedding.minSegmentDurationSeconds = 0.3
        try config.validate()
        return config
    }

    static func metadata(inputConstruction: String, comparisonRule: String) -> [String: Any] {
        [
            "schemaVersion": 1,
            "fluidAudioVersion": version,
            "fluidAudioRevision": revision,
            "inputConstruction": inputConstruction,
            "comparisonRule": comparisonRule,
        ]
    }

    static func checkOrWrite(_ object: [String: Any], named name: String) throws {
        guard fixtureNames.contains(name) else {
            throw DiarizationParityOracleError.invalidFixtureName(name)
        }

        let encoded = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        var contents = encoded
        contents.append(0x0A)
        guard contents.count <= maximumFixtureBytes else {
            throw DiarizationParityOracleError.fixtureTooLarge(contents.count)
        }

        let url = sourceResourcesURL.appendingPathComponent(name, isDirectory: false)
        if ProcessInfo.processInfo.environment["MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY"] == "1" {
            try FileManager.default.createDirectory(
                at: sourceResourcesURL,
                withIntermediateDirectories: true
            )
            try contents.write(to: url, options: .atomic)
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DiarizationParityOracleError.missingFixture(name)
        }
        let committed = try Data(contentsOf: url)
        guard committed.count <= maximumFixtureBytes else {
            throw DiarizationParityOracleError.fixtureTooLarge(committed.count)
        }
        #expect(committed == contents)
    }

    static func checkPLDARhoOrWrite(_ object: [String: Any]) throws {
        let name = "plda-rho.json"
        let encoded = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        var contents = encoded
        contents.append(0x0A)
        guard contents.count <= maximumFixtureBytes else {
            throw DiarizationParityOracleError.fixtureTooLarge(contents.count)
        }

        let url = sourceResourcesURL.appendingPathComponent(name, isDirectory: false)
        if ProcessInfo.processInfo.environment["MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY"] == "1" {
            try FileManager.default.createDirectory(
                at: sourceResourcesURL,
                withIntermediateDirectories: true
            )
            try contents.write(to: url, options: .atomic)
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DiarizationParityOracleError.missingFixture(name)
        }
        let committed = try Data(contentsOf: url)
        guard committed.count <= maximumFixtureBytes else {
            throw DiarizationParityOracleError.fixtureTooLarge(committed.count)
        }
        let committedObject: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: committed) as? [String: Any] else {
                throw DiarizationParityOracleError.invalidFixtureData("\(name) must contain a JSON object")
            }
            committedObject = decoded
        } catch let error as DiarizationParityOracleError {
            throw error
        } catch {
            throw DiarizationParityOracleError.invalidFixtureData("could not decode \(name): \(error)")
        }

        let committedCases = try pldaRhoCases(in: committedObject, source: "committed \(name)")
        let freshCases = try pldaRhoCases(in: object, source: "fresh Core ML fixture")
        try #require(
            committedCases.count == freshCases.count,
            "plda-rho.json case count differs: committed=\(committedCases.count), fresh=\(freshCases.count)"
        )
        let committedWithoutRho = try canonicalFixtureWithoutPLDARho(committedObject, source: "committed \(name)")
        let freshWithoutRho = try canonicalFixtureWithoutPLDARho(object, source: "fresh Core ML fixture")
        try #require(
            committedWithoutRho == freshWithoutRho,
            "plda-rho.json fields other than cases[*].expectedRho must match exactly"
        )

        for index in committedCases.indices {
            let committedCase = committedCases[index]
            let freshCase = freshCases[index]
            let caseName = try #require(
                freshCase["name"] as? String,
                "Fresh PLDA case at index \(index) must have a string name"
            )
            let committedRho = try decodePLDARho(
                committedCase["expectedRho"],
                source: "committed case \(caseName)"
            )
            let freshRho = try decodePLDARho(
                freshCase["expectedRho"],
                source: "fresh case \(caseName)"
            )
            try #require(
                committedRho.dtype == freshRho.dtype,
                "PLDA rho dtype mismatch for case \(caseName): committed=\(committedRho.dtype), fresh=\(freshRho.dtype)"
            )
            try #require(
                committedRho.values.count == freshRho.values.count,
                "PLDA rho value count mismatch for case \(caseName): committed=\(committedRho.values.count), fresh=\(freshRho.values.count)"
            )
            for valueIndex in committedRho.values.indices {
                let committedValue = committedRho.values[valueIndex]
                let freshValue = freshRho.values[valueIndex]
                let absoluteError = abs(committedValue - freshValue)
                try #require(
                    absoluteError <= pldaRhoDesignContractAbsoluteError,
                    "PLDA rho mismatch for case \(caseName) at index \(valueIndex): committed=\(committedValue), fresh Core ML=\(freshValue), absolute error=\(absoluteError), allowed=\(pldaRhoDesignContractAbsoluteError)"
                )
            }
        }
    }

    private static func pldaRhoCases(in object: [String: Any], source: String) throws -> [[String: Any]] {
        let cases = try #require(object["cases"] as? [[String: Any]], "\(source) must contain a cases array of objects")
        for (index, parityCase) in cases.enumerated() {
            try #require(
                parityCase["expectedRho"] != nil,
                "\(source) case at index \(index) must contain expectedRho"
            )
        }
        return cases
    }

    private static func canonicalFixtureWithoutPLDARho(_ object: [String: Any], source: String) throws -> Data {
        var fixture = object
        let cases = try pldaRhoCases(in: object, source: source)
        fixture["cases"] = cases.map { parityCase -> [String: Any] in
            var fields = parityCase
            fields.removeValue(forKey: "expectedRho")
            return fields
        }
        return try JSONSerialization.data(
            withJSONObject: fixture,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func decodePLDARho(_ value: Any?, source: String) throws -> DecodedPLDARho {
        let tensor = try #require(value as? [String: Any], "\(source) expectedRho must be a tensor object")
        let dtype = try #require(tensor["dtype"] as? String, "\(source) expectedRho must have a dtype")
        let shape = try #require(tensor["shape"] as? [Int], "\(source) expectedRho must have an integer shape")
        try #require(!shape.isEmpty, "\(source) expectedRho shape must not be empty")
        let encoded = try #require(
            tensor["littleEndianBase64"] as? String,
            "\(source) expectedRho must have littleEndianBase64 data"
        )
        let itemSize: Int
        switch dtype {
        case "float32":
            itemSize = MemoryLayout<UInt32>.size
        case "float64":
            itemSize = MemoryLayout<UInt64>.size
        default:
            throw DiarizationParityOracleError.invalidFixtureData(
                "\(source) expectedRho has unsupported dtype \(dtype)"
            )
        }
        guard let payload = Data(base64Encoded: encoded), payload.count % itemSize == 0 else {
            throw DiarizationParityOracleError.invalidFixtureData(
                "\(source) expectedRho has invalid base64 data or byte count for \(dtype)"
            )
        }
        let count = payload.count / itemSize
        var shapeCount = 1
        for dimension in shape {
            guard dimension >= 0 else {
                throw DiarizationParityOracleError.invalidFixtureData("\(source) expectedRho shape has a negative dimension")
            }
            let (nextCount, overflow) = shapeCount.multipliedReportingOverflow(by: dimension)
            guard !overflow else {
                throw DiarizationParityOracleError.invalidFixtureData("\(source) expectedRho shape product overflows Int")
            }
            shapeCount = nextCount
        }
        guard shapeCount == count else {
            throw DiarizationParityOracleError.invalidFixtureData(
                "\(source) expectedRho shape contains \(shapeCount) values, but its payload contains \(count)"
            )
        }
        let values: [Double]
        if dtype == "float32" {
            values = payload.withUnsafeBytes { rawBuffer in
                (0..<count).map { valueIndex in
                    let bits = rawBuffer.loadUnaligned(
                        fromByteOffset: valueIndex * MemoryLayout<UInt32>.size,
                        as: UInt32.self
                    )
                    return Double(Float(bitPattern: UInt32(littleEndian: bits)))
                }
            }
        } else {
            values = payload.withUnsafeBytes { rawBuffer in
                (0..<count).map { valueIndex in
                    let bits = rawBuffer.loadUnaligned(
                        fromByteOffset: valueIndex * MemoryLayout<UInt64>.size,
                        as: UInt64.self
                    )
                    return Double(bitPattern: UInt64(littleEndian: bits))
                }
            }
        }
        guard values.allSatisfy(\.isFinite) else {
            throw DiarizationParityOracleError.invalidFixtureData("\(source) expectedRho contains a non-finite value")
        }
        return DecodedPLDARho(dtype: dtype, values: values)
    }

    static func tensor(_ values: [Float], shape: [Int]) throws -> [String: Any] {
        try validateTensorShape(shape, valueCount: values.count)
        var payload = Data()
        let (byteCount, overflow) = values.count.multipliedReportingOverflow(by: MemoryLayout<UInt32>.size)
        guard !overflow else {
            throw DiarizationParityOracleError.invalidTensor("float32 payload size overflows Int")
        }
        payload.reserveCapacity(byteCount)
        for (index, value) in values.enumerated() {
            guard value.isFinite else {
                throw DiarizationParityOracleError.invalidTensor("float32 value at index \(index) is not finite")
            }
            var bits = value.bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        }
        return [
            "dtype": "float32",
            "shape": shape,
            "littleEndianBase64": payload.base64EncodedString(),
        ]
    }

    static func tensor(_ values: [Double], shape: [Int]) throws -> [String: Any] {
        try validateTensorShape(shape, valueCount: values.count)
        var payload = Data()
        let (byteCount, overflow) = values.count.multipliedReportingOverflow(by: MemoryLayout<UInt64>.size)
        guard !overflow else {
            throw DiarizationParityOracleError.invalidTensor("float64 payload size overflows Int")
        }
        payload.reserveCapacity(byteCount)
        for (index, value) in values.enumerated() {
            guard value.isFinite else {
                throw DiarizationParityOracleError.invalidTensor("float64 value at index \(index) is not finite")
            }
            var bits = value.bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        }
        return [
            "dtype": "float64",
            "shape": shape,
            "littleEndianBase64": payload.base64EncodedString(),
        ]
    }

    private static var sourcePackageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var sourceResourcesURL: URL {
        sourcePackageRoot
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("MacAmbientJevDiarizationTests", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
    }

    private static func validateFluidAudioPin() throws {
        let packageResolvedURL = sourcePackageRoot.appendingPathComponent("Package.resolved", isDirectory: false)
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: Data(contentsOf: packageResolvedURL))
        } catch {
            throw DiarizationParityOracleError.invalidPackageResolved(
                "could not read or decode \(packageResolvedURL.path): \(error)"
            )
        }
        guard
            let object = root as? [String: Any],
            let pins = object["pins"] as? [[String: Any]]
        else {
            throw DiarizationParityOracleError.invalidPackageResolved("expected a top-level pins array")
        }
        let matchingPins = pins.filter { $0["identity"] as? String == "fluidaudio" }
        guard matchingPins.count == 1,
            let state = matchingPins[0]["state"] as? [String: Any],
            let foundVersion = state["version"] as? String,
            let foundRevision = state["revision"] as? String
        else {
            throw DiarizationParityOracleError.invalidPackageResolved(
                "expected exactly one complete FluidAudio pin"
            )
        }
        guard foundVersion == version, foundRevision == revision else {
            throw DiarizationParityOracleError.invalidPackageResolved(
                "expected FluidAudio \(version) at \(revision), found \(foundVersion) at \(foundRevision)"
            )
        }
    }

    private static func validateTensorShape(_ shape: [Int], valueCount: Int) throws {
        guard !shape.isEmpty else {
            throw DiarizationParityOracleError.invalidTensor("shape must contain at least one dimension")
        }
        guard !shape.contains(where: { $0 < 0 }) else {
            throw DiarizationParityOracleError.invalidTensor("shape dimensions must be nonnegative")
        }
        var product = 1
        for dimension in shape {
            let (nextProduct, overflow) = product.multipliedReportingOverflow(by: dimension)
            guard !overflow else {
                throw DiarizationParityOracleError.invalidTensor("shape dimension product overflows Int")
            }
            product = nextProduct
        }
        guard product == valueCount else {
            throw DiarizationParityOracleError.invalidTensor(
                "shape product is \(product), but values contain \(valueCount) elements"
            )
        }
    }
}

@Suite("DiarizationParityFixtureTests")
struct DiarizationParityFixtureTests {
    @Test
    func parametersMatchFluidAudio() throws {
        let config = try DiarizationParityOracle.config()
        let numeric: [String: Double] = [
            "sampleRate": Double(config.segmentation.sampleRate),
            "windowSamples": Double(config.samplesPerWindow),
            "stepSamples": Double(config.samplesPerStep),
            "windowDurationSeconds": config.segmentation.windowDurationSeconds,
            "stepRatio": config.segmentation.stepRatio,
            "minimumSegmentSeconds": config.embedding.minSegmentDurationSeconds,
            "ahcThreshold": config.clustering.threshold,
            "fa": config.clustering.warmStartFa,
            "fb": config.clustering.warmStartFb,
            "maximumIterations": Double(config.vbx.maxIterations),
            "elboTolerance": config.vbx.convergenceTolerance,
            "minimumGapSeconds": config.postProcessing.minGapDurationSeconds,
            "minimumOnSeconds": config.segmentation.minDurationOn,
            "minimumOffSeconds": config.segmentation.minDurationOff,
            "activePriorThreshold": VBxOutput.activeClusterEpsilon,
            "embeddingBatchSize": Double(config.embedding.batchSize),
            "speechOnsetThreshold": Double(config.segmentation.speechOnsetThreshold),
            "speechOffsetThreshold": Double(config.segmentation.speechOffsetThreshold),
            "zeroVoteMinimumDurationSeconds": config.zeroVoteReembed.minDurationSeconds,
        ]

        let skipStrategy: String
        switch config.embedding.skipStrategy {
        case .none:
            skipStrategy = "none"
        default:
            throw DiarizationParityOracleError.unsupportedEmbeddingSkipStrategy
        }

        let minSpeakers: String
        switch config.clustering.minSpeakers {
        case .none:
            minSpeakers = "nil"
        case .some(let count):
            minSpeakers = String(count)
        }
        let maxSpeakers: String
        switch config.clustering.maxSpeakers {
        case .none:
            maxSpeakers = "nil"
        case .some(let count):
            maxSpeakers = String(count)
        }
        let numSpeakers: String
        switch config.clustering.numSpeakers {
        case .none:
            numSpeakers = "nil"
        case .some(let count):
            numSpeakers = String(count)
        }
        let embeddingExportPath: String
        switch config.export.embeddingsPath {
        case .none:
            embeddingExportPath = "nil"
        case .some(let path):
            embeddingExportPath = path
        }

        let fixed: [String: String] = [
            "excludeOverlap": String(config.embedding.excludeOverlap),
            "exclusive": String(config.postProcessing.exclusiveSegments),
            "zeroVoteReembedding": String(config.zeroVoteReembed.enabled),
            "constrainedAssignment": String(config.clustering.constrainedAssignment),
            "embeddingSkipStrategy": skipStrategy,
            "minSpeakers": minSpeakers,
            "maxSpeakers": maxSpeakers,
            "numSpeakers": numSpeakers,
            "embeddingExportPath": embeddingExportPath,
            "exposeChunkEmbeddings": String(config.exposeChunkEmbeddings),
        ]

        let fixture: [String: Any] = [
            "metadata": DiarizationParityOracle.metadata(
                inputConstruction: "OfflineDiarizerConfig.default (OfflineDiarizerTypes.swift:551-553; configuration defaults at 273-291), then set only config.embedding.minSegmentDurationSeconds = 0.3 (Embedding defaults at 94-105), then validate(). No inference or audio input is used. Derived window/step samples use samplesPerWindow/samplesPerStep (347-354); activePriorThreshold uses VBxOutput.activeClusterEpsilon (663-664).",
                comparisonRule: "Exact field-by-field equality: every numeric value and every fixed policy string must match with no tolerance, aliases, omitted fields, or inferred defaults. Numeric values are observed from the effective validated configuration except activePriorThreshold, which is observed from VBxOutput.activeClusterEpsilon. Fixed values are exact string encodings of observed effective configuration values; nil optionals are encoded as 'nil'."
            ),
            "numeric": numeric,
            "fixed": fixed,
        ]
        try DiarizationParityOracle.checkOrWrite(fixture, named: "parameters.json")
    }
}
#endif
