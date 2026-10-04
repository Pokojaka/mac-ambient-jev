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
    var refusedReleases: Set<String> = []
    var events: [String] = []
    var formatListener: AudioObjectPropertyListenerBlock?
    var callback: AudioDeviceIOBlock?
    var callbackQueue: DispatchQueue?
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
                           _ listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        events.append("listener")
        #expect(tap == self.tap)
        formatListener = listener
        return failure == .listener ? -50 : noErr
    }

    func removeFormatListener(_ tap: AudioObjectID, _ queue: DispatchQueue,
                              _ listener: AudioObjectPropertyListenerBlock) -> OSStatus {
        events.append("removeListener")
        if refusedReleases.contains("removeListener") { return -1 }
        #expect(tap == self.tap)
        return noErr
    }

    func createIOProc(_ result: inout AudioDeviceIOProcID?, _ device: AudioObjectID,
                      _ queue: DispatchQueue, _ callback: @escaping AudioDeviceIOBlock) -> OSStatus {
        events.append("ioProc")
        #expect(device == self.device)
        self.callback = callback
        callbackQueue = queue
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
        if refusedReleases.contains("stop") { return -1 }
        #expect(device == self.device)
        return noErr
    }

    func destroyIOProc(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus {
        events.append("destroyIOProc")
        if refusedReleases.contains("destroyIOProc") { return -1 }
        #expect(device == self.device)
        return noErr
    }

    func destroyAggregate(_ device: AudioObjectID) -> OSStatus {
        events.append("destroyAggregate")
        if refusedReleases.contains("destroyAggregate") { return -1 }
        #expect(device == self.device)
        return noErr
    }

    func destroyTap(_ tap: AudioObjectID) -> OSStatus {
        events.append("destroyTap")
        if refusedReleases.contains("destroyTap") { return -1 }
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
            try tap.stop()
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
                                       frameCapacity: 8, clock: FixedClock(), meter: nil)
        do {
            try tap.start(sink: sink, onFailure: { _ in })
            Issue.record("Expected \(stage) to fail")
        } catch {
            #expect(Array(hardware.events.dropFirst(initial)) == expected,
                    "Failure at \(stage): \(hardware.events)")
        }
        try tap.stop()
        #expect(hardware.events.count == initial + expected.count)
    }
}

@MainActor
@Test("A missing IOProc ID and a normal stop both release their exact acquired resources")
func tapIOProcMissingAndNormalStop() throws {
    let sink = TimestampedMonoSink(ring: AudioBlockRing(capacity: 4, blockFrameCapacity: 8),
                                   frameCapacity: 8, clock: FixedClock(), meter: nil)
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
    try tap.stop()
    let afterStop = normal.events
    #expect(Array(afterStop.dropFirst(4)) ==
            ["listener", "ioProc", "start", "stop", "destroyIOProc",
             "removeListener", "destroyAggregate", "destroyTap"])
    try tap.stop()
    #expect(normal.events == afterStop)
}

@MainActor
@Test("A refused release still attempts every later release and is reported, once")
func tapStopReportsRefusedRelease() throws {
    let sink = TimestampedMonoSink(ring: AudioBlockRing(capacity: 4, blockFrameCapacity: 8),
                                   frameCapacity: 8, clock: FixedClock(), meter: nil)
    let hardware = FakeTapHardware()
    hardware.refusedReleases = ["stop", "destroyAggregate"]
    let tap = try SystemAudioTap(hardware: hardware)
    try tap.start(sink: sink, onFailure: { _ in })
    do {
        try tap.stop()
        Issue.record("Expected the refused releases to be reported")
    } catch SystemAudioTapError.releaseFailed(let operations, let after) {
        #expect(operations == ["録音の停止 OSStatus -1", "仮想デバイスの破棄 OSStatus -1"])
        #expect(after == nil)
    }
    #expect(Array(hardware.events.dropFirst(4)) ==
            ["listener", "ioProc", "start", "stop", "destroyIOProc",
             "removeListener", "destroyAggregate", "destroyTap"])
    try tap.stop()
}

@MainActor
@Test("A refused release during a failed start keeps the start failure in the report")
func tapStartFailureWithRefusedRelease() throws {
    let hardware = FakeTapHardware()
    hardware.failure = .start
    hardware.refusedReleases = ["destroyTap"]
    let tap = try SystemAudioTap(hardware: hardware)
    let sink = TimestampedMonoSink(ring: AudioBlockRing(capacity: 4, blockFrameCapacity: 8),
                                   frameCapacity: 8, clock: FixedClock(), meter: nil)
    do {
        try tap.start(sink: sink, onFailure: { _ in })
        Issue.record("Expected start to fail")
    } catch SystemAudioTapError.releaseFailed(let operations, let after) {
        #expect(operations == ["タップの破棄 OSStatus -1"])
        #expect(after?.contains("録音の開始") == true)
    }
}

