import Foundation
import Synchronization
import Testing
@testable import MacAmbientJevWindowsSupport
import MacAmbientJevCore
import MacAmbientJevPipeline

private enum SafetyTestError: Error, Equatable {
    case diskQuery
    case acquire
    case release
}

private final class SafetyDiskProbe: @unchecked Sendable {
    let queries = Atomic<Int>(0)
    let forwardedDirectory = Atomic<Bool>(false)
    private let bytes: Atomic<UInt64>
    private let shouldFail: Atomic<Bool>
    private let expectedDirectory: URL?

    init(bytes: UInt64 = 0, shouldFail: Bool = false, expectedDirectory: URL? = nil) {
        self.bytes = Atomic(bytes)
        self.shouldFail = Atomic(shouldFail)
        self.expectedDirectory = expectedDirectory
    }

    func query(at directory: URL) throws -> UInt64 {
        _ = queries.add(1, ordering: .relaxed)
        if let expectedDirectory {
            forwardedDirectory.store(directory == expectedDirectory, ordering: .relaxed)
        }
        if shouldFail.load(ordering: .relaxed) { throw SafetyTestError.diskQuery }
        return bytes.load(ordering: .relaxed)
    }

    func setBytes(_ value: UInt64) {
        bytes.store(value, ordering: .relaxed)
    }
}

private final class SafetyCaptureClock: CaptureClock, @unchecked Sendable {
    private let millis: Atomic<Int64>

    init(millis: Int64) { self.millis = Atomic(millis) }

    func now() -> TimeInterval {
        Double(millis.load(ordering: .relaxed)) / 1_000
    }

    func setMillis(_ value: Int64) {
        millis.store(value, ordering: .relaxed)
    }
}

private final class SafetyCounter: @unchecked Sendable {
    private let countValue = Atomic<Int>(0)

    func increment() {
        _ = countValue.add(1, ordering: .relaxed)
    }

    var count: Int { countValue.load(ordering: .relaxed) }
}

private func makeDiskProvider(_ probe: SafetyDiskProbe) -> WindowsCaptureDiskSpaceProvider {
    WindowsCaptureDiskSpaceProvider(query: { try probe.query(at: $0) })
}

@Test("disk query failures throw and reject capture startup")
func diskQueryFailureRejectsCaptureStart() {
    let probe = SafetyDiskProbe(shouldFail: true)
    let provider = makeDiskProvider(probe)
    let directory = FileManager.default.temporaryDirectory

    #expect(throws: SafetyTestError.diskQuery) {
        try provider.availableBytes(at: directory)
    }
    #expect {
        try CaptureDiskPolicy.checkStart(diskSpace: provider, directory: directory)
    } throws: { error in
        guard let error = error as? AudioCaptureEngineError,
              case .diskSpaceUnavailable = error else { return false }
        return true
    }
    #expect(probe.queries.load(ordering: .relaxed) == 2)
}

@Test("disk provider rejects unsigned values that overflow Int64")
func diskProviderRejectsUInt64Overflow() {
    let provider = WindowsCaptureDiskSpaceProvider(query: { _ in UInt64(Int64.max) + 1 })

    #expect(throws: WindowsCaptureAdapterError.diskOverflow) {
        try provider.availableBytes(at: FileManager.default.temporaryDirectory)
    }
}

@Test("capture preflight accepts exactly 601600000 bytes and rejects one byte less")
func captureDiskReservationBoundary() throws {
    let required = CaptureDiskPolicy.requiredStartBytes
    let directory = FileManager.default.temporaryDirectory
    #expect(required == 601_600_000)

    let enough = SafetyDiskProbe(bytes: UInt64(required))
    try CaptureDiskPolicy.checkStart(diskSpace: makeDiskProvider(enough), directory: directory)

    let short = SafetyDiskProbe(bytes: UInt64(required - 1))
    #expect {
        try CaptureDiskPolicy.checkStart(diskSpace: makeDiskProvider(short), directory: directory)
    } throws: { error in
        guard let error = error as? AudioCaptureEngineError,
              case .insufficientDiskSpace(let requested) = error else { return false }
        return requested == required
    }
}

