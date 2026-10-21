#if os(macOS)
import CoreML
import CryptoKit
import Foundation
import Testing
@testable import FluidAudio

private enum DiarizationFrontendParityError: Error, CustomStringConvertible {
    case invalidModelDirectory(String)
    case invalidModelAsset(String)
    case invalidInjectedPrediction(String)

    var description: String {
        switch self {
        case .invalidModelDirectory(let reason):
            return "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY: \(reason)"
        case .invalidModelAsset(let reason):
            return "Invalid diarization frontend model asset: \(reason)"
        case .invalidInjectedPrediction(let reason):
            return "Invalid injected segmentation prediction: \(reason)"
        }
    }
}

private struct DiarizationFrontendMaskCase {
    let name: String
    let speakerWeights: [Float]
}

private struct DiarizationFrontendInterpolationCase {
    let name: String
    let input: [Float]
}

private final class InjectedSegmentationModel: MLModel, @unchecked Sendable {
    private let logits: [Float]
    private let frames = 589
    private let classes = 7
    private let lock = NSLock()
    private var capturedWindows: [[Float]] = []

    init(logits: [Float]) throws {
        guard logits.count == frames * classes, logits.allSatisfy(\.isFinite) else {
            throw DiarizationFrontendParityError.invalidInjectedPrediction(
                "logits must contain exactly 589 × 7 finite Float32 values"
            )
        }
        self.logits = logits
        super.init()
    }

