import CMiniaudio
import MacAmbientJevCore

/// Stateful conversion owned by the serialized ingress lane.
///
/// The non-identity path uses miniaudio 0.11.23's linear resampler with its eighth-order
/// low-pass filter and 0.95 Nyquist factor (7,600 Hz downsampling cutoff; manual section 10.3:
/// https://miniaud.io/docs/manual/index.html;
/// release: https://github.com/mackron/miniaudio/releases/tag/0.11.23).
/// `mja_resampler_latency` reports the rounded analytical output-frame DC group delay for this
/// Butterworth filter plus linear interpolation, not miniaudio's native section-count latency;
/// that delay is removed at stream start. At EOS, bounded zero input extends the filter state;
/// output is clipped to the rounded source-timeline boundary, so the filter tail never becomes
/// additional audio time.
public final class CanonicalAudioResampler: CanonicalAudioConverting, @unchecked Sendable {
    public let sourceSampleRate: Double

    private static let outputBufferSize = 4096
    private var resampler: OpaquePointer?
    private let isIdentity: Bool
    private var latencyFramesToDrop: UInt64 = 0
    private var ended = false
    private var failure: Error?
    private var sourceFrames: Int64 = 0
    private var emittedFrames: Int64 = 0
    private var pendingOutput: [Float] = []
    private var pendingOutputOffset = 0

    public init(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              sampleRate.rounded() == sampleRate,
              sampleRate <= Double(UInt32.max) else {
            throw CanonicalAudioError.invalidSourceFormat
        }

        sourceSampleRate = sampleRate
        isIdentity = sampleRate == CanonicalAudio.sampleRate
        guard !isIdentity else { return }

        var created: OpaquePointer?
        let result = mja_resampler_create(UInt32(sampleRate), &created)
        guard result == 0 else {
            throw CanonicalAudioError.conversionFailed(
                "miniaudio のリサンプラー作成に失敗しました (エラーコード: \(result))"
            )
        }
        guard let created else {
            throw CanonicalAudioError.conversionFailed(
                "miniaudio のリサンプラー作成に失敗しました (エラーコード: \(result))"
            )
        }

        let latency = mja_resampler_latency(created)
        guard latency <= UInt64(Int64.max) else {
            mja_resampler_destroy(created)
            throw CanonicalAudioError.conversionFailed("miniaudio が不正なレイテンシを返しました")
        }
        resampler = created
        latencyFramesToDrop = latency
    }

    deinit {
        if let resampler { mja_resampler_destroy(resampler) }
    }

    public func convert(mono: [Float]) throws -> [Float] {
        if let failure { throw failure }
        guard !ended else { throw CanonicalAudioError.alreadyFinished }
        guard mono.allSatisfy(\.isFinite) else { throw CanonicalAudioError.invalidSamples }
        guard !mono.isEmpty else { return [] }

        let (nextSourceFrames, sourceOverflow) = sourceFrames.addingReportingOverflow(Int64(mono.count))
        guard !sourceOverflow else { throw CanonicalAudioError.invalidSamples }
        let targetFrames = try CanonicalAudio.boundary(nextSourceFrames, sampleRate: sourceSampleRate)
        sourceFrames = nextSourceFrames

        if isIdentity {
            let (nextEmittedFrames, emittedOverflow) = emittedFrames.addingReportingOverflow(Int64(mono.count))
            guard !emittedOverflow else { throw CanonicalAudioError.invalidSamples }
            emittedFrames = nextEmittedFrames
            return mono
        }

        do {
            var output: [Float] = []
            try emitPending(upTo: targetFrames, into: &output)
            try mono.withUnsafeBufferPointer { input in
                guard let baseAddress = input.baseAddress else { throw CanonicalAudioError.invalidSamples }
                try process(input: baseAddress, frameCount: input.count, targetFrames: targetFrames,
                            stopAtTarget: false, into: &output)
            }
            return output
        } catch {
            failure = error
            throw error
        }
    }