@Test("invalid non-file URL is rejected before the disk query")
func invalidDiskURLDoesNotQueryProvider() {
    let probe = SafetyDiskProbe(bytes: 900_000_000)
    let provider = makeDiskProvider(probe)
    let url = URL(string: "https://example.invalid/capture")!

    #expect {
        try provider.availableBytes(at: url)
    } throws: { error in
        guard let error = error as? WindowsCaptureAdapterError,
              case .invalidConfiguration = error else { return false }
        return true
    }
    #expect(probe.queries.load(ordering: .relaxed) == 0)
}

@Test("disk provider forwards the caller's explicit directory")
func diskProviderForwardsExplicitDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WindowsCaptureSafety explicit directory", isDirectory: true)
    let probe = SafetyDiskProbe(bytes: 700_000_000, expectedDirectory: directory)

    #expect(try makeDiskProvider(probe).availableBytes(at: directory) == 700_000_000)
    #expect(probe.queries.load(ordering: .relaxed) == 1)
    let wasForwarded = probe.forwardedDirectory.load(ordering: .relaxed)
    #expect(wasForwarded)
}

@MainActor
@Test("recording disk query failures warn without stopping; polling is every 30 seconds")
func recordingDiskFailuresWarnAtThirtySecondCadence() {
    let clock = SafetyCaptureClock(millis: 10_000)
    let probe = SafetyDiskProbe(shouldFail: true)
    let provider = makeDiskProvider(probe)
    var failures: [String] = []
    var warnings: [String] = []
    let monitor = CaptureHealthMonitor(
        source: .microphone,
        clock: clock,
        diskSpace: provider,
        directory: FileManager.default.temporaryDirectory,
        startedAt: 10,
        onFailure: { failures.append($0) },
        onWarning: { warnings.append($0) },
        onDropouts: { _ in },
        onSilenceChanged: { _ in }
    )

    clock.setMillis(39_999)
    #expect(monitor.poll(lastBufferMillis: 39_999, silentSinceMillis: 0, dropouts: 0))
    #expect(probe.queries.load(ordering: .relaxed) == 0)
    clock.setMillis(40_000)
    #expect(monitor.poll(lastBufferMillis: 40_000, silentSinceMillis: 0, dropouts: 0))
    #expect(probe.queries.load(ordering: .relaxed) == 1)
    clock.setMillis(69_999)
    #expect(monitor.poll(lastBufferMillis: 69_999, silentSinceMillis: 0, dropouts: 0))
    #expect(probe.queries.load(ordering: .relaxed) == 1)
    clock.setMillis(70_000)
    #expect(monitor.poll(lastBufferMillis: 70_000, silentSinceMillis: 0, dropouts: 0))
    #expect(probe.queries.load(ordering: .relaxed) == 2)
    #expect(warnings.count == 2)
    #expect(failures.isEmpty)
}

@MainActor
@Test("recording continues at the 128000000-byte floor and stops below it")
func recordingDiskStopFloorBoundary() {
    let clock = SafetyCaptureClock(millis: 10_000)
    let probe = SafetyDiskProbe(bytes: UInt64(CaptureDiskPolicy.stopFloorBytes))
    var failures: [String] = []
    var warnings: [String] = []
    let monitor = CaptureHealthMonitor(
        source: .systemAudio,
        clock: clock,
        diskSpace: makeDiskProvider(probe),
        directory: FileManager.default.temporaryDirectory,
        startedAt: 10,
        onFailure: { failures.append($0) },
        onWarning: { warnings.append($0) },
        onDropouts: { _ in },
        onSilenceChanged: { _ in }
    )

    clock.setMillis(40_000)
    #expect(monitor.poll(lastBufferMillis: 40_000, silentSinceMillis: 0, dropouts: 0))
    probe.setBytes(UInt64(CaptureDiskPolicy.stopFloorBytes - 1))
    clock.setMillis(70_000)
    #expect(!monitor.poll(lastBufferMillis: 70_000, silentSinceMillis: 0, dropouts: 0))
    #expect(probe.queries.load(ordering: .relaxed) == 2)
    #expect(failures.count == 1)
    #expect(warnings.isEmpty)
}

