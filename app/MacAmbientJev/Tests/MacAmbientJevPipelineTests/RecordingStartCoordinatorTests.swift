import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private struct StartTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum CapturePlan {
    case succeed
    case failDuringStart(String)
    case throwError(any Error)
    case writeAudioThenThrow(hasGap: Bool, containsCapture: Bool)
}

@MainActor
private final class FakeStartEffects: RecordingStartEffects {
    var recording = RecordingLifecycle()
    let paths: AppPaths
    var capturePlan = CapturePlan.succeed
    var liveSessionError: (any Error)?
    var bootstrapError: (any Error)?
    var events: [String] = []
    var sessionURL: URL?
    var failure: RecordingStartFailure?
    var failureHandler: (@MainActor @Sendable (String) -> Void)?

    init(paths: AppPaths) { self.paths = paths }

    func recordingStartDidBegin(sessionID: UUID) { events.append("begin") }

    func bootstrapSession(sessionID: UUID) throws -> URL {
        if let bootstrapError { throw bootstrapError }
        let url = try SessionBootstrapper(fileManager: .default).createSession(
            paths: paths, sessionID: sessionID, source: .recording(.microphone),
            createdAt: Date(), timeZone: .current
        )
        sessionURL = url
        return url
    }

    func startCapture(
        sessionID: UUID,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        events.append("capture")
        failureHandler = onFailure
        switch capturePlan {
        case .succeed:
            return
        case .failDuringStart(let message):
            onFailure(message)
        case .throwError(let error):
            throw error
        case .writeAudioThenThrow(let hasGap, let containsCapture):
            let url = try #require(sessionURL)
            let writer = try DurableAudioWriter(
                directory: SessionLayout(sessionURL: url).processingDirectory,
                chunkDurationSeconds: 1, sessionURL: url
            )
            if hasGap {
                try await writer.recordGap(startFrame: 0, frameCount: 16_000, reason: .missingCallback)
                try await writer.append(samples: Array(repeating: 0, count: 16_000))
            }
            if containsCapture {
                try await writer.append(samples: Array(repeating: 0.25, count: 16_000))
            }
            _ = try await writer.finish()
            throw AudioCaptureEngineError.captureFailure("startup failed")
        }
    }

    func markRecordingStarted(sessionID: UUID) {
        recording.didStart(sessionID: sessionID)
        events.append("started")
    }

    func captureDidFailDuringStart(sessionID: UUID, message: String) {
        events.append("fail:\(message)")
    }

    func recordingDidStart(sessionID: UUID) { events.append("live-ready") }

    func startLiveSession(sessionID: UUID) async throws {
        events.append("live-session")
        if let liveSessionError { throw liveSessionError }
    }

    func liveSessionStartDidFail(sessionID: UUID, error: any Error) {
        events.append("live-failed:\(error.localizedDescription)")
    }

    func recordingStartWillCleanUp() { events.append("cleanup") }

    func recordingStartDidFail(_ failure: RecordingStartFailure) {
        self.failure = failure
        events.append("start-failed")
    }

    func refreshSavedSessions() { events.append("refresh") }
    func releaseIdleResourcesIfIdle() { events.append("release") }
}

@MainActor
private func makeStartFixture() -> (root: URL, effects: FakeStartEffects, coordinator: RecordingStartCoordinator) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    return (root, FakeStartEffects(paths: paths), RecordingStartCoordinator(sessionsRoot: paths.sessionsRoot))
}

@MainActor
@Test("a successful start records, then creates the live session")
func startRunsStepsInOrder() async {
    let (root, effects, coordinator) = makeStartFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()

    await coordinator.start(sessionID: sessionID, effects: effects)

    #expect(effects.events == ["begin", "capture", "started", "live-ready", "live-session"])
    #expect(effects.recording.isCurrentRecording(sessionID))
    #expect(effects.failure == nil)
}

@MainActor
@Test("a capture failure raised while starting is handled once capture has started")
func startDefersCaptureFailure() async {
    let (root, effects, coordinator) = makeStartFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    effects.capturePlan = .failDuringStart("device lost")

    await coordinator.start(sessionID: UUID(), effects: effects)

    #expect(effects.events == ["begin", "capture", "started", "fail:device lost"])
}

@MainActor
@Test("a capture failure after the start returns goes straight to the failure path")
func startForwardsLaterCaptureFailure() async throws {
    let (root, effects, coordinator) = makeStartFixture()
    defer { try? FileManager.default.removeItem(at: root) }

    await coordinator.start(sessionID: UUID(), effects: effects)
    let handler = try #require(effects.failureHandler)
    handler("late failure")

    #expect(effects.events.last == "fail:late failure")
}

@MainActor
@Test("a live session failure leaves the recording running")
func liveSessionFailureKeepsRecording() async {
    let (root, effects, coordinator) = makeStartFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    effects.liveSessionError = StartTestError(message: "vad")
    let sessionID = UUID()

    await coordinator.start(sessionID: sessionID, effects: effects)

    #expect(effects.events.last == "live-failed:vad")
    #expect(effects.recording.isCurrentRecording(sessionID))
    #expect(effects.failure == nil)
}

@MainActor
@Test("a failed start removes an empty session and reports the error")
func failedStartRemovesEmptySession() async throws {
    let (root, effects, coordinator) = makeStartFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    effects.capturePlan = .throwError(StartTestError(message: "no input"))

    await coordinator.start(sessionID: UUID(), effects: effects)

    let url = try #require(effects.sessionURL)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(effects.failure == .failed("no input"))
    #expect(effects.recording.phase == .idle)
    #expect(effects.events == ["begin", "capture", "cleanup", "start-failed", "release"])
}

@MainActor
@Test("a cancelled start reports cancellation")
func cancelledStartReportsCancellation() async {
    let (root, effects, coordinator) = makeStartFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    effects.capturePlan = .throwError(AudioCaptureEngineError.cancelled)

    await coordinator.start(sessionID: UUID(), effects: effects)

    #expect(effects.failure == .cancelled)
    #expect(effects.recording.phase == .idle)
}

@MainActor
@Test("a failed bootstrap fails the start without touching capture")
func failedBootstrapSkipsCapture() async {
    let (root, effects, coordinator) = makeStartFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    effects.bootstrapError = StartTestError(message: "no folder")

    await coordinator.start(sessionID: UUID(), effects: effects)

    #expect(!effects.events.contains("capture"))
    #expect(effects.failure == .failed("no folder"))
    #expect(effects.recording.phase == .idle)
}

@MainActor
@Test("failed startup removes a recovered gap-only checkpoint but keeps real captured audio")
func failedStartRetainsOnlyCapturedAudio() async throws {
    for (hasGap, containsCapture) in [(true, false), (false, true), (true, true)] {
        let (root, effects, coordinator) = makeStartFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        effects.capturePlan = .writeAudioThenThrow(hasGap: hasGap, containsCapture: containsCapture)

        await coordinator.start(sessionID: UUID(), effects: effects)

        let url = try #require(effects.sessionURL)
        #expect(FileManager.default.fileExists(atPath: url.path) == containsCapture)
        #expect(effects.events.contains("refresh") == containsCapture)
        #expect(effects.failure == .failed("startup failed"))
        #expect(effects.recording.phase == .idle)
    }
}