    override func __prediction(
        fromFeatures input: MLFeatureProvider,
        options: MLPredictionOptions,
        completionHandler: @escaping (MLFeatureProvider?, Error?) -> Void
    ) {
        do {
            guard let audio = input.featureValue(for: "audio")?.multiArrayValue else {
                throw DiarizationFrontendParityError.invalidInjectedPrediction(
                    "the segmentation processor did not provide its audio MLMultiArray"
                )
            }
            guard audio.shape.count == 3, audio.shape[1].intValue == 1 else {
                throw DiarizationFrontendParityError.invalidInjectedPrediction(
                    "expected segmentation audio shaped [batch, 1, samples], got \(audio.shape)"
                )
            }

            let batchSize = audio.shape[0].intValue
            let sampleCount = audio.shape[2].intValue
            let audioPointer = audio.dataPointer.assumingMemoryBound(to: Float.self)
            let strides = audio.strides.map(\.intValue)
            var nonzeroWindows: [[Float]] = []
            nonzeroWindows.reserveCapacity(batchSize)
            for batch in 0..<batchSize {
                let start = batch * strides[0]
                let window = (0..<sampleCount).map { sample in
                    audioPointer[start + sample * strides[2]]
                }
                if window.contains(where: { $0 != 0 }) {
                    nonzeroWindows.append(window)
                }
            }
            lock.lock()
            capturedWindows.append(contentsOf: nonzeroWindows)
            lock.unlock()

            let output = try MLMultiArray(
                shape: [NSNumber(value: batchSize), NSNumber(value: frames), NSNumber(value: classes)],
                dataType: .float32
            )
            let outputPointer = output.dataPointer.assumingMemoryBound(to: Float.self)
            for batch in 0..<batchSize {
                let outputStart = batch * frames * classes
                outputPointer.advanced(by: outputStart).update(from: logits, count: logits.count)
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "segments": MLFeatureValue(multiArray: output)
            ])
            completionHandler(provider, nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    func takeCapturedWindows() -> [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        let windows = capturedWindows
        capturedWindows.removeAll(keepingCapacity: true)
        return windows
    }
}

extension DiarizationParityFixtureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"))
    func frontendMatchesFluidAudio() async throws {
        let directoryPath = try #require(
            ProcessInfo.processInfo.environment["MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY"],
            "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY is required and must name an absolute existing directory"
        )
        try #require(
            !directoryPath.isEmpty,
            "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY must not be empty; there is no model-directory default"
        )
        try #require(
            directoryPath.hasPrefix("/"),
            "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY must name an absolute path; there is no model-directory default"
        )
        let modelDirectory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        try #require(
            FileManager.default.fileExists(atPath: modelDirectory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY must name an existing directory: \(directoryPath)"
        )

        let modelDirectoryNames = [
            "Segmentation.mlmodelc",
            "Embedding.mlmodelc",
            "FBank.mlmodelc",
            "PldaRho.mlmodelc",
        ]
        var modelURLs: [String: URL] = [:]
        for name in modelDirectoryNames {
            let url = modelDirectory.appendingPathComponent(name, isDirectory: true)
            var isModelDirectory: ObjCBool = false
            try #require(
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isModelDirectory)
                    && isModelDirectory.boolValue,
                "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY must contain the required model bundle before loading: \(url.path)"
            )
            modelURLs[name] = url
        }
        let pldaJSONURL = modelDirectory.appendingPathComponent("plda-parameters.json", isDirectory: false)
        try #require(
            FileManager.default.fileExists(atPath: pldaJSONURL.path),
            "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY must contain the required PLDA parameters before loading: \(pldaJSONURL.path)"
        )

        var hashedModelFiles: [(String, URL)] = []
        for name in modelDirectoryNames {
            let modelURL = try #require(
                modelURLs[name],
                "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY validation did not retain model bundle: \(name)"
            )
            for relativePath in ["model.mil", "weights/weight.bin"] {
                let fileURL = modelURL.appendingPathComponent(relativePath, isDirectory: false)
                try #require(
                    FileManager.default.fileExists(atPath: fileURL.path),
                    "MAC_AMBIENT_JEV_DIARIZATION_MODEL_DIRECTORY must contain required graph/hash input before loading: \(fileURL.path)"
                )
                hashedModelFiles.append(("\(name)/\(relativePath)", fileURL))
            }
        }

        let config = try DiarizationParityOracle.config()
        try #require(config.sampleRate == 16_000, "the pinned frontend oracle expects a 16 kHz sample rate")
        let models = try await loadOfflineDiarizerModelsUsingStaging(
            modelURLs: modelURLs,
            pldaJSONURL: pldaJSONURL
        )
        let extractor = OfflineEmbeddingExtractor(
            fbankModel: models.fbankModel,
            embeddingModel: models.embeddingModel,
            pldaTransform: PLDATransform(pldaRhoModel: models.pldaRhoModel, psi: models.pldaPsi),
            config: config
        )

        var modelHashes: [String: String] = [:]
        for (name, url) in hashedModelFiles {
            modelHashes[name] = sha256Hex(try Data(contentsOf: url))
        }
        modelHashes["plda-parameters.json"] = sha256Hex(try Data(contentsOf: pldaJSONURL))

        let injection = try InjectedSegmentationModel(logits: makeDecoderLogits())
        let decoderOutput = try await OfflineSegmentationProcessor().process(
            audioSamples: [Float](repeating: 0.5, count: 1),
            segmentationModel: injection,
            config: config,
            chunkHandler: nil
        )
        try #require(decoderOutput.speakerWeights.count == 1, "decoder input must yield one segmentation chunk")
        try #require(decoderOutput.speakerWeights[0].count == 589, "decoder output must contain 589 frames")
        let flattenedDecoderBits = decoderOutput.speakerWeights[0].flatMap { row in
            row.map { $0 > 0 ? 1 : 0 }
        }
        let decoderBits = decoderOutput.speakerWeights[0].map { row in
            row.enumerated().reduce(0) { bits, entry in
                bits | (entry.element > 0 ? 1 << entry.offset : 0)
            }
        }
        let powersetBits = [
            [0, 0, 0],
            [1, 0, 0],
            [0, 1, 0],
            [0, 0, 1],
            [1, 1, 0],
            [1, 0, 1],
            [0, 1, 1],
        ]
        for classIndex in 0..<7 {
            #expect(
                Array(flattenedDecoderBits[(classIndex * 3)..<(classIndex * 3 + 3)]) == powersetBits[classIndex],
                "the segmentation postprocessor must decode powerset class \(classIndex)"
            )
        }
        #expect(Array(flattenedDecoderBits[(28 * 3)..<(28 * 3 + 3)]) == [0, 0, 0], "an all-equal row must select class zero")
        var tiedFrame = 7
        for firstClass in 0..<7 {
            for secondClass in (firstClass + 1)..<7 {
                #expect(
                    Array(flattenedDecoderBits[(tiedFrame * 3)..<(tiedFrame * 3 + 3)]) == powersetBits[firstClass],
                    "an exact class-pair tie must keep its first class (\(firstClass), \(secondClass))"
                )
                tiedFrame += 1
            }
        }

        let windowSampleCounts = [1, 31_999, 32_000, 32_001, 159_999, 160_000, 160_001, 192_000]
        var windowCases: [[String: Any]] = []
        for sampleCount in windowSampleCounts {
            let audio = (0..<sampleCount).map { Float(($0 % 17) + 1) / 32 }
            _ = injection.takeCapturedWindows()
            let output = try await OfflineSegmentationProcessor().process(
                audioSamples: audio,
                segmentationModel: injection,
                config: config,
                chunkHandler: nil
            )
            let captured = injection.takeCapturedWindows()
            let expectedStarts = output.chunkOffsets.map { Int(($0 * Double(config.sampleRate)).rounded()) }
            try #require(
                captured.count == expectedStarts.count,
                "sampleCount=\(sampleCount): the injected model must observe each source-scheduled window"
            )
            var availableCounts: [Int] = []
            var paddingCounts: [Int] = []
            for (index, start) in expectedStarts.enumerated() {
                let actualWindow = captured[index]
                let available = actualWindow.prefix(while: { $0 != 0 }).count
                let expectedAvailable = max(0, min(config.samplesPerWindow, sampleCount - start))
                try #require(
                    actualWindow.count == config.samplesPerWindow,
                    "sampleCount=\(sampleCount), window=\(index): injected audio length must equal the configured window"
                )
                #expect(
                    available == expectedAvailable,
                    "sampleCount=\(sampleCount), window=\(index): nonzero prefix must match available input samples"
                )
                let expectedPrefix = Array(audio[start..<(start + expectedAvailable)])
                #expect(
                    Array(actualWindow.prefix(expectedAvailable)) == expectedPrefix,
                    "sampleCount=\(sampleCount), window=\(index): source window prefix must preserve input samples"
                )
                #expect(
                    actualWindow.dropFirst(expectedAvailable).allSatisfy { $0 == 0 },
                    "sampleCount=\(sampleCount), window=\(index): source window suffix must be zero padded"
                )
                availableCounts.append(available)
                paddingCounts.append(actualWindow.count - available)
            }
            windowCases.append([
                "sampleCount": sampleCount,
                "expectedStarts": expectedStarts,
                "expectedAvailable": availableCounts,
                "expectedPadding": paddingCounts,
            ])
        }

        let maskAudio: [Float] = (0..<32_001).map { index -> Float in
            let sampleIndex = Double(index)
            let sineComponent = sin(sampleIndex * 0.017) * 0.6
            let cosineComponent = cos(sampleIndex * 0.0031) * 0.2
            return Float(sineComponent + cosineComponent)
        }
        let maskChunkOffset = Double(config.samplesPerStep) / Double(config.sampleRate)
        try #require(
            maskAudio.count == config.samplesPerStep + 1,
            "mask extraction must use exactly 32001 synthetic samples"
        )
        try #require(
            config.samplesPerStep < maskAudio.count,
            "the mask chunk offset sample must be strictly before EOF"
        )
        let maskCases = makeMaskCases()
        var serializedMaskCases: [[String: Any]] = []
        var observedMaskCases: [String: [TimedEmbedding]] = [:]
        for maskCase in maskCases {
            let rows = (0..<589).map { frame in
                Array(maskCase.speakerWeights[(frame * 3)..<(frame * 3 + 3)])
            }
            let segmentation = SegmentationOutput(
                logProbs: [],
                speakerWeights: [rows],
                numChunks: 1,
                numFrames: 589,
                numSpeakers: 3,
                chunkOffsets: [maskChunkOffset],
                frameDuration: 10.0 / 589.0
            )
            let embeddings: [TimedEmbedding] = try await extractor.extractEmbeddings(
                audio: maskAudio,
                segmentation: segmentation
            )
            observedMaskCases[maskCase.name] = embeddings
            for embedding in embeddings {
                let firstActiveFrame = embedding.frameWeights.firstIndex { $0 > 1e-3 }
                let lastActiveFrame = embedding.frameWeights.lastIndex { $0 > 1e-3 }
                #expect(embedding.frameWeights.count == 589, "returned TimedEmbedding masks must retain all 589 frames")
                #expect(
                    firstActiveFrame.map { $0 == embedding.startFrame } == true,
                    "TimedEmbedding startFrame must name its first active frame"
                )
                #expect(
                    lastActiveFrame.map { $0 == embedding.endFrame } == true,
                    "TimedEmbedding endFrame must inclusively name its last active frame"
                )
                #expect(
                    embedding.startTime == maskChunkOffset + Double(embedding.startFrame) * (10.0 / 589.0),
                    "TimedEmbedding startTime must include the supplied chunk offset"
                )
                #expect(
                    embedding.endTime == maskChunkOffset + Double(embedding.endFrame + 1) * (10.0 / 589.0),
                    "TimedEmbedding endTime must include the supplied chunk offset and exclusive frame boundary"
                )
            }
            let slots = embeddings.map { $0.speakerIndex }
            let startFrames = embeddings.map { $0.startFrame }
            let endFrames = embeddings.map { $0.endFrame }
            let returnedMasks = embeddings.flatMap { $0.frameWeights }
            let returnedResampledMasks = embeddings.flatMap {
                WeightInterpolation.resample($0.frameWeights, to: 589)
            }
            serializedMaskCases.append([
                "name": maskCase.name,
                "speakerWeights": try DiarizationParityOracle.tensor(maskCase.speakerWeights, shape: [589, 3]),
                "expectedSlots": slots,
                "expectedStartFrames": startFrames,
                "expectedEndFrames": endFrames,
                "expectedMasks": try DiarizationParityOracle.tensor(returnedMasks, shape: [embeddings.count, 589]),
                "expectedResampledMasks": try DiarizationParityOracle.tensor(
                    returnedResampledMasks,
                    shape: [embeddings.count, 589]
                ),
            ])
        }
        let observedByName = observedMaskCases
        #expect(observedByName["zero-active"]?.isEmpty == true, "zero activity must produce no embedding masks")
        #expect(observedByName["overlap-all"]?.isEmpty == true, "complete overlap across all slots must produce no masks")
        #expect(observedByName["one-active"]?.map(\.speakerIndex) == [0], "one active slot must remain selected")
        #expect(observedByName["two-active"]?.map(\.speakerIndex) == [0, 1], "two active slots must remain selected")
        #expect(
            observedByName["three-active"]?.map(\.speakerIndex) == [0, 1, 2],
            "the three disjoint 118-frame runs must select all three slots"
        )
        #expect(
            observedByName["three-active"]?.map(\.startFrame) == [0, 180, 400],
            "the three disjoint mask runs must preserve their starts"
        )
        #expect(
            ["clean-17", "clean-18", "clean-117"].allSatisfy { observedByName[$0]?.isEmpty == true },
            "clean masks below the 20% gate must be rejected"
        )
        #expect(
            observedByName["clean-118"]?.map(\.speakerIndex) == [0],
            "118 clean frames must meet the strict 20% mask gate"
        )
        #expect(observedByName["ratio-below"]?.isEmpty == true, "the ratio immediately below 20% must be rejected")
        #expect(
            observedByName["ratio-exact"]?.map(\.speakerIndex) == [0],
            "the exact 20% boundary must pass the strict-less-than gate"
        )
        #expect(observedByName["ratio-above"]?.map(\.speakerIndex) == [0], "the ratio above 20% must pass")
        let overlapBelow = try #require(observedByName["overlap-nextDown"]?.first)
        let overlapExact = try #require(observedByName["overlap-exact"]?.first)
        let overlapAbove = try #require(observedByName["overlap-nextUp"]?.first)
        #expect(overlapBelow.frameWeights[50] == 1, "the nextDown overlap weight must not be suppressed")
        #expect(overlapExact.frameWeights[50] == 1, "the exact overlap threshold must not be suppressed")
        #expect(overlapAbove.frameWeights[50] == 0, "only the nextUp overlap weight must be suppressed")
        let excluded = try #require(observedByName["overlap-excluded"]?.first)
        #expect(excluded.speakerIndex == 0, "the overlapped short second slot must be excluded")
        #expect(excluded.startFrame == 20 && excluded.endFrame == 199, "overlap exclusion must trim the retained mask")

        let interpolationCases = makeInterpolationCases()
        var serializedInterpolationCases: [[String: Any]] = []
        for interpolationCase in interpolationCases {
            let identity = WeightInterpolation.resample(interpolationCase.input, to: 589)
            let halfPixel = WeightInterpolation.resample(interpolationCase.input, to: 125)
            let pooling = alignCornersPoolingReference(interpolationCase.input)
            serializedInterpolationCases.append([
                "name": interpolationCase.name,
                "input": try DiarizationParityOracle.tensor(interpolationCase.input, shape: [589]),
                "expectedIdentity": try DiarizationParityOracle.tensor(identity, shape: [589]),
                "expectedHalfPixel": try DiarizationParityOracle.tensor(halfPixel, shape: [125]),
                "expectedPooling": try DiarizationParityOracle.tensor(pooling, shape: [589]),
            ])
        }

        let fixture: [String: Any] = [
            "metadata": DiarizationParityOracle.metadata(
                inputConstruction: "FluidAudio 0.15.8 at the pinned package revision is used only for the production OfflineSegmentationProcessor, OfflineEmbeddingExtractor, and WeightInterpolation paths. Decoder inputs are deterministic Float32 logits injected into a test-only MLModel subclass; the real segmentation processor performs class selection and postprocessing. Window inputs are deterministic nonzero Float32 samples. Mask inputs use 32001 synthetic audio samples and public SegmentationOutput values with 589 frames and three speaker slots. Each is extracted at supplied chunk offset 2s, the last scheduled start at sample 32000, leaving one real sample and 159999 zero-padded samples in the final window; returned masks remain untrimmed, including the frame-17/frame-18 gate cases. Each stored output is copied from returned TimedEmbedding metadata/masks. Interpolation inputs are deterministic zero, one, ramp, alternating, scattered, and endpoint vectors. Actual Core ML embedding/rho values are deliberately discarded and are not stored. Model loading always uses OfflineDiarizerModels.load from a unique temporary root with a speaker-diarization child, symlinks to validated caller assets, the pinned revision marker, and ModelHub.offlineMode enabled for the load; it removes only that verified staging root. The source model directory remains read-only, and recorded model hashes are computed from the original source assets.",
                comparisonRule: "Exact canonical JSON comparison. Decode bits, starts, available/padding counts, slots, frame bounds, masks, and source half-pixel interpolation values must match exactly. Each model asset SHA-256 is recorded. expectedPooling is a geometry-only align-corners reference: for j=0..<125 sample input at Double(j)*588/124, compute Float32 linear coefficients, and scatter at integer index j*589/125. This records no Core ML FP16 graph numerical output and is intentionally distinct from WeightInterpolation's 125-point half-pixel result."
            ),
            "modelRevision": "df2625ac79a7ac6b65ad868fee6d80f320da4232",
            "modelSHA256": modelHashes,
            "decodeCases": [[
                "name": "powerset-classes-and-ties",
                "logits": try DiarizationParityOracle.tensor(makeDecoderLogits(), shape: [589, 7]),
                "expectedSpeakerBits": decoderBits,
            ]],
            "windowCases": windowCases,
            "maskCases": serializedMaskCases,
            "interpolationCases": serializedInterpolationCases,
        ]
        try checkOrWriteFrontendFixture(fixture)
    }
}

