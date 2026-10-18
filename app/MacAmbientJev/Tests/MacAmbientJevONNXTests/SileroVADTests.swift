import Foundation
import Testing
import MacAmbientJevONNX

struct SileroVADTests {
    private let environment: ONNXEnvironment
    private let modelURL: URL

    init() throws {
        modelURL = try SileroModelPath.modelURL(environment: ProcessInfo.processInfo.environment)
        environment = try ONNXEnvironment(loggingID: "SileroVADTests")
    }

    @Test
    func consecutiveSilenceFramesRemainBelowThreshold() throws {
        let vad = try makeVAD()
        let silence = [Float](repeating: 0, count: SileroVAD.frameSamples)

        for frameIndex in 0..<128 {
            let probability = try vad.speechProbability(frame: silence)
            #expect(probability < 0.1, "沈黙フレーム\(frameIndex)の確率: \(probability)")
        }
    }

    @Test
    func voicedSpeechFramesReachProbabilityThreshold() throws {
        let frames = try speechFrames()
        #expect(frames.count == 141)

        let voicedFrames = frames.filter(isVoiced)
        try #require(voicedFrames.count >= 100)

        let vad = try makeVAD()
        let probabilities = try infer(frames, using: vad)
        let highProbabilityVoicedCount = zip(frames, probabilities).reduce(into: 0) { count, pair in
            if isVoiced(pair.0) && pair.1 >= 0.5 {
                count += 1
            }
        }
        #expect(Double(highProbabilityVoicedCount) / Double(voicedFrames.count) >= 0.70)
    }

    @Test
    func resetReplaysExactlyAndClearsSpeechContext() throws {
        let frames = try speechFrames()
        let vad = try makeVAD()
        let firstRun = try infer(frames, using: vad)

        vad.reset()
        let secondRun = try infer(frames, using: vad)
        #expect(firstRun.map { $0.bitPattern } == secondRun.map { $0.bitPattern })

        vad.reset()
        let silenceFrames = [[Float]](repeating: [Float](repeating: 0, count: SileroVAD.frameSamples), count: 128)
        let afterSpeechReset = try infer(silenceFrames, using: vad)
        let freshVAD = try makeVAD()
        let freshSilence = try infer(silenceFrames, using: freshVAD)
        #expect(afterSpeechReset.map { $0.bitPattern } == freshSilence.map { $0.bitPattern })
    }

    @Test
    func upstreamReferenceProbabilitiesMatchContinuousInference() throws {
        let frames = try speechFrames()
        let references = try referenceFixture()
        #expect(references.sampleRate == 16_000)
        #expect(references.frameSamples == SileroVAD.frameSamples)
        #expect(references.frameCount == 141)
        try #require(frames.count == references.frameCount)
        try #require(references.references.count >= 10)
        try #require(references.references.allSatisfy { frames.indices.contains($0.frameIndex) })

        let vad = try makeVAD()
        let probabilities = try infer(frames, using: vad)
        for reference in references.references {
            let actual = probabilities[reference.frameIndex]
            #expect(abs(Double(actual) - reference.probability) <= 1e-4,
                    "frame \(reference.frameIndex): expected \(reference.probability), got \(actual)")
        }
    }

    @Test
    func invalidFrameCountsReportExpectedAndActualSampleCounts() throws {
        let vad = try makeVAD()

        for count in [0, 1, 64, 511, 513, 576, 1024] {
            let message = onnxErrorMessage {
                _ = try vad.speechProbability(frame: [Float](repeating: 0, count: count))
            }
            #expect(message.contains(String(SileroVAD.frameSamples)))
            #expect(message.contains(String(count)))
        }
    }

    @Test
    func invalidInputsDoNotChangeStateOrContext() throws {
        let frames = try speechFrames()
        let cleanVAD = try makeVAD()
        let cleanProbabilities = try infer(frames, using: cleanVAD)

        let vad = try makeVAD()
        _ = try infer(Array(frames.prefix(2)), using: vad)
        for count in [511, 513] {
            #expect(throws: ONNXRuntimeError.self) {
                _ = try vad.speechProbability(frame: [Float](repeating: 0, count: count))
            }
        }
        for invalidValue in [Float.nan, Float.infinity, -Float.infinity] {
            var invalidFrame = [Float](repeating: 0, count: SileroVAD.frameSamples)
            invalidFrame[0] = invalidValue
            #expect(throws: ONNXRuntimeError.self) {
                _ = try vad.speechProbability(frame: invalidFrame)
            }
        }

        let probabilitiesAfterInvalidInputs = try infer(Array(frames.dropFirst(2)), using: vad)
        #expect(probabilitiesAfterInvalidInputs.map { $0.bitPattern } == cleanProbabilities.dropFirst(2).map { $0.bitPattern })
    }

    private func makeVAD() throws -> SileroVAD {
        try SileroVAD(environment: environment, modelURL: modelURL, intraOpThreads: 1)
    }
}

private struct SileroReferenceFixture: Decodable {
    let sampleRate: Int
    let frameSamples: Int
    let frameCount: Int
    let references: [SileroProbabilityReference]
}

