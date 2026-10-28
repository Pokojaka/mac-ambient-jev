import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevONNX
@testable import MacAmbientJevPipeline
import MacAmbientJevPortableRuntime
@testable import MacAmbientJevTranscribeFile

@Suite("TranscribeFileTests")
struct TranscribeFileTests {
    private let optionNames = [
        "--silero-model",
        "--asr-model-directory",
        "--asr-model-size",
        "--threads",
        "--output",
        "--artifact-output"
    ]

    @Test
    func validArgumentsExposeEveryRequiredValueIncludingModelSize() throws {
        let input = "/tmp/transcribe/input.wav"
        let silero = "/tmp/transcribe/silero.onnx"
        let asrDirectory = "/tmp/transcribe/asr"
        let output = "/tmp/transcribe/output.json"
        let artifact = "/tmp/transcribe/artifact.json"
        let arguments = makeArguments(
            input: input,
            sileroModel: silero,
            asrModelDirectory: asrDirectory,
            modelSize: "1.7b",
            threads: "7",
            output: output,
            artifactOutput: artifact
        )

        let parsed = try TranscribeFileArguments.parse(arguments)

        #expect(parsed.inputURL == canonicalURL(input))
        #expect(parsed.sileroModelURL == canonicalURL(silero))
        #expect(parsed.asrModelDirectory == canonicalURL(asrDirectory))
        #expect(parsed.asrModelSize == .large)
        #expect(parsed.threads == 7)
        #expect(parsed.outputURL == canonicalURL(output))
        #expect(parsed.artifactOutputURL == canonicalURL(artifact))
    }

    @Test
    func optionPairsMayBeShuffled() throws {
        let input = "/tmp/shuffled/input.wav"
        let silero = "/tmp/shuffled/silero.onnx"
        let asrDirectory = "/tmp/shuffled/asr"
        let output = "/tmp/shuffled/output.json"
        let artifact = "/tmp/shuffled/artifact.json"
        let arguments = [
            input,
            "--artifact-output", artifact,
            "--threads", "3",
            "--output", output,
            "--asr-model-size", "0.6b",
            "--silero-model", silero,
            "--asr-model-directory", asrDirectory
        ]

        let parsed = try TranscribeFileArguments.parse(arguments)

        #expect(parsed.inputURL == canonicalURL(input))
        #expect(parsed.sileroModelURL == canonicalURL(silero))
        #expect(parsed.asrModelDirectory == canonicalURL(asrDirectory))
        #expect(parsed.asrModelSize == .small)
        #expect(parsed.threads == 3)
        #expect(parsed.outputURL == canonicalURL(output))
        #expect(parsed.artifactOutputURL == canonicalURL(artifact))
    }