/// Always exercises FluidAudio's public loader through its expected cache layout while keeping
/// every caller-owned model asset read-only. Only this UUID-owned temporary root is removed.
func loadOfflineDiarizerModelsUsingStaging(
    modelURLs: [String: URL],
    pldaJSONURL: URL
) async throws -> OfflineDiarizerModels {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL
    let stagingRoot = temporaryDirectory
        .appendingPathComponent("diarization-frontend-oracle-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    guard
        stagingRoot.deletingLastPathComponent() == temporaryDirectory,
        stagingRoot.lastPathComponent.hasPrefix("diarization-frontend-oracle-")
    else {
        throw DiarizationFrontendParityError.invalidModelAsset(
            "temporary staging root is outside its required directory or basename prefix"
        )
    }
    try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
    try verifyDiarizationFrontendStagingRoot(stagingRoot, temporaryDirectory: temporaryDirectory)

    let models: OfflineDiarizerModels
    do {
        let repositoryDirectory = stagingRoot.appendingPathComponent("speaker-diarization", isDirectory: true)
        try fileManager.createDirectory(at: repositoryDirectory, withIntermediateDirectories: false)
        for (name, sourceURL) in modelURLs {
            let stagedURL = repositoryDirectory.appendingPathComponent(name, isDirectory: true)
            try fileManager.createSymbolicLink(at: stagedURL, withDestinationURL: sourceURL)
        }
        let stagedPLDAURL = repositoryDirectory.appendingPathComponent("plda-parameters.json", isDirectory: false)
        try fileManager.createSymbolicLink(at: stagedPLDAURL, withDestinationURL: pldaJSONURL)
        let markerURL = repositoryDirectory.appendingPathComponent(".fluidaudio-revision", isDirectory: false)
        try Data("df2625ac79a7ac6b65ad868fee6d80f320da4232\n".utf8).write(to: markerURL)

        // offlineMode prevents ModelHub from downloading, purging, or recovering source assets.
        // Restore prior process state even when Core ML rejects a corrupt compiled bundle.
        let previousOfflineMode = ModelHub.offlineMode
        ModelHub.offlineMode = true
        do {
            defer { ModelHub.offlineMode = previousOfflineMode }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            models = try await OfflineDiarizerModels.load(
                from: stagingRoot,
                configuration: configuration,
                progressHandler: nil
            )
        }
    } catch {
        try removeDiarizationFrontendStagingRoot(stagingRoot, temporaryDirectory: temporaryDirectory)
        throw error
    }

    try removeDiarizationFrontendStagingRoot(stagingRoot, temporaryDirectory: temporaryDirectory)
    return models
}

private func verifyDiarizationFrontendStagingRoot(_ root: URL, temporaryDirectory: URL) throws {
    guard
        root.standardizedFileURL.deletingLastPathComponent() == temporaryDirectory.standardizedFileURL,
        root.lastPathComponent.hasPrefix("diarization-frontend-oracle-")
    else {
        throw DiarizationFrontendParityError.invalidModelAsset(
            "refusing staging cleanup outside the validated temporary root or basename prefix"
        )
    }
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw DiarizationFrontendParityError.invalidModelAsset(
            "refusing staging cleanup because the saved temporary root is not a real directory"
        )
    }
}

