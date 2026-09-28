import Foundation
import MacAmbientJevCore
import Synchronization
import Testing
@testable import MacAmbientJevCapture

private final class FixedClock: CaptureClock {
    let millis = Atomic<Int64>(10_000)
    func now() -> TimeInterval { Double(millis.load(ordering: .relaxed)) / 1_000 }
}

@Test("Device sample and host time preserve discontinuities and fall back without timestamps")
func timestampMapperContinuityAndClockFallback() {
    let mapper = CaptureFrameTimestampMapper()
    #expect(mapper.startFrame(sampleTime: 48_000, hostTimeNanos: 10_000_000_000,
                              sampleRate: 48_000, fallbackEndFrame: 0) == 0)
    #expect(mapper.startFrame(sampleTime: 48_480, hostTimeNanos: 10_010_000_000,
                              sampleRate: 48_000, fallbackEndFrame: 240) == 480)
    #expect(mapper.startFrame(sampleTime: nil, hostTimeNanos: 10_020_000_000,
                              sampleRate: 48_000, fallbackEndFrame: 500) == 960)
    #expect(mapper.startFrame(sampleTime: nil, hostTimeNanos: nil,
                              sampleRate: 48_000, fallbackEndFrame: 1_008) == 1_008)
    let hostOnly = CaptureFrameTimestampMapper()
    #expect(hostOnly.startFrame(sampleTime: nil, hostTimeNanos: 5_000_000_000,
                                sampleRate: 1_000, fallbackEndFrame: 10) == 10)
    #expect(hostOnly.startFrame(sampleTime: nil, hostTimeNanos: 5_005_000_000,
                                sampleRate: 1_000, fallbackEndFrame: 11) == 15)
}

@Test("Stereo packed and planar callbacks downmix without changing frame timestamps")
func timestampedMonoConversionAndGapAccounting() throws {
    let ring = AudioBlockRing(capacity: 8, blockFrameCapacity: 8, sampleRate: 1_000)
    let clock = FixedClock()
    let sink = TimestampedMonoSink(ring: ring, frameCapacity: 8, clock: clock)
    var packed: [Float] = [0.25, 0.75, -0.5, 0.5]
    var left: [Float] = [1, -1]
    var right: [Float] = [-1, 1]
    let packedStrides = [2, 2]
    let planarStrides = [1, 1]
    packed.withUnsafeMutableBufferPointer { packedBuffer in
        var pointers = [UnsafePointer(packedBuffer.baseAddress!), UnsafePointer(packedBuffer.baseAddress!.advanced(by: 1))]
        pointers.withUnsafeMutableBufferPointer { channels in
            packedStrides.withUnsafeBufferPointer { strides in
                sink.receive(channels: channels.baseAddress!, strides: strides.baseAddress!,
                             channelCount: 2, frameCount: 2, startFrame: 0)
            }
        }
    }
    left.withUnsafeMutableBufferPointer { leftBuffer in
        right.withUnsafeMutableBufferPointer { rightBuffer in
            var pointers = [UnsafePointer(leftBuffer.baseAddress!), UnsafePointer(rightBuffer.baseAddress!)]
            pointers.withUnsafeMutableBufferPointer { channels in
                planarStrides.withUnsafeBufferPointer { strides in
                    sink.receive(channels: channels.baseAddress!, strides: strides.baseAddress!,
                                 channelCount: 2, frameCount: 2, startFrame: 5)
                }
            }
        }
    }
    ring.finish(tailFrame: sink.lastEndFrame)
    let first = try #require(ring.pop())
    let second = try #require(ring.pop())
    #expect(first.samples == [0.5, 0])
    #expect(second.samples == [0, 0])
    #expect(first.startFrame == 0 && second.startFrame == 5)
    #expect(ring.dropoutCount == 1)
    #expect(sink.lastEndFrame == 7)
    #expect(sink.lastBufferMillis.load(ordering: .relaxed) == 10_000)
    #expect(sink.silentSinceMillis.load(ordering: .relaxed) == 10_000)
}