@MainActor
@Test("silence is reported after 30 seconds while advancing zero-buffer timestamps stay healthy")
func silenceNoticeDoesNotMisclassifyAdvancingZeroBuffersAsStalled() {
    let clock = SafetyCaptureClock(millis: 10_000)
    let probe = SafetyDiskProbe(bytes: 500_000_000)
    var failures: [String] = []
    var silenceStates: [Bool] = []
    let monitor = CaptureHealthMonitor(
        source: .microphone,
        clock: clock,
        diskSpace: makeDiskProvider(probe),
        directory: FileManager.default.temporaryDirectory,
        startedAt: 10,
        onFailure: { failures.append($0) },
        onWarning: { _ in },
        onDropouts: { _ in },
        onSilenceChanged: { silenceStates.append($0) }
    )

    clock.setMillis(39_999)
    #expect(monitor.poll(lastBufferMillis: 39_999, silentSinceMillis: 10_000, dropouts: 0))
    #expect(silenceStates.isEmpty)
    clock.setMillis(40_000)
    #expect(monitor.poll(lastBufferMillis: 40_000, silentSinceMillis: 10_000, dropouts: 0))
    clock.setMillis(40_100)
    #expect(monitor.poll(lastBufferMillis: 40_100, silentSinceMillis: 10_000, dropouts: 0))
    #expect(silenceStates == [true])
    #expect(failures.isEmpty)
}

@MainActor
@Test("failed power acquisition leaves no active lifetime and never releases")
func failedPowerAcquireDoesNotActivateOrRelease() throws {
    let releases = SafetyCounter()
    let provider = WindowsRecordingPowerProvider(
        acquire: { throw SafetyTestError.acquire },
        release: { releases.increment() }
    )

    #expect(throws: SafetyTestError.acquire) { try provider.acquire() }
    try provider.release()
    #expect(releases.count == 0)
}

@MainActor
@Test("a second power acquisition reports the already-active error")
func powerProviderRejectsDuplicateAcquire() throws {
    let acquires = SafetyCounter()
    let releases = SafetyCounter()
    let provider = WindowsRecordingPowerProvider(
        acquire: { acquires.increment() },
        release: { releases.increment() }
    )

    try provider.acquire()
    #expect {
        try provider.acquire()
    } throws: { error in
        guard let error = error as? WindowsCaptureAdapterError,
              case .invalidConfiguration(let message) = error else { return false }
        return message == "Recording power is already active"
    }
    try provider.release()
    #expect(acquires.count == 1)
    #expect(releases.count == 1)
}

@MainActor
@Test("power release errors propagate once and clear the provider's active state")
func failedPowerReleaseIsNotRepeatedAndClearsState() throws {
    let acquires = SafetyCounter()
    let releases = SafetyCounter()
    let provider = WindowsRecordingPowerProvider(
        acquire: { acquires.increment() },
        release: {
            releases.increment()
            if releases.count == 1 { throw SafetyTestError.release }
        }
    )

    try provider.acquire()
    #expect(throws: SafetyTestError.release) { try provider.release() }
    try provider.release()
    #expect(releases.count == 1)

    // The failed release cleared wrapper state; a new injected lifetime can be acquired and released.
    try provider.acquire()
    try provider.release()
    #expect(acquires.count == 2)
    #expect(releases.count == 2)
}

// Verify the injected wrapper lifecycle only; this does not claim to prove Win32 flags or thread affinity.
@MainActor
@Test("injected startup and teardown pair one acquire with one release")
func injectedPowerLifecyclePairsAcquireAndRelease() throws {
    let calls = SafetyCounter()
    let provider = WindowsRecordingPowerProvider(
        acquire: { calls.increment() },
        release: { calls.increment() }
    )

    try provider.acquire()
    try provider.release()
    #expect(calls.count == 2)
}

@MainActor
@Test("Windows declares no automatic volume or thermal monitoring and uses process-now policy")
func windowsCapabilitiesRemainExplicit() {
    let capabilities = WindowsCaptureCapabilities()
    let thermal = WindowsNoThermalMonitoring()

    #expect(capabilities.automaticInputVolume == .none)
    #expect(capabilities.thermalMonitoring == .none)
    #expect(!thermal.isCritical)
    #expect(thermal.liveASRDecision == .processNow)
    _ = thermal.observeChanges {}
}

#if os(Windows)
@Test("native disk query fails for an explicit nonexistent directory")
func nativeDiskQueryRejectsMissingDirectory() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WindowsCaptureSafety missing-\(UUID().uuidString)", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: directory.path))

    let provider = WindowsCaptureDiskSpaceProvider()
    #expect {
        try provider.availableBytes(at: directory)
    } throws: { error in
        guard let error = error as? WindowsCaptureAdapterError,
              case .native(let operation, let code) = error else { return false }
        return operation == "GetDiskFreeSpaceExW" && code != 0
    }
}
#endif
