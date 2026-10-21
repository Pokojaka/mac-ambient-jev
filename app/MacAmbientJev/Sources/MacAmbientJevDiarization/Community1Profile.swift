// Pinned to FluidAudio 0.15.8, revision 87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc.
import Foundation

/// Fixed numerical profile for the portable Community-1 diarizer.
enum Community1Profile {
    /// Community sample rate; FluidAudio `OfflineDiarizerTypes.swift:46-55`.
    static let sampleRate: Int = 16_000

    /// Ten seconds of audio at the community sample rate; FluidAudio `OfflineDiarizerTypes.swift:46-52,347-350`.
    static let windowSamples: Int = 160_000

    /// Community step is 20% of the window; FluidAudio `OfflineDiarizerTypes.swift:46-52,352-354`.
    static let stepSamples: Int = 32_000

    /// Community window duration; FluidAudio `OfflineDiarizerTypes.swift:46-48`.
    static let windowDurationSeconds: Double = 10.0

    /// Community step-to-window ratio; FluidAudio `OfflineDiarizerTypes.swift:46-52`.
    static let stepRatio: Double = 0.2

    /// 589 segmentation frames; FluidAudio resolves the embedding mask-weight frame count at `OfflineEmbeddingExtractor.swift:147-151`, matching the output frame dimension in compiled `Segmentation.mlmodelc/model.mil`.
    static let segmentationFrames: Int = 589

    /// Seven model output classes in the frozen Community-1 contract; FluidAudio's class-to-local-speaker lookup is `OfflineSegmentationProcessor.swift:15-24,327-369`, while the profile's graph shape is recorded in `candidate-sol/design.md:106`.
    static let powersetClasses: Int = 7

    /// Three local speaker slots in the pinned powerset table; FluidAudio `OfflineSegmentationProcessor.swift:15-24`.
    static let localSpeakers: Int = 3

    /// Embedding vector width; FluidAudio `PLDATransform.swift:13-14,29-32`, compiled embedding graph `Embedding.mlmodelc/model.mil:4,413-427`.
    static let embeddingDimensions: Int = 256

    /// PLDA rho vector width; FluidAudio `PLDATransform.swift:13-14,149-159`, compiled rho graph `PldaRho.mlmodelc/model.mil:4-7,35-39`.
    static let rhoDimensions: Int = 128

    /// Compiled fbank frame count; the FluidAudio graph boundary is `OfflineEmbeddingExtractor.swift:750-757`, and `FBank.mlmodelc/model.mil:18-21,85-86` fixes 998 frames.
    static let fbankFrames: Int = 998

    /// Compiled mel-bin count; the FluidAudio graph boundary is `OfflineEmbeddingExtractor.swift:750-757`, and `FBank.mlmodelc/model.mil:5,77-80` has 80 mel channels.
    static let melBins: Int = 80

    /// Mask-pooling frame count; the FluidAudio graph boundary is `OfflineEmbeddingExtractor.swift:872-894`, and `Embedding.mlmodelc/model.mil:14-17` pools to 125 frames.
    static let poolingFrames: Int = 125

    /// Powerset class-to-speaker bitmask order; `OfflineSegmentationProcessor.swift:15-24,368-399`. Argmax scans upward and updates only on strict `>`, so equal logits retain the first class (`:327-335`).
    static let powersetSpeakerBits: [UInt8] = [0, 1, 2, 4, 3, 5, 6]

    /// Overlap requires a weight strictly greater than 1e-3; FluidAudio `OfflineEmbeddingExtractor.swift:306,431-444`.
    static let overlapThreshold: Float = 1e-3

    /// Clean-mask acceptance is inclusive at 20%; FluidAudio `OfflineEmbeddingExtractor.swift:518-523` rejects only when the sum is less than this frame-count ratio.
    static let minimumActiveRatio: Float = 0.2

    /// Ceiling of the 0.3-second minimum over 589 frames in a 10-second window; FluidAudio's ceiling gate is `OfflineEmbeddingExtractor.swift:381-386`, and the 0.3-second application override is recorded in `candidate-sol/design.md:99` (FluidAudio's own default is 1.0 second at `OfflineDiarizerTypes.swift:100-105`).
    static let minimumEmbeddingFrames: Int = 18

