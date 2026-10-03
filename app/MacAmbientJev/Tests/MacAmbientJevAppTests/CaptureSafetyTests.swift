import AppKit
import AVFoundation
import Foundation
import IOKit.audio
import Synchronization
import Testing
@testable import MacAmbientJevCapture
@testable import MacAmbientJev
import MacAmbientJevCore

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
@Test("engine stop, failed write, missing first buffer, cancellation and termination release capture power")
func recordingPowerLifetimePairsEveryExit() async throws {
    for exit in ["normal", "write failure", "no buffer", "cancel", "terminate"] {
        let (root, paths) = temporaryRecordingPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakePower()
        let engine = AudioCaptureEngine(paths: paths, power: provider, micInputVolumeFactory: {
            preconditionFailure("Input-free teardown never binds a microphone volume control")
        })
        let directory = root.appending(path: "capture", directoryHint: .isDirectory)
        let writer = try DurableAudioWriter(
            directory: directory, sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1
        )
        let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 10)
        let receiver = AudioCaptureReceiver(
            ring: ring, sampleRate: 10, channelCount: 1, onFormatChange: {}, clock: SystemCaptureClock(), frameCapacity: 16_384, meter: nil
        )
        let drain = AudioCaptureDrain(ring: ring, writer: writer)
        #expect(engine.power.begin())
        engine.installCapture(
            session: AVCaptureSession(), output: AVCaptureAudioDataOutput(),
            receiver: receiver, callbackQueue: DispatchQueue(label: "test.capture.teardown"),
            tap: nil, sink: receiver.sink,
            ring: ring, drain: drain, drainTask: nil, sessionID: UUID(),
            timeline: ProcessingTimeline(sampleRate: 10, channelCount: 1, sampleFormat: .float32LE)
        )
        if exit == "terminate" {
            try await writer.append(samples: Array(repeating: 0.25, count: 10))
            #expect(try await engine.committedCheckpoint().committedFrames == 10)
            engine.terminate()
            #expect(try AudioCheckpoint.loadRecovered(from: directory)?.committedFrames == 10)
        } else {
            if exit == "normal" || exit == "write failure" {
                #expect(pushRingMono(Array(repeating: 0.25, count: 10), at: 0, into: ring))
            }
            if exit == "write failure" {
                let blockedChunk = directory.appending(path: "chunk-000000.f32le")
                try FileManager.default.createDirectory(
                    at: blockedChunk, withIntermediateDirectories: false
                )
                var rejected = false
                do { _ = try await engine.stop() } catch { rejected = true }
                #expect(rejected)
                try FileManager.default.removeItem(at: blockedChunk)
                #expect(try AudioCheckpoint.loadRecovered(from: directory)?.committedFrames == 0)
            } else if exit == "normal" {
                let result = try await engine.stop()
                #expect(result.checkpoint.committedFrames == 10)
                #expect(try ProcessingTimelineReader(directory: directory, checkpoint: result.checkpoint)
                    .readSamples(frameRange: 0..<10) == Array(repeating: Float(0.25), count: 10))
            } else {
                if exit == "cancel" { engine.cancelStarting() }
                do {
                    _ = try await engine.stop()
                    Issue.record("No captured frames should fail startup")
                } catch AudioCaptureEngineError.noAudioCaptured {}
                #expect(try AudioCheckpoint.loadRecovered(from: directory)?.committedFrames == 0)
            }
        }
        #expect(!engine.power.active)
        #expect(provider.acquisitions == 1)
        #expect(provider.releases == 1)
    }
}