    public func finish() throws -> [Float] {
        if let failure { throw failure }
        guard !ended else { return [] }

        do {
            let targetFrames = try CanonicalAudio.boundary(sourceFrames, sampleRate: sourceSampleRate)
            if isIdentity {
                guard emittedFrames == targetFrames else {
                    throw CanonicalAudioError.frameCountMismatch(expected: targetFrames, actual: emittedFrames)
                }
                ended = true
                return []
            }

            var output: [Float] = []
            try emitPending(upTo: targetFrames, into: &output)
            if emittedFrames < targetFrames {
                // miniaudio rejects nil input with a nonzero length, so EOS is explicitly
                // represented by this bounded buffer of real zeros, fed until the timeline is full.
                let zeroInput = [Float](repeating: 0, count: Self.outputBufferSize)
                try zeroInput.withUnsafeBufferPointer { input in
                    guard let baseAddress = input.baseAddress else { throw CanonicalAudioError.invalidSamples }
                    while emittedFrames < targetFrames {
                        try process(input: baseAddress, frameCount: input.count, targetFrames: targetFrames,
                                    stopAtTarget: true, into: &output)
                    }
                }
            }
            guard emittedFrames == targetFrames else {
                throw CanonicalAudioError.frameCountMismatch(expected: targetFrames, actual: emittedFrames)
            }
            // Any buffered samples beyond the half-open source interval are filter tail.
            pendingOutput.removeAll(keepingCapacity: true)
            pendingOutputOffset = 0
            ended = true
            return output
        } catch {
            failure = error
            throw error
        }
    }

    private func process(
        input: UnsafePointer<Float>,
        frameCount: Int,
        targetFrames: Int64,
        stopAtTarget: Bool,
        into output: inout [Float]
    ) throws {
        guard let resampler else {
            throw CanonicalAudioError.conversionFailed("miniaudio のリサンプラーがありません")
        }

        var consumedTotal = 0
        while consumedTotal < frameCount {
            var samples = [Float](repeating: 0, count: Self.outputBufferSize)
            var consumed = UInt64(frameCount - consumedTotal)
            var produced = UInt64(samples.count)
            let result = samples.withUnsafeMutableBufferPointer { destination in
                mja_resampler_process(
                    resampler,
                    input.advanced(by: consumedTotal),
                    &consumed,
                    destination.baseAddress,
                    &produced
                )
            }
            guard result == 0 else {
                throw CanonicalAudioError.conversionFailed(
                    "miniaudio の変換に失敗しました (エラーコード: \(result))"
                )
            }
            guard consumed <= UInt64(frameCount - consumedTotal), produced <= UInt64(samples.count) else {
                throw CanonicalAudioError.conversionFailed("miniaudio が不正なフレーム数を返しました")
            }
            guard consumed != 0 || produced != 0 else {
                throw CanonicalAudioError.conversionFailed("miniaudio の変換が進行しません")
            }

            consumedTotal += Int(consumed)
            let producedCount = Int(produced)
            if producedCount > 0 {
                try samples.withUnsafeBufferPointer { source in
                    guard let baseAddress = source.baseAddress else { throw CanonicalAudioError.invalidSamples }
                    let frames = UnsafeBufferPointer(start: baseAddress, count: producedCount)
                    guard frames.allSatisfy(\.isFinite) else { throw CanonicalAudioError.invalidSamples }
                    try accept(frames, upTo: targetFrames, into: &output)
                }
                if stopAtTarget && emittedFrames >= targetFrames { return }
            }
        }
    }

    private func accept(_ frames: UnsafeBufferPointer<Float>, upTo targetFrames: Int64, into output: inout [Float]) throws {
        let dropped = min(latencyFramesToDrop, UInt64(frames.count))
        latencyFramesToDrop -= dropped
        let start = Int(dropped)
        guard start < frames.count else { return }

        compactPendingOutput()
        let incomingCount = frames.count - start
        guard pendingOutput.count <= Self.outputBufferSize + 64 - incomingCount else {
            throw CanonicalAudioError.conversionFailed("miniaudio の保留出力が上限を超えました")
        }
        pendingOutput.append(contentsOf: frames[start...])
        try emitPending(upTo: targetFrames, into: &output)
    }

    private func emitPending(upTo targetFrames: Int64, into output: inout [Float]) throws {
        guard targetFrames >= emittedFrames else {
            throw CanonicalAudioError.frameCountMismatch(expected: targetFrames, actual: emittedFrames)
        }
        let available = pendingOutput.count - pendingOutputOffset
        guard available > 0 else { return }
        let timelineRoom = targetFrames - emittedFrames
        guard timelineRoom > 0 else { return }
        let count = min(available, Int(min(timelineRoom, Int64(Int.max))))
        let (nextEmittedFrames, overflow) = emittedFrames.addingReportingOverflow(Int64(count))
        guard !overflow else { throw CanonicalAudioError.invalidSamples }

        let end = pendingOutputOffset + count
        output.append(contentsOf: pendingOutput[pendingOutputOffset..<end])
        pendingOutputOffset = end
        emittedFrames = nextEmittedFrames
        if pendingOutputOffset == pendingOutput.count {
            pendingOutput.removeAll(keepingCapacity: true)
            pendingOutputOffset = 0
        }
    }

    private func compactPendingOutput() {
        guard pendingOutputOffset > 0 else { return }
        pendingOutput = Array(pendingOutput[pendingOutputOffset...])
        pendingOutputOffset = 0
    }
}