/// Core Audio's imported block aliases erase Sendable; immutable copies cross to the fake queue.
private struct TapCallbackBlocks: @unchecked Sendable {
    let receive: AudioDeviceIOBlock
    let formatChanged: AudioObjectPropertyListenerBlock
}

@MainActor
@Test("Background tap callbacks stop accepting matching-layout audio after format invalidation")
func tapRejectsAudioAfterFormatInvalidation() async throws {
    let hardware = FakeTapHardware()
    let tap = try SystemAudioTap(hardware: hardware)
    defer { #expect(throws: Never.self) { try tap.stop() } }
    let ring = AudioBlockRing(capacity: 4, blockFrameCapacity: 8, sampleRate: 48_000)
    let sink = TimestampedMonoSink(ring: ring, frameCapacity: 8, clock: FixedClock(), meter: nil)
    try tap.start(sink: sink, onFailure: { _ in })
    let callbacks = TapCallbackBlocks(
        receive: try #require(hardware.callback),
        formatChanged: try #require(hardware.formatListener)
    )
    let callbackQueue = try #require(hardware.callbackQueue)
    await withCheckedContinuation { continuation in
        callbackQueue.async { @Sendable in
            #expect(!Thread.isMainThread)
            var samples: [Float] = [0.25, -0.5]
            var timestamp = AudioTimeStamp()
            timestamp.mFlags = .sampleTimeValid
            samples.withUnsafeMutableBytes { bytes in
                var input = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count),
                                         mData: bytes.baseAddress)
                )
                var output = AudioBufferList()
                withUnsafePointer(to: &timestamp) { time in
                    callbacks.receive(time, &input, time, &output, time)
                }
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                callbacks.formatChanged(1, &address)
                timestamp.mSampleTime = 2
                withUnsafePointer(to: &timestamp) { time in
                    callbacks.receive(time, &input, time, &output, time)
                }
            }
            continuation.resume()
        }
    }
    ring.finish(tailFrame: sink.lastEndFrame)
    #expect(sink.lastEndFrame == 2)
    #expect(try #require(ring.pop()).samples == [0.25, -0.5])
    #expect(ring.pop() == nil)
    #expect(ring.dropoutCount == 0)
}

private final class FixedClock: CaptureClock {
    let millis = Atomic<Int64>(10_000)
    func now() -> TimeInterval { Double(millis.load(ordering: .relaxed)) / 1_000 }
}

@Test("Device sample and host time preserve discontinuities; untimestamped buffers stay contiguous")
func timestampMapperContinuityAndHostClockMapping() {
    let mapper = CaptureFrameTimestampMapper()
    #expect(mapper.startFrame(sampleTime: 48_000, hostTimeNanos: 10_000_000_000,
                              sampleRate: 48_000, contiguousEndFrame: 0) == 0)
    #expect(mapper.startFrame(sampleTime: 48_480, hostTimeNanos: 10_010_000_000,
                              sampleRate: 48_000, contiguousEndFrame: 240) == 480)
    #expect(mapper.startFrame(sampleTime: nil, hostTimeNanos: 10_020_000_000,
                              sampleRate: 48_000, contiguousEndFrame: 500) == 960)
    #expect(mapper.startFrame(sampleTime: nil, hostTimeNanos: nil,
                              sampleRate: 48_000, contiguousEndFrame: 1_008) == 1_008)
    let hostOnly = CaptureFrameTimestampMapper()
    #expect(hostOnly.startFrame(sampleTime: nil, hostTimeNanos: 5_000_000_000,
                                sampleRate: 1_000, contiguousEndFrame: 10) == 10)
    #expect(hostOnly.startFrame(sampleTime: nil, hostTimeNanos: 5_005_000_000,
                                sampleRate: 1_000, contiguousEndFrame: 11) == 15)
}