private func removeDiarizationFrontendStagingRoot(_ root: URL, temporaryDirectory: URL) throws {
    try verifyDiarizationFrontendStagingRoot(root, temporaryDirectory: temporaryDirectory)
    try FileManager.default.removeItem(at: root)
}

private func makeDecoderLogits() -> [Float] {
    let frames = 589
    let classes = 7
    var logits = [Float](repeating: -1, count: frames * classes)
    for frame in 0..<frames {
        let classIndex = frame % classes
        if frame == 28 {
            for classValue in 0..<classes {
                logits[frame * classes + classValue] = 0
            }
        } else if (7..<28).contains(frame) {
            for classValue in 0..<classes {
                logits[frame * classes + classValue] = -1
            }
            let tieIndex = frame - 7
            var pairIndex = 0
            for firstClass in 0..<classes {
                for secondClass in (firstClass + 1)..<classes {
                    if pairIndex == tieIndex {
                        logits[frame * classes + firstClass] = 0
                        logits[frame * classes + secondClass] = 0
                    }
                    pairIndex += 1
                }
            }
        } else {
            logits[frame * classes + classIndex] = 0
        }
    }
    return logits
}

private func makeMaskCases() -> [DiarizationFrontendMaskCase] {
    func blank() -> [Float] { [Float](repeating: 0, count: 589 * 3) }
    func set(_ values: inout [Float], slot: Int, range: Range<Int>, value: Float) {
        for frame in range {
            values[frame * 3 + slot] = value
        }
    }

    let zero = blank()
    var one = blank()
    set(&one, slot: 0, range: 0..<589, value: 1)
    var two = blank()
    set(&two, slot: 0, range: 0..<295, value: 1)
    set(&two, slot: 1, range: 295..<589, value: 1)
    var three = blank()
    set(&three, slot: 0, range: 0..<118, value: 1)
    set(&three, slot: 1, range: 180..<298, value: 1)
    set(&three, slot: 2, range: 400..<518, value: 1)
    var overlapAll = blank()
    for slot in 0..<3 { set(&overlapAll, slot: slot, range: 0..<589, value: 1) }
    var overlapExcluded = blank()
    set(&overlapExcluded, slot: 0, range: 0..<200, value: 1)
    set(&overlapExcluded, slot: 1, range: 0..<20, value: 1)

    func thresholdCase(_ fraction: Float) -> [Float] {
        var values = blank()
        set(&values, slot: 0, range: 0..<200, value: 1)
        values[50 * 3 + 1] = fraction
        return values
    }

    func cleanPrefix(_ count: Int) -> [Float] {
        var values = blank()
        set(&values, slot: 0, range: 0..<count, value: 1)
        return values
    }

    func ratioBoundary(_ adjustment: Float) -> [Float] {
        var values = blank()
        set(&values, slot: 0, range: 0..<117, value: 1)
        values[117 * 3] = Float(589) * Float(0.2) - Float(117) + adjustment
        return values
    }

    let overlapThreshold = Float(1e-3)
    let ratioCases: [(String, [Float])] = [
        ("ratio-below", ratioBoundary(-0.01)),
        ("ratio-exact", ratioBoundary(0)),
        ("ratio-above", ratioBoundary(0.01)),
    ]
    return [
        DiarizationFrontendMaskCase(name: "zero-active", speakerWeights: zero),
        DiarizationFrontendMaskCase(name: "one-active", speakerWeights: one),
        DiarizationFrontendMaskCase(name: "two-active", speakerWeights: two),
        DiarizationFrontendMaskCase(name: "three-active", speakerWeights: three),
        DiarizationFrontendMaskCase(name: "overlap-all", speakerWeights: overlapAll),
        DiarizationFrontendMaskCase(name: "overlap-excluded", speakerWeights: overlapExcluded),
        DiarizationFrontendMaskCase(name: "overlap-nextDown", speakerWeights: thresholdCase(overlapThreshold.nextDown)),
        DiarizationFrontendMaskCase(name: "overlap-exact", speakerWeights: thresholdCase(overlapThreshold)),
        DiarizationFrontendMaskCase(name: "overlap-nextUp", speakerWeights: thresholdCase(overlapThreshold.nextUp)),
        DiarizationFrontendMaskCase(name: "clean-17", speakerWeights: cleanPrefix(17)),
        DiarizationFrontendMaskCase(name: "clean-18", speakerWeights: cleanPrefix(18)),
        DiarizationFrontendMaskCase(name: "clean-117", speakerWeights: cleanPrefix(117)),
        DiarizationFrontendMaskCase(name: "clean-118", speakerWeights: cleanPrefix(118)),
    ] + ratioCases.map { DiarizationFrontendMaskCase(name: $0.0, speakerWeights: $0.1) }
}

