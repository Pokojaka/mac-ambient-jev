import Foundation
import MacAmbientJevCore

/// One deterministic input for comparing two VAD engines, built from the speech clip.
public struct VADParityCase: Sendable {
    public enum Step: Sendable {
        case clip
        case silence(samples: Int)
    }

    public let name: String
    public let steps: [Step]

    public func samples(clip: [Float]) -> [Float] {
        steps.flatMap { step -> [Float] in
            switch step {
            case .clip: clip
            case let .silence(samples): [Float](repeating: 0, count: samples)
            }
        }
    }

    public static let all = [
        VADParityCase(name: "speech_clip", steps: [.clip]),
        // Pauses above and below the 0.75 s minimum silence, an unbroken utterance of about 19 s that
        // the 14 s split must cut, and a recording that ends inside speech on a partial chunk.
        VADParityCase(name: "pauses_and_long_utterance", steps: [
            .silence(samples: 16_000),
            .clip,
            .silence(samples: 24_000),
            .clip,
            .silence(samples: 6_400),
            .clip,
            .silence(samples: 16_000),
            .clip, .silence(samples: 4_800),
            .clip, .silence(samples: 4_800),
            .clip, .silence(samples: 4_800),
            .clip,
            .silence(samples: 32_000),
            .clip,
            .silence(samples: 1_234)
        ])
    ]
}

/// Largest allowed absolute difference between two engines' chunk probabilities.
public enum VADParityTolerance {
    /// Core ML runs the Mac model in mixed float16 and rounds its recurrent state to float16 after
    /// every 32 ms frame, so its probabilities drift from the float32 ONNX export by up to 0.2015
    /// (measured, right after a speech end). Both engines must still agree on which side of every
    /// decision threshold each chunk lies.
    public static let onnxVersusCoreML: Float = 0.25
    /// The same Core ML model on another Mac.
    public static let coreMLVersusCommitted: Float = 0.05
}

/// What the Mac engine (FluidAudio) produced for one case: the reference for every other engine.
public struct VADParityExpectation: Codable, Sendable {
    public struct Segment: Codable, Sendable, Equatable {
        public let startFrame: Int64
        public let endFrame: Int64

        public init(startFrame: Int64, endFrame: Int64) {
            self.startFrame = startFrame
            self.endFrame = endFrame
        }
    }

    public let name: String
    public let sampleCount: Int
    public let chunkProbabilities: [Float]
    public let segments: [Segment]

    public init(name: String, sampleCount: Int, chunkProbabilities: [Float], segments: [Segment]) {
        self.name = name
        self.sampleCount = sampleCount
        self.chunkProbabilities = chunkProbabilities
        self.segments = segments
    }
}

public struct VADParityFile: Codable, Sendable {
    public let generator: String
    public let cases: [VADParityExpectation]

    public init(generator: String, cases: [VADParityExpectation]) {
        self.generator = generator
        self.cases = cases
    }

    public static func load() throws -> VADParityFile {
        try JSONDecoder().decode(VADParityFile.self, from: Data(contentsOf: SileroTestInputs.parityFixtureURL))
    }

    public func write() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(self) + Data("\n".utf8)).write(to: SileroTestInputs.parityFixtureURL, options: .atomic)
    }

    public func expectation(named name: String) throws -> VADParityExpectation {
        guard let match = cases.first(where: { $0.name == name }) else {
            throw SileroFixtureError.invalid("vad_parity.jsonに\(name)がありません。")
        }
        return match
    }
}

/// An in-memory canonical timeline for running a VAD engine over a case.
public struct VADParityTimeline: TimelineAudioReading {
    public let info: TimelineAudioInfo
    private let samples: [Float]

    public init(samples: [Float]) throws {
        self.samples = samples
        info = try TimelineAudioInfo(committedFrames: Int64(samples.count), gapEvents: [])
    }

    public func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        Array(samples[Int(frameRange.lowerBound)..<Int(frameRange.upperBound)])
    }

    public func validateAudio() throws {}
}
