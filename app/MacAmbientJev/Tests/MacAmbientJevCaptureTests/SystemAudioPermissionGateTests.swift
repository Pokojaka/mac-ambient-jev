import Foundation
import Testing
@testable import MacAmbientJevCapture
import MacAmbientJevCore
import MacAmbientJevPipeline

private actor GatePermission: SystemAudioPermissionProviding {
    /// nil models an absent SPI or an unknown TCC status.
    let status: SystemAudioPermissionStatus?
    private var answer: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var requestedContinuation: CheckedContinuation<Void, Never>?
    private(set) var requests = 0

    init(_ status: SystemAudioPermissionStatus?, answer: Bool?) {
        self.status = status
        self.answer = answer
    }
    func preflight() async throws(SystemAudioPermissionError) -> SystemAudioPermissionStatus {
        guard let status else { throw .unverifiable }
        return status
    }
    func waitUntilRequested() async {
        if requests > 0 { return }
        await withCheckedContinuation { continuation in
            precondition(requestedContinuation == nil)
            requestedContinuation = continuation
        }
    }
    func request() async throws(SystemAudioPermissionError) -> Bool {
        requests += 1
        requestedContinuation?.resume()
        requestedContinuation = nil
        if let answer { return answer }
        return await withCheckedContinuation { continuation = $0 }
    }
    func resolve(_ granted: Bool) {
        answer = granted
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

@MainActor
private final class GateTap: SystemAudioTapProviding {
    let sampleRate: Double = 1_000
    var starts = 0
    func start(sink: TimestampedMonoSink, onFailure: @escaping @MainActor @Sendable (String) -> Void) throws {
        starts += 1
        sink.silence(startFrame: 0, frameCount: 4)
    }
    func stop() throws {}
}

private struct GateDisk: CaptureDiskSpaceProviding {
    func availableBytes(at url: URL) throws -> Int64? { 10_000_000_000 }
}
private struct GateOutput: SystemAudioOutputProcessProviding {
    func runningExternalOutputPIDs() async -> Set<Int32>? { [] }
}

private struct GateClock: CaptureClock {
    func now() -> TimeInterval { 10 }
}

@MainActor
private func gateEngine(_ permission: GatePermission, tap: GateTap, clock: any CaptureClock, creations: @escaping () -> Void) throws -> (AudioCaptureEngine, UUID, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let sessionID = UUID()
    try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .recording(.systemAudio),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let engine = AudioCaptureEngine(
        paths: paths,
        bufferFrameCount: 8, clock: clock, diskSpace: GateDisk(),
        tapFactory: { creations(); return tap }, systemAudioPermission: permission,
        outputProcesses: GateOutput(),
        micInputVolumeFactory: { preconditionFailure("System audio never binds a microphone volume control") }
    )
    return (engine, sessionID, root)
}

@MainActor
@Test("Denied preflight followed by a denied request prevents tap creation", .timeLimit(.minutes(10)))
func deniedSystemAudioGate() async throws {
    let tap = GateTap()
    let clock = GateClock()
    let permission = GatePermission(.denied, answer: false)
    var creations = 0
    let (engine, sessionID, root) = try gateEngine(permission, tap: tap, clock: clock) { creations += 1 }
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        try await engine.start(sessionID: sessionID, source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
        Issue.record("Denied permission started capture")
    } catch SystemAudioTapError.permissionDenied {
        #expect(creations == 0 && tap.starts == 0 && !engine.isRecording)
        #expect(await permission.requests == 1)
    }
}

@MainActor
@Test("A grant after a cached denied preflight starts system audio capture", .timeLimit(.minutes(10)))
func grantedAfterDeniedPreflightSystemAudioGate() async throws {
    let tap = GateTap()
    let clock = GateClock()
    let permission = GatePermission(.denied, answer: true)
    var creations = 0
    let (engine, sessionID, root) = try gateEngine(permission, tap: tap, clock: clock) { creations += 1 }
    defer { try? FileManager.default.removeItem(at: root) }
    try await engine.start(sessionID: sessionID, source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
    #expect(await permission.requests == 1)
    #expect(creations == 1 && tap.starts == 1 && engine.isRecording)
    #expect(engine.systemAudioPermissionResult == .grantedNow)
    _ = try await engine.stop()
}

@MainActor
@Test("Pending grant waits without creating a tap", .timeLimit(.minutes(10)))
func grantedSystemAudioGate() async throws {
    let tap = GateTap()
    let clock = GateClock()
    let permission = GatePermission(.notDetermined, answer: nil)
    var creations = 0
    var waiting = false
    let (engine, sessionID, root) = try gateEngine(permission, tap: tap, clock: clock) { creations += 1 }
    defer { try? FileManager.default.removeItem(at: root) }
    let task = Task {
        try await engine.start(sessionID: sessionID, source: .systemAudio,
                               onFailure: { _ in }, onWarning: { _ in },
                               onPermissionWaiting: { waiting = true }, onDropouts: { _ in }, onSilenceChanged: { _ in })
    }
    await permission.waitUntilRequested()
    #expect(waiting && creations == 0 && tap.starts == 0 && !engine.isRecording)
    await permission.resolve(true)
    try await task.value
    #expect(creations == 1 && tap.starts == 1)
    #expect(engine.systemAudioPermissionResult == .grantedNow)
    _ = try await engine.stop()
}

@MainActor
@Test("Pending denial never creates a tap", .timeLimit(.minutes(10)))
func deniedAfterPromptSystemAudioGate() async throws {
    let tap = GateTap()
    let clock = GateClock()
    let permission = GatePermission(.notDetermined, answer: nil)
    var creations = 0
    let (engine, sessionID, root) = try gateEngine(permission, tap: tap, clock: clock) { creations += 1 }
    defer { try? FileManager.default.removeItem(at: root) }
    let task = Task { try await engine.start(sessionID: sessionID, source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in }) }
    await permission.waitUntilRequested()
    await permission.resolve(false)
    do {
        try await task.value
        Issue.record("Denied dialog started capture")
    } catch SystemAudioTapError.permissionDenied {
        #expect(creations == 0 && tap.starts == 0 && !engine.isRecording)
    }
}

@MainActor
@Test("An absent permission SPI or unknown status refuses to start without creating a tap", .timeLimit(.minutes(10)))
func unverifiableSystemAudioGate() async throws {
    let tap = GateTap()
    let clock = GateClock()
    let permission = GatePermission(nil, answer: nil)
    var creations = 0
    let (engine, sessionID, root) = try gateEngine(permission, tap: tap, clock: clock) { creations += 1 }
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: SystemAudioPermissionError.unverifiable) {
        try await engine.start(sessionID: sessionID, source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
    }
    #expect(creations == 0 && tap.starts == 0 && !engine.isRecording)
    #expect(engine.systemAudioPermissionResult == nil)
    #expect(await permission.requests == 0)
}

@MainActor
@Test("Cancellation while permission dialog is pending returns without waiting for its answer",
      .timeLimit(.minutes(10)), arguments: [SystemAudioPermissionStatus.notDetermined, .denied])
func cancelledPendingSystemAudioGate(status: SystemAudioPermissionStatus) async throws {
    let tap = GateTap()
    let clock = GateClock()
    let permission = GatePermission(status, answer: nil)
    var creations = 0
    let (engine, sessionID, root) = try gateEngine(permission, tap: tap, clock: clock) { creations += 1 }
    defer { try? FileManager.default.removeItem(at: root) }
    let task = Task { try await engine.start(sessionID: sessionID, source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in }) }
    await permission.waitUntilRequested()
    let requestTask = try #require(engine.permissionRequestTask, "Permission request task was not started")
    engine.cancelStarting()
    do {
        try await task.value
        Issue.record("Cancelled start succeeded")
    } catch AudioCaptureEngineError.cancelled {
        #expect(creations == 0 && tap.starts == 0 && !engine.isRecording)
    }
    await permission.resolve(true)
    await requestTask.value
    #expect(creations == 0 && !engine.isRecording)
}