private func makeInterpolationCases() -> [DiarizationFrontendInterpolationCase] {
    let zero = [Float](repeating: 0, count: 589)
    let ones = [Float](repeating: 1, count: 589)
    let ramp = (0..<589).map { Float($0) / 588 }
    let alternating = (0..<589).map { $0.isMultiple(of: 2) ? Float(1) : Float(0) }
    let scattered = (0..<589).map { Float(($0 * 37) % 101) / 100 }
    var endpoints = [Float](repeating: 0, count: 589)
    endpoints[0] = 1
    endpoints[588] = 1
    return [
        DiarizationFrontendInterpolationCase(name: "zero", input: zero),
        DiarizationFrontendInterpolationCase(name: "ones", input: ones),
        DiarizationFrontendInterpolationCase(name: "ramp", input: ramp),
        DiarizationFrontendInterpolationCase(name: "alternating", input: alternating),
        DiarizationFrontendInterpolationCase(name: "scattered", input: scattered),
        DiarizationFrontendInterpolationCase(name: "endpoints", input: endpoints),
    ]
}

// Pinned probe-report.md lines 911, 967, and 1011 distinguish graph FP16 values from pure geometry.
private func alignCornersPoolingReference(_ input: [Float]) -> [Float] {
    precondition(input.count == 589)
    var reference = [Float](repeating: 0, count: 589)
    for outputIndex in 0..<125 {
        let coordinate = Double(outputIndex) * 588.0 / 124.0
        let left = Int(floor(coordinate))
        let right = min(left + 1, 588)
        let rightCoefficient = Float(coordinate - Double(left))
        let leftCoefficient = Float(1) - rightCoefficient
        let value = input[left] * leftCoefficient + input[right] * rightCoefficient
        let scatterIndex = outputIndex * 589 / 125
        reference[scatterIndex] = value
    }
    return reference
}

