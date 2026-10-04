import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCore
import MacAmbientJevRuntime

/// Five-second utterance cadence; no capture, model load, or audio-file allocation.
@MainActor
@Test("Measure live backlog at 10-minute, 1-hour and 4-hour event equivalents")
func bugHuntMeasureThermalBacklogGrowth() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let state = AppState(
        paths: paths, captureEngine: FakeAppCaptureEngine(), microphoneAccess: { false },
        pausesProcessing: true, userDefaults: defaults, engines: .production(paths: paths),
        makeLiveVADSession: idleLiveVADFactory()
    )
    let sessionID = UUID()
    _ = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .recording(.systemAudio), createdAt: Date()
    )
    state.markRecordingStarted(sessionID: sessionID)
    state.readLiveThermalPressure = { .critical }
    _ = try await state.sessionProcessor.startLiveTranscription(
        sessionID: sessionID, segmentationRunID: "growth", sampleRate: 16_000
    )
    var chunkFiles: [String] = []
    var chunkFrameCounts: [Int] = []
    for index in 0..<2_880 {
        chunkFiles.append("audio-\(index).caf")
        chunkFrameCounts.append(80_000)
        let checkpoint = AudioCheckpoint(
            committedFrames: Int64(index + 1) * 80_000,
            sampleRate: 16_000, channelCount: 1, sampleFormat: .float32LE,
            chunkFiles: chunkFiles, chunkFrameCounts: chunkFrameCounts, gapEvents: []
        )
        await state.enqueueLiveASR(
            sessionID: sessionID,
            segments: [SegmentReference(
                segmentationRunID: "growth", segmentID: "row_\(index)",
                startFrame: Int64(index) * 80_000, endFrame: Int64(index + 1) * 80_000
            )],
            checkpoint: checkpoint
        )
        let count = index + 1
        if [120, 720, 2_880].contains(count) {
            let batches = try #require(state.liveASRQueues[sessionID])
            let retained = batches.reduce(0) { $0 + $1.segments.count }
            let checkpoints = Array(state.liveASRLatestCheckpoints.values)
            let retainedChunks = checkpoints.reduce(0) { $0 + $1.chunkFiles.count }
            print("LIVE_ASR backlog equivalent_seconds=\(count * 5) batches=\(batches.count) retained_segment_refs=\(retained) retained_checkpoints=\(checkpoints.count) retained_chunk_entries=\(retainedChunks) latest_chunk_entries=\(checkpoint.chunkFiles.count)")
        }
    }
    let draining = state.liveASRTasks[sessionID]
    draining?.cancel()
    await draining?.value
    state.cleanupLiveASRState(sessionID: sessionID)
    await state.sessionProcessor.cancelLiveTranscription(sessionID: sessionID)
}