@Test("A device sample clock that restarts continues the timeline instead of rewinding it")
func timestampMapperReanchorsWhenSampleTimeRestarts() {
    let mapper = CaptureFrameTimestampMapper()
    #expect(mapper.startFrame(sampleTime: 48_000, hostTimeNanos: nil,
                              sampleRate: 48_000, contiguousEndFrame: 0) == 0)
    #expect(mapper.startFrame(sampleTime: 48_480, hostTimeNanos: nil,
                              sampleRate: 48_000, contiguousEndFrame: 480) == 480)
    #expect(mapper.startFrame(sampleTime: 100, hostTimeNanos: nil,
                              sampleRate: 48_000, contiguousEndFrame: 960) == 960)
    #expect(mapper.startFrame(sampleTime: 580, hostTimeNanos: nil,
                              sampleRate: 48_000, contiguousEndFrame: 1_440) == 1_440)
    #expect(mapper.startFrame(sampleTime: 1_540, hostTimeNanos: nil,
                              sampleRate: 48_000, contiguousEndFrame: 1_920) == 2_400)
}

@Test("A restarted sample clock preserves the host-time gap and later timestamp mappings")
func timestampMapperRestartPreservesHostTimeGap() throws {
    let mapper = CaptureFrameTimestampMapper()
    let ring = AudioBlockRing(capacity: 8, blockFrameCapacity: 512, sampleRate: 48_000)
    let sink = TimestampedMonoSink(ring: ring, frameCapacity: 512, clock: FixedClock(), meter: nil)
    let timestamps: [(Double?, UInt64?, Int64)] = [
        (48_000, 10_000_000_000, 0),
        (48_480, 10_010_000_000, 480),
        (100, 11_020_000_000, 48_960),
        (580, 11_030_000_000, 49_440),
        (nil, 11_040_000_000, 49_920)
    ]
    for (sampleTime, hostTime, expectedFrame) in timestamps {
        let start = mapper.startFrame(sampleTime: sampleTime, hostTimeNanos: hostTime,
                                      sampleRate: 48_000, contiguousEndFrame: sink.lastEndFrame)
        #expect(start == expectedFrame)
        sink.silence(startFrame: start, frameCount: 480)
    }
    ring.finish(tailFrame: sink.lastEndFrame)
    #expect(sink.lastEndFrame == 50_400)
    #expect(ring.dropoutCount == 1)
    #expect(try #require(ring.pop()).startFrame == 0)
    #expect(try #require(ring.pop()).startFrame == 480)
    #expect(try #require(ring.pop()).startFrame == 48_960)
    #expect(try #require(ring.pop()).startFrame == 49_440)
    #expect(try #require(ring.pop()).startFrame == 49_920)
}

@Test("Stereo packed and planar callbacks downmix without changing frame timestamps")
func timestampedMonoConversionAndGapAccounting() throws {
    let ring = AudioBlockRing(capacity: 8, blockFrameCapacity: 8, sampleRate: 1_000)
    let clock = FixedClock()
    let sink = TimestampedMonoSink(ring: ring, frameCapacity: 8, clock: clock, meter: nil)
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
    let sink = TimestampedMonoSink(ring: ring, frameCapacity: 8, clock: FixedClock(), meter: nil)
    sink.missing(startFrame: 10, frameCount: 3)
    ring.finish(tailFrame: sink.lastEndFrame)
    #expect(sink.lastBufferMillis.load(ordering: .relaxed) == 0)
    #expect(sink.invalidBufferCount.load(ordering: .relaxed) == 1)
    #expect(try #require(ring.pop()).gap == AudioGap(startFrame: 10, frameCount: 3, reason: .invalidBuffer))
}

