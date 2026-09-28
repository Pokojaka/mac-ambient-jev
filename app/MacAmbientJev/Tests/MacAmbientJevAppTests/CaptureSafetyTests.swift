import AppKit
import AVFoundation
import Foundation
import IOKit.audio
import Synchronization
import Testing
@testable import MacAmbientJev

@MainActor
private final class FakePower: RecordingPowerProviding {
    var acquisitions = 0
    var releases = 0
    var assertionAvailable = true
    func acquire() -> Bool {
        acquisitions += 1
        return assertionAvailable
    }
    func release() { releases += 1 }
}

@MainActor
@Test("recording power lifetime releases on success, start failure, write failure, cancellation and termination")
func recordingPowerLifetimePairsEveryExit() {
    for exit in ["normal", "start failure", "write failure", "cancel", "terminate"] {
        let provider = FakePower()
        if exit == "start failure" { provider.assertionAvailable = false }
        let lifetime = RecordingPowerLifetime(provider: provider)
        #expect(lifetime.begin() == provider.assertionAvailable)
        #expect(lifetime.active)
        lifetime.end()
        lifetime.end() // Termination during an in-flight stop must not release twice.
        #expect(!lifetime.active)
        #expect(provider.acquisitions == 1)
        #expect(provider.releases == 1)
    }
}

@MainActor
@Test("real IOKit sleep assertion and ProcessInfo activity can be acquired and released without audio")
func systemRecordingPowerAssertionRoundTrip() {
    let power = SystemRecordingPower()
    let acquired = power.acquire()
    power.release()
    #expect(acquired)
    // A second acquisition proves the first release restored the lease to an idle state.
    #expect(power.acquire())
    power.release()
}

@Test("first-buffer and stall deadlines distinguish intermittent input from silence")
func captureHealthDeadlinesAndMute() {
    #expect(!CaptureHealth.hasStalled(startedAt: 10, lastBufferMillis: 0, now: 12.99))
    #expect(CaptureHealth.hasStalled(startedAt: 10, lastBufferMillis: 0, now: 13))
    #expect(!CaptureHealth.hasStalled(startedAt: 10, lastBufferMillis: 12_000, now: 14.99))
    #expect(CaptureHealth.hasStalled(startedAt: 10, lastBufferMillis: 12_000, now: 15))
    #expect(!CaptureHealth.isSilent(silentSinceMillis: 10_000, now: 39.99))
    #expect(CaptureHealth.isSilent(silentSinceMillis: 10_000, now: 40))
    #expect(!CaptureHealth.isSilent(silentSinceMillis: 0, now: 100))
}

@Test("startup waits for the first real buffer, expires at 3 seconds, and cancellation and failures win")
func firstBufferDeadlineAndCancellation() {
    func state(_ now: Double, _ last: Int64 = 0, cancelled: Bool = false,
               failure: String? = nil) -> CaptureStartStatus {
        CaptureStartStatus.evaluate(
            startedAt: 10, now: now, lastBufferMillis: last,
            cancelled: cancelled, failure: failure
        )
    }
    #expect(state(12.99) == .waiting)
    #expect(state(13) == .timedOut)
    #expect(state(12, 12_000) == .ready)
    #expect(state(12, cancelled: true) == .cancelled)
    #expect(state(12, failure: "マイクが切断されました") == .failed("マイクが切断されました"))
    #expect(state(12, 12_000, cancelled: true) == .cancelled)
}

private final class TestCaptureClock: CaptureClock {
    let millis: Atomic<Int64>
    init(millis: Int64) { self.millis = Atomic(millis) }
    func now() -> TimeInterval { Double(millis.load(ordering: .relaxed)) / 1_000 }
}

private final class TestCaptureDisk: CaptureDiskSpaceProviding {
    let free: Atomic<Int64>
    let checks = Atomic(0)
    init(free: Int64) { self.free = Atomic(free) }
    func availableBytes(at url: URL) throws -> Int64? {
        _ = checks.add(1, ordering: .relaxed)
        return free.load(ordering: .relaxed)
    }
}

@MainActor
@Test("recording stalls after last buffer, without mistaking continuous silent buffers for a stall")
func recordingStallMonitor() {
    let clock = TestCaptureClock(millis: 10_000)
    let disk = TestCaptureDisk(free: 500_000_000)
    var failures: [String] = []
    var warnings: [String] = []
    var dropouts: [UInt64] = []
    let monitor = CaptureHealthMonitor(
        clock: clock, diskSpace: disk,
        directory: FileManager.default.temporaryDirectory, startedAt: 10,
        onFailure: { failures.append($0) },
        onWarning: { warnings.append($0) },
        onDropouts: { dropouts.append($0) },
        onSilenceChanged: { _ in }
    )
    clock.millis.store(12_999, ordering: .relaxed)
    #expect(monitor.poll(lastBufferMillis: 10_000, silentSinceMillis: 10_000, dropouts: 2))
    #expect(dropouts == [2])
    clock.millis.store(13_000, ordering: .relaxed)
    #expect(!monitor.poll(lastBufferMillis: 10_000, silentSinceMillis: 10_000, dropouts: 2))
    #expect(failures == ["マイクから音声が届かなくなりました。録音を停止しました"])
    #expect(warnings.isEmpty)
    #expect(disk.checks.load(ordering: .relaxed) == 0)
}

