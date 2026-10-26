import Foundation
#if os(Windows)
import WinSDK
#endif
import MacAmbientJevCore
import MacAmbientJevONNX
import Testing
@testable import MacAmbientJevPortableRuntime

struct Qwen3ASRModelTestConfiguration {
    static let directoryEnvironmentKey = "QWEN3_ASR_ONNX_MODEL_DIRECTORY"
    static let sizeEnvironmentKey = "QWEN3_ASR_ONNX_MODEL_SIZE"

    let directory: URL
    let size: Qwen3ASRModelSize

    init(environment: [String: String]) throws {
        guard let directoryPath = environment[Self.directoryEnvironmentKey] else {
            throw Qwen3ASRModelTestConfigurationError.invalid(
                key: Self.directoryEnvironmentKey,
                reason: "is required"
            )
        }
        guard !directoryPath.isEmpty else {
            throw Qwen3ASRModelTestConfigurationError.invalid(
                key: Self.directoryEnvironmentKey,
                reason: "must not be empty"
            )
        }
        guard (directoryPath as NSString).isAbsolutePath else {
            throw Qwen3ASRModelTestConfigurationError.invalid(
                key: Self.directoryEnvironmentKey,
                reason: "must be an absolute path"
            )
        }

        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let fileManager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: directory.path)
        } catch {
            throw Qwen3ASRModelTestConfigurationError.invalid(
                key: Self.directoryEnvironmentKey,
                reason: "does not name an existing readable directory: \(directoryPath)"
            )
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw Qwen3ASRModelTestConfigurationError.invalid(
                key: Self.directoryEnvironmentKey,
                reason: "must name a directory: \(directoryPath)"
            )
        }
        guard fileManager.isReadableFile(atPath: directory.path) else {
            throw Qwen3ASRModelTestConfigurationError.invalid(
                key: Self.directoryEnvironmentKey,
                reason: "must name a readable directory: \(directoryPath)"
            )
        }

        guard let sizeValue = environment[Self.sizeEnvironmentKey] else {
            throw Qwen3ASRModelTestConfigurationError.invalid(
                key: Self.sizeEnvironmentKey,
                reason: "is required"
            )
        }
        guard let size = Qwen3ASRModelSize(rawValue: sizeValue) else {
            throw Qwen3ASRModelTestConfigurationError.invalid(
                key: Self.sizeEnvironmentKey,
                reason: "must be exactly 0.6b or 1.7b"
            )
        }

        self.directory = directory
        self.size = size
    }
}

enum Qwen3ASRModelTestConfigurationError: Error, LocalizedError {
    case invalid(key: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .invalid(key, reason):
            "\(key) \(reason)."
        }
    }
}

struct Qwen3ASRModelValidationTests {
    @Test
    func publicValidatorReportsInvalidDirectoryMissingAssetsAndWrongSize() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "Qwen3ASRModelValidationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let invalidDirectory = root.appendingPathComponent("not-a-directory")
        try Data().write(to: invalidDirectory)
        let invalidDirectoryError = modelValidationError {
            try Qwen3ASRModelSize.small.validate(directory: invalidDirectory)
        }
        #expect(invalidDirectoryError?.contains("パスがディレクトリではありません") == true)

        let modelDirectory = root.appendingPathComponent("missing-assets", isDirectory: true)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: false)
        let modelSize = Qwen3ASRModelSize.small
        let firstFile = try #require(modelSize.files.first)
        let missingAssetError = modelValidationError {
            try modelSize.validate(directory: modelDirectory)
        }
        #expect(missingAssetError?.contains(firstFile.name) == true)
        #expect(missingAssetError?.contains("ファイル情報を取得できません") == true)

        try Data().write(to: modelDirectory.appendingPathComponent(firstFile.name))
        let wrongSizeError = modelValidationError {
            try modelSize.validate(directory: modelDirectory)
        }
        #expect(wrongSizeError?.contains(firstFile.name) == true)
        #expect(wrongSizeError?.contains("モデルファイルのサイズが一致しません") == true)
        #expect(
            wrongSizeError?.contains("期待値: \(firstFile.byteCount) bytes, 実際: 0 bytes") == true
        )
    }
}