    /// Ceiling of the inclusive 20% active-mask gate over 589 frames; FluidAudio `OfflineEmbeddingExtractor.swift:518-523`.
    static let minimumActiveFrames: Int = 118

    /// Application override of 0.3 seconds, not FluidAudio's 1.0-second embedding default; `OfflineDiarizerTypes.swift:100-105`, `design-final.md:17-18`, and `candidate-sol/design.md:99`.
    static let minimumSegmentSeconds: Double = 0.3

    /// Compiled fbank input amplitude scale; FluidAudio graph boundary `OfflineEmbeddingExtractor.swift:750-757`, `FBank.mlmodelc/model.mil:11-12`.
    static let waveformScale: Float = 32_768

    /// Compiled fbank window length; FluidAudio graph boundary `OfflineEmbeddingExtractor.swift:750-757`, `FBank.mlmodelc/model.mil:8,10,18-21`.
    static let frameLengthSamples: Int = 400

    /// Compiled fbank frame shift; FluidAudio graph boundary `OfflineEmbeddingExtractor.swift:750-757`, `FBank.mlmodelc/model.mil:14-18`.
    static let frameShiftSamples: Int = 160

    /// Compiled fbank FFT width; FluidAudio graph boundary `OfflineEmbeddingExtractor.swift:750-757`, `FBank.mlmodelc/model.mil:46-54`.
    static let fftSize: Int = 512

    /// Lower mel-bank edge in the frozen frontend profile; FluidAudio graph boundary `OfflineEmbeddingExtractor.swift:750-757`, compiled mel weights `FBank.mlmodelc/model.mil:5`, profile `candidate-sol/design.md:100`.
    static let lowFrequencyHz: Float = 20

    /// Upper mel-bank edge in the frozen frontend profile; FluidAudio graph boundary `OfflineEmbeddingExtractor.swift:750-757`, compiled mel weights `FBank.mlmodelc/model.mil:5`, profile `candidate-sol/design.md:100`.
    static let highFrequencyHz: Float = 8_000

    /// One-sided spectrum width (fftSize / 2 + 1); the compiled DFT and mel weights are `[257, 1, 512]` and `[80, 257, 1]`, `FBank.mlmodelc/model.mil:5-7`.
    static let fftBins: Int = 257

    /// Mel scale slope 1127 (Kaldi mel scale, `mel = 1127 * ln(1 + f / 700)`); the compiled mel weights `FBank.mlmodelc/model.mil:5` match this triangular bank within 1.4e-5 (checked against `weights/weight.bin`), profile `candidate-sol/design.md:100`.
    static let melScaleSlope: Double = 1_127

    /// Mel scale break frequency in Hz; same source as `melScaleSlope`.
    static let melScaleBreakHz: Double = 700

    /// Compiled first-sample preemphasis coefficient; FluidAudio graph boundary `OfflineEmbeddingExtractor.swift:750-757`, `FBank.mlmodelc/model.mil:35-42`.
    static let preemphasis: Float = 0.97

    /// Hamming-window alpha in the frozen frontend profile; FluidAudio graph boundary `OfflineEmbeddingExtractor.swift:750-757`, compiled window weights `FBank.mlmodelc/model.mil:8`, profile `candidate-sol/design.md:100`.
    static let hammingAlpha: Float = 0.54

    /// Hamming-window beta in the frozen frontend profile; FluidAudio graph boundary `OfflineEmbeddingExtractor.swift:750-757`, compiled window weights `FBank.mlmodelc/model.mil:8`, profile `candidate-sol/design.md:100`.
    static let hammingBeta: Float = 0.46

    /// Compiled fbank epsilon added before the lower clamp; FluidAudio graph boundary `OfflineEmbeddingExtractor.swift:750-757`, `FBank.mlmodelc/model.mil:9,80-84`.
    static let logEnergyOffset: Float = 1e-6

    /// Compiled fbank lower energy clamp before log; FluidAudio graph boundary `OfflineEmbeddingExtractor.swift:750-757`, `FBank.mlmodelc/model.mil:9,80-84`.
    static let logEnergyFloor: Float = 1e-6

