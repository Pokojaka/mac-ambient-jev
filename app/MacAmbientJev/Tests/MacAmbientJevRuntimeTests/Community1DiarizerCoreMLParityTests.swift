#if os(macOS)
@preconcurrency import CoreML
import FluidAudio
import Foundation
import MacAmbientJevCore
@testable import MacAmbientJevDiarization
@testable import MacAmbientJevRuntime
import Testing

private enum Community1CoreMLError: Error, CustomStringConvertible {
    case invalidEnvironment(String)
    case invalidWAV(String)
    case invalidModelIO(String)
    case synthesisFailed(String)
    case missingClip(String)

    var description: String {
        switch self {
        case .invalidEnvironment(let reason): return "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY: \(reason)"
        case .invalidWAV(let reason): return "Invalid WAV: \(reason)"
        case .invalidModelIO(let reason): return "Invalid Core ML model I/O: \(reason)"
        case .synthesisFailed(let reason): return "Two-speaker synthesis failed: \(reason)"
        case .missingClip(let path): return "Test clip is missing: \(path)"
        }
    }
}

/// Test-only Core ML implementation of the kernel's two operations. It feeds the same compiled
/// models FluidAudio uses: the portable fbank output goes into `Embedding.mlmodelc` once per mask,
/// with the cleaned 589-frame activity as `weights`, which the graph interpolates itself.
private final class CoreMLCommunity1Inference: Community1Inference {
    private let segmentation: MLModel
    private let embedding: MLModel
    private let segmentationOutputName: String

    init(segmentation: MLModel, embedding: MLModel) throws {
        self.segmentation = segmentation
        self.embedding = embedding
        let outputs = Set(segmentation.modelDescription.outputDescriptionsByName.keys)
        if outputs.contains("segments") {
            segmentationOutputName = "segments"
        } else if outputs.contains("log_probs") {
            segmentationOutputName = "log_probs"
        } else {
            throw Community1CoreMLError.invalidModelIO("segmentation outputs \(outputs.sorted())")
        }
    }

    func segment(_ window: WindowAudio) throws -> PowersetScores {
        let input = try MLMultiArray(shape: [1, 1, NSNumber(value: Community1Profile.windowSamples)], dataType: .float32)
        window.samples.withUnsafeBufferPointer { buffer in
            input.dataPointer.copyMemory(from: buffer.baseAddress!, byteCount: buffer.count * MemoryLayout<Float>.size)
        }
        let output = try segmentation.prediction(from: MLDictionaryFeatureProvider(
            dictionary: ["audio": MLFeatureValue(multiArray: input)]
        ))
        let array = try #require(output.featureValue(for: segmentationOutputName)?.multiArrayValue)
        return try PowersetScores(logProbabilities: contiguousFloats(
            array,
            shape: [1, Community1Profile.segmentationFrames, Community1Profile.powersetClasses]
        ))
    }

    func embed(features: Community1FbankFeatures, masks: [SpeakerMask]) throws -> [[Float]] {
        let melBins = Community1Profile.melBins
        let frames = Community1Profile.fbankFrames
        let fbank = try MLMultiArray(shape: [1, 1, NSNumber(value: melBins), NSNumber(value: frames)], dataType: .float32)
        let fbankPointer = fbank.dataPointer.assumingMemoryBound(to: Float.self)
        guard fbank.strides.map(\.intValue) == [melBins * frames, melBins * frames, frames, 1] else {
            throw Community1CoreMLError.invalidModelIO("fbank input strides \(fbank.strides)")
        }
        for frame in 0..<frames {
            for mel in 0..<melBins {
                fbankPointer[mel * frames + frame] = features.values[frame * melBins + mel]
            }
        }
        return try masks.map { mask in
            let weights = try MLMultiArray(shape: [1, NSNumber(value: Community1Profile.segmentationFrames)], dataType: .float32)
            let weightPointer = weights.dataPointer.assumingMemoryBound(to: Float.self)
            for (index, value) in mask.activity.values.enumerated() { weightPointer[index] = value }
            let output = try embedding.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "fbank_features": MLFeatureValue(multiArray: fbank),
                "weights": MLFeatureValue(multiArray: weights)
            ]))
            let array = try #require(output.featureValue(for: "embedding")?.multiArrayValue)
            return try contiguousFloats(array, shape: [1, Community1Profile.embeddingDimensions])
        }
    }

    private func contiguousFloats(_ array: MLMultiArray, shape expected: [Int]) throws -> [Float] {
        let shape = array.shape.map(\.intValue)
        let flatShape = shape.filter { $0 != 1 }
        guard array.dataType == .float32, flatShape == expected.filter({ $0 != 1 }) else {
            throw Community1CoreMLError.invalidModelIO("output \(array.dataType.rawValue) \(shape); expected float32 \(expected)")
        }
        let strides = array.strides.map(\.intValue)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        let count = shape.reduce(1, *)
        var result = [Float](repeating: 0, count: count)
        var index = [Int](repeating: 0, count: shape.count)
        for linear in 0..<count {
            var offset = 0
            for axis in 0..<shape.count { offset += index[axis] * strides[axis] }
            result[linear] = pointer[offset]
            var axis = shape.count - 1
            while axis >= 0 {
                index[axis] += 1
                if index[axis] < shape[axis] { break }
                index[axis] = 0
                axis -= 1
            }
        }
        return result
    }
}

