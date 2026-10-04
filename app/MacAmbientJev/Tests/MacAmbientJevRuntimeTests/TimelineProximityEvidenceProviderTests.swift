import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private func sineWave(
    frequency: Double,
    amplitude: Double,
    sampleRate: Double,
    frames: Int
) -> [Float] {
    (0..<frames).map { index in
        Float(
            amplitude * sin(
                2 * Double.pi * frequency
                    * Double(index) / sampleRate
            )
        )
    }
}

private func makeProximityFixture(thirdSpeakerSilent: Bool = false) async throws -> (
    root: URL,
    reader: ProcessingTimelineReader,
    spans: [SpeakerSpan]
) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )

    let sampleRate = 16_000.0
    let frames = 16_000
    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1)

    try await writer.append(samples: sineWave(
        frequency: 3_000,
        amplitude: 0.8,
        sampleRate: sampleRate,
        frames: frames
    ))
    try await writer.append(samples: sineWave(
        frequency: 1_000,
        amplitude: 0.2,
        sampleRate: sampleRate,
        frames: frames
    ))
    try await writer.append(samples: thirdSpeakerSilent
        ? [Float](repeating: 0, count: frames)
        : sineWave(
            frequency: 300,
            amplitude: 0.03,
            sampleRate: sampleRate,
            frames: frames
        ))

    let checkpoint = await writer.committedSnapshot()
    let spans = [
        SpeakerSpan(
            speakerID: "near",
            startFrame: 0,
            endFrame: 16_000,
            confidence: 1
        ),
        SpeakerSpan(
            speakerID: "middle",
            startFrame: 16_000,
            endFrame: 32_000,
            confidence: 1
        ),
        SpeakerSpan(
            speakerID: "distant",
            startFrame: 32_000,
            endFrame: 48_000,
            confidence: 1
        )
    ]

    return (
        root,
        ProcessingTimelineReader(
            directory: root,
            checkpoint: checkpoint
        ),
        spans
    )
}

@Test
func timelineProximityEvidenceFindsStrongRelativeNearAndDistantSpeakers() async throws {
    let fixture = try await makeProximityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let provider = TimelineProximityEvidenceProvider(
        reader: fixture.reader
    )

    let near = try await provider.evidenceSpans(
        startFrame: 0,
        endFrame: 16_000,
        speakerSpans: fixture.spans
    )
    let distant = try await provider.evidenceSpans(
        startFrame: 32_000,
        endFrame: 48_000,
        speakerSpans: fixture.spans
    )

    #expect(near.count == 1)
    #expect(near[0].evidence.distanceHint == .near)
    #expect(
        near[0].evidence.levelConfidence ?? 0 >= 0.75
    )
    #expect(
        near[0].evidence.spectralConfidence ?? 0 >= 0.75
    )

    #expect(distant.count == 1)
    #expect(distant[0].evidence.distanceHint == .distant)
    #expect(
        distant[0].evidence.levelConfidence ?? 0 >= 0.75
    )
    #expect(
        distant[0].evidence.spectralConfidence ?? 0 >= 0.75
    )
}

@Test
func timelineProximityEvidenceStaysUnknownWithOnlyTwoSpeakers() async throws {
    let fixture = try await makeProximityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let provider = TimelineProximityEvidenceProvider(
        reader: fixture.reader
    )
    let twoSpeakers = Array(fixture.spans.prefix(2))

    let evidence = try await provider.evidenceSpans(
        startFrame: 0,
        endFrame: 16_000,
        speakerSpans: twoSpeakers
    )

    #expect(evidence.count == 1)
    #expect(evidence[0].evidence.distanceHint == .unknown)
}

@Test
func silentSpeakerMustNotBeConfidentlyHiddenAsBackground() async throws {
    let fixture = try await makeProximityFixture(thirdSpeakerSilent: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let provider = TimelineProximityEvidenceProvider(reader: fixture.reader)
    let spans = try await provider.evidenceSpans(
        startFrame: 32_000,
        endFrame: 48_000,
        speakerSpans: fixture.spans
    )
    let evidence = try #require(spans.first?.evidence)
    #expect(evidence.distanceHint == .unknown)
    #expect(ScopeClassifier().classify(
        evidence: evidence,
        scene: .discussion
    ).scope != .background)
}

@Test
func timelineProximityEvidenceKeepsOverlappingSpeechUnknown() async throws {
    let fixture = try await makeProximityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let provider = TimelineProximityEvidenceProvider(
        reader: fixture.reader
    )
    let overlapping = fixture.spans + [
        SpeakerSpan(
            speakerID: "middle",
            startFrame: 8_000,
            endFrame: 16_000,
            confidence: 1
        )
    ]

    let evidence = try await provider.evidenceSpans(
        startFrame: 8_000,
        endFrame: 16_000,
        speakerSpans: overlapping
    )

    #expect(evidence.count == 1)
    #expect(evidence[0].evidence.distanceHint == .unknown)
}

@Test
func unreadableTimelineChunkFailsInsteadOfReportingUnknown() async throws {
    let fixture = try await makeProximityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstChunk = try #require(fixture.reader.checkpoint.chunkFiles.first)
    try FileManager.default.removeItem(at: fixture.root.appending(path: firstChunk))

    let provider = TimelineProximityEvidenceProvider(reader: fixture.reader)

    await #expect(throws: TimelineProximityEvidenceError.self) {
        try await provider.evidenceSpans(
            startFrame: 0,
            endFrame: 16_000,
            speakerSpans: fixture.spans
        )
    }
}