    @Test
    func parserRejectsMissingAndMalformedArgumentsWithClearErrors() {
        assertParseRejected([])
        assertParseRejected([""] + Array(validArguments(modelSize: "0.6b").dropFirst()))

        let baseline = validArguments(modelSize: "0.6b")
        for option in optionNames {
            let optionIndex = baseline.firstIndex(of: option)!
            var missingOption = baseline
            missingOption.removeSubrange(optionIndex..<(optionIndex + 2))
            assertParseRejected(missingOption)

            var duplicateOption = baseline
            duplicateOption.append(contentsOf: [option, "duplicate-value"])
            assertParseRejected(duplicateOption)

            var emptyValue = baseline
            emptyValue[optionIndex + 1] = ""
            assertParseRejected(emptyValue)
        }

        assertParseRejected(baseline + ["--unknown", "value"])
        assertParseRejected(baseline + ["extra-positional"])
        var missingValueAtEnd = baseline
        let threadsOptionIndex = missingValueAtEnd.firstIndex(of: "--threads")!
        missingValueAtEnd.removeSubrange(threadsOptionIndex..<(threadsOptionIndex + 2))
        missingValueAtEnd.append("--threads")
        assertParseRejected(missingValueAtEnd)
        assertParseRejected(argumentsWith(
            input: "/tmp/valid/input.wav",
            modelSize: "not-a-model-size",
            threads: "2",
            output: "/tmp/valid/output.json",
            artifactOutput: "/tmp/valid/artifact.json"
        ))
        assertParseRejected(argumentsWith(
            input: "/tmp/valid/input.wav",
            modelSize: "0.6b",
            threads: "0",
            output: "/tmp/valid/output.json",
            artifactOutput: "/tmp/valid/artifact.json"
        ))
        assertParseRejected(argumentsWith(
            input: "/tmp/valid/input.wav",
            modelSize: "0.6b",
            threads: "-1",
            output: "/tmp/valid/output.json",
            artifactOutput: "/tmp/valid/artifact.json"
        ))
        assertParseRejected(argumentsWith(
            input: "/tmp/valid/input.wav",
            modelSize: "0.6b",
            threads: "not-an-integer",
            output: "/tmp/valid/output.json",
            artifactOutput: "/tmp/valid/artifact.json"
        ))
        assertParseRejected(argumentsWith(
            input: "/tmp/valid/input.wav",
            modelSize: "0.6b",
            threads: "2147483648",
            output: "/tmp/valid/output.json",
            artifactOutput: "/tmp/valid/artifact.json"
        ))
    }

    @Test
    func parserRejectsInputOutputAliasesAcrossCanonicalPathForms() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        let input = root.appendingPathComponent("input.wav")
        try Data([1, 2, 3, 4]).write(to: input)

