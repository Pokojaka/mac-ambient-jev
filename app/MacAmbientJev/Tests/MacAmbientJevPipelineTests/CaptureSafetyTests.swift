import Foundation
import Synchronization
import Testing
import MacAmbientJevCore
import MacAmbientJevPipeline

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

@Test("90-minute canonical PCM reservation accepts equality and rejects one byte less")
func canonicalDiskRequirement() {
    let required = CaptureDiskPolicy.requiredStartBytes
    #expect(required == 601_600_000)
    #expect(!CaptureDiskPolicy.mayStart(availableBytes: required - 1))
    #expect(CaptureDiskPolicy.mayStart(availableBytes: required))
    #expect(!CaptureDiskPolicy.mustStop(
        availableBytes: CaptureDiskPolicy.stopFloorBytes))
    #expect(CaptureDiskPolicy.mustStop(
        availableBytes: CaptureDiskPolicy.stopFloorBytes - 1))
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

private struct UnavailableDiskSpace: CaptureDiskSpaceProviding {
    struct QueryError: Error {}
    func availableBytes(at url: URL) throws -> Int64? { throw QueryError() }
}

private struct MeasuredDiskSpace: CaptureDiskSpaceProviding {
    let bytes: Int64?
    func availableBytes(at url: URL) throws -> Int64? { bytes }
}

@Test("disk capacity query errors reject recording startup")
func diskCapacityQueryFailureRejectsStart() {
    #expect {
        try CaptureDiskPolicy.checkStart(diskSpace: UnavailableDiskSpace(), directory: FileManager.default.temporaryDirectory)
    } throws: { error in
        guard case AudioCaptureEngineError.diskSpaceUnavailable = error else { return false }
        return true
    }
}

@Test("unknown or insufficient capacity rejects startup; measured sufficient capacity starts")
func diskCapacityCheckPreservesMeasuredThreshold() throws {
    let required = CaptureDiskPolicy.requiredStartBytes
    let directory = FileManager.default.temporaryDirectory
    #expect {
        try CaptureDiskPolicy.checkStart(diskSpace: MeasuredDiskSpace(bytes: nil), directory: directory)
    } throws: { error in
        guard case AudioCaptureEngineError.diskSpaceUnavailable = error else { return false }
        return true
    }
    try CaptureDiskPolicy.checkStart(diskSpace: MeasuredDiskSpace(bytes: required), directory: directory)
    do {
        try CaptureDiskPolicy.checkStart(diskSpace: MeasuredDiskSpace(bytes: required - 1), directory: directory)
        Issue.record("Measured low capacity must reject recording startup")
    } catch AudioCaptureEngineError.insufficientDiskSpace(let requested) {
        #expect(requested == required)
    }
}