private func canonicalSamples(ofWAVAt url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    func le16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
    func le32(_ offset: Int) -> Int { le16(offset) | le16(offset + 2) << 16 }
    guard data.count > 44, String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
          String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
        throw Community1CoreMLError.invalidWAV("not a RIFF/WAVE file")
    }
    var cursor = 12
    var formatChecked = false
    while cursor + 8 <= data.count {
        let id = String(decoding: data[cursor..<cursor + 4], as: UTF8.self)
        let size = le32(cursor + 4)
        let body = cursor + 8
        if id == "fmt " {
            guard le16(body) == 1, le16(body + 2) == 1, le32(body + 4) == 16_000, le16(body + 14) == 16 else {
                throw Community1CoreMLError.invalidWAV("expected mono 16 kHz PCM16")
            }
            formatChecked = true
        } else if id == "data" {
            guard formatChecked, body + size <= data.count, size % 2 == 0 else {
                throw Community1CoreMLError.invalidWAV("data chunk is truncated or precedes fmt")
            }
            return (0..<size / 2).map { index in
                Float(Int16(bitPattern: UInt16(le16(body + 2 * index)))) / 32_768
            }
        }
        cursor = body + size + (size & 1)
    }
    throw Community1CoreMLError.invalidWAV("no data chunk")
}

private func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw Community1CoreMLError.synthesisFailed(
            "\(executable) \(arguments.joined(separator: " ")) exited \(process.terminationStatus): \(message)"
        )
    }
}

/// Alternating turns of two macOS voices, synthesized into a temporary directory with `say` and
/// converted to 16 kHz mono PCM16 with `afconvert`. A missing voice makes `say` fail, so there is
/// no substitute voice.
private func synthesizedTwoSpeakerSamples() throws -> [Float] {
    let turns: [(voice: String, text: String)] = [
        ("Kyoko", "こんにちは、今日は会議の進め方について少し相談させてください。まず先週の結果を簡単に振り返ってから、次の予定を決めたいと思います。"),
        ("Rocko (日本語（日本）)", "了解しました。先週は新しい機能の確認をして、いくつか細かい問題が見つかりました。それらを優先して直す方向で進めましょう。"),
        ("Kyoko", "ありがとうございます。それでは担当を分けて、金曜日までに一度全員で結果を見直す形にしましょう。"),
        ("Rocko (日本語（日本）)", "わかりました。私は画面まわりの修正を担当しますので、残りの確認作業をお願いします。")
    ]
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("community1-two-speaker-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    var samples: [Float] = []
    for (index, turn) in turns.enumerated() {
        let aiff = directory.appendingPathComponent("turn\(index).aiff").path
        let wav = directory.appendingPathComponent("turn\(index).wav").path
        try run("/usr/bin/say", ["-v", turn.voice, "-o", aiff, turn.text])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav])
        samples += try canonicalSamples(ofWAVAt: URL(fileURLWithPath: wav))
    }
    return samples
}

private func clipSamples(named clip: String) throws -> [Float] {
    if clip == "two_speaker_say" { return try synthesizedTwoSpeakerSamples() }
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("MacAmbientJevPortableRuntimeTests/Resources/\(clip).wav")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw Community1CoreMLError.missingClip(url.path)
    }
    return try canonicalSamples(ofWAVAt: url)
}

