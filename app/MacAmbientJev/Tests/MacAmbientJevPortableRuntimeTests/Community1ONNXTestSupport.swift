import Foundation
import MacAmbientJevCore
@testable import MacAmbientJevDiarization

/// Core ML stage outputs and FluidAudio spans written by the Mac generator
/// (`Community1ONNXStageFixtureTests` in MacAmbientJevRuntimeTests).
struct Community1StageFixture: Decodable {
    struct Mask: Decodable {
        let slot: Int
        let activity: String
        let embedding: String
    }

    struct Window: Decodable {
        let name: String
        let startSample: Int64
        let segmentation: String
        let masks: [Mask]
    }

    struct Scattered: Decodable {
        let windowName: String
        let activity: String
        let embedding: String
    }

    struct Span: Decodable {
        let speakerID: String
        let startFrame: Int64
        let endFrame: Int64
    }

    let schemaVersion: Int
    let clip: String
    let sampleCount: Int64
    let windows: [Window]
    let silenceSegmentation: String
    let scattered: Scattered
    let spans: [Span]

    static func load() throws -> Community1StageFixture {
        guard let url = Bundle.module.url(
            forResource: "diarization_onnx_stages", withExtension: "json", subdirectory: "Resources"
        ) else {
            throw Community1TestError.missing("diarization_onnx_stages.json")
        }
        let fixture = try JSONDecoder().decode(Community1StageFixture.self, from: Data(contentsOf: url))
        guard fixture.schemaVersion == 1 else {
            throw Community1TestError.invalid("stage fixture schema \(fixture.schemaVersion)")
        }
        return fixture
    }

    static func floats(_ text: String) throws -> [Float] {
        guard let data = Data(base64Encoded: text), data.count % 4 == 0 else {
            throw Community1TestError.invalid("fixture payload is not base64 Float32")
        }
        return data.withUnsafeBytes { raw in
            (0..<data.count / 4).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
    }
}

enum Community1TestError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    var description: String {
        switch self {
        case let .missing(what): "Community-1 test input is missing: \(what)"
        case let .invalid(reason): "Community-1 test input is invalid: \(reason)"
        }
    }
}

enum Community1ONNXTestInputs {
    static let modelDirectoryKey = "MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY"
    static let clipName = "qwen3_asr_voicevox_long"

    /// The directory `scripts/fetch_community1_diarization.py` printed. There is no default, and a
    /// missing or wrong value fails the test instead of skipping it.
    static func modelDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[modelDirectoryKey], !path.isEmpty else {
            throw Community1TestError.missing("environment variable \(modelDirectoryKey)")
        }
        guard (path as NSString).isAbsolutePath else {
            throw Community1TestError.invalid("\(modelDirectoryKey) must be an absolute path: \(path)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Community1TestError.invalid("\(modelDirectoryKey) is not an existing directory: \(path)")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The VOICEVOX clip as 16 kHz mono samples (canonical 44-byte PCM16 header).
    static func clipSamples() throws -> [Float] {
        guard let url = Bundle.module.url(forResource: clipName, withExtension: "wav", subdirectory: "Resources") else {
            throw Community1TestError.missing("\(clipName).wav")
        }
        let bytes = [UInt8](try Data(contentsOf: url))
        func le32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        guard bytes.count > 44,
              String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<16], as: UTF8.self) == "WAVEfmt ",
              String(decoding: bytes[36..<40], as: UTF8.self) == "data",
              le32(24) == 16_000, bytes[22] == 1, bytes[34] == 16,
              le32(40) == bytes.count - 44
        else {
            throw Community1TestError.invalid("\(clipName).wav is not a canonical mono 16 kHz PCM16 WAV")
        }
        return (0..<(bytes.count - 44) / 2).map { index in
            Float(Int16(bitPattern: UInt16(bytes[44 + 2 * index]) | UInt16(bytes[45 + 2 * index]) << 8)) / 32_768
        }
    }

    static func window(of samples: [Float], at index: Int) throws -> WindowAudio {
        try Community1WindowPlan(sampleCount: Int64(samples.count)).window(at: index) { range in
            Array(samples[Int(range.lowerBound)..<Int(range.upperBound)])
        }
    }

    static func silenceWindow() throws -> WindowAudio {
        try Community1WindowPlan(sampleCount: Int64(Community1Profile.windowSamples)).window(at: 0) { range in
            [Float](repeating: 0, count: Int(range.count))
        }
    }

    static func cosine(_ left: [Float], _ right: [Float]) -> Double {
        var dot = 0.0
        var leftNorm = 0.0
        var rightNorm = 0.0
        for (a, b) in zip(left, right) {
            dot += Double(a) * Double(b)
            leftNorm += Double(a) * Double(a)
            rightNorm += Double(b) * Double(b)
        }
        return dot / (leftNorm.squareRoot() * rightNorm.squareRoot())
    }
}

/// A canonical CAF: `desc` (16 kHz mono float32 LPCM), then an exact `data` chunk.
func canonicalCAFData(samples: [Float]) -> Data {
    func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }
    var bytes = Array("caff".utf8) + bigEndian(UInt16(1)) + bigEndian(UInt16(0))
    bytes += Array("desc".utf8) + bigEndian(Int64(32))
    bytes += bigEndian(Double(16_000).bitPattern) + Array("lpcm".utf8) + bigEndian(UInt32(3))
    bytes += bigEndian(UInt32(4)) + bigEndian(UInt32(1)) + bigEndian(UInt32(1)) + bigEndian(UInt32(32))
    bytes += Array("data".utf8) + bigEndian(Int64(4 + samples.count * 4)) + bigEndian(UInt32(0))
    for sample in samples {
        bytes += withUnsafeBytes(of: sample.bitPattern.littleEndian) { Array($0) }
    }
    return Data(bytes)
}

/// A temporary session directory that holds one CAF.
struct Community1CAFSession {
    let root: URL
    let cafURL: URL

    init(samples: [Float]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Community1CAF-\(UUID().uuidString)")
        try SessionFileAccess.createDirectory(root, relativeTo: root)
        cafURL = root.appendingPathComponent("input.caf")
        try SessionFileAccess.writeAtomically(canonicalCAFData(samples: samples), to: cafURL, relativeTo: root)
    }

    func cleanup() {
        try? SessionFileAccess.removeIfPresent(root, relativeTo: root.deletingLastPathComponent())
    }
}