private func modelValidationError(_ validate: () throws -> Void) -> String? {
    do {
        try validate()
        return nil
    } catch let Qwen3ASRModelError.invalid(message) {
        return message
    } catch {
        return "unexpected error: \(error)"
    }
}

@Suite(.serialized)
struct ONNXQwen3ASRModelTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1",
            "Set RUN_MODEL_TESTS=1 and provide the ONNX model directory and size to run inference."
        )
    )
    func transcribesJapaneseFixtures() async throws {
        let configuration = try Qwen3ASRModelTestConfiguration(
            environment: ProcessInfo.processInfo.environment
        )
        let engine = ONNXQwen3ASREngine(
            modelDirectory: configuration.directory,
            size: configuration.size,
            intraOpThreads: 2
        )
        let sampleRate = 16_000
        let fixtures = [
            JapaneseFixtureDescriptor(
                id: "short",
                resourceName: "qwen3_asr_voicevox_short",
                sampleCount: 52_907,
                reference: "今日は音声認識の動作を確認します。",
                // Measured 0.0 CER baseline with a 0.05 margin.
                maximumCER: 0.05,
                long: false
            ),
            JapaneseFixtureDescriptor(
                id: "long",
                resourceName: "qwen3_asr_voicevox_long",
                sampleCount: 295_424,
                reference: "通信相手を認証したあと、セッション鍵を共有し、その鍵を使って以降の通信内容を暗号化する流れを考えます。今日の講義ではベイズ推定について説明します。この場合、公開鍵はどこで配布されるのでしょうか。",
                // Measured 0.0879121 CER baseline with a 0.0620879 margin.
                maximumCER: 0.15,
                long: true
            ),
        ]

        do {
            try await engine.prepare()

            let emptyInputResult = try await engine.transcribe(
                ASRAudioInput(samples: [], sampleRate: sampleRate)
            )
            #expect(emptyInputResult.text.isEmpty)
            #expect(emptyInputResult.detectedLanguage == nil)

            let belowMinimumResult = try await engine.transcribe(
                ASRAudioInput(samples: Array(repeating: 0, count: 319), sampleRate: sampleRate)
            )
            #expect(belowMinimumResult.text.isEmpty)
            #expect(belowMinimumResult.detectedLanguage == nil)

            let clock = ContinuousClock()
            for fixture in fixtures {
                let fixtureURL = try #require(
                    Bundle.module.url(
                        forResource: fixture.resourceName,
                        withExtension: "wav",
                        subdirectory: "Resources"
                    )
                )
                let audio = try readJapaneseFixture(at: fixtureURL)
                #expect(audio.samples.count == fixture.sampleCount)

                let audioSeconds = Double(audio.samples.count) / Double(audio.sampleRate)
                if fixture.long {
                    #expect(audioSeconds > 15)
                } else {
                    #expect((3.0...6.0).contains(audioSeconds))
                }

                let firstStart = clock.now
                let firstResult = try await engine.transcribe(audio.input)
                let firstElapsed = firstStart.duration(to: clock.now)
                let firstCER = CharacterErrorRate.evaluate(
                    reference: normalizedForFixtureCER(fixture.reference),
                    hypothesis: normalizedForFixtureCER(firstResult.text)
                )

                #expect(!firstResult.text.isEmpty)
                #expect(firstResult.detectedLanguage == nil)
                try expectJapaneseText(firstResult.text)
                printFixtureMetrics(
                    clipID: fixture.id,
                    pass: "first",
                    size: configuration.size,
                    audioSeconds: audioSeconds,
                    transcript: firstResult.text,
                    reference: fixture.reference,
                    cer: firstCER.rate,
                    elapsed: firstElapsed
                )
                #expect(firstCER.rate <= fixture.maximumCER)

                let repeatStart = clock.now
                let repeatResult = try await engine.transcribe(audio.input)
                let repeatElapsed = repeatStart.duration(to: clock.now)
                let repeatCER = CharacterErrorRate.evaluate(
                    reference: normalizedForFixtureCER(fixture.reference),
                    hypothesis: normalizedForFixtureCER(repeatResult.text)
                )

                #expect(repeatResult.text == firstResult.text)
                #expect(!repeatResult.text.isEmpty)
                #expect(repeatResult.detectedLanguage == nil)
                try expectJapaneseText(repeatResult.text)
                printFixtureMetrics(
                    clipID: fixture.id,
                    pass: "repeat",
                    size: configuration.size,
                    audioSeconds: audioSeconds,
                    transcript: repeatResult.text,
                    reference: fixture.reference,
                    cer: repeatCER.rate,
                    elapsed: repeatElapsed
                )

            }

            await engine.unload()
        } catch {
            await engine.unload()
            throw error
        }
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"
                && ProcessInfo.processInfo.environment[Qwen3ASRModelTestConfiguration.sizeEnvironmentKey] != "1.7b",
            "Set RUN_MODEL_TESTS=1 with the 0.6b ONNX model to run exact token parity."
        )
    )
    func exactTokenParity() async throws {
        let configuration = try Qwen3ASRModelTestConfiguration(
            environment: ProcessInfo.processInfo.environment
        )
        let reference = try loadQwen3ASRTokenReference()
        try validateQwen3ASRTokenReference(reference)
        print(
            "Qwen3-ASR token parity reference platform=\(reference.reference.platform) "
                + "architecture=\(reference.reference.architecture) "
                + "intra_op_threads=\(reference.reference.intraOpThreads)"
        )
        #expect(configuration.size == .small)
        #expect(reference.schemaVersion == 1)
        #expect(reference.model.size == configuration.size.rawValue)
        #expect(reference.model.commit == configuration.size.commit)
        #expect(reference.reference.packages["onnxruntime"] == "1.31.0")
        #expect(ONNXEnvironment.runtimeVersion == "1.31.0")
        #expect(reference.reference.packages["numpy"] == "2.2.6")
        #expect(reference.reference.packages["transformers"] == "4.57.1")
        #expect(reference.reference.packages["tokenizers"] == "0.22.2")

        let expectedFiles = configuration.size.files.map {
            Qwen3ASRTokenReference.ModelFile(name: $0.name, sha256: $0.sha256, byteCount: $0.byteCount)
        }.sorted { $0.name < $1.name }
        #expect(reference.model.files.sorted { $0.name < $1.name } == expectedFiles)
        #expect(reference.clips.map(\.id) == ["short", "long"])

        let intraOpThreads = 2
        print(
            "Qwen3-ASR token parity run platform=\(qwen3ASRParityPlatform) "
                + "architecture=\(qwen3ASRParityArchitecture) intra_op_threads=\(intraOpThreads)"
        )
        let engine = ONNXQwen3ASREngine(
            modelDirectory: configuration.directory,
            size: configuration.size,
            intraOpThreads: intraOpThreads
        )
        do {
            try await engine.prepare()
            for clip in reference.clips {
                let audio = try readJapaneseFixture(at: try fixtureURL(named: clip.file))
                #expect(audio.samples.count == clip.sampleCount)

                let transcription = try await engine.transcribeWithTokens(audio.input)
                let expectedIDs = clip.generatedIds
                let actualIDs = transcription.generatedIDs
                let lastActualID = try #require(
                    actualIDs.last,
                    "decoding parity FAIL clip_id=\(clip.id) actual generated IDs must be nonempty"
                )
                let actualEndedAtTokenCap = actualIDs.count == reference.reference.maxNewTokens
                    && !Qwen3ASRToken.stopTokens.contains(lastActualID)
                #expect(
                    actualEndedAtTokenCap == clip.endedAtTokenCap,
                    "decoding parity FAIL clip_id=\(clip.id) expected_ended_at_token_cap=\(clip.endedAtTokenCap) actual_ended_at_token_cap=\(actualEndedAtTokenCap)"
                )
                if expectedIDs != actualIDs {
                    let sharedLength = min(expectedIDs.count, actualIDs.count)
                    let firstDifference: Int? = (0..<sharedLength).first {
                        expectedIDs[$0] != actualIDs[$0]
                    } ?? (expectedIDs.count == actualIDs.count ? nil : sharedLength)
                    if let firstDifference {
                        let expectedID = firstDifference < expectedIDs.count
                            ? String(expectedIDs[firstDifference]) : "<end>"
                        let actualID = firstDifference < actualIDs.count
                            ? String(actualIDs[firstDifference]) : "<end>"
                        print(
                            "Qwen3-ASR token parity FAIL clip_id=\(clip.id) "
                                + "first_difference_index=\(firstDifference) expected_id=\(expectedID) "
                                + "actual_id=\(actualID) expected_length=\(expectedIDs.count) "
                                + "actual_length=\(actualIDs.count)"
                        )
                    }
                } else {
                    print("Qwen3-ASR token parity PASS clip_id=\(clip.id) tokens=\(actualIDs.count)")
                }
                #expect(actualIDs == expectedIDs, "decoding parity FAIL clip_id=\(clip.id) generated IDs differ")
                #expect(transcription.text == clip.text, "decoding parity FAIL clip_id=\(clip.id) transcript differs")
            }
        } catch {
            await engine.unload()
            throw error
        }
        await engine.unload()
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["QWEN3_ASR_MEMORY_BENCHMARK"] == "1"
                && ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1",
            "Set QWEN3_ASR_MEMORY_BENCHMARK=1 and RUN_MODEL_TESTS=1 to run the memory benchmark."
        )
    )
    func memoryOverManyCalls() async throws {
        let configuration = try Qwen3ASRModelTestConfiguration(
            environment: ProcessInfo.processInfo.environment
        )
        let audio = try readJapaneseFixture(
            at: fixtureURL(named: "qwen3_asr_voicevox_long.wav")
        )
        let input = audio.input
        let audioSeconds = Double(audio.samples.count) / Double(audio.sampleRate)
        let engine = ONNXQwen3ASREngine(
            modelDirectory: configuration.directory,
            size: configuration.size,
            intraOpThreads: 2
        )

        do {
            try await engine.prepare()
            try printResidentMemory(label: "after_prepare")

            let clock = ContinuousClock()
            let totalStart = clock.now
            var expectedText: String?
            for call in 1...50 {
                let callStart = clock.now
                let result = try await engine.transcribe(input)
                let elapsed = callStart.duration(to: clock.now)
                #expect(!result.text.isEmpty)
                if let expectedText {
                    #expect(result.text == expectedText)
                } else {
                    expectedText = result.text
                }
                let elapsedSeconds = seconds(elapsed)
                print(
                    "Qwen3-ASR memory call=\(call) elapsed_seconds=\(elapsedSeconds) "
                        + "rtf=\(elapsedSeconds / audioSeconds)"
                )
                if [1, 10, 25, 50].contains(call) {
                    try printResidentMemory(label: "after_call_\(call)")
                }
            }
            let totalElapsed = totalStart.duration(to: clock.now)
            print(
                "Qwen3-ASR memory summary calls=50 total_elapsed_seconds=\(seconds(totalElapsed)) "
                    + "rtf=\(seconds(totalElapsed) / (50 * audioSeconds))"
            )
        } catch {
            await engine.unload()
            throw error
        }
        await engine.unload()
        try printResidentMemory(label: "after_unload")
    }
}