@Test("Invalid callback preserves its timestamp and blocks a false ready signal")
func timestampedMonoInvalidBuffer() throws {
    let ring = AudioBlockRing(capacity: 4, blockFrameCapacity: 8)
    let sink = TimestampedMonoSink(ring: ring, frameCapacity: 8, clock: FixedClock())
    sink.missing(startFrame: 10, frameCount: 3)
    ring.finish(tailFrame: sink.lastEndFrame)
    #expect(sink.lastBufferMillis.load(ordering: .relaxed) == 0)
    #expect(sink.invalidBufferCount.load(ordering: .relaxed) == 1)
    #expect(try #require(ring.pop()).gap == AudioGap(startFrame: 10, frameCount: 3, reason: .invalidBuffer))
}

@Test("Explicit silent packets contain zeros and retain preceding timestamp gaps")
func timestampedSilentPacketAfterSignal() throws {
    let ring = AudioBlockRing(capacity: 8, blockFrameCapacity: 4, sampleRate: 1_000)
    let sink = TimestampedMonoSink(ring: ring, frameCapacity: 4, clock: FixedClock())
    var sample: Float = 0.75
    var stride = 1
    withUnsafePointer(to: &sample) { value in
        var pointer = value
        withUnsafePointer(to: &pointer) { channels in
            withUnsafePointer(to: &stride) { strides in
                sink.receive(channels: channels, strides: strides,
                             channelCount: 1, frameCount: 1, startFrame: 0)
            }
        }
    }
    sink.silence(startFrame: 3, frameCount: 6)
    ring.finish(tailFrame: sink.lastEndFrame)
    #expect(try #require(ring.pop()).samples == [0.75])
    let first = try #require(ring.pop())
    let second = try #require(ring.pop())
    #expect(first.samples == [0, 0, 0, 0])
    #expect(second.samples == [0, 0])
    #expect(first.startFrame == 3 && second.startFrame == 7)
    #expect(ring.dropoutCount == 1)
    #expect(sink.invalidBufferCount.load(ordering: .relaxed) == 0)
    #expect(sink.silentSinceMillis.load(ordering: .relaxed) == 10_000)
}

@MainActor
private final class FakeTap: SystemAudioTapProviding {
    var sampleRate: Double = 1_000
    var starts = 0
    var stops = 0
    var shouldFail = false
    var emitsBuffer = true
    var onStarted: (@MainActor () -> Void)?
    func start(sink: TimestampedMonoSink, onFailure: @escaping @MainActor @Sendable (String) -> Void) throws {
        starts += 1
        onStarted?()
        guard emitsBuffer else { return }
        if shouldFail { throw SystemAudioTapError.permissionDenied }
        var samples: [Float] = [0.25, -0.25, 0.5, -0.5]
        samples.withUnsafeMutableBufferPointer { buffer in
            var pointer = UnsafePointer(buffer.baseAddress!)
            var stride = 1
            withUnsafePointer(to: &pointer) { channels in
                withUnsafePointer(to: &stride) { strides in
                    sink.receive(channels: channels, strides: strides, channelCount: 1,
                                 frameCount: 4, startFrame: 0)
                }
            }
        }
    }
    func stop() { stops += 1 }
}

@MainActor
private final class FakeCapturePower: RecordingPowerProviding {
    var acquisitions = 0
    var releases = 0
    func acquire() -> Bool { acquisitions += 1; return true }
    func release() { releases += 1 }
}

private struct AvailableDisk: CaptureDiskSpaceProviding {
    var bytes: Int64 = 10_000_000_000
    func availableBytes(at url: URL) throws -> Int64? { bytes }
}

@MainActor
@Test("A fake process tap records through durable mono chunks and pairs cleanup with power")
func fakeTapEngineLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let tap = FakeTap()
    let power = FakeCapturePower()
    let engine = AudioCaptureEngine(paths: paths, bufferFrameCount: 8, ringCapacity: 8,
                                    chunkDurationSeconds: 0.004, power: power,
                                    diskSpace: AvailableDisk(), tapFactory: { tap })
    let session = UUID()
    try await engine.start(sessionID: session, source: .systemAudio, onFailure: { _ in })
    #expect(engine.isRecording && engine.activeSessionID == session)
    #expect(engine.timeline?.channelCount == 1)
    let result = try await engine.stop()
    #expect(result.checkpoint.committedFrames == 4)
    #expect(result.dropoutCount == 0 && result.gapCount == 0)
    #expect(result.sleepAssertionHeld)
    #expect(tap.starts == 1 && tap.stops == 1)
    #expect(power.acquisitions == 1 && power.releases == 1)
    #expect(!engine.isRecording)
}

