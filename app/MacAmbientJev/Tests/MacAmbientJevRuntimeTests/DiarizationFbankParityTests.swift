#if os(macOS)
import CoreML
import CryptoKit
import Foundation
import Testing
@testable import FluidAudio

private enum DiarizationFbankParityError: Error, CustomStringConvertible {
    case invalidModelDirectory(String)
    case invalidGraph(String)
    case invalidOutput(String)

    var description: String {
        switch self {
        case .invalidModelDirectory(let reason):
            return "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY: \(reason)"
        case .invalidGraph(let reason):
            return "Invalid FBank.mlmodelc graph: \(reason)"
        case .invalidOutput(let reason):
            return "Invalid FBank.mlmodelc output: \(reason)"
        }
    }
}

/// Deterministic synthetic windows. The portable test regenerates the same signals from the same recipe.
private enum FbankParityInputs {
    static let caseNames = ["speech", "clipping", "silence", "short", "dc-offset"]
    static let constructions: [String: String] = [
        "speech": "160000 samples. Seed 1 LCG noise. x[n]=0.12*env[n]*sum_{k=1..6}(sin(2*pi*140*k*n/16000)/k)+0.01*noise[n], with env[n]=gate*(0.15+0.85*triangle(n mod 4000 over 0..1..0)) and gate=0 for n in 60000..<80000, else 1. Harmonics come from rotation oscillators.",
        "clipping": "160000 samples. Seed 2 LCG noise. x[n]=clamp(1.8*(0.7*sin(2*pi*220*n/16000)+0.3*sin(2*pi*3300*n/16000))+0.05*noise[n], -1, 1), so the waveform sits at exactly +-1 over long stretches.",
        "silence": "160000 samples of exact digital zero. Every mel energy is 0, which exercises the 1e-6 log floor.",
        "short": "48000 real samples (3 s) built like speech with f0 160 Hz and seed 3, followed by 112000 zeros so the 10 s window is zero padded.",
        "dc-offset": "160000 samples. Seed 4 LCG noise. x[n]=0.25+0.05*sin(2*pi*1000*n/16000)+0.002*noise[n].",
    ]

    static func availableSampleCount(_ name: String) -> Int {
        name == "short" ? 48_000 : 160_000
    }

    static func samples(_ name: String) -> [Float] {
        let count = availableSampleCount(name)
        var noise = Noise(seed: seed(name))
        switch name {
        case "speech":
            return speech(count: count, fundamental: 140, noise: &noise)
        case "short":
            return speech(count: count, fundamental: 160, noise: &noise)
        case "clipping":
            var low = Oscillator(hertz: 220)
            var high = Oscillator(hertz: 3300)
            return (0..<count).map { _ in
                let value = 1.8 * (0.7 * low.next() + 0.3 * high.next()) + 0.05 * noise.next()
                return Float(min(1, max(-1, value)))
            }
        case "silence":
            return [Float](repeating: 0, count: count)
        case "dc-offset":
            var tone = Oscillator(hertz: 1_000)
            return (0..<count).map { _ in Float(0.25 + 0.05 * tone.next() + 0.002 * noise.next()) }
        default:
            fatalError("unknown fbank parity case \(name)")
        }
    }

    private static func seed(_ name: String) -> UInt64 {
        switch name {
        case "speech": return 1
        case "clipping": return 2
        case "short": return 3
        case "dc-offset": return 4
        default: return 0
        }
    }

    private static func speech(count: Int, fundamental: Double, noise: inout Noise) -> [Float] {
        var harmonics = (1...6).map { Oscillator(hertz: fundamental * Double($0)) }
        return (0..<count).map { index in
            let phase = index % 4_000
            let triangle = phase < 2_000 ? Double(phase) / 2_000 : Double(4_000 - phase) / 2_000
            let gate = (60_000..<80_000).contains(index) ? 0.0 : 1.0
            let envelope = gate * (0.15 + 0.85 * triangle)
            var sum = 0.0
            for harmonic in harmonics.indices {
                sum += harmonics[harmonic].next() / Double(harmonic + 1)
            }
            return Float(0.12 * envelope * sum + 0.01 * noise.next())
        }
    }