struct Qwen3ASRTokenReferenceTests {
    @Test
    func validatesPromptAndMetadataWithoutModel() throws {
        try validateQwen3ASRTokenReference(loadQwen3ASRTokenReference())
    }
}

private struct Qwen3ASRTokenReference: Decodable {
    struct Model: Decodable {
        let size: String
        let commit: String
        let files: [ModelFile]
    }

    struct ModelFile: Decodable, Equatable {
        let name: String
        let sha256: String
        let byteCount: Int64
    }

    struct Reference: Decodable {
        let platform: String
        let architecture: String
        let intraOpThreads: Int
        let interOpThreads: Int
        let audioOffset: Int64
        let maxNewTokens: Int
        let packages: [String: String]
    }

    struct Clip: Decodable {
        let id: String
        let file: String
        let sampleCount: Int
        let promptIds: [Int64]
        let audioTokenCount: Int
        let noRepeatNgramSize: Int?
        let endedAtTokenCap: Bool
        let generatedIds: [Int64]
        let text: String
    }

    let schemaVersion: Int
    let model: Model
    let reference: Reference
    let clips: [Clip]
}

private func loadQwen3ASRTokenReference() throws -> Qwen3ASRTokenReference {
    let url = try #require(
        Bundle.module.url(
            forResource: "qwen3_asr_token_reference",
            withExtension: "json",
            subdirectory: "Resources"
        )
    )
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(Qwen3ASRTokenReference.self, from: Data(contentsOf: url))
}