@MainActor
@Test("Fake tap start failure destroys backend and power assertion")
func fakeTapStartFailureReleasesResources() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let tap = FakeTap()
    tap.shouldFail = true
    let power = FakeCapturePower()
    let engine = AudioCaptureEngine(paths: paths, power: power, diskSpace: AvailableDisk(),
                                    tapFactory: { tap })
    do {
        try await engine.start(sessionID: UUID(), source: .systemAudio, onFailure: { _ in })
        Issue.record("Expected denial")
    } catch {
        #expect(error.localizedDescription.contains("システム音声"))
    }
    #expect(tap.starts == 1 && tap.stops >= 1)
    #expect(power.acquisitions == 1 && power.releases == 1)
    #expect(!engine.isRecording)
}

@MainActor
@Test("Tap preflight checks the selected recording volume and destroys the unused tap")
func tapPreflightDiskRejection() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let tap = FakeTap()
    let power = FakeCapturePower()
    let engine = AudioCaptureEngine(paths: paths, power: power, diskSpace: AvailableDisk(bytes: 0),
                                    tapFactory: { tap })
    do {
        try await engine.start(sessionID: UUID(), source: .systemAudio, onFailure: { _ in })
        Issue.record("Expected selected-volume disk rejection")
    } catch AudioCaptureEngineError.insufficientDiskSpace {
        #expect(tap.starts == 0 && tap.stops == 1)
        #expect(power.acquisitions == 0 && power.releases == 0)
    }
}

@MainActor
@Test("Writer directory failure destroys prepared tap before starting the IOProc")
func tapWriterDirectoryFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data([1]).write(to: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let tap = FakeTap()
    let power = FakeCapturePower()
    let engine = AudioCaptureEngine(paths: paths, power: power, diskSpace: AvailableDisk(),
                                    tapFactory: { tap })
    do {
        try await engine.start(sessionID: UUID(), source: .systemAudio, onFailure: { _ in })
        Issue.record("Expected directory creation to fail")
    } catch {
        #expect(tap.starts == 0 && tap.stops == 1)
        #expect(power.acquisitions == 0 && power.releases == 0)
    }
}

@MainActor
@Test("Cancelled first-buffer wait tears down IOProc, ring, and sleep assertion")
func tapStartCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let tap = FakeTap()
    tap.emitsBuffer = false
    let power = FakeCapturePower()
    let engine = AudioCaptureEngine(paths: paths, power: power, diskSpace: AvailableDisk(),
                                    tapFactory: { tap })
    tap.onStarted = { engine.cancelStarting() }
    do {
        try await engine.start(sessionID: UUID(), source: .systemAudio, onFailure: { _ in })
        Issue.record("Expected cancellation")
    } catch AudioCaptureEngineError.cancelled {
        #expect(tap.starts == 1 && tap.stops == 1)
        #expect(power.acquisitions == 1 && power.releases == 1)
        #expect(!engine.isRecording)
    }
}

@MainActor
@Test("Writer flush failure still destroys tap and releases sleep assertion")
func tapWriterFlushFailureReleasesResources() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let tap = FakeTap()
    let power = FakeCapturePower()
    let engine = AudioCaptureEngine(paths: paths, power: power, diskSpace: AvailableDisk(),
                                    tapFactory: { tap })
    let session = UUID()
    try await engine.start(sessionID: session, source: .systemAudio, onFailure: { _ in })
    let processing = root.appending(path: session.uuidString)
        .appending(path: "audio").appending(path: "processing")
    try FileManager.default.removeItem(at: processing)
    do {
        _ = try await engine.stop()
        Issue.record("Expected failure while flushing deleted writer directory")
    } catch {
        #expect(!engine.isRecording)
        #expect(tap.stops == 1)
        #expect(power.releases == 1)
    }
}