private func checkOrWriteFrontendFixture(_ fixture: [String: Any]) throws {
    let encoded = try JSONSerialization.data(
        withJSONObject: fixture,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    var contents = encoded
    contents.append(0x0A)
    guard contents.count <= 1_048_576 else {
        throw DiarizationFrontendParityError.invalidModelAsset(
            "frontend.json is \(contents.count) bytes; maximum is 1048576 bytes"
        )
    }

    let sourcePackageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let resourcesURL = sourcePackageRoot
        .appendingPathComponent("Tests", isDirectory: true)
        .appendingPathComponent("MacAmbientJevDiarizationTests", isDirectory: true)
        .appendingPathComponent("Resources", isDirectory: true)
    let fixtureURL = resourcesURL.appendingPathComponent("frontend.json", isDirectory: false)
    if ProcessInfo.processInfo.environment["MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY"] == "1" {
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try contents.write(to: fixtureURL, options: .atomic)
        return
    }

    guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
        throw DiarizationFrontendParityError.invalidModelAsset(
            "frontend.json is missing: \(fixtureURL.path); set MAC_AMBIENT_JEV_WRITE_DIARIZATION_PARITY=1 to generate it"
        )
    }
    let committed = try Data(contentsOf: fixtureURL)
    guard committed.count <= 1_048_576 else {
        throw DiarizationFrontendParityError.invalidModelAsset(
            "committed frontend.json is \(committed.count) bytes; maximum is 1048576 bytes"
        )
    }
    #expect(committed == contents, "frontend.json must exactly match canonical fresh oracle output")
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
#endif
