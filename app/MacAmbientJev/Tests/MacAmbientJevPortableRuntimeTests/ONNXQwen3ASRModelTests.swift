import Foundation
import MacAmbientJevCore
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
