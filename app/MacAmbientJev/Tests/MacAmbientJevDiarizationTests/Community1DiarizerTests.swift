import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevDiarization

private let voiceAAmplitude: Float = 0.1
private let voiceBAmplitude: Float = 0.2

/// Deterministic stand-in for the two models. Voice A (amplitude 0.1) and voice B (0.2) are told
/// apart by their samples; the local slot of each voice alternates with the window parity so that
/// slot identity has to be kept by the kernel.
private final class FakeInference: Community1Inference, @unchecked Sendable {
    var segmentCalls = 0
    var embedCalls = 0
    var nonfiniteMasks: [(window: Int, mask: Int)] = []
    var allNonfinite = false
    var embeddingCountOffset = 0
    var vectorLength = Community1Profile.embeddingDimensions
    private var lastWindow: WindowAudio?

    func segment(_ window: WindowAudio) throws -> PowersetScores {
        segmentCalls += 1
        lastWindow = window
        let frames = Community1Profile.segmentationFrames
        let classes = Community1Profile.powersetClasses
        let windowIndex = Int(window.startFrame) / Community1Profile.stepSamples
        var scores = [Float](repeating: -10, count: frames * classes)
        for frame in 0..<frames {
            var chosenClass = 0
            switch Self.voice(in: window, frame: frame) {
            case .some(.a): chosenClass = windowIndex % 2 == 0 ? 1 : 3
            case .some(.b): chosenClass = windowIndex % 2 == 0 ? 2 : 1
            case .none: chosenClass = 0
            }
            scores[frame * classes + chosenClass] = 0
        }
        return try PowersetScores(logProbabilities: scores)
    }

    func embed(features: Community1FbankFeatures, masks: [SpeakerMask]) throws -> [[Float]] {
        embedCalls += 1
        let window = try #require(lastWindow)
        let windowIndex = Int(window.startFrame) / Community1Profile.stepSamples
        var vectors: [[Float]] = []
        for (maskIndex, mask) in masks.enumerated() {
            let firstFrame = try #require(mask.activity.values.firstIndex(where: { $0 > 0 }))
            let voice = try #require(Self.voice(in: window, frame: firstFrame))
            var vector = [Float](repeating: .nan, count: vectorLength)
            if !(allNonfinite || nonfiniteMasks.contains(where: { $0.window == windowIndex && $0.mask == maskIndex })) {
                vector = Self.vector(voice: voice, windowIndex: windowIndex, maskIndex: maskIndex, length: vectorLength)
            }
            vectors.append(vector)
        }
        return Array(vectors.dropLast(max(embeddingCountOffset, 0)))
    }

    enum Voice { case a, b }

    static func voice(in window: WindowAudio, frame: Int) -> Voice? {
        let center = Int((Double(frame) + 0.5) * Double(Community1Profile.windowSamples)
            / Double(Community1Profile.segmentationFrames))
        let amplitude = window.samples[center]
        if abs(amplitude - voiceAAmplitude) < 1e-6 { return .a }
        if abs(amplitude - voiceBAmplitude) < 1e-6 { return .b }
        return nil
    }

    static func vector(voice: Voice, windowIndex: Int, maskIndex: Int, length: Int) -> [Float] {
        var state = UInt64(voice == .a ? 11 : 29)
        func next(_ state: inout UInt64) -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 2 * Double(state >> 11) / 9_007_199_254_740_992 - 1
        }
        var noiseState = UInt64(1_000 + windowIndex * 3 + maskIndex)
        return (0..<length).map { _ in
            Float(3 * next(&state) + 0.01 * next(&noiseState))
        }
    }
}

private let sharedPLDA: Result<Community1PLDA, Error> = Result {
    try Community1PLDA(
        pldaData: DiarizationParityFixtures.data(named: "plda-parameters.json"),
        xvectorData: DiarizationParityFixtures.data(named: "xvector-transform.json"),
        coordinateSigns: Community1Manifest.bundled().coordinateSigns
    )
}

private func diarizer() throws -> Community1Diarizer {
    Community1Diarizer(plda: try sharedPLDA.get())
}

private let clipSamples: Int64 = 64_000
private let clipSwitchSample: Int64 = 32_000
/// Voice A only; the final window is mostly padding, so exactly one window is embedded.
private let shortClipSamples: Int64 = 50_200

/// One complete run with an untouched fake, kept so that the tests which only read the result
/// share a single pipeline run of each clip.
private struct Run {
    let spans: [SpeakerSpan]
    let segmentCalls: Int
    let embedCalls: Int
}