private func validateQwen3ASRTokenReference(_ reference: Qwen3ASRTokenReference) throws {
    #expect(reference.reference.platform == "Linux", "reference parity FAIL platform")
    #expect(reference.reference.architecture == "aarch64", "reference parity FAIL architecture")
    #expect(reference.reference.intraOpThreads == 2, "reference parity FAIL intra-op threads")
    #expect(reference.reference.interOpThreads == 1, "reference parity FAIL inter-op threads")
    #expect(reference.reference.audioOffset == Qwen3ASRPrompt.audioOffset, "reference parity FAIL audio offset")
    #expect(reference.reference.maxNewTokens == 448, "reference parity FAIL max new tokens")
    #expect(reference.clips.map(\.id) == ["short", "long"], "prompt parity FAIL clip IDs")

    let expectedAudioTokenCounts = ["short": 43, "long": 240]
    for clip in reference.clips {
        let expectedAudioTokenCount = try #require(
            expectedAudioTokenCounts[clip.id],
            "prompt parity FAIL clip_id=\(clip.id) unknown reference clip"
        )
        #expect(
            clip.audioTokenCount == expectedAudioTokenCount,
            "prompt parity FAIL clip_id=\(clip.id) expected audio token count \(expectedAudioTokenCount)"
        )
        #expect(clip.audioTokenCount > 0, "prompt parity FAIL clip_id=\(clip.id) audio token count must be positive")
        let prompt = try Qwen3ASRPrompt(audioTokenCount: clip.audioTokenCount)
        _ = try #require(
            clip.promptIds == prompt.tokenIDs,
            "prompt parity FAIL clip_id=\(clip.id) prompt IDs differ"
        )

        let expectedNoRepeatNgramSize: Int? = clip.sampleCount > 15 * 16_000 ? 3 : nil
        #expect(
            clip.noRepeatNgramSize == expectedNoRepeatNgramSize,
            "decoding parity FAIL clip_id=\(clip.id) no-repeat n-gram size"
        )
        #expect(!clip.endedAtTokenCap, "decoding parity FAIL clip_id=\(clip.id) reference ended at token cap")
    }
}