private func modelDirectory() throws -> URL {
    let name = "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY"
    guard let path = ProcessInfo.processInfo.environment[name], path.hasPrefix("/") else {
        throw Community1CoreMLError.invalidEnvironment("is required and must name an absolute existing directory")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw Community1CoreMLError.invalidEnvironment("does not exist or is not a directory: \(path)")
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

/// Label of the span covering each elementary interval between all boundaries of both span lists.
private func disagreement(portable: [SpeakerSpan], reference: [SpeakerSpan]) -> (samples: Int64, mapping: [String: String]) {
    let portableIDs = Array(Set(portable.map(\.speakerID))).sorted()
    let referenceIDs = Array(Set(reference.map(\.speakerID))).sorted()
    var boundaries = Set<Int64>()
    for span in portable + reference {
        boundaries.insert(span.startFrame)
        boundaries.insert(span.endFrame)
    }
    let points = boundaries.sorted()
    func label(_ spans: [SpeakerSpan], at point: Int64) -> String? {
        spans.first { $0.startFrame <= point && point < $0.endFrame }?.speakerID
    }
    var overlap: [String: [String: Int64]] = [:]
    var intervals: [(length: Int64, portable: String?, reference: String?)] = []
    for (lower, upper) in zip(points, points.dropFirst()) {
        let left = label(portable, at: lower)
        let right = label(reference, at: lower)
        intervals.append((upper - lower, left, right))
        if let left, let right { overlap[left, default: [:]][right, default: 0] += upper - lower }
    }
    var bestMapping: [String: String] = [:]
    var bestAgreement: Int64 = -1
    func search(_ index: Int, used: Set<String>, mapping: [String: String], agreement: Int64) {
        if index == portableIDs.count {
            if agreement > bestAgreement {
                bestAgreement = agreement
                bestMapping = mapping
            }
            return
        }
        search(index + 1, used: used, mapping: mapping, agreement: agreement)
        for candidate in referenceIDs where !used.contains(candidate) {
            var next = mapping
            next[portableIDs[index]] = candidate
            search(
                index + 1,
                used: used.union([candidate]),
                mapping: next,
                agreement: agreement + (overlap[portableIDs[index]]?[candidate] ?? 0)
            )
        }
    }
    search(0, used: [], mapping: [:], agreement: 0)
    var different: Int64 = 0
    for interval in intervals {
        let mapped = interval.portable.flatMap { bestMapping[$0] }
        if mapped != interval.reference { different += interval.length }
    }
    return (different, bestMapping)
}

@Suite(.serialized) struct Community1DiarizerCoreMLParityTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"),
        arguments: ["qwen3_asr_voicevox_long", "two_speaker_say"]
    )
    func portableKernelMatchesFluidAudio(clip: String) async throws {
        let directory = try modelDirectory()
        let names = ["Segmentation.mlmodelc", "Embedding.mlmodelc", "FBank.mlmodelc", "PldaRho.mlmodelc"]
        var modelURLs: [String: URL] = [:]
        for name in names { modelURLs[name] = directory.appendingPathComponent(name, isDirectory: true) }
        let models = try await loadOfflineDiarizerModelsUsingStaging(
            modelURLs: modelURLs,
            pldaJSONURL: directory.appendingPathComponent("plda-parameters.json", isDirectory: false)
        )

        let samples = try clipSamples(named: clip)
        let sampleCount = Int64(samples.count)

        let plda = try Community1PLDA(
            pldaData: Data(contentsOf: directory.appendingPathComponent("plda-parameters.json")),
            xvectorData: Data(contentsOf: directory.appendingPathComponent("xvector-transform.json")),
            coordinateSigns: Community1Manifest.bundled().coordinateSigns
        )
        let inference = try CoreMLCommunity1Inference(
            segmentation: models.segmentationModel,
            embedding: models.embeddingModel
        )
        let portableStart = Date()
        let portable = try Community1Diarizer(plda: plda).diarize(
            sampleCount: sampleCount,
            readFrames: { range in Array(samples[Int(range.lowerBound)..<Int(range.upperBound)]) },
            inference: inference
        )
        let portableSeconds = Date().timeIntervalSince(portableStart)

        let config = FluidOfflineDiarizationEngine.configuration
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let referenceStart = Date()
        let result = try await manager.process(audio: samples)
        let referenceSeconds = Date().timeIntervalSince(referenceStart)
        let reference = try FluidOfflineDiarizationEngine.mapSegments(
            result.segments,
            sampleCount: samples.count,
            config: config
        )

        let portableSpeakers = Set(portable.map(\.speakerID))
        let referenceSpeakers = Set(reference.map(\.speakerID))
        let comparison = disagreement(portable: portable, reference: reference)
        let frame = Int64((Double(Community1Profile.sampleRate) * 10 / 589).rounded(.up))
        var boundaryErrors: [Int64] = []
        if portable.count == reference.count {
            for (left, right) in zip(portable, reference) {
                boundaryErrors.append(abs(left.startFrame - right.startFrame))
                boundaryErrors.append(abs(left.endFrame - right.endFrame))
            }
        }
        print("PARITY clip=\(clip) samples=\(sampleCount) portableSpans=\(portable.count) referenceSpans=\(reference.count)")
        print("PARITY speakers portable=\(portableSpeakers.sorted()) reference=\(referenceSpeakers.sorted()) mapping=\(comparison.mapping)")
        print("PARITY differingSamples=\(comparison.samples) (\(Double(comparison.samples) / 16))ms maxBoundaryError=\(boundaryErrors.max() ?? -1) samples frame=\(frame)")
        print("PARITY seconds portable=\(portableSeconds) reference=\(referenceSeconds)")
        for span in portable { print("PARITY portable \(span.speakerID) \(span.startFrame)-\(span.endFrame)") }
        for span in reference { print("PARITY reference \(span.speakerID) \(span.startFrame)-\(span.endFrame)") }

        #expect(portableSpeakers.count == referenceSpeakers.count)
        #expect(portable.count == reference.count)
        #expect(boundaryErrors.allSatisfy { $0 <= frame })
        #expect(comparison.samples <= Int64(boundaryErrors.count) * frame)
    }
}
#endif