private func execute(sampleCount: Int64, switchSample: Int64) throws -> Run {
    let inference = FakeInference()
    let spans = try diarizer().diarize(
        sampleCount: sampleCount,
        readFrames: twoVoiceReader(switchSample: switchSample),
        inference: inference
    )
    return Run(spans: spans, segmentCalls: inference.segmentCalls, embedCalls: inference.embedCalls)
}

private let healthyRun: Result<Run, Error> = Result {
    try execute(sampleCount: clipSamples, switchSample: clipSwitchSample)
}

private let shortRun: Result<Run, Error> = Result {
    try execute(sampleCount: shortClipSamples, switchSample: 1_000_000)
}

/// Voice A for the first `switchSample` samples of the clip and voice B after that.
private func twoVoiceReader(switchSample: Int64) -> (Range<Int64>) -> [Float] {
    { range in
        range.map { $0 < switchSample ? voiceAAmplitude : voiceBAmplitude }
    }
}

@Suite(.serialized) struct Community1DiarizerTests {
    @Test func twoVoicesKeepTheirIdentityAcrossSlotPermutations() throws {
        let sampleCount = clipSamples
        let switchSample = clipSwitchSample
        let spans = try healthyRun.get().spans
        #expect(Set(spans.map(\.speakerID)) == ["S1", "S2"])
        let frameTolerance: Int64 = 2 * 272
        let first = try #require(spans.first)
        #expect(first.speakerID == "S1")
        #expect(first.startFrame <= frameTolerance)
        let last = try #require(spans.last)
        #expect(last.speakerID == "S2")
        #expect(sampleCount - last.endFrame <= frameTolerance)
        for span in spans {
            let expectedSpeaker = span.startFrame < switchSample - frameTolerance ? "S1" : "S2"
            #expect(span.speakerID == expectedSpeaker)
            #expect(span.endFrame > span.startFrame)
        }
        let switchSpan = try #require(spans.first { $0.speakerID == "S2" })
        #expect(abs(switchSpan.startFrame - switchSample) <= 4 * 272)
    }

    @Test func repeatedRunsAreIdenticalAndShareNoState() throws {
        let first = try shortRun.get()
        let other = try healthyRun.get()
        let second = try execute(sampleCount: shortClipSamples, switchSample: 1_000_000)
        #expect(!other.spans.isEmpty)
        #expect(first.spans == second.spans)
    }

    @Test func shortInputIsPaddedAndEndClampedToTheAudio() throws {
        let run = try shortRun.get()
        #expect(run.segmentCalls == 2)
        #expect(run.embedCalls == 1)
        let span = try #require(run.spans.first)
        #expect(run.spans.count == 1)
        #expect(span.speakerID == "S1")
        #expect(span.startFrame == 0)
        #expect(span.endFrame == shortClipSamples)
    }

    @Test func noSamplesAndNoExtractedSlotAreNoSpeech() throws {
        let engine = try diarizer()
        let empty = FakeInference()
        #expect(throws: Community1Error.self) {
            try engine.diarize(sampleCount: 0, readFrames: { _ in [] }, inference: empty)
        }
        #expect(empty.segmentCalls == 0)