private var qwen3ASRParityPlatform: String {
    #if os(Windows)
    "Windows"
    #elseif os(Linux)
    "Linux"
    #else
    #error("Qwen3-ASR token parity supports only Windows and Linux")
    #endif
}

private var qwen3ASRParityArchitecture: String {
    #if arch(arm64)
    "aarch64"
    #elseif arch(x86_64)
    "x86_64"
    #else
    #error("Qwen3-ASR token parity supports only arm64 and x86_64")
    #endif
}

private func fixtureURL(named filename: String) throws -> URL {
    let file = URL(fileURLWithPath: filename)
    return try #require(
        Bundle.module.url(
            forResource: file.deletingPathExtension().lastPathComponent,
            withExtension: file.pathExtension,
            subdirectory: "Resources"
        )
    )
}

private enum ResidentMemoryError: Error, LocalizedError {
    case invalidLinuxStatus(String)
    case windowsAPI(UInt32)
    case unsupportedPlatform

    var errorDescription: String? {
        switch self {
        case let .invalidLinuxStatus(reason):
            "Invalid /proc/self/status VmRSS value: \(reason)"
        case let .windowsAPI(code):
            "K32GetProcessMemoryInfo failed with GetLastError()=\(code)"
        case .unsupportedPlatform:
            "Resident-memory measurements are supported only on Linux and Windows."
        }
    }
}

