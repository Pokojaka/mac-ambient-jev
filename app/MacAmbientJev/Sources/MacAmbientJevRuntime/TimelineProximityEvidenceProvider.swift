import Foundation
import MacAmbientJevCore

private struct SpeakerAcousticProfile: Sendable {
    let levelDBFS: Double
    let spectralSharpness: Double
}

actor TimelineProximityEvidenceProvider: ProximityEvidenceProvider {
    private let reader: ProcessingTimelineReader
    private let maxSamplesPerSpeaker: Int
    private let maxSecondsPerSample: Double
    private let minimumSampleSeconds: Double

    private var profiles: [String: SpeakerAcousticProfile]?
    private var sessionLevelMedian: Double?
    private var sessionSpectralMedian: Double?

    init(
        reader: ProcessingTimelineReader,
        maxSamplesPerSpeaker: Int = 8,
        maxSecondsPerSample: Double = 2.0,
        minimumSampleSeconds: Double = 0.35
    ) {
        precondition(maxSamplesPerSpeaker > 0)
        precondition(maxSecondsPerSample > 0)
        precondition(minimumSampleSeconds > 0)
        self.reader = reader
        self.maxSamplesPerSpeaker = maxSamplesPerSpeaker
        self.maxSecondsPerSample = maxSecondsPerSample
        self.minimumSampleSeconds = minimumSampleSeconds
    }

    func evidenceSpans(
        startFrame: Int64,
        endFrame: Int64,
        speakerSpans: [SpeakerSpan]
    ) async throws -> [ProximityEvidenceSpan] {
        guard endFrame > startFrame else { return [] }

        if profiles == nil {
            buildProfiles(speakerSpans: speakerSpans)
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
                evidence = evidence(for: speakerID)
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

    private func buildProfiles(speakerSpans: [SpeakerSpan]) {
        let sampleRate = reader.checkpoint.sampleRate
        let minimumFrames = Int64(
            (minimumSampleSeconds * sampleRate).rounded(.up)
        )
        let maximumFrames = Int64(
            (maxSecondsPerSample * sampleRate).rounded(.down)
        )

        let grouped = Dictionary(grouping: speakerSpans) { $0.speakerID }
        var built: [String: SpeakerAcousticProfile] = [:]

        for (speakerID, spans) in grouped {
            let candidates = spans
                .compactMap { span -> Range<Int64>? in
                    let start = max(0, span.startFrame)
                    let end = min(
                        reader.checkpoint.committedFrames,
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
                .prefix(maxSamplesPerSpeaker)

            var levels: [Double] = []
            var sharpnessValues: [Double] = []

            for range in candidates {
                guard let features = try? acousticFeatures(
                    frameRange: range
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

    private func acousticFeatures(
        frameRange: Range<Int64>
    ) throws -> SpeakerAcousticProfile {
        let interleaved = try reader.readSamples(
            frameRange: frameRange
        )
        let channelCount = reader.checkpoint.channelCount
        guard channelCount > 0,
              !interleaved.isEmpty else {
            return SpeakerAcousticProfile(
                levelDBFS: -120,
                spectralSharpness: 0
            )
        }

        let frameCount = interleaved.count / channelCount
        guard frameCount > 1 else {
            return SpeakerAcousticProfile(
                levelDBFS: -120,
                spectralSharpness: 0
            )
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
        let diffRMS = sqrt(
            diffSquares / Double(max(1, frameCount - 1))
        )

        return SpeakerAcousticProfile(
            levelDBFS: 20 * log10(max(rms, 1e-9)),
            spectralSharpness: diffRMS / max(rms, 1e-9)
        )
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
