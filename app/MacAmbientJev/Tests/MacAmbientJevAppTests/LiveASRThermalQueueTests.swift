import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCapture
import MacAmbientJevCore
@testable import MacAmbientJevRuntime

@MainActor
@Test("critical heat holds the live queue without recognizing, and cooling resumes it")
func criticalHeatSuspendsLiveRecognitionUntilCooled() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let state = AppState(
        paths: paths, captureEngine: AudioCaptureEngine(paths: paths), microphoneAccess: { false },
        pausesProcessing: false, userDefaults: defaults, engines: .production(paths: paths), makeLiveVADSession: idleLiveVADFactory()
    )
    let sessionID = UUID()
    state.selectSavedSession(sessionID: sessionID)
    state.markRecordingStarted(sessionID: sessionID)

    let pressure = ThermalPressureSource(.critical)
    state.readLiveThermalPressure = { pressure.value }
    let segments = [
        SegmentReference(segmentationRunID: "seg", segmentID: "seg_000001", startFrame: 0, endFrame: 8_000),
        SegmentReference(segmentationRunID: "seg", segmentID: "seg_000002", startFrame: 8_000, endFrame: 16_000)
    ]
    state.liveASRQueues[sessionID] = segments.map {
        AppState.LiveASRBatch(segments: [$0], checkpoint: testCheckpoint())
    }
    state.startLiveASRDrainIfIdle(sessionID: sessionID)

    try await Task.sleep(for: .milliseconds(1_500))
    let suspendedText = UserFacingStatus.liveTranscriptionThermalSuspended.text
    #expect(state.liveASRQueues[sessionID]?.count == 2)
    #expect(state.liveASRFailures[sessionID] == nil)
    #expect(state.processingStatusText == suspendedText)
    #expect(state.transcriptViewModel.statusText == suspendedText)

    // No live ASR session was started, so the first recognition attempt fails visibly.
    pressure.value = .fair
    let deadline = ContinuousClock.now + .seconds(5)
    while state.liveASRFailures[sessionID] == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(
        state.liveASRFailures[sessionID]
            == NativeSessionProcessorError.liveASRSessionNotStarted.localizedDescription
    )
    #expect(state.liveASRQueues[sessionID]?.isEmpty == true)
}

@MainActor
private final class ThermalPressureSource {
    var value: ThermalPressure
    init(_ value: ThermalPressure) { self.value = value }
}
