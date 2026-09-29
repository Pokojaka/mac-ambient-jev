import AudioToolbox
import CoreAudio
import Foundation
import MacAmbientJevCore
import Synchronization
import Testing
@testable import MacAmbientJevCapture

/// No Core Audio call escapes this fake; it exercises SystemAudioTap's real ownership code.
@MainActor
private final class FakeTapHardware: SystemAudioTapHardware {
    enum Stage: CaseIterable {
        case process, tap, format, invalidFormat, aggregate, listener, ioProc, start
    }

    var failure: Stage?
    var returnIDOnFailure = false
    var returnNilIOProc = false
    var events: [String] = []
    private let proc = unsafeBitCast(UInt(0x1234), to: AudioDeviceIOProcID.self)
    private let tap: AudioObjectID = 41
    private let device: AudioObjectID = 42

    func ownProcessObject() throws -> AudioObjectID {
        events.append("process")
        if failure == .process { throw SystemAudioTapError.unavailable("process lookup") }
        return 43
    }

    func createTap(_ description: CATapDescription, _ result: inout AudioObjectID) -> OSStatus {
        events.append("tap")
        #expect(description.isExclusive)
        #expect(description.isMono)
        #expect(description.deviceUID == nil)
        #expect(description.muteBehavior == .unmuted)
        #expect((description.value(forKey: "processes") as? [NSNumber]) == [NSNumber(value: 43)])
        if failure != .tap || returnIDOnFailure { result = tap }
        return failure == .tap ? -50 : noErr
    }

    func tapFormat(_ tap: AudioObjectID, _ format: inout AudioStreamBasicDescription) -> OSStatus {
        events.append("format")
        #expect(tap == self.tap)
        if failure == .format { return -50 }
        format.mSampleRate = 48_000
        format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags = kAudioFormatFlagIsFloat
        format.mBitsPerChannel = failure == .invalidFormat ? 16 : 32
        format.mChannelsPerFrame = 1
        return noErr
    }

    func createAggregate(_ description: CFDictionary, _ result: inout AudioObjectID) -> OSStatus {
        events.append("aggregate")
        let dictionary = description as NSDictionary
        #expect(dictionary["private"] as? Bool == true)
        #expect((dictionary["taps"] as? [[String: Any]])?.count == 1)
        if failure != .aggregate || returnIDOnFailure { result = device }
        return failure == .aggregate ? -50 : noErr
    }

    func addFormatListener(_ tap: AudioObjectID, _ queue: DispatchQueue,
                           _ listener: AudioObjectPropertyListenerBlock) -> OSStatus {
        events.append("listener")
        #expect(tap == self.tap)
        return failure == .listener ? -50 : noErr
    }

    func removeFormatListener(_ tap: AudioObjectID, _ queue: DispatchQueue,
                              _ listener: AudioObjectPropertyListenerBlock) -> OSStatus {
        events.append("removeListener")
        #expect(tap == self.tap)
        return noErr
    }

    func createIOProc(_ result: inout AudioDeviceIOProcID?, _ device: AudioObjectID,
                      _ queue: DispatchQueue, _ callback: @escaping AudioDeviceIOBlock) -> OSStatus {
        events.append("ioProc")
        #expect(device == self.device)
        if !returnNilIOProc && (failure != .ioProc || returnIDOnFailure) { result = proc }
        return failure == .ioProc ? -50 : noErr
    }