@MainActor
@Test("a writer failure after committed chunks stops with the healthy prefix and a cause naming the chunk")
func writerFailureReturnsHealthyPrefix() async throws {
    let (root, paths) = temporaryRecordingPaths()
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = AudioCaptureEngine(paths: paths, power: FakePower(), micInputVolumeFactory: {
        preconditionFailure("Input-free teardown never binds a microphone volume control")
    })
    let directory = root.appending(path: "capture", directoryHint: .isDirectory)
    let writer = try DurableAudioWriter(
        directory: directory, sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1
    )
    let ring = AudioBlockRing(capacity: 4, blockFrameCapacity: 10)
    let receiver = AudioCaptureReceiver(
        ring: ring, sampleRate: 10, channelCount: 1, onFormatChange: {}, clock: SystemCaptureClock(), frameCapacity: 16_384, meter: nil
    )
    let drain = AudioCaptureDrain(ring: ring, writer: writer)
    #expect(engine.power.begin())
    engine.installCapture(
        session: nil, output: nil, receiver: receiver, callbackQueue: nil,
        tap: nil, sink: receiver.sink,
        ring: ring, drain: drain, drainTask: nil, sessionID: UUID(),
        timeline: ProcessingTimeline(sampleRate: 10, channelCount: 1, sampleFormat: .float32LE)
    )
    #expect(pushRingMono(Array(repeating: 0.25, count: 10), at: 0, into: ring))
    _ = try await drain.drainAvailable()
    try FileManager.default.createDirectory(
        at: directory.appending(path: "chunk-000001.f32le"), withIntermediateDirectories: false
    )
    #expect(pushRingMono(Array(repeating: 0.5, count: 5), at: 10, into: ring))

    let result = try await engine.stop()
    #expect(result.writerFailure == "録音の保存に失敗しました: chunk-000001.f32le を書き込めませんでした")
    #expect(result.checkpoint.committedFrames == 10)
    #expect(try ProcessingTimelineReader(directory: directory, checkpoint: result.checkpoint)
        .readSamples(frameRange: 0..<10) == Array(repeating: Float(0.25), count: 10))
    #expect(!engine.power.active && !engine.isRecording)
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
@Test("recording stalls after last buffer, named by input source, without mistaking silent buffers for a stall",
      arguments: [
          (CaptureSource.microphone, "マイクから音声が届かなくなりました。録音を停止しました"),
          (CaptureSource.systemAudio, "システム音声が届かなくなりました。録音を停止しました")
      ])
func recordingStallMonitor(source: CaptureSource, message: String) {
    let clock = TestCaptureClock(millis: 10_000)
    let disk = TestCaptureDisk(free: 500_000_000)
    var failures: [String] = []
    var warnings: [String] = []
    var dropouts: [UInt64] = []
    let monitor = CaptureHealthMonitor(
        source: source, clock: clock, diskSpace: disk,
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
    #expect(failures == [message])
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
        source: .microphone, clock: clock, diskSpace: disk,
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
    // A private center keeps this post from terminating AppStates in parallel tests.
    let center = NotificationCenter()
    var observation: TerminationObservation? = TerminationObservation(center: center) {
        _ = calls.add(1, ordering: .relaxed)
    }
    withExtendedLifetime(observation) {
        center.post(name: NSApplication.willTerminateNotification, object: nil)
    }
    #expect(calls.load(ordering: .relaxed) == 1)
    observation = nil
    center.post(name: NSApplication.willTerminateNotification, object: nil)
    #expect(calls.load(ordering: .relaxed) == 1)
}

@Test("Large packed tap buffers split at scratch capacity without losing their timestamps")
func oversizedTimestampedMonoBufferKeepsSamples() throws {
    let ring = AudioBlockRing(capacity: 8, blockFrameCapacity: 4)
    let sink = TimestampedMonoSink(ring: ring, frameCapacity: 2, clock: SystemCaptureClock(), meter: nil)
    var packed: [Float] = [1, 3, 2, 4, 3, 5, 4, 6, 5, 7]
    packed.withUnsafeMutableBufferPointer { buffer in
        let channels = [UnsafePointer(buffer.baseAddress!), UnsafePointer(buffer.baseAddress!.advanced(by: 1))]
        let strides = [2, 2]
        channels.withUnsafeBufferPointer { pointers in
            strides.withUnsafeBufferPointer { steps in
                sink.receive(channels: pointers.baseAddress!, strides: steps.baseAddress!,
                             channelCount: 2, frameCount: 5, startFrame: 10)
            }
        }
    }
    ring.finish(tailFrame: sink.lastEndFrame)
    let blocks = [try #require(ring.pop()), try #require(ring.pop()), try #require(ring.pop())]
    #expect(blocks.map(\.startFrame) == [10, 12, 14])
    #expect(blocks.flatMap(\.samples) == [2, 3, 4, 5, 6])
    #expect(sink.lastEndFrame == 15)
}