private func printResidentMemory(label: String) throws {
    print("Qwen3-ASR memory phase=\(label) resident_bytes=\(try residentMemoryBytes())")
}

private func parseLinuxResidentMemoryBytes(_ status: String) throws -> UInt64 {
    let rssLines = status.split(whereSeparator: \.isNewline).filter { line in
        guard let colon = line.firstIndex(of: ":") else { return false }
        return line[..<colon] == "VmRSS"
    }
    guard rssLines.count == 1 else {
        throw ResidentMemoryError.invalidLinuxStatus("expected one VmRSS line, found \(rssLines.count)")
    }

    let line = String(rssLines[0])
    let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
    let pattern = try NSRegularExpression(pattern: #"^VmRSS:[\t ]+([0-9]+)[\t ]+kB[\t ]*$"#)
    guard let match = pattern.firstMatch(in: line, range: fullRange),
          match.range == fullRange,
          let valueRange = Range(match.range(at: 1), in: line),
          let kilobytes = UInt64(line[valueRange]),
          kilobytes > 0
    else {
        throw ResidentMemoryError.invalidLinuxStatus("expected exactly 'VmRSS: <positive integer> kB', found '\(line)'")
    }
    let (bytes, overflow) = kilobytes.multipliedReportingOverflow(by: 1024)
    guard !overflow else {
        throw ResidentMemoryError.invalidLinuxStatus("VmRSS kilobyte value overflows bytes: \(kilobytes)")
    }
    return bytes
}

private func residentMemoryBytes() throws -> UInt64 {
    #if os(Linux)
    let status = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
    return try parseLinuxResidentMemoryBytes(status)
    #elseif os(Windows)
    var counters = PROCESS_MEMORY_COUNTERS()
    let byteCount = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
    counters.cb = byteCount
    guard K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, byteCount) else {
        throw ResidentMemoryError.windowsAPI(UInt32(GetLastError()))
    }
    return UInt64(counters.WorkingSetSize)
    #else
    throw ResidentMemoryError.unsupportedPlatform
    #endif
}

private struct JapaneseFixtureDescriptor {
    let id: String
    let resourceName: String
    let sampleCount: Int
    let reference: String
    let maximumCER: Double
    let long: Bool
}

private struct JapaneseFixtureAudio {
    let samples: [Float]
    let sampleRate: Int

    var input: ASRAudioInput {
        ASRAudioInput(samples: samples, sampleRate: sampleRate)
    }
}

private enum JapaneseFixtureWAVError: Error, LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(reason):
            "Invalid Qwen3-ASR fixture WAV: \(reason)"
        }
    }
}

