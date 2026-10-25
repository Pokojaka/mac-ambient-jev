import Testing
@testable import MacAmbientJevCore

private struct CaptureWriterObservations: Sendable {
    let checkpointCalls: Int
    let finishCalls: Int
    let samples: [Float]
    let gapEvents: [AudioGapEvent]
}

private actor CountingCaptureWriter: AudioCaptureWriting {
    private var samples: [Float] = []
    private var gapEvents: [AudioGapEvent] = []
    private var checkpointCalls = 0
    private var finishCalls = 0

    func append(samples newSamples: [Float]) async throws {
        samples.append(contentsOf: newSamples)
    }

    func recordGap(startFrame: Int64, frameCount: Int64, reason: AudioGapReason) throws {
        gapEvents.append(AudioGapEvent(startFrame: startFrame, frameCount: frameCount, reason: reason))
    }

    func committedSnapshot() -> AudioCheckpoint {
        makeCheckpoint()
    }

    func checkpoint() throws -> AudioCheckpoint {
        checkpointCalls += 1
        return makeCheckpoint()
    }

    func finish() throws -> AudioCheckpoint {
        finishCalls += 1
        return makeCheckpoint()
    }

    func observations() -> CaptureWriterObservations {
        CaptureWriterObservations(
            checkpointCalls: checkpointCalls,
            finishCalls: finishCalls,
            samples: samples,
            gapEvents: gapEvents
        )
    }

    private func makeCheckpoint() -> AudioCheckpoint {
        AudioCheckpoint(
            committedFrames: Int64(samples.count),
            sampleRate: CanonicalAudio.sampleRate,
            channelCount: CanonicalAudio.channelCount,
            sampleFormat: CanonicalAudio.sampleFormat,
            chunkFiles: samples.isEmpty ? [] : ["test-chunk.f32le"],
            chunkFrameCounts: samples.isEmpty ? [] : [samples.count],
            gapEvents: gapEvents
        )
    }
}

private final class CountingIdentityConverter: CanonicalAudioConverting, @unchecked Sendable {
    let sourceSampleRate = CanonicalAudio.sampleRate
    private(set) var finishCalls = 0

    func convert(mono: [Float]) throws -> [Float] { mono }

    func finish() throws -> [Float] {
        finishCalls += 1
        return []
    }
}

@Test func finishSegmentCheckpointsAndNextDrainContinuesAfterKnownTimestampGap() async throws {
    let writer = CountingCaptureWriter()
    let firstConverter = CountingIdentityConverter()
    let firstRing = AudioBlockRing(capacity: 4, blockFrameCapacity: 4, sampleRate: CanonicalAudio.sampleRate)
    let firstDrain = AudioCaptureDrain(ring: firstRing, writer: writer, converter: firstConverter)

    #expect(pushSegmentSamples([1, 2], at: 0, into: firstRing))
    firstRing.finish(tailFrame: 2)
    let segmentCheckpoint = try await firstDrain.finishSegment()

    #expect(segmentCheckpoint.committedFrames == 2)
    let boundaryCalls = await writer.observations()
    #expect(boundaryCalls.checkpointCalls == 1)
    #expect(boundaryCalls.finishCalls == 0)
    #expect(firstConverter.finishCalls == 1)
    await #expect(throws: CanonicalAudioError.self) {
        _ = try await firstDrain.drainAvailable()
    }

    let secondRing = AudioBlockRing(capacity: 4, blockFrameCapacity: 4, sampleRate: CanonicalAudio.sampleRate)
    let secondConverter = CountingIdentityConverter()
    let secondDrain = AudioCaptureDrain(ring: secondRing, writer: writer, converter: secondConverter)
    secondRing.noteTimestampGap(startFrame: 0, frameCount: 2)
    #expect(pushSegmentSamples([5, 6], at: 2, into: secondRing))
    #expect(pushSegmentSamples([7], at: 4, into: secondRing))
    secondRing.finish(tailFrame: 5)

    let finalCheckpoint = try await secondDrain.finish()
    #expect(finalCheckpoint.committedFrames == 7)
    #expect(finalCheckpoint.gapEvents == [
        AudioGapEvent(startFrame: 2, frameCount: 2, reason: .missingCallback)
    ])
    #expect(secondConverter.finishCalls == 1)

    let observations = await writer.observations()
    #expect(observations.checkpointCalls == 1)
    #expect(observations.finishCalls == 1)
    #expect(observations.samples == [1, 2, 0, 0, 5, 6, 7])
    #expect(observations.gapEvents == [
        AudioGapEvent(startFrame: 2, frameCount: 2, reason: .missingCallback)
    ])
}

@Test func finishAfterSegmentFinalizesWriterOnceWithoutFlushingConverterAgain() async throws {
    let writer = CountingCaptureWriter()
    let converter = CountingIdentityConverter()
    let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 2, sampleRate: CanonicalAudio.sampleRate)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: converter)
    ring.finish(tailFrame: 0)

    let segmentCheckpoint = try await drain.finishSegment()
    #expect(segmentCheckpoint.committedFrames == 0)
    let segmentCalls = await writer.observations()
    #expect(segmentCalls.checkpointCalls == 1)
    #expect(segmentCalls.finishCalls == 0)
    #expect(converter.finishCalls == 1)

    let finalCheckpoint = try await drain.finish()
    let repeatedCheckpoint = try await drain.finish()
    #expect(finalCheckpoint == segmentCheckpoint)
    #expect(repeatedCheckpoint == finalCheckpoint)
    #expect(converter.finishCalls == 1)

    let finalCalls = await writer.observations()
    #expect(finalCalls.checkpointCalls == 1)
    #expect(finalCalls.finishCalls == 1)
}

@Test func postFinishSnapshotAndDrainReturnFinalCheckpointWithoutRepeatingFinish() async throws {
    let writer = CountingCaptureWriter()
    let converter = CountingIdentityConverter()
    let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 2, sampleRate: CanonicalAudio.sampleRate)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: converter)
    ring.finish(tailFrame: 0)

    let finalCheckpoint = try await drain.finish()
    #expect(finalCheckpoint.committedFrames == 0)

    let snapshot = try await drain.committedSnapshot()
    let drained = try await drain.drainAvailable()
    #expect(snapshot == finalCheckpoint)
    #expect(drained == 0)
    #expect(converter.finishCalls == 1)

    let observations = await writer.observations()
    #expect(observations.finishCalls == 1)
}

private func pushSegmentSamples(_ values: [Float], at frame: Int64, into ring: AudioBlockRing) -> Bool {
    var values = values
    let frameCount = values.count
    return values.withUnsafeMutableBufferPointer { samples in
        var channel = [samples.baseAddress!]
        return channel.withUnsafeMutableBufferPointer {
            ring.pushPlanarFloat32(channelData: $0.baseAddress!, channelCount: 1,
                                   frameCount: frameCount, startFrame: frame)
        }
    }
}