    private struct Oscillator {
        private var cosine = 1.0
        private var sine = 0.0
        private let stepCosine: Double
        private let stepSine: Double

        init(hertz: Double) {
            let angle = 2 * Double.pi * hertz / 16_000
            stepCosine = cos(angle)
            stepSine = sin(angle)
        }

        mutating func next() -> Double {
            let output = sine
            let nextCosine = cosine * stepCosine - sine * stepSine
            sine = cosine * stepSine + sine * stepCosine
            cosine = nextCosine
            return output
        }
    }

    private struct Noise {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 2 * Double(state >> 11) / 9_007_199_254_740_992 - 1
        }
    }
}

extension DiarizationParityFixtureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"))
    func fbankMatchesCoreML() throws {
        let modelURL = try fbankModelDirectory().appendingPathComponent("FBank.mlmodelc", isDirectory: true)
        let weightData = try Data(contentsOf: modelURL.appendingPathComponent("weights/weight.bin", isDirectory: false))
        let modelMIL = try String(
            contentsOf: modelURL.appendingPathComponent("model.mil", isDirectory: false),
            encoding: .utf8
        )
        try validateFbankGraphDeclarations(modelMIL)
        let weightsSHA256 = SHA256.hash(data: weightData).map { String(format: "%02x", $0) }.joined()
        let melWeights = try fbankBlobFloat32(weightData, blobOffset: 64, count: 80 * 257, name: "_fbank_mel_weight")
        let window = try fbankBlobFloat32(weightData, blobOffset: 1_135_168, count: 400, name: "_fbank_window")

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)

        try DiarizationParityOracle.checkFbankOrWrite(
            [
                "metadata": DiarizationParityOracle.metadata(
                    inputConstruction: "window and melWeights are the Float32 BLOBFILE tensors _fbank_window [1,400] and _fbank_mel_weight [80,257,1] decoded from the caller-provided FBank.mlmodelc weights/weight.bin after the 64-byte record header; their model.mil declarations and offsets are checked.",
                    comparisonRule: "The portable window must match within 1e-6 and the portable mel bank within 2e-5 absolute error."
                ),
                "modelWeightsSHA256": weightsSHA256,
                "window": try DiarizationParityOracle.tensor(window, shape: [400]),
                "melWeights": try DiarizationParityOracle.tensor(melWeights, shape: [80, 257]),
            ],
            named: "fbank-graph.json"
        )

        let fileNames = ["speech": "fbank-speech.json", "clipping": "fbank-clipping.json", "silence": "fbank-silence.json", "short": "fbank-short.json", "dc-offset": "fbank-dc-offset.json"]
        try #require(Set(fileNames.values).union(["fbank-graph.json"]) == Set(DiarizationParityOracle.fbankFixtureNames))
        for name in FbankParityInputs.caseNames {
            var padded = FbankParityInputs.samples(name)
            let availableCount = padded.count
            try #require(availableCount == FbankParityInputs.availableSampleCount(name))
            padded.append(contentsOf: repeatElement(Float.zero, count: 160_000 - availableCount))
            let features = try runFbank(model, samples: padded)
            try DiarizationParityOracle.checkFbankOrWrite(
                [
                    "metadata": DiarizationParityOracle.metadata(
                        inputConstruction: "The oracle loads only the caller-provided FBank.mlmodelc using MLModel(contentsOf:configuration:) with .cpuOnly and feeds it the deterministic 10 s Float32 window named by `construction` as audio [1,1,160000]. The expected grid is the graph's fbank_features [1,1,80,998] output transposed to frame-major [998,80] and stored as exact Float32 values. No portable implementation is used as the oracle.",
                        comparisonRule: "Portable comparison uses the maximum absolute error over the full 998x80 grid, which must be <= 3e-3. Generator check mode compares a fresh Core ML run with the committed grid by maximum absolute error <= 1e-3, never byte equality, because Core ML float output differs between environments."
                    ),
                    "modelWeightsSHA256": weightsSHA256,
                    "name": name,
                    "construction": try #require(FbankParityInputs.constructions[name]),
                    "availableSampleCount": availableCount,
                    "expectedFeatures": try DiarizationParityOracle.tensor(features, shape: [998, 80]),
                ],
                named: try #require(fileNames[name])
            )
        }
    }
}