        assertParseRejected(argumentsWith(
            input: input.path,
            modelSize: "0.6b",
            threads: "2",
            output: input.path,
            artifactOutput: "/tmp/valid/artifact.json"
        ))

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: false)
        let standardizedAlias = nested.appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("input.wav")
        assertParseRejected(argumentsWith(
            input: input.path,
            modelSize: "0.6b",
            threads: "2",
            output: standardizedAlias.path,
            artifactOutput: "/tmp/valid/artifact.json"
        ))

        #if os(Linux)
        let symbolicAlias = root.appendingPathComponent("symbolic-input.wav")
        try fileManager.createSymbolicLink(at: symbolicAlias, withDestinationURL: input)
        assertParseRejected(argumentsWith(
            input: input.path,
            modelSize: "0.6b",
            threads: "2",
            output: symbolicAlias.path,
            artifactOutput: "/tmp/valid/artifact.json"
        ))
        #endif

    }

    @Test
    func parserRejectsArtifactInputAndOutputOutputAliases() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        let input = root.appendingPathComponent("input.wav")
        let firstOutput = root.appendingPathComponent("first.json")
        let secondOutput = root.appendingPathComponent("second.json")
        try Data([9, 8, 7]).write(to: input)
        try Data([6, 5, 4]).write(to: firstOutput)

        assertParseRejected(argumentsWith(
            input: input.path,
            modelSize: "0.6b",
            threads: "2",
            output: "/tmp/valid/output.json",
            artifactOutput: input.path
        ))
        assertParseRejected(argumentsWith(
            input: input.path,
            modelSize: "0.6b",
            threads: "2",
            output: firstOutput.path,
            artifactOutput: firstOutput.path
        ))

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: false)
        let standardizedOutput = nested.appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("first.json")
        assertParseRejected(argumentsWith(
            input: input.path,
            modelSize: "0.6b",
            threads: "2",
            output: firstOutput.path,
            artifactOutput: standardizedOutput.path
        ))

        #if os(Linux)
        let symbolicAlias = root.appendingPathComponent("symbolic-output.json")
        try fileManager.createSymbolicLink(at: symbolicAlias, withDestinationURL: firstOutput)
        assertParseRejected(argumentsWith(
            input: input.path,
            modelSize: "0.6b",
            threads: "2",
            output: firstOutput.path,
            artifactOutput: symbolicAlias.path
        ))
        #endif

        #expect(!fileManager.fileExists(atPath: secondOutput.path))
    }

    @Test
    func parserRejectsExistingOutputAndArtifactWithoutChangingBytes() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        let input = root.appendingPathComponent("input.wav")
        let existingOutput = root.appendingPathComponent("existing-output.json")
        let missingArtifact = root.appendingPathComponent("missing-artifact.json")
        let existingArtifact = root.appendingPathComponent("existing-artifact.json")
        let missingOutput = root.appendingPathComponent("missing-output.json")
        let outputBytes = Data([1, 3, 5, 7])
        let artifactBytes = Data([2, 4, 6, 8])
        try Data([0, 1, 2]).write(to: input)
        try outputBytes.write(to: existingOutput)
        try artifactBytes.write(to: existingArtifact)

        let outputError = parseError(argumentsWith(
            input: input.path,
            modelSize: "0.6b",
            threads: "2",
            output: existingOutput.path,
            artifactOutput: missingArtifact.path
        ))
        #expect(outputError.contains("出力先は既に存在します: \(existingOutput.path)"))
        #expect(try Data(contentsOf: existingOutput) == outputBytes)
        #expect(!fileManager.fileExists(atPath: missingArtifact.path))

        let artifactError = parseError(argumentsWith(
            input: input.path,
            modelSize: "0.6b",
            threads: "2",
            output: missingOutput.path,
            artifactOutput: existingArtifact.path
        ))
        #expect(artifactError.contains("出力先は既に存在します: \(existingArtifact.path)"))
        #expect(try Data(contentsOf: existingArtifact) == artifactBytes)
        #expect(!fileManager.fileExists(atPath: missingOutput.path))
    }

    #if os(Linux)
    @Test
    func parserRejectsDanglingOutputSymlink() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        let input = root.appendingPathComponent("input.wav")
        let danglingOutput = root.appendingPathComponent("dangling-output.json")
        let missingTarget = root.appendingPathComponent("missing-target.json")
        let artifact = root.appendingPathComponent("artifact.json")
        try Data([0, 1, 2]).write(to: input)
        try fileManager.createSymbolicLink(at: danglingOutput, withDestinationURL: missingTarget)
        #expect(!fileManager.fileExists(atPath: danglingOutput.path))

        let message = parseError(argumentsWith(
            input: input.path,
            modelSize: "0.6b",
            threads: "2",
            output: danglingOutput.path,
            artifactOutput: artifact.path
        ))
        #expect(message.contains("出力先は既に存在します: \(danglingOutput.path)"))
        #expect(!fileManager.fileExists(atPath: artifact.path))
    }
    #endif

    @Test
    func runRejectsExistingOutputBeforeCheckingModels() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.wav")
        let output = root.appendingPathComponent("existing-output.json")
        let artifact = root.appendingPathComponent("artifact.json")
        let original = Data([9, 8, 7, 6])
        try Data([0, 1, 2]).write(to: input)
        try original.write(to: output)

        let message = await runError(makeArguments(
            input: input.path,
            sileroModel: root.appendingPathComponent("missing-silero.onnx").path,
            asrModelDirectory: root.appendingPathComponent("missing-asr", isDirectory: true).path,
            modelSize: "0.6b",
            threads: "1",
            output: output.path,
            artifactOutput: artifact.path
        ))
        #expect(message.contains("出力先は既に存在します: \(output.path)"))
        #expect(!message.contains("missing-silero"))
        #expect(try Data(contentsOf: output) == original)
        #expect(!FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test
    func runRejectsMissingInputAndOutputParentBeforeModelLoading() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        let missingInput = root.appendingPathComponent("missing.wav")
        let sileroModel = root.appendingPathComponent("placeholder-silero.onnx")
        let asrDirectory = root.appendingPathComponent("placeholder-asr", isDirectory: true)
        try Data([0, 1, 2]).write(to: sileroModel)
        try fileManager.createDirectory(at: asrDirectory, withIntermediateDirectories: false)

        let missingInputError = await runError(makeArguments(
            input: missingInput.path,
            sileroModel: sileroModel.path,
            asrModelDirectory: asrDirectory.path,
            modelSize: "0.6b",
            threads: "1",
            output: root.appendingPathComponent("missing-output.json").path,
            artifactOutput: root.appendingPathComponent("missing-artifact.json").path
        ))
        #expect(!missingInputError.isEmpty)
        #expect(missingInputError.contains("入力音声ファイル"))

        let validInput = root.appendingPathComponent("valid.wav")
        try writePCM16Wave(
            to: validInput,
            sampleRate: 16_000,
            channelCount: 1,
            samples: [0, 16_384, -16_384]
        )
        let outputDirectory = root.appendingPathComponent("missing-output-directory", isDirectory: true)
        let outputPath = outputDirectory.appendingPathComponent("output.json")
        let artifactPath = root.appendingPathComponent("parent-artifact.json")
        let outputDirectoryError = await runError(makeArguments(
            input: validInput.path,
            sileroModel: sileroModel.path,
            asrModelDirectory: asrDirectory.path,
            modelSize: "0.6b",
            threads: "1",
            output: outputPath.path,
            artifactOutput: artifactPath.path
        ))
        #expect(!outputDirectoryError.isEmpty)
        #expect(outputDirectoryError.contains("出力先ディレクトリ"))
        #expect(!outputDirectoryError.contains("SHA-256"))
        #expect(!fileManager.fileExists(atPath: outputDirectory.path))
        #expect(!fileManager.fileExists(atPath: artifactPath.path))
    }

    @Test
    func runRejectsSileroModelWithWrongHashBeforeCreatingOutputs() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        let input = root.appendingPathComponent("valid.wav")
        let sileroModel = root.appendingPathComponent("wrong-silero.onnx")
        let asrDirectory = root.appendingPathComponent("readable-asr", isDirectory: true)
        let output = root.appendingPathComponent("output.json")
        let artifact = root.appendingPathComponent("artifact.json")
        try writePCM16Wave(
            to: input,
            sampleRate: 16_000,
            channelCount: 1,
            samples: [0, 16_384, -16_384]
        )
        try Data([0, 1, 2, 3]).write(to: sileroModel)
        try fileManager.createDirectory(at: asrDirectory, withIntermediateDirectories: false)

        let message = await runError(makeArguments(
            input: input.path,
            sileroModel: sileroModel.path,
            asrModelDirectory: asrDirectory.path,
            modelSize: "0.6b",
            threads: "1",
            output: output.path,
            artifactOutput: artifact.path
        ))
        #expect(message.contains("SHA-256 が一致しません"))
        #expect(!fileManager.fileExists(atPath: output.path))
        #expect(!fileManager.fileExists(atPath: artifact.path))
    }

    @Test
    func portableAudioFileImporterBuildsCanonicalTimelineFromGeneratedWave() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, named: "valid-session")
        let source = root.appendingPathComponent("canonical.wav")
        let sourceSamples: [Int16] = [0, 16_384, -16_384, -32_768, 8_192]
        try writePCM16Wave(
            to: source,
            sampleRate: 16_000,
            channelCount: 1,
            samples: sourceSamples
        )

        let reader = try await PortableAudioFileImporter.open(inputURL: source, sessionURL: session)
        let info = reader.info
        let samples = try reader.readSamples(frameRange: 0..<5)

        #expect(info.committedFrames == 5)
        #expect(info.sampleRate == 16_000)
        #expect(info.channelCount == 1)
        #expect(info.gapEvents.isEmpty)
        #expect(samples == [0, 0.5, -0.5, -1, 0.25])
    }

    @Test
    func portableAudioFileImporterRejectsUnsupportedExtensionAndCorruptWave() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let validWave = root.appendingPathComponent("valid-source.wav")
        try writePCM16Wave(
            to: validWave,
            sampleRate: 16_000,
            channelCount: 1,
            samples: [0, 8_192, -8_192]
        )
        let unsupported = root.appendingPathComponent("unsupported.ogg")
        try Data(contentsOf: validWave).write(to: unsupported)
        let unsupportedSession = try makeSession(in: root, named: "unsupported-session")
        await assertImportRejected(input: unsupported, session: unsupportedSession)

        let corruptWave = root.appendingPathComponent("corrupt.wav")
        try Data("not a RIFF wave".utf8).write(to: corruptWave)
        let corruptSession = try makeSession(in: root, named: "corrupt-session")
        await assertImportRejected(input: corruptWave, session: corruptSession)
    }

    #if os(Linux)
    @Test
    func linuxPortableAudioFileImporterRejectsNoncanonicalRateAndChannelsWithLocalizedMessage() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stereoWave = root.appendingPathComponent("stereo.wav")
        try writePCM16Wave(
            to: stereoWave,
            sampleRate: 16_000,
            channelCount: 2,
            samples: [1_024, -1_024, 2_048, -2_048]
        )
        let stereoSession = try makeSession(in: root, named: "stereo-session")
        let stereoError = await importError(input: stereoWave, session: stereoSession)
        #expect(stereoError.contains("16 kHz・モノラル"))
        #expect(!stereoError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let highRateWave = root.appendingPathComponent("high-rate.wav")
        try writePCM16Wave(
            to: highRateWave,
            sampleRate: 48_000,
            channelCount: 1,
            samples: [1_024, -1_024, 2_048]
        )
        let highRateSession = try makeSession(in: root, named: "high-rate-session")
        let highRateError = await importError(input: highRateWave, session: highRateSession)
        #expect(highRateError.contains("48000 Hz・1 ch"))
        #expect(!highRateError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    #endif

    @Test
    func payloadsHaveExactSchemasAndUseEngineProvenanceConfiguration() throws {
        let segments = [
            FileTranscriptionSegment(
                reference: SegmentReference(segmentationRunID: "vad-run", segmentID: "segment-1", startFrame: 1_600, endFrame: 3_200),
                text: "first"
            ),
            FileTranscriptionSegment(
                reference: SegmentReference(segmentationRunID: "vad-run", segmentID: "segment-2", startFrame: 8_000, endFrame: 9_600),
                text: "second"
            )
        ]
        let asrConfiguration = validASRConfiguration()
        let payload = try makePayload(
            segments: segments,
            asrConfiguration: asrConfiguration,
            audioSeconds: 10,
            segmentationSeconds: 1,
            asrWallSeconds: 4,
            modelLoadSeconds: 2,
            threads: 99
        )

        let expectedRuntime: [String: Any] = [
            "audio_seconds": 10.0,
            "model_load_seconds": 2.0,
            "inference_seconds": 3.0,
            "rtf": 0.3
        ]
        let expectedASR: [String: Any] = [
            "engine": "fixture-asr",
            "model": "fixture-asr-model",
            "version": "fixture-asr-version",
            "configuration": asrConfiguration
        ]
        let vadConfiguration = ["mode": "final-transcript", "intra_op_threads": "5"]
        let expectedVAD: [String: Any] = [
            "engine": "fixture-vad",
            "model": "fixture-silero-model",
            "version": "fixture-vad-version",
            "configuration": vadConfiguration
        ]
        let firstPrimarySegment: [String: Any] = ["start_ms": 100, "end_ms": 200, "text": "first"]
        let secondPrimarySegment: [String: Any] = ["start_ms": 500, "end_ms": 600, "text": "second"]
        let expectedPrimary: [String: Any] = [
            "schema_version": 1,
            "asr": expectedASR,
            "vad": expectedVAD,
            "segments": [firstPrimarySegment, secondPrimarySegment],
            "runtime": expectedRuntime
        ]
        try assertJSONDictionary(payload.primary, equals: expectedPrimary)
        let primarySegments = try #require(payload.primary["segments"] as? [[String: Any]])
        #expect(primarySegments.count == 2)
        try assertJSONDictionary(primarySegments[0], equals: firstPrimarySegment)
        try assertJSONDictionary(primarySegments[1], equals: secondPrimarySegment)

        let expectedInferenceConfiguration: [String: Any] = [
            "language": "ja",
            "minimum_input_seconds": 0.25,
            "quantization": "int4",
            "mel_variant": "fixture-mel-v1",
            "max_new_tokens": 448,
            "no_repeat_ngram": "3 when input_seconds > 15; disabled otherwise",
            "intra_op_threads": 7,
            "inter_op_threads": 1,
            "cpu_memory_arena": false,
            "segmentation": "silero-final-transcript"
        ]
        let expectedEngine: [String: Any] = [
            "name": "qwen3-asr",
            "model": ASRModelSize.small.repository,
            "revision": ASRModelSize.small.commit,
            "backend": "onnxruntime",
            "device": "cpu",
            "package_versions": ["onnxruntime": ONNXEnvironment.runtimeVersion],
            "inference_config": expectedInferenceConfiguration
        ]
        let expectedArtifactSegment: [String: Any] = [
            "start_ms": 0,
            "end_ms": 10_000,
            "text": "first\nsecond",
            "language": "ja"
        ]
        let expectedArtifact: [String: Any] = [
            "schema_version": 2,
            "engine": expectedEngine,
            "segments": [expectedArtifactSegment],
            "runtime": expectedRuntime
        ]
        try assertJSONDictionary(payload.artifact, equals: expectedArtifact)
        let artifactEngine = try #require(payload.artifact["engine"] as? [String: Any])
        try assertJSONDictionary(artifactEngine, equals: expectedEngine)
        let artifactInferenceConfiguration = try #require(artifactEngine["inference_config"] as? [String: Any])
        try assertJSONDictionary(artifactInferenceConfiguration, equals: expectedInferenceConfiguration)
        let artifactSegments = try #require(payload.artifact["segments"] as? [[String: Any]])
        #expect(artifactSegments.count == 1)
        try assertJSONDictionary(artifactSegments[0], equals: expectedArtifactSegment)

        #expect(payload.audioSeconds == 10)
        #expect(payload.modelLoadSeconds == 2)
        #expect(payload.inferenceSeconds == 3)
        #expect(payload.rtf == 0.3)
    }

    @Test
    func emptySegmentsProduceEmptyPrimaryAndEmptyArtifactHypothesis() throws {
        let payload = try makePayload(
            segments: [],
            asrConfiguration: validASRConfiguration(),
            audioSeconds: 10,
            segmentationSeconds: 1,
            asrWallSeconds: 4,
            modelLoadSeconds: 2,
            threads: 99
        )
        let primarySegments = try #require(payload.primary["segments"] as? [[String: Any]])
        #expect(primarySegments.isEmpty)
        let artifactSegments = try #require(payload.artifact["segments"] as? [[String: Any]])
        #expect(artifactSegments.count == 1)
        #expect(artifactSegments[0]["text"] as? String == "")
    }

    @Test
    func payloadRejectsMissingOrMalformedNewEngineConfiguration() {
        let requiredKeys = ["intra_op_threads", "inter_op_threads", "cpu_memory_arena"]
        for key in requiredKeys {
            var configuration = validASRConfiguration()
            configuration.removeValue(forKey: key)
            assertPayloadInvalidMetric(configuration: configuration, segmentationSeconds: 1, asrWallSeconds: 4, modelLoadSeconds: 2)
        }

        var malformedIntraOpThreads = validASRConfiguration()
        malformedIntraOpThreads["intra_op_threads"] = "seven"
        assertPayloadInvalidMetric(configuration: malformedIntraOpThreads, segmentationSeconds: 1, asrWallSeconds: 4, modelLoadSeconds: 2)

        var malformedInterOpThreads = validASRConfiguration()
        malformedInterOpThreads["inter_op_threads"] = "1.5"
        assertPayloadInvalidMetric(configuration: malformedInterOpThreads, segmentationSeconds: 1, asrWallSeconds: 4, modelLoadSeconds: 2)

        var malformedArena = validASRConfiguration()
        malformedArena["cpu_memory_arena"] = "False"
        assertPayloadInvalidMetric(configuration: malformedArena, segmentationSeconds: 1, asrWallSeconds: 4, modelLoadSeconds: 2)
    }

    @Test
    func payloadRejectsNegativeInferenceDuration() {
        assertPayloadInvalidMetric(
            configuration: validASRConfiguration(),
            segmentationSeconds: 1,
            asrWallSeconds: 0,
            modelLoadSeconds: 2
        )
    }

    private func validASRConfiguration() -> [String: String] {
        [
            "language": "ja",
            "minimum_input_seconds": "0.25",
            "quantization": "int4",
            "mel_variant": "fixture-mel-v1",
            "max_new_tokens": "448",
            "no_repeat_ngram": "3 when input_seconds > 15; disabled otherwise",
            "intra_op_threads": "7",
            "inter_op_threads": "1",
            "cpu_memory_arena": "false"
        ]
    }

    private func makePayload(
        segments: [FileTranscriptionSegment],
        asrConfiguration: [String: String],
        audioSeconds: Double,
        segmentationSeconds: Double,
        asrWallSeconds: Double,
        modelLoadSeconds: Double,
        threads: Int
    ) throws -> (primary: [String: Any], artifact: [String: Any], audioSeconds: Double, modelLoadSeconds: Double, inferenceSeconds: Double, rtf: Double) {
        var metrics = ASRBatchMetrics.zero
        metrics.modelLoadSeconds = modelLoadSeconds
        let result = FileTranscriptionResult(
            segments: segments,
            metrics: metrics,
            segmentationSeconds: segmentationSeconds,
            asrWallSeconds: asrWallSeconds
        )
        let asrProvenance = RunProvenance(
            engine: "fixture-asr",
            model: "fixture-asr-model",
            version: "fixture-asr-version",
            configuration: asrConfiguration
        )
        let vadProvenance = RunProvenance(
            engine: "fixture-vad",
            model: "fixture-silero-model",
            version: "fixture-vad-version",
            configuration: ["mode": "final-transcript", "intra_op_threads": "5"]
        )
        let root = URL(fileURLWithPath: "/tmp/transcribe-file-payload-\(UUID().uuidString)")
        let options = TranscribeFileArguments(
            inputURL: root.appendingPathComponent("input.wav"),
            sileroModelURL: root.appendingPathComponent("silero.onnx"),
            asrModelDirectory: root.appendingPathComponent("asr", isDirectory: true),
            asrModelSize: .small,
            threads: threads,
            outputURL: root.appendingPathComponent("output.json"),
            artifactOutputURL: root.appendingPathComponent("artifact.json")
        )
        return try TranscribeFileCommand.makePayload(
            result: result,
            audioSeconds: audioSeconds,
            asrProvenance: asrProvenance,
            vadProvenance: vadProvenance,
            options: options
        )
    }

    private func assertPayloadInvalidMetric(
        configuration: [String: String],
        segmentationSeconds: Double,
        asrWallSeconds: Double,
        modelLoadSeconds: Double
    ) {
        do {
            _ = try makePayload(
                segments: [],
                asrConfiguration: configuration,
                audioSeconds: 10,
                segmentationSeconds: segmentationSeconds,
                asrWallSeconds: asrWallSeconds,
                modelLoadSeconds: modelLoadSeconds,
                threads: 99
            )
            Issue.record("Expected payload generation to reject invalid metrics or ASR configuration")
        } catch let error as TranscribeFileCommandError {
            if case .invalidMetric = error {
                return
            }
            Issue.record("Expected invalidMetric, received: \(error.localizedDescription)")
        } catch {
            Issue.record("Expected invalidMetric, received: \(error.localizedDescription)")
        }
    }

    private func assertJSONDictionary(_ actual: [String: Any], equals expected: [String: Any]) throws {
        #expect(Set(actual.keys) == Set(expected.keys))
        let actualData = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
        let expectedData = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        #expect(actualData == expectedData)
    }

    private func validArguments(modelSize: String) -> [String] {
        makeArguments(
            input: "/tmp/valid/input.wav",
            sileroModel: "/tmp/valid/silero.onnx",
            asrModelDirectory: "/tmp/valid/asr",
            modelSize: modelSize,
            threads: "2",
            output: "/tmp/valid/output.json",
            artifactOutput: "/tmp/valid/artifact.json"
        )
    }

    private func argumentsWith(
        input: String,
        modelSize: String,
        threads: String,
        output: String,
        artifactOutput: String
    ) -> [String] {
        makeArguments(
            input: input,
            sileroModel: "/tmp/valid/silero.onnx",
            asrModelDirectory: "/tmp/valid/asr",
            modelSize: modelSize,
            threads: threads,
            output: output,
            artifactOutput: artifactOutput
        )
    }

    private func makeArguments(
        input: String,
        sileroModel: String,
        asrModelDirectory: String,
        modelSize: String,
        threads: String,
        output: String,
        artifactOutput: String
    ) -> [String] {
        [
            input,
            "--silero-model", sileroModel,
            "--asr-model-directory", asrModelDirectory,
            "--asr-model-size", modelSize,
            "--threads", threads,
            "--output", output,
            "--artifact-output", artifactOutput
        ]
    }

    private func canonicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private func assertParseRejected(_ arguments: [String]) {
        let message = parseError(arguments)
        #expect(!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func parseError(_ arguments: [String]) -> String {
        do {
            _ = try TranscribeFileArguments.parse(arguments)
            Issue.record("Expected CLI arguments to be rejected: \(arguments)")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    private func runError(_ arguments: [String]) async -> String {
        do {
            _ = try await TranscribeFileCommand.run(arguments: arguments)
            Issue.record("Expected CLI run to be rejected: \(arguments)")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    private func assertImportRejected(input: URL, session: URL) async {
        let message = await importError(input: input, session: session)
        #expect(!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func importError(input: URL, session: URL) async -> String {
        do {
            _ = try await PortableAudioFileImporter.open(inputURL: input, sessionURL: session)
            Issue.record("Expected audio import to be rejected: \(input.path)")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    private func makeScratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAmbientJevTranscribeFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func makeSession(in root: URL, named name: String) throws -> URL {
        let session = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        return session
    }

    private func writePCM16Wave(
        to url: URL,
        sampleRate: UInt32,
        channelCount: UInt16,
        samples: [Int16]
    ) throws {
        guard channelCount > 0, !samples.isEmpty, samples.count % Int(channelCount) == 0 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let payloadBytes = UInt32(samples.count * MemoryLayout<Int16>.size)
        let blockAlign = channelCount * UInt16(MemoryLayout<Int16>.size)
        let byteRate = sampleRate * UInt32(blockAlign)
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(36 + payloadBytes, to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(channelCount, to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(byteRate, to: &data)
        appendLittleEndian(blockAlign, to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(payloadBytes, to: &data)
        for sample in samples {
            appendLittleEndian(UInt16(bitPattern: sample), to: &data)
        }
        try data.write(to: url)
    }

    private func appendLittleEndian(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