@MainActor
@Test("monitor checks disk every 30 seconds and clears the silence warning when input resumes")
func recordingDiskAndSilenceMonitor() {
    let clock = TestCaptureClock(millis: 10_000)
    let disk = TestCaptureDisk(free: 500_000_000)
    var failures: [String] = []
    var warnings: [String] = []
    var dropouts: [UInt64] = []
    var silenceStates: [Bool] = []
    let monitor = CaptureHealthMonitor(
        clock: clock, diskSpace: disk,
        directory: FileManager.default.temporaryDirectory, startedAt: 10,
        onFailure: { failures.append($0) },
        onWarning: { warnings.append($0) },
        onDropouts: { dropouts.append($0) },
        onSilenceChanged: { silenceStates.append($0) }
    )
    clock.millis.store(39_999, ordering: .relaxed)
    #expect(monitor.poll(lastBufferMillis: 39_999, silentSinceMillis: 10_000, dropouts: 1))
    #expect(disk.checks.load(ordering: .relaxed) == 0)
    clock.millis.store(40_000, ordering: .relaxed)
    #expect(monitor.poll(lastBufferMillis: 40_000, silentSinceMillis: 10_000, dropouts: 2))
    #expect(silenceStates == [true])
    #expect(disk.checks.load(ordering: .relaxed) == 1)
    clock.millis.store(41_000, ordering: .relaxed)
    #expect(monitor.poll(lastBufferMillis: 41_000, silentSinceMillis: 0, dropouts: 2))
    #expect(silenceStates == [true, false])
    #expect(warnings.isEmpty)
    disk.free.store(CaptureDiskPolicy.stopFloorBytes - 1, ordering: .relaxed)
    clock.millis.store(70_000, ordering: .relaxed)
    #expect(!monitor.poll(lastBufferMillis: 70_000, silentSinceMillis: 10_000, dropouts: 3))
    #expect(disk.checks.load(ordering: .relaxed) == 2)
    #expect(failures == ["空き容量が不足しています。録音を停止して保存しました"])
    #expect(dropouts == [1, 2, 2, 3])
}

@Test("90-minute mono 48-kHz start allowance exceeds one GB and scales by channels")
func deviceRateDiskRequirement() {
    let mono = CaptureDiskPolicy.requiredStartBytes(sampleRate: 48_000, channelCount: 1)
    #expect(mono == 1_292_800_000)
    #expect(CaptureDiskPolicy.requiredStartBytes(sampleRate: 48_000, channelCount: 2)
        == 2_329_600_000)
    #expect(!CaptureDiskPolicy.mayStart(
        availableBytes: 1_000_000_000, sampleRate: 48_000, channelCount: 1))
    #expect(CaptureDiskPolicy.mayStart(
        availableBytes: mono, sampleRate: 48_000, channelCount: 1))
    #expect(!CaptureDiskPolicy.mustStop(
        availableBytes: CaptureDiskPolicy.stopFloorBytes))
    #expect(CaptureDiskPolicy.mustStop(
        availableBytes: CaptureDiskPolicy.stopFloorBytes - 1))
}

@Test("Bluetooth HFP warning requires both Bluetooth transport and low sample rate")
func bluetoothHFPWarningPolicy() {
    #expect(CaptureInputWarnings.isLowRateBluetooth(
        transportType: Int32(kIOAudioDeviceTransportTypeBluetooth), sampleRate: 16_000))
    #expect(CaptureInputWarnings.isLowRateBluetooth(
        transportType: Int32(kIOAudioDeviceTransportTypeBluetooth), sampleRate: 24_000))
    #expect(!CaptureInputWarnings.isLowRateBluetooth(
        transportType: Int32(kIOAudioDeviceTransportTypeBluetooth), sampleRate: 48_000))
    #expect(!CaptureInputWarnings.isLowRateBluetooth(transportType: 0, sampleRate: 16_000))
}

@MainActor
private final class CaptureFailureSink {
    var messages: [String] = []
    func append(_ message: String) { messages.append(message) }
}

@MainActor
@Test("only runtime failures, interruptions, and disconnection of the active input stop capture")
func activeCaptureNotificationRouting() async {
    let session = NSObject()
    let device = NSObject()
    let otherDevice = NSObject()
    let sink = CaptureFailureSink()
    let observers = CaptureFailureObservers(provider: SystemCaptureNotifications())
    observers.start(session: session, device: device) { message in sink.append(message) }
    NotificationCenter.default.post(name: AVCaptureDevice.wasDisconnectedNotification, object: otherDevice)
    NotificationCenter.default.post(name: AVCaptureSession.wasInterruptedNotification, object: NSObject())
    await Task.yield()
    #expect(sink.messages.isEmpty)

    NotificationCenter.default.post(name: AVCaptureSession.runtimeErrorNotification, object: session)
    NotificationCenter.default.post(name: AVCaptureSession.wasInterruptedNotification, object: session)
    NotificationCenter.default.post(name: AVCaptureDevice.wasDisconnectedNotification, object: device)
    for _ in 0..<20 where sink.messages.count < 3 { await Task.yield() }
    #expect(sink.messages.contains("マイクの動作エラーが発生しました。録音を停止しました"))
    #expect(sink.messages.contains("マイク入力が中断されました。録音を停止しました"))
    #expect(sink.messages.contains("マイクが切断されました。録音を停止しました"))
    observers.stop()
    NotificationCenter.default.post(name: AVCaptureDevice.wasDisconnectedNotification, object: device)
    await Task.yield()
    #expect(sink.messages.count == 3)
}

@MainActor
@Test("termination observer releases even when no recording window is open")
func terminationObservationIsWindowIndependent() {
    let calls = Atomic(0)
    var observation: TerminationObservation? = TerminationObservation {
        _ = calls.add(1, ordering: .relaxed)
    }
    withExtendedLifetime(observation) {
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    }
    #expect(calls.load(ordering: .relaxed) == 1)
    observation = nil
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    #expect(calls.load(ordering: .relaxed) == 1)
}
