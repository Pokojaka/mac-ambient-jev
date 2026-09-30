import Foundation
import Testing
@testable import MacAmbientJevCapture
import MacAmbientJevCore

private actor GatePermission: SystemAudioPermissionProviding {
    let status: SystemAudioPermissionStatus?
    private var answer: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var requests = 0

    init(_ status: SystemAudioPermissionStatus?, answer: Bool? = nil) {
        self.status = status
        self.answer = answer
    }
    func preflight() async -> SystemAudioPermissionStatus? { status }
    func request() async -> Bool {
        requests += 1
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
    func stop() {}
}

private struct GateDisk: CaptureDiskSpaceProviding {
    func availableBytes(at url: URL) throws -> Int64? { 10_000_000_000 }
}
private struct GateOutput: SystemAudioOutputProcessProviding {
    func runningExternalOutputPIDs() async -> Set<Int32>? { [] }
}

@MainActor
private func gateEngine(_ permission: GatePermission, tap: GateTap, creations: @escaping () -> Void) -> AudioCaptureEngine {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    return AudioCaptureEngine(
        paths: AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root),
        bufferFrameCount: 8, diskSpace: GateDisk(),
        tapFactory: { creations(); return tap }, systemAudioPermission: permission,
        outputProcesses: GateOutput()
    )
}

@MainActor
@Test("Denied system audio permission prevents tap creation")
func deniedSystemAudioGate() async throws {
    let tap = GateTap()
    let permission = GatePermission(.denied)
    var creations = 0
    let engine = gateEngine(permission, tap: tap) { creations += 1 }
    do {
        try await engine.start(sessionID: UUID(), source: .systemAudio, onFailure: { _ in })
        Issue.record("Denied permission started capture")
    } catch SystemAudioTapError.permissionDenied {
        #expect(creations == 0 && tap.starts == 0 && !engine.isRecording)
        #expect(await permission.requests == 0)
    }
}

@MainActor
@Test("Pending grant waits without creating tap or beginning first-buffer deadline")
func grantedSystemAudioGate() async throws {
    let tap = GateTap()
    let permission = GatePermission(.notDetermined)
    var creations = 0
    var waiting = false
    let engine = gateEngine(permission, tap: tap) { creations += 1 }
    let task = Task {
        try await engine.start(sessionID: UUID(), source: .systemAudio,
                               onFailure: { _ in }, onPermissionWaiting: { waiting = true })
    }
    while await permission.requests == 0 { await Task.yield() }
    #expect(waiting && creations == 0 && tap.starts == 0 && !engine.isRecording)
    // This exceeds the first-buffer timeout; no tap or deadline may run while the dialog is open.
    try await Task.sleep(for: .seconds(3.2))
    #expect(creations == 0 && !engine.isRecording)
    await permission.resolve(true)
    try await task.value
    #expect(creations == 1 && tap.starts == 1)
    #expect(engine.systemAudioPermissionResult == .grantedNow)
    _ = try await engine.stop()
}

@MainActor
@Test("Pending denial never creates a tap")
func deniedAfterPromptSystemAudioGate() async throws {
    let tap = GateTap()
    let permission = GatePermission(.notDetermined)
    var creations = 0
    let engine = gateEngine(permission, tap: tap) { creations += 1 }
    let task = Task { try await engine.start(sessionID: UUID(), source: .systemAudio, onFailure: { _ in }) }
    while await permission.requests == 0 { await Task.yield() }
    await permission.resolve(false)
    do {
        try await task.value
        Issue.record("Denied dialog started capture")
    } catch SystemAudioTapError.permissionDenied {
        #expect(creations == 0 && tap.starts == 0 && !engine.isRecording)
    }
}

@MainActor
@Test("Unavailable permission SPI falls back to tap capture")
func unavailableSystemAudioGate() async throws {
    let tap = GateTap()
    let permission = GatePermission(nil)
    var creations = 0
    let engine = gateEngine(permission, tap: tap) { creations += 1 }
    try await engine.start(sessionID: UUID(), source: .systemAudio, onFailure: { _ in })
    #expect(creations == 1 && tap.starts == 1)
    #expect(engine.systemAudioPermissionResult == .unavailable)
    #expect(await permission.requests == 0)
    _ = try await engine.stop()
}

@MainActor
@Test("Cancellation while permission dialog is pending returns without waiting for its answer")
func cancelledPendingSystemAudioGate() async throws {
    let tap = GateTap()
    let permission = GatePermission(.notDetermined)
    var creations = 0
    let engine = gateEngine(permission, tap: tap) { creations += 1 }
    let task = Task { try await engine.start(sessionID: UUID(), source: .systemAudio, onFailure: { _ in }) }
    while await permission.requests == 0 { await Task.yield() }
    engine.cancelStarting()
    do {
        try await task.value
        Issue.record("Cancelled start succeeded")
    } catch AudioCaptureEngineError.cancelled {
        #expect(creations == 0 && tap.starts == 0 && !engine.isRecording)
    }
    await permission.resolve(true)
    await Task.yield()
    #expect(creations == 0 && !engine.isRecording)
}