private struct SileroProbabilityReference: Decodable {
    let frameIndex: Int
    let probability: Double
}

private enum SileroModelPath {
    static func modelURL(environment: [String: String]) throws -> URL {
        guard let path = environment["MAC_AMBIENT_JEV_SILERO_MODEL"], !path.isEmpty else {
            throw modelPathError("環境変数MAC_AMBIENT_JEV_SILERO_MODELが未設定または空です。")
        }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw modelPathError("指定されたSilero VADモデルファイルが存在しないか、通常ファイルではありません: \(url.path)。")
        }
        return url
    }
}

private func modelPathError(_ reason: String) -> SileroFixtureError {
    .invalid("\(reason) \(fetchCommand)を実行し、取得されたモデルの絶対パスを環境変数MAC_AMBIENT_JEV_SILERO_MODELに設定してください。")
}

private var fetchCommand: String {
    #if os(Windows)
    "python scripts/fetch_silero_vad.py"
    #else
    "python3 scripts/fetch_silero_vad.py"
    #endif
}

private func speechFrames() throws -> [[Float]] {
    guard let audioURL = Bundle.module.url(
        forResource: "silero_speech",
        withExtension: "wav",
        subdirectory: "Resources"
    ) else {
        throw SileroFixtureError.invalid("Resources/silero_speech.wavが見つかりません。")
    }
    let data = try Data(contentsOf: audioURL)
    let bytes = [UInt8](data)
    guard bytes.count >= 44 else {
        throw SileroFixtureError.invalid("silero_speech.wavのRIFF/WAVEヘッダーが44バイト未満です。")
    }
    guard fourCC(bytes, at: 0) == "RIFF",
          littleEndianUInt32(bytes, at: 4) == UInt32(bytes.count - 8),
          fourCC(bytes, at: 8) == "WAVE",
          fourCC(bytes, at: 12) == "fmt ",
          littleEndianUInt32(bytes, at: 16) == 16,
          littleEndianUInt16(bytes, at: 20) == 1,
          littleEndianUInt16(bytes, at: 22) == 1,
          littleEndianUInt32(bytes, at: 24) == 16_000,
          littleEndianUInt32(bytes, at: 28) == 32_000,
          littleEndianUInt16(bytes, at: 32) == 2,
          littleEndianUInt16(bytes, at: 34) == 16,
          fourCC(bytes, at: 36) == "data" else {
        throw SileroFixtureError.invalid("silero_speech.wavは44バイトの標準PCM16・モノラル・16kHz WAVE形式ではありません。")
    }

    let payloadByteCount = Int(littleEndianUInt32(bytes, at: 40))
    guard payloadByteCount == bytes.count - 44,
          payloadByteCount.isMultiple(of: 2),
          (payloadByteCount / 2).isMultiple(of: SileroVAD.frameSamples) else {
        throw SileroFixtureError.invalid("silero_speech.wavのdataサイズがヘッダーまたは\(SileroVAD.frameSamples)サンプル境界と一致しません。")
    }

    let sampleCount = payloadByteCount / 2
    let samples = (0..<sampleCount).map { sampleIndex -> Float in
        let byteOffset = 44 + sampleIndex * 2
        let value = Int16(bitPattern: littleEndianUInt16(bytes, at: byteOffset))
        return Float(value) / 32_768
    }
    return stride(from: 0, to: samples.count, by: SileroVAD.frameSamples).map { frameStart in
        Array(samples[frameStart..<(frameStart + SileroVAD.frameSamples)])
    }
}

private func referenceFixture() throws -> SileroReferenceFixture {
    guard let referenceURL = Bundle.module.url(
        forResource: "silero_reference",
        withExtension: "json",
        subdirectory: "Resources"
    ) else {
        throw SileroFixtureError.invalid("Resources/silero_reference.jsonが見つかりません。")
    }
    return try JSONDecoder().decode(SileroReferenceFixture.self, from: Data(contentsOf: referenceURL))
}

private func infer(_ frames: [[Float]], using vad: SileroVAD) throws -> [Float] {
    try frames.map { try vad.speechProbability(frame: $0) }
}

private func isVoiced(_ frame: [Float]) -> Bool {
    let meanSquare = frame.reduce(0.0) { sum, sample in
        sum + Double(sample) * Double(sample)
    } / Double(frame.count)
    return meanSquare.squareRoot() >= 0.01
}

private func fourCC(_ bytes: [UInt8], at offset: Int) -> String {
    String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
}

private func littleEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

private func onnxErrorMessage(_ operation: () throws -> Void) -> String {
    do {
        try operation()
        Issue.record("ONNX Runtimeエラーが必要です。")
    } catch let error as ONNXRuntimeError {
        return error.message
    } catch let error as SileroFixtureError {
        return error.localizedDescription
    } catch {
        Issue.record("ONNX Runtimeエラーではありません: \(error)")
    }
    return ""
}

private enum SileroFixtureError: Error, LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}