private func readJapaneseFixture(at url: URL) throws -> JapaneseFixtureAudio {
    let data = try Data(contentsOf: url)
    guard data.count >= 12,
          fourCC(data, at: 0) == "RIFF",
          fourCC(data, at: 8) == "WAVE"
    else {
        throw JapaneseFixtureWAVError.invalid("missing RIFF/WAVE header")
    }

    let riffSize = Int(littleEndianUInt32(data, at: 4))
    guard riffSize >= 4, riffSize == data.count - 8 else {
        throw JapaneseFixtureWAVError.invalid("RIFF chunk length does not match the file")
    }
    let riffEnd = 8 + riffSize
    var offset = 12
    var format: (channels: UInt16, sampleRate: UInt32, byteRate: UInt32, blockAlign: UInt16, bitsPerSample: UInt16)?
    var sampleDataRange: Range<Int>?

    while offset < riffEnd {
        guard offset <= riffEnd - 8 else {
            throw JapaneseFixtureWAVError.invalid("truncated chunk header")
        }
        let chunkID = fourCC(data, at: offset)
        let chunkSize = Int(littleEndianUInt32(data, at: offset + 4))
        let payloadStart = offset + 8
        guard chunkSize <= riffEnd - payloadStart else {
            throw JapaneseFixtureWAVError.invalid("chunk extends past the RIFF boundary")
        }
        let chunkEnd = payloadStart + chunkSize

        switch chunkID {
        case "fmt ":
            guard format == nil, chunkSize >= 16 else {
                throw JapaneseFixtureWAVError.invalid("invalid or duplicate fmt chunk")
            }
            guard littleEndianUInt16(data, at: payloadStart) == 1 else {
                throw JapaneseFixtureWAVError.invalid("audio encoding is not PCM")
            }
            format = (
                channels: littleEndianUInt16(data, at: payloadStart + 2),
                sampleRate: littleEndianUInt32(data, at: payloadStart + 4),
                byteRate: littleEndianUInt32(data, at: payloadStart + 8),
                blockAlign: littleEndianUInt16(data, at: payloadStart + 12),
                bitsPerSample: littleEndianUInt16(data, at: payloadStart + 14)
            )
        case "data":
            guard sampleDataRange == nil else {
                throw JapaneseFixtureWAVError.invalid("duplicate data chunk")
            }
            sampleDataRange = payloadStart..<chunkEnd
        default:
            break
        }

        let paddedEnd = chunkEnd + (chunkSize & 1)
        guard paddedEnd <= riffEnd else {
            throw JapaneseFixtureWAVError.invalid("missing padding after an odd-sized chunk")
        }
        offset = paddedEnd
    }

    guard let format, let sampleDataRange else {
        throw JapaneseFixtureWAVError.invalid("missing fmt or data chunk")
    }
    guard format.channels == 1,
          format.sampleRate == 16_000,
          format.byteRate == 32_000,
          format.blockAlign == 2,
          format.bitsPerSample == 16
    else {
        throw JapaneseFixtureWAVError.invalid("expected mono PCM16 at 16 kHz")
    }
    guard sampleDataRange.count.isMultiple(of: 2) else {
        throw JapaneseFixtureWAVError.invalid("PCM16 data has an incomplete sample")
    }

    var samples: [Float] = []
    samples.reserveCapacity(sampleDataRange.count / 2)
    for offset in stride(from: sampleDataRange.lowerBound, to: sampleDataRange.upperBound, by: 2) {
        let bits = littleEndianUInt16(data, at: offset)
        samples.append(Float(Int16(bitPattern: bits)) / 32_768)
    }
    return JapaneseFixtureAudio(samples: samples, sampleRate: Int(format.sampleRate))
}

private func fourCC(_ data: Data, at offset: Int) -> String {
    String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
}

private func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

private func normalizedForFixtureCER(_ text: String) -> String {
    let stripped = text.unicodeScalars.filter {
        !CharacterSet.whitespacesAndNewlines.contains($0)
            && !CharacterSet.punctuationCharacters.contains($0)
    }
    return String(String.UnicodeScalarView(stripped))
}

private func expectJapaneseText(_ text: String) throws {
    let japaneseScript = try NSRegularExpression(
        pattern: #"\p{sc=Hiragana}|\p{sc=Katakana}|\p{sc=Han}"#
    )
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    _ = try #require(japaneseScript.firstMatch(in: text, range: range))
}

private func printFixtureMetrics(
    clipID: String,
    pass: String,
    size: Qwen3ASRModelSize,
    audioSeconds: Double,
    transcript: String,
    reference: String,
    cer: Double,
    elapsed: Duration
) {
    #if DEBUG
    let build = "debug"
    #else
    let build = "release"
    #endif
    print(
        "Qwen3-ASR clip_id=\(clipID) pass=\(pass) size=\(size.rawValue) build=\(build) "
            + "duration_seconds=\(audioSeconds) transcript=\(transcript) reference=\(reference) "
            + "cer=\(cer) elapsed_seconds=\(seconds(elapsed)) rtf=\(seconds(elapsed) / audioSeconds)"
    )
}

private func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