private func runFbank(_ model: MLModel, samples: [Float]) throws -> [Float] {
    let input = try MLMultiArray(shape: [1, 1, 160_000], dataType: .float32)
    samples.withUnsafeBufferPointer { buffer in
        input.dataPointer.copyMemory(from: buffer.baseAddress!, byteCount: buffer.count * MemoryLayout<Float>.size)
    }
    let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: input)])
    let output = try model.prediction(from: provider)
    guard let array = output.featureValue(for: "fbank_features")?.multiArrayValue else {
        throw DiarizationFbankParityError.invalidOutput("missing fbank_features")
    }
    guard array.dataType == .float32, array.shape.map(\.intValue) == [1, 1, 80, 998] else {
        throw DiarizationFbankParityError.invalidOutput(
            "expected float32 [1,1,80,998]; got \(array.dataType.rawValue) \(array.shape)"
        )
    }
    let melStride = array.strides[2].intValue
    let frameStride = array.strides[3].intValue
    let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
    var frameMajor = [Float](repeating: 0, count: 998 * 80)
    for frame in 0..<998 {
        for mel in 0..<80 {
            frameMajor[frame * 80 + mel] = pointer[mel * melStride + frame * frameStride]
        }
    }
    return frameMajor
}

private func fbankModelDirectory() throws -> URL {
    let environmentName = "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY"
    guard let directoryPath = ProcessInfo.processInfo.environment[environmentName] else {
        throw DiarizationFbankParityError.invalidModelDirectory("is required and must name an absolute existing directory")
    }
    guard directoryPath.hasPrefix("/") else {
        throw DiarizationFbankParityError.invalidModelDirectory("must be an absolute path; found \(directoryPath)")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw DiarizationFbankParityError.invalidModelDirectory("does not exist or is not a directory: \(directoryPath)")
    }
    return URL(fileURLWithPath: directoryPath, isDirectory: true)
}

private func validateFbankGraphDeclarations(_ modelMIL: String) throws {
    let declarations = [
        ("_fbank_mel_weight", "[80,257,1]", 64),
        ("_fbank_window", "[1,400]", 1_135_168),
    ]
    let normalizedLines = modelMIL.split(whereSeparator: \.isNewline).map { $0.filter { !$0.isWhitespace } }
    for (name, shape, offset) in declarations {
        let expectedName = "name=tensor<string,[]>(\"\(name)\")"
        let expectedShape = "tensor<fp32,\(shape)>"
        let expectedBlob = "BLOBFILE(path=tensor<string,[]>(\"@model_path/weights/weight.bin\"),offset=tensor<uint64,[]>(\(offset)))"
        let matches = normalizedLines.filter {
            $0.contains(expectedName) && $0.contains(expectedShape) && $0.contains(expectedBlob)
        }
        guard matches.count == 1 else {
            throw DiarizationFbankParityError.invalidGraph(
                "expected exactly one Float32 \(shape) BLOBFILE declaration for \(name) at offset \(offset); found \(matches.count)"
            )
        }
    }
}

private func fbankBlobFloat32(_ data: Data, blobOffset: Int, count: Int, name: String) throws -> [Float] {
    let payloadOffset = blobOffset + 64
    guard payloadOffset + count * MemoryLayout<UInt32>.size <= data.count else {
        throw DiarizationFbankParityError.invalidGraph("\(name) BLOBFILE at offset \(blobOffset) exceeds weight.bin")
    }
    let values = data.withUnsafeBytes { rawBuffer in
        (0..<count).map { index in
            Float(bitPattern: UInt32(littleEndian: rawBuffer.loadUnaligned(
                fromByteOffset: payloadOffset + index * MemoryLayout<UInt32>.size,
                as: UInt32.self
            )))
        }
    }
    guard values.allSatisfy(\.isFinite) else {
        throw DiarizationFbankParityError.invalidGraph("\(name) BLOBFILE contains a non-finite Float32 value")
    }
    return values
}
#endif