        let silent = FakeInference()
        let error = try #require(throws: Community1Error.self) {
            try engine.diarize(
                sampleCount: 64_000,
                readFrames: { range in [Float](repeating: 0, count: range.count) },
                inference: silent
            )
        }
        guard case .noSpeechDetected = error else {
            Issue.record("expected noSpeechDetected; got \(error)")
            return
        }
        #expect(silent.segmentCalls == 2)
        #expect(silent.embedCalls == 0)
    }

    @Test func onlyNonfiniteEmbeddingsFailWithoutAClusterFallback() throws {
        let inference = FakeInference()
        inference.allNonfinite = true
        let error = try #require(throws: Community1Error.self) {
            try diarizer().diarize(
                sampleCount: shortClipSamples,
                readFrames: twoVoiceReader(switchSample: 1_000_000),
                inference: inference
            )
        }
        guard case .noFiniteTrainingEmbeddings = error else {
            Issue.record("expected noFiniteTrainingEmbeddings; got \(error)")
            return
        }
        #expect(inference.embedCalls > 0)
    }

    @Test func aNonfiniteSlotDoesNotTrainClustersButStillTakesPartInAssignment() throws {
        let reader = twoVoiceReader(switchSample: clipSwitchSample)
        let healthy = try healthyRun.get().spans
        let damaged = FakeInference()
        damaged.nonfiniteMasks = [(window: 0, mask: 1)]
        let spans = try diarizer().diarize(sampleCount: clipSamples, readFrames: reader, inference: damaged)
        #expect(damaged.embedCalls == 2)
        #expect(spans == healthy)
    }

    @Test func structuralMismatchesFailClearly() throws {
        let engine = try diarizer()
        let reader = twoVoiceReader(switchSample: 1_000_000)

        let missingVector = FakeInference()
        missingVector.embeddingCountOffset = 1
        let countError = try #require(throws: Community1Error.self) {
            try engine.diarize(sampleCount: shortClipSamples, readFrames: reader, inference: missingVector)
        }
        #expect(countError.description.contains("returned 0 vectors for 1 masks"))

        let shortVector = FakeInference()
        shortVector.vectorLength = 255
        let lengthError = try #require(throws: Community1Error.self) {
            try engine.diarize(sampleCount: shortClipSamples, readFrames: reader, inference: shortVector)
        }
        #expect(lengthError.description.contains("255 values; expected 256"))

        let readerError = try #require(throws: FrontendError.self) {
            try engine.diarize(
                sampleCount: 64_000,
                readFrames: { _ in [0.1] },
                inference: FakeInference()
            )
        }
        #expect(readerError.description.contains("reader returned 1 samples"))

        #expect(throws: FrontendError.self) {
            try engine.diarize(sampleCount: -1, readFrames: { _ in [] }, inference: FakeInference())
        }
    }

    @Test func cancellationStopsAtTheWindowBoundary() async throws {
        let engine = try diarizer()
        let inference = FakeInference()
        let task = Task { () throws -> [SpeakerSpan] in
            try engine.diarize(
                sampleCount: shortClipSamples,
                readFrames: { range in
                    if range.lowerBound == 0 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return [Float](repeating: 0, count: range.count)
                },
                inference: inference
            )
        }
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("a cancelled run must not publish spans")
            return
        }
        #expect(error is CancellationError)
        #expect(inference.segmentCalls == 1)
    }

    @Test func cancellationAfterTheLastWindowStopsClusteringAndReconstruction() async throws {
        let engine = try diarizer()
        let inference = FakeInference()
        let task = Task { () throws -> [SpeakerSpan] in
            try engine.diarize(
                sampleCount: shortClipSamples,
                readFrames: { range in
                    if range.lowerBound == 32000 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return range.map { _ in voiceAAmplitude }
                },
                inference: inference
            )
        }
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("a cancelled run must not publish spans")
            return
        }
        #expect(error is CancellationError)
        #expect(inference.segmentCalls == 2)
    }
}

@Suite struct Community1ObservationTableTests {
    @Test func finiteRowsAndSlotsFormABijection() {
        let speakerBits = [UInt8](repeating: 0, count: Community1Profile.segmentationFrames)
        func finite(_ seed: Float) -> Community1SlotObservation {
            .finite(
                embedding: [Float](repeating: seed, count: Community1Profile.embeddingDimensions),
                rho: [Double](repeating: Double(seed), count: Community1Profile.rhoDimensions)
            )
        }
        var table = Community1ObservationTable()
        table.append(speakerBits: speakerBits, slots: [finite(1), .notExtracted, .nonfinite])
        table.append(speakerBits: speakerBits, slots: [.notExtracted, .notExtracted, .notExtracted])
        table.append(speakerBits: speakerBits, slots: [.nonfinite, finite(2), finite(3)])

        #expect(table.windows.count == 3)
        #expect(table.rowCount == 3)
        #expect(table.extractedSlotCount == 5)
        #expect(table.rowKeys == [
            Community1EmbeddingKey(window: 0, slot: 0),
            Community1EmbeddingKey(window: 2, slot: 1),
            Community1EmbeddingKey(window: 2, slot: 2)
        ])
        #expect(table.windows[0].slots == [.finite(row: 0), .notExtracted, .nonfinite])
        #expect(table.windows[1].slots == [.notExtracted, .notExtracted, .notExtracted])
        #expect(table.windows[2].slots == [.nonfinite, .finite(row: 1), .finite(row: 2)])
        for (row, key) in table.rowKeys.enumerated() {
            #expect(table.windows[key.window].slots[key.slot] == .finite(row: row))
        }
        #expect(table.trainingEmbeddings().map { $0[0] } == [1, 2, 3])
        #expect(table.trainingRho().map { $0[127] } == [1, 2, 3])
    }
}