    /// Embedding L2 floor 1e-4 is a graph/profile fact, not a Swift call-site parameter; FluidAudio invokes the graph in `OfflineEmbeddingExtractor.swift:872-894`, compiled normalization is `Embedding.mlmodelc/model.mil:419-427`, and the profile policy is `design-final.md:17`, `candidate-sol/design.md:101`.
    static let embeddingL2Floor: Float = 1e-4

    /// Squared norm clip before the first PLDA square root; compiled graph `PldaRho.mlmodelc/model.mil:12-21`.
    static let pldaFirstSquaredNormFloor: Float = 1e-12

    /// Squared norm clip before the second PLDA square root; compiled graph `PldaRho.mlmodelc/model.mil:27-35`.
    static let pldaSecondSquaredNormFloor: Float = 1e-12

    /// First transform scale sqrt(256)=16; compiled graph `PldaRho.mlmodelc/model.mil:24-26`.
    static let pldaFirstTransformScale: Float = 16

    /// Second transform scale sqrt(128), with the graph's Float32 literal; compiled graph `PldaRho.mlmodelc/model.mil:8,34-36`.
    static let pldaSecondTransformScale: Float = 0x1.6a09e6p+3

    /// Portable deterministic eigensolver sweep cap (64), a design-only policy rather than a FluidAudio constant; graph boundary `PLDATransform.swift:149-159`, `candidate-sol/design.md:102`.
    static let pldaEigenMaximumSweeps: Int = 64

    /// Portable eigensolver and generalized-eigen residual tolerance, a design-only policy rather than a FluidAudio constant; graph boundary `PLDATransform.swift:149-159`, `candidate-sol/design.md:102`.
    static let pldaEigenRelativeTolerance: Double = 1e-12

    /// Community AHC cut threshold; FluidAudio `OfflineDiarizerTypes.swift:120-126,155-163`, with Euclidean cut and subtree traversal in `AHCClustering.swift:107-120,150-188`.
    static let ahcThreshold: Double = 0.6

    /// VBx initialization smoothing; FluidAudio passes 7.0 at `VBxClustering.swift:120-133`.
    static let initializationSmoothing: Double = 7

    /// VBx Fa warm-start parameter; FluidAudio `OfflineDiarizerTypes.swift:155-162,184-192`, forwarded at `VBxClustering.swift:128-132`.
    static let fa: Double = 0.07

    /// VBx Fb warm-start parameter; FluidAudio `OfflineDiarizerTypes.swift:155-162,184-192`, forwarded at `VBxClustering.swift:128-132`.
    static let fb: Double = 0.8

    /// Maximum VBx iterations; FluidAudio `OfflineDiarizerTypes.swift:184-192`, consumed by `VBxClustering.swift:121-133,302-304`.
    static let maximumIterations: Int = 20

    /// VBx absolute ELBO convergence tolerance; FluidAudio `OfflineDiarizerTypes.swift:184-192`, `VBxClustering.swift:654-660`.
    static let elboTolerance: Double = 1e-4

    /// VBx phi lower bound; FluidAudio `VBxClustering.swift:240-241`.
    static let phiFloor: Double = 1e-12

    /// Inverse-precision denominator lower bound; FluidAudio `VBxClustering.swift:331-337`.
    static let inversePrecisionDenominatorFloor: Double = 1e-12

    /// VBx log-prior lower bound; FluidAudio `VBxClustering.swift:497-516`.
    static let logPriorFloor: Double = 1e-8

    /// Active VBx prior cutoff, with activity requiring pi strictly greater than epsilon; FluidAudio `OfflineDiarizerManager.swift:720-725` and `OfflineDiarizerTypes.swift:663-677`.
    static let activePriorThreshold: Double = 1e-7

    /// Hungarian score quantization scale; FluidAudio `HungarianAssignment.swift:78-88`.
    static let hungarianQuantization: Double = 1e6

    /// Community minimum segment gap; FluidAudio `OfflineDiarizerTypes.swift:203-215`.
    static let minimumGapSeconds: Double = 0.1

    /// Community minimum-on duration; FluidAudio `OfflineDiarizerTypes.swift:46-55`.
    static let minimumOnSeconds: Double = 0

    /// Community minimum-off duration; FluidAudio `OfflineDiarizerTypes.swift:46-55`.
    static let minimumOffSeconds: Double = 0
}