    func start(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus {
        events.append("start")
        #expect(device == self.device)
        return failure == .start ? -50 : noErr
    }

    func stop(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus {
        events.append("stop")
        #expect(device == self.device)
        return noErr
    }

    func destroyIOProc(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus {
        events.append("destroyIOProc")
        #expect(device == self.device)
        return noErr
    }

    func destroyAggregate(_ device: AudioObjectID) -> OSStatus {
        events.append("destroyAggregate")
        #expect(device == self.device)
        return noErr
    }

    func destroyTap(_ tap: AudioObjectID) -> OSStatus {
        events.append("destroyTap")
        #expect(tap == self.tap)
        return noErr
    }
}

@MainActor
@Test("A failed tap preparation releases every resource already returned by Core Audio")
func tapPreparationFailureBoundaries() {
    let cases: [(FakeTapHardware.Stage, [String])] = [
        (.process, ["process"]),
        (.tap, ["process", "tap", "destroyTap"]),
        (.format, ["process", "tap", "format", "destroyTap"]),
        (.invalidFormat, ["process", "tap", "format", "destroyTap"]),
        (.aggregate, ["process", "tap", "format", "aggregate", "destroyAggregate", "destroyTap"])
    ]
    for (stage, expected) in cases {
        let hardware = FakeTapHardware()
        hardware.failure = stage
        hardware.returnIDOnFailure = true
        do {
            let tap = try SystemAudioTap(hardware: hardware)
            tap.stop()
            Issue.record("Expected \(stage) to fail")
        } catch {
            #expect(hardware.events == expected, "Failure at \(stage): \(hardware.events)")
        }
    }
}

@MainActor
@Test("Listener, IOProc, and device start failures unwind in reverse acquisition order")
func tapStartFailureBoundaries() throws {
    let cases: [(FakeTapHardware.Stage, [String])] = [
        (.listener, ["listener", "destroyAggregate", "destroyTap"]),
        (.ioProc, ["listener", "ioProc", "destroyIOProc", "removeListener", "destroyAggregate", "destroyTap"]),
        (.start, ["listener", "ioProc", "start", "destroyIOProc", "removeListener", "destroyAggregate", "destroyTap"])
    ]
    for (stage, expected) in cases {
        let hardware = FakeTapHardware()
        hardware.failure = stage
        hardware.returnIDOnFailure = true
        let tap = try SystemAudioTap(hardware: hardware)
        let initial = hardware.events.count
        let sink = TimestampedMonoSink(ring: AudioBlockRing(capacity: 4, blockFrameCapacity: 8),
                                       frameCapacity: 8, clock: FixedClock())
        do {
            try tap.start(sink: sink, onFailure: { _ in })
            Issue.record("Expected \(stage) to fail")
        } catch {
            #expect(Array(hardware.events.dropFirst(initial)) == expected,
                    "Failure at \(stage): \(hardware.events)")
        }
        tap.stop()
        #expect(hardware.events.count == initial + expected.count)
    }
}

@MainActor
@Test("A missing IOProc ID and a normal stop both release their exact acquired resources")
func tapIOProcMissingAndNormalStop() throws {
    let sink = TimestampedMonoSink(ring: AudioBlockRing(capacity: 4, blockFrameCapacity: 8),
                                   frameCapacity: 8, clock: FixedClock())
    let missing = FakeTapHardware()
    missing.returnNilIOProc = true
    let missingTap = try SystemAudioTap(hardware: missing)
    do {
        try missingTap.start(sink: sink, onFailure: { _ in })
        Issue.record("Expected a missing IOProc ID")
    } catch {
        #expect(Array(missing.events.dropFirst(4)) ==
                ["listener", "ioProc", "removeListener", "destroyAggregate", "destroyTap"])
    }
    let normal = FakeTapHardware()
    let tap = try SystemAudioTap(hardware: normal)
    try tap.start(sink: sink, onFailure: { _ in })
    tap.stop()
    let afterStop = normal.events
    #expect(Array(afterStop.dropFirst(4)) ==
            ["listener", "ioProc", "start", "stop", "destroyIOProc",
             "removeListener", "destroyAggregate", "destroyTap"])
    tap.stop()
    #expect(normal.events == afterStop)
}

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
    var emitsSilence = false
    var emitsGap = false
    var onStarted: (@MainActor () -> Void)?
    func start(sink: TimestampedMonoSink, onFailure: @escaping @MainActor @Sendable (String) -> Void) throws {
        starts += 1
        onStarted?()
        guard emitsBuffer else { return }
        if shouldFail { throw SystemAudioTapError.permissionDenied }
        if emitsSilence {
            sink.silence(startFrame: 0, frameCount: 4)
            return
        }
        var samples: [Float] = [0.25, -0.25, 0.5, -0.5]
        samples.withUnsafeMutableBufferPointer { buffer in
            var pointer = UnsafePointer(buffer.baseAddress!)
            var stride = 1
            withUnsafePointer(to: &pointer) { channels in
                withUnsafePointer(to: &stride) { strides in
                    sink.receive(channels: channels, strides: strides, channelCount: 1,
                                 frameCount: 4, startFrame: 0)
                    if emitsGap {
                        sink.receive(channels: channels, strides: strides, channelCount: 1,
                                     frameCount: 4, startFrame: 6)
                    }
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
@Test("Silent system buffers satisfy startup and remain valid captured audio on stop")
func fakeTapSilentStartupAndStop() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let tap = FakeTap()
    tap.emitsSilence = true
    let power = FakeCapturePower()
    let engine = AudioCaptureEngine(paths: paths, bufferFrameCount: 8, power: power,
                                    diskSpace: AvailableDisk(), tapFactory: { tap })
    try await engine.start(sessionID: UUID(), source: .systemAudio, onFailure: { _ in })
    let result = try await engine.stop()
    #expect(result.checkpoint.committedFrames == 4)
    #expect(result.dropoutCount == 0 && result.gapCount == 0)
    #expect(tap.starts == 1 && tap.stops == 1)
    #expect(power.acquisitions == 1 && power.releases == 1)
}

@MainActor
@Test("A system tap PTS jump uses shared durable gap filling and stop diagnostics")
func fakeTapGapUsesSharedDrain() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let tap = FakeTap()
    tap.emitsGap = true
    let engine = AudioCaptureEngine(paths: paths, bufferFrameCount: 8,
                                    power: FakeCapturePower(), diskSpace: AvailableDisk(),
                                    tapFactory: { tap })
    let sessionID = UUID()
    try await engine.start(sessionID: sessionID, source: .systemAudio, onFailure: { _ in })
    let result = try await engine.stop()
    #expect(result.checkpoint.committedFrames == 10)
    #expect(result.didOverflow && result.dropoutCount == 1)
    #expect(result.gapCount == 1 && result.totalGapFrames == 2)
    let directory = root.appending(path: sessionID.uuidString)
        .appending(path: "audio/processing")
    let samples = try ProcessingTimelineReader(directory: directory, checkpoint: result.checkpoint)
        .readSamples(frameRange: 0..<10)
    #expect(samples == [0.25, -0.25, 0.5, -0.5, 0, 0, 0.25, -0.25, 0.5, -0.5])
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
