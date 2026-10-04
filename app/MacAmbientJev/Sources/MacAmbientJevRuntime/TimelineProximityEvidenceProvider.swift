import Foundation
import MacAmbientJevCore

private struct SpeakerAcousticProfile: Sendable {
    let levelDBFS: Double
    let spectralSharpness: Double
}

enum TimelineProximityEvidenceError: LocalizedError {
    case speakerSampleUnreadable(
        speakerID: String,
        frameRange: Range<Int64>,
        reason: String
    )

    var errorDescription: String? {
        switch self {
        case .speakerSampleUnreadable(let speakerID, let frameRange, let reason):
            "話者 \(speakerID) の音声（フレーム \(frameRange.lowerBound)..<\(frameRange.upperBound)）を近接度の判定用に読み取れませんでした: \(reason)"
        }
    }
}

/// Builds one fixed acoustic profile per speaker for the whole session and
/// compares it with the session median.
actor TimelineProximityEvidenceProvider: ProximityEvidenceProvider {
    private static let maxSamplesPerSpeaker = 8
    private static let maxSecondsPerSample = 2.0
    private static let minimumSampleSeconds = 0.35
    private static let minimumSignalRMS = 1e-5

    private let reader: any TimelineAudioReading

    private var profiles: [String: SpeakerAcousticProfile]?
    private var sessionLevelMedian: Double?
    private var sessionSpectralMedian: Double?

    init(reader: any TimelineAudioReading) {
        self.reader = reader
    }

    func evidenceSpans(
        startFrame: Int64,
        endFrame: Int64,
        speakerSpans: [SpeakerSpan]
    ) async throws -> [ProximityEvidenceSpan] {
        guard endFrame > startFrame else { return [] }

        if profiles == nil {
            try buildProfiles(speakerSpans: speakerSpans)
        }

        let clipped = speakerSpans.compactMap { span -> SpeakerSpan? in
            let start = max(startFrame, span.startFrame)
            let end = min(endFrame, span.endFrame)
            guard end > start else { return nil }
            return SpeakerSpan(
                speakerID: span.speakerID,
                startFrame: start,
                endFrame: end,
                confidence: span.confidence
            )
        }

        var boundaries = Set<Int64>([startFrame, endFrame])
        for span in clipped {
            boundaries.insert(span.startFrame)
            boundaries.insert(span.endFrame)
        }
        let points = boundaries.sorted()
        guard points.count >= 2 else { return [] }

        var result: [ProximityEvidenceSpan] = []
        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            guard end > start else { continue }

            let activeSpeakerIDs = Set(
                clipped.compactMap { span -> String? in
                    guard span.startFrame < end,
                          span.endFrame > start else {
                        return nil
                    }
                    return span.speakerID
                }
            )

            let evidence: ProximityEvidence
            if activeSpeakerIDs.count == 1,
               let speakerID = activeSpeakerIDs.first {
                evidence = self.evidence(for: speakerID)
            } else {
                evidence = .unknown
            }

            if let last = result.last,
               last.endFrame == start,
               last.evidence == evidence {
                result[result.count - 1] = ProximityEvidenceSpan(
                    startFrame: last.startFrame,
                    endFrame: end,
                    evidence: evidence
                )
            } else {
                result.append(ProximityEvidenceSpan(
                    startFrame: start,
                    endFrame: end,
                    evidence: evidence
                ))
            }
        }

        return result
    }

    private func buildProfiles(speakerSpans: [SpeakerSpan]) throws {
        let sampleRate = reader.info.sampleRate
        let minimumFrames = Int64(
            (Self.minimumSampleSeconds * sampleRate).rounded(.up)
        )
        let maximumFrames = Int64(
            (Self.maxSecondsPerSample * sampleRate).rounded(.down)
        )

        let grouped = Dictionary(grouping: speakerSpans) { $0.speakerID }
        var built: [String: SpeakerAcousticProfile] = [:]

        for (speakerID, spans) in grouped {
            let candidates = spans
                .compactMap { span -> Range<Int64>? in
                    let start = max(0, span.startFrame)
                    let end = min(
                        reader.info.committedFrames,
                        span.endFrame
                    )
                    guard end - start >= minimumFrames else {
                        return nil
                    }

                    let available = end - start
                    let length = min(available, maximumFrames)
                    let cropStart = start + (available - length) / 2
                    return cropStart..<(cropStart + length)
                }
                .sorted { lhs, rhs in
                    lhs.count > rhs.count
                }
                .prefix(Self.maxSamplesPerSpeaker)

            var levels: [Double] = []
            var sharpnessValues: [Double] = []

            for range in candidates {
                let interleaved: [Float]
                do {
                    interleaved = try reader.readSamples(frameRange: range)
                } catch {
                    throw TimelineProximityEvidenceError.speakerSampleUnreadable(
                        speakerID: speakerID,
                        frameRange: range,
                        reason: error.localizedDescription
                    )
                }
                guard let features = acousticFeatures(
                    interleaved: interleaved
                ) else {
                    continue
                }
                levels.append(features.levelDBFS)
                sharpnessValues.append(features.spectralSharpness)
            }

            guard !levels.isEmpty,
                  !sharpnessValues.isEmpty else {
                continue
            }

            built[speakerID] = SpeakerAcousticProfile(
                levelDBFS: median(levels),
                spectralSharpness: median(sharpnessValues)
            )
        }

        profiles = built

        // Relative distance inference is intentionally disabled for fewer than
        // three stable speaker profiles. With one or two speakers, differences
        // in vocal effort are too easy to confuse with microphone distance.
        guard built.count >= 3 else {
            sessionLevelMedian = nil
            sessionSpectralMedian = nil
            return
        }

        sessionLevelMedian = median(
            built.values.map(\.levelDBFS)
        )
        sessionSpectralMedian = median(
            built.values.map(\.spectralSharpness)
        )
    }

    private func evidence(for speakerID: String) -> ProximityEvidence {
        guard let profile = profiles?[speakerID],
              let levelMedian = sessionLevelMedian,
              let spectralMedian = sessionSpectralMedian,
              spectralMedian > 0 else {
            return .unknown
        }

        let levelDelta = profile.levelDBFS - levelMedian
        let spectralDeltaDB = 20 * log10(
            max(profile.spectralSharpness, 1e-9)
                / max(spectralMedian, 1e-9)
        )

        let levelConfidence = min(1, abs(levelDelta) / 8.0)
        let spectralConfidence = min(
            1,
            abs(spectralDeltaDB) / 2.5
        )

        if levelDelta >= 6.0,
           spectralDeltaDB >= 2.0 {
            return ProximityEvidence(
                distanceHint: .near,
                levelConfidence: levelConfidence,
                spectralConfidence: spectralConfidence
            )
        }

        if levelDelta <= -8.0,
           spectralDeltaDB <= -2.0 {
            return ProximityEvidence(
                distanceHint: .distant,
                levelConfidence: levelConfidence,
                spectralConfidence: spectralConfidence
            )
        }

        return ProximityEvidence(
            distanceHint: .unknown,
            levelConfidence: levelConfidence,
            spectralConfidence: spectralConfidence
        )
    }

    /// Returns nil when the sample is too short or too quiet to describe.
    private func acousticFeatures(
        interleaved: [Float]
    ) -> SpeakerAcousticProfile? {
        let channelCount = reader.info.channelCount
        guard channelCount > 0,
              !interleaved.isEmpty else {
            return nil
        }

        let frameCount = interleaved.count / channelCount
        guard frameCount > 1 else {
            return nil
        }

        var sumSquares = 0.0
        var diffSquares = 0.0
        var previous: Double?

        for frame in 0..<frameCount {
            let base = frame * channelCount
            var mono = 0.0
            for channel in 0..<channelCount {
                mono += Double(interleaved[base + channel])
            }
            mono /= Double(channelCount)

            sumSquares += mono * mono
            if let previous {
                let difference = mono - previous
                diffSquares += difference * difference
            }
            previous = mono
        }

        let rms = sqrt(sumSquares / Double(frameCount))
        guard rms >= Self.minimumSignalRMS else {
            return nil
        }
        let diffRMS = sqrt(
            diffSquares / Double(max(1, frameCount - 1))
        )

        return SpeakerAcousticProfile(
            levelDBFS: 20 * log10(rms),
            spectralSharpness: diffRMS / rms
        )
    }

    private func median(_ values: [Double]) -> Double {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
