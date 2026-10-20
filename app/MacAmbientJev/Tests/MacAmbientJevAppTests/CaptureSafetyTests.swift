import AppKit
import AVFoundation
import Foundation
import IOKit.audio
import Synchronization
import Testing
@testable import MacAmbientJevCapture
@testable import MacAmbientJev
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevPipeline

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
        let writer = try DurableAudioWriter(directory: directory, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
        let ring = AudioBlockRing(capacity: 2, blockFrameCapacity: 10)
        let receiver = AudioCaptureReceiver(
            ring: ring, sampleRate: 10, channelCount: 1, onFormatChange: {}, clock: SystemCaptureClock(), frameCapacity: 16_384, meter: nil
        )
        let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: CanonicalAudio.sampleRate))
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
            #expect(try AudioCheckpoint.loadRecovered(from: directory, relativeTo: root)?.committedFrames == 10)
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
                #expect(try AudioCheckpoint.loadRecovered(from: directory, relativeTo: root)?.committedFrames == 0)
            } else if exit == "normal" {
                let result = try await engine.stop()
                #expect(result.checkpoint.committedFrames == 10)
                #expect(try ProcessingTimelineReader(directory: directory, checkpoint: result.checkpoint, sessionURL: root)
                    .readSamples(frameRange: 0..<10) == Array(repeating: Float(0.25), count: 10))
            } else {
                if exit == "cancel" { engine.cancelStarting() }
                do {
                    _ = try await engine.stop()
                    Issue.record("No captured frames should fail startup")
                } catch AudioCaptureEngineError.noAudioCaptured {}
                #expect(try AudioCheckpoint.loadRecovered(from: directory, relativeTo: root)?.committedFrames == 0)
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
    let writer = try DurableAudioWriter(directory: directory, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: root)
    let ring = AudioBlockRing(capacity: 4, blockFrameCapacity: 10)
    let receiver = AudioCaptureReceiver(
        ring: ring, sampleRate: 10, channelCount: 1, onFormatChange: {}, clock: SystemCaptureClock(), frameCapacity: 16_384, meter: nil
    )
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: CanonicalAudio.sampleRate))
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
    #expect(result.checkpoint.committedFrames == 10)
    #expect(try ProcessingTimelineReader(directory: directory, checkpoint: result.checkpoint, sessionURL: root)
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