@Test("Explicit silent packets contain zeros and retain preceding timestamp gaps")
func timestampedSilentPacketAfterSignal() throws {
    let ring = AudioBlockRing(capacity: 8, blockFrameCapacity: 4, sampleRate: 1_000)
    let sink = TimestampedMonoSink(ring: ring, frameCapacity: 4, clock: FixedClock(), meter: nil)
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
    var sampleRate: Double = CanonicalAudio.sampleRate
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
    var refusesRelease = false
    func stop() throws {
        stops += 1
        if refusesRelease {
            throw SystemAudioTapError.releaseFailed(operations: ["タップの破棄 OSStatus -1"], after: nil)
        }
    }
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
private struct AuthorizedSystemAudioPermission: SystemAudioPermissionProviding {
    func preflight() async throws(SystemAudioPermissionError) -> SystemAudioPermissionStatus { .authorized }
    func request() async throws(SystemAudioPermissionError) -> Bool { true }
}
private struct NoExternalOutput: SystemAudioOutputProcessProviding {
    func runningExternalOutputPIDs() async -> Set<Int32>? { [] }
}

/// System-audio runs must never construct, bind, write or restore a microphone volume control.
@MainActor
private final class MicVolumeFactoryProbe {
    private(set) var calls = 0
    func make() -> any MicInputVolumeControlling {
        calls += 1
        return TrapMicVolume()
    }
}

@MainActor
private final class TrapMicVolume: MicInputVolumeControlling {
    func bind(captureDeviceUID: String,
              onChange: @escaping @MainActor @Sendable (MicInputVolumeChange) -> Void) throws(MicInputVolumeFailure)
        -> MicInputVolumeSnapshot {
        Issue.record("System audio bound a microphone volume control")
        throw .notBound
    }
    func snapshot() throws(MicInputVolumeFailure) -> MicInputVolumeSnapshot {
        Issue.record("System audio read a microphone volume control")
        throw .notBound
    }
    func setVolumes(_ values: [MicInputVolumeElement], expected: MicInputVolumeSnapshot)
        async throws(MicInputVolumeWriteFailure) -> MicInputVolumeSnapshot {
        Issue.record("System audio wrote a microphone volume control")
        throw MicInputVolumeWriteFailure(reason: .notBound, effective: [], unresolved: [])
    }
    func unbind() throws(MicInputVolumeFailure) {
        Issue.record("System audio unbound a microphone volume control")
    }
}

private func createTapSession(paths: AppPaths) throws -> UUID {
    let id = UUID()
    try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: id, source: .recording(.systemAudio),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    return id
}

@MainActor
@Test("A fake process tap records through durable mono chunks and pairs cleanup with power")
func fakeTapEngineLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let tap = FakeTap()
    let power = FakeCapturePower()
    let micVolumes = MicVolumeFactoryProbe()
    let engine = AudioCaptureEngine(paths: paths, bufferFrameCount: 8, ringCapacity: 8,
                                    chunkDurationSeconds: 0.004, power: power,
                                    diskSpace: AvailableDisk(), tapFactory: { tap },
                                    systemAudioPermission: AuthorizedSystemAudioPermission(),
                                    outputProcesses: NoExternalOutput(),
                                    micInputVolumeFactory: micVolumes.make)
    engine.configureMicInputVolume(automaticAdjustmentEnabled: true) { _, _ in
        Issue.record("System audio reported a microphone input status")
    }
    let session = try createTapSession(paths: paths)
    try await engine.start(sessionID: session, source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
    #expect(engine.isRecording && engine.activeSessionID == session)
    #expect(engine.timeline?.channelCount == 1)
    let result = try await engine.stop()
    #expect(micVolumes.calls == 0)
    #expect(result.checkpoint.committedFrames == 4)
    #expect(result.dropoutCount == 0 && result.gapCount == 0)
    #expect(result.sleepAssertionHeld)
    #expect(tap.starts == 1 && tap.stops == 1)
    #expect(power.acquisitions == 1 && power.releases == 1)
    #expect(!engine.isRecording)
}

@MainActor
@Test("A refused tap release is returned with the saved recording instead of a clean stop")
func fakeTapRefusedReleaseIsReported() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let tap = FakeTap()
    tap.refusesRelease = true
    let power = FakeCapturePower()
    let engine = AudioCaptureEngine(paths: paths, bufferFrameCount: 8, power: power,
                                    diskSpace: AvailableDisk(), tapFactory: { tap },
                                    systemAudioPermission: AuthorizedSystemAudioPermission(),
                                    outputProcesses: NoExternalOutput(),
                                    micInputVolumeFactory: MicVolumeFactoryProbe().make)
    let session = try createTapSession(paths: paths)
    try await engine.start(sessionID: session, source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
    let result = try await engine.stop()
    #expect(result.checkpoint.committedFrames == 4)
    #expect(result.writerFailure == nil)
    #expect(result.systemAudioReleaseFailure?.contains("タップの破棄 OSStatus -1") == true)
    #expect(power.releases == 1 && !engine.isRecording)
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
    let micVolumes = MicVolumeFactoryProbe()
    let engine = AudioCaptureEngine(paths: paths, bufferFrameCount: 8, power: power,
                                    diskSpace: AvailableDisk(), tapFactory: { tap },
                                    systemAudioPermission: AuthorizedSystemAudioPermission(),
                                    outputProcesses: NoExternalOutput(),
                                    micInputVolumeFactory: micVolumes.make)
    let session = try createTapSession(paths: paths)
    try await engine.start(sessionID: session, source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
    let result = try await engine.stop()
    #expect(micVolumes.calls == 0)
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
    let micVolumes = MicVolumeFactoryProbe()
    let engine = AudioCaptureEngine(paths: paths, bufferFrameCount: 8,
                                    power: FakeCapturePower(), diskSpace: AvailableDisk(),
                                    tapFactory: { tap },
                                    systemAudioPermission: AuthorizedSystemAudioPermission(),
                                    outputProcesses: NoExternalOutput(),
                                    micInputVolumeFactory: micVolumes.make)
    let sessionID = try createTapSession(paths: paths)
    try await engine.start(sessionID: sessionID, source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
    let result = try await engine.stop()
    #expect(micVolumes.calls == 0)
    #expect(result.checkpoint.committedFrames == 10)
    #expect(result.didOverflow && result.dropoutCount == 1)
    #expect(result.gapCount == 1 && result.totalGapFrames == 2)
    let sessionURL = try SessionDirectoryLocator(fileManager: .default).resolve(sessionsRoot: root, sessionID: sessionID)
    let directory = SessionLayout(sessionURL: sessionURL).processingDirectory
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
    let micVolumes = MicVolumeFactoryProbe()
    let engine = AudioCaptureEngine(paths: paths, power: power, diskSpace: AvailableDisk(),
                                    tapFactory: { tap },
                                    systemAudioPermission: AuthorizedSystemAudioPermission(),
                                    outputProcesses: NoExternalOutput(),
                                    micInputVolumeFactory: micVolumes.make)
    let session = try createTapSession(paths: paths)
    do {
        try await engine.start(sessionID: session, source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
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
    let micVolumes = MicVolumeFactoryProbe()
    let engine = AudioCaptureEngine(paths: paths, power: power, diskSpace: AvailableDisk(bytes: 0),
                                    tapFactory: { tap },
                                    systemAudioPermission: AuthorizedSystemAudioPermission(),
                                    outputProcesses: NoExternalOutput(),
                                    micInputVolumeFactory: micVolumes.make)
    do {
        try await engine.start(sessionID: UUID(), source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
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
    let micVolumes = MicVolumeFactoryProbe()
    let engine = AudioCaptureEngine(paths: paths, power: power, diskSpace: AvailableDisk(),
                                    tapFactory: { tap },
                                    systemAudioPermission: AuthorizedSystemAudioPermission(),
                                    outputProcesses: NoExternalOutput(),
                                    micInputVolumeFactory: micVolumes.make)
    do {
        try await engine.start(sessionID: UUID(), source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
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
    let micVolumes = MicVolumeFactoryProbe()
    let engine = AudioCaptureEngine(paths: paths, power: power, diskSpace: AvailableDisk(),
                                    tapFactory: { tap },
                                    systemAudioPermission: AuthorizedSystemAudioPermission(),
                                    outputProcesses: NoExternalOutput(),
                                    micInputVolumeFactory: micVolumes.make)
    tap.onStarted = { engine.cancelStarting() }
    let session = try createTapSession(paths: paths)
    do {
        try await engine.start(sessionID: session, source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
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
    let micVolumes = MicVolumeFactoryProbe()
    let engine = AudioCaptureEngine(paths: paths, power: power, diskSpace: AvailableDisk(),
                                    tapFactory: { tap },
                                    systemAudioPermission: AuthorizedSystemAudioPermission(),
                                    outputProcesses: NoExternalOutput(),
                                    micInputVolumeFactory: micVolumes.make)
    let session = try createTapSession(paths: paths)
    try await engine.start(sessionID: session, source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
    let sessionURL = try SessionDirectoryLocator(fileManager: .default).resolve(sessionsRoot: root, sessionID: session)
    let processing = SessionLayout(sessionURL: sessionURL).processingDirectory
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

@MainActor
@Test(arguments: [48_000.0, 44_100.0, 16_000.0])
func captureStartReservesStoredPCMNotDeviceRate(rate: Double) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    for bytes: Int64 in [601_600_000, 601_599_999] {
        let tap = FakeTap()
        tap.sampleRate = rate
        let engine = AudioCaptureEngine(paths: paths, power: FakeCapturePower(),
            diskSpace: AvailableDisk(bytes: bytes), tapFactory: { tap },
            systemAudioPermission: AuthorizedSystemAudioPermission(), outputProcesses: NoExternalOutput(),
            micInputVolumeFactory: MicVolumeFactoryProbe().make)
        let session = try createTapSession(paths: paths)
        do {
            try await engine.start(sessionID: session, source: .systemAudio, onFailure: { _ in }, onWarning: { _ in },
                onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
            #expect(bytes == 601_600_000)
            let result = try await engine.stop()
            #expect(result.checkpoint.sampleRate == CanonicalAudio.sampleRate)
            #expect(result.checkpoint.channelCount == CanonicalAudio.channelCount)
        } catch AudioCaptureEngineError.insufficientDiskSpace(let required) {
            #expect(bytes == 601_599_999)
            #expect(required == 601_600_000)
            #expect(tap.starts == 0)
        }
    }
}
