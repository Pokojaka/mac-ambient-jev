import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevCapture

private actor OutputSnapshots: SystemAudioOutputProcessProviding {
    private var snapshots: [Set<Int32>?]
    init(_ snapshots: [Set<Int32>?]) { self.snapshots = snapshots }
    func runningExternalOutputPIDs() async -> Set<Int32>? {
        guard !snapshots.isEmpty else { return nil }
        return snapshots.removeFirst()
    }
}

@MainActor
@Test("Zero-only capture warns once after grace and two seconds of continuous external output")
func sustainedExternalOutputWarns() async {
    let monitor = SystemAudioOutputMonitor(provider: OutputSnapshots([[42], [42], [42], [42]]),
                                           captureStartMillis: 10_000)
    #expect(!(await monitor.poll(nowMillis: 11_000, everNonZero: false)))
    #expect(!(await monitor.poll(nowMillis: 12_000, everNonZero: false)))
    #expect(await monitor.poll(nowMillis: 13_000, everNonZero: false))
    #expect(!(await monitor.poll(nowMillis: 14_000, everNonZero: false)))
}

@MainActor
@Test("Own PID and nested descendants are excluded, while unrelated output remains external")
func ownProcessTreeIsNotExternalOutput() async {
    let parents: [Int32: Int32] = [101: 100, 102: 101, 103: 1]
    let parent: (Int32) -> Int32? = { parents[$0] }
    #expect(CoreAudioOutputProcesses.isDescendantOrSelf(100, of: 100, parent: parent) == true)
    #expect(CoreAudioOutputProcesses.isDescendantOrSelf(102, of: 100, parent: parent) == true)
    #expect(CoreAudioOutputProcesses.isDescendantOrSelf(103, of: 100, parent: parent) == false)
    #expect(CoreAudioOutputProcesses.isDescendantOrSelf(104, of: 100, parent: parent) == nil)
    let tree = Set([100, 101, 102]).filter {
        CoreAudioOutputProcesses.isDescendantOrSelf($0, of: 100, parent: parent) == false
    }
    let monitor = SystemAudioOutputMonitor(provider: OutputSnapshots([tree, tree, tree, tree]),
                                           captureStartMillis: 0)
    #expect(!(await monitor.poll(nowMillis: 1_000, everNonZero: false)))
    #expect(!(await monitor.poll(nowMillis: 2_000, everNonZero: false)))
    #expect(!(await monitor.poll(nowMillis: 3_000, everNonZero: false)))
}

@MainActor
@Test("Three-second grace applies even when other output has run for two seconds")
func silentTapGracePeriod() async {
    let monitor = SystemAudioOutputMonitor(provider: OutputSnapshots([[42], [42], [42]]),
                                           captureStartMillis: 0)
    #expect(!(await monitor.poll(nowMillis: 0, everNonZero: false)))
    #expect(!(await monitor.poll(nowMillis: 1_000, everNonZero: false)))
    #expect(!(await monitor.poll(nowMillis: 2_999, everNonZero: false)))
}

@MainActor
@Test("Interrupted or short output does not satisfy continuous two-second condition")
func briefExternalOutputDoesNotWarn() async {
    let monitor = SystemAudioOutputMonitor(
        provider: OutputSnapshots([[42], [42], [], [42], nil, [42], [42]]),
        captureStartMillis: 0
    )
    for time in [Int64(3_000), 4_000, 5_000, 6_000, 7_000, 8_000, 9_000] {
        #expect(!(await monitor.poll(nowMillis: time, everNonZero: false)))
    }
}

@MainActor
@Test("Any exact nonzero sample permanently disables the silenced-tap warning")
func nonZeroInputDisablesSilentTapWarning() async {
    let sink = TimestampedMonoSink(ring: AudioBlockRing(capacity: 4, blockFrameCapacity: 4),
                                   frameCapacity: 4, clock: SystemCaptureClock(), meter: nil)
    sink.silence(startFrame: 0, frameCount: 4)
    let initiallyNonZero = sink.everNonZero.load(ordering: .acquiring)
    #expect(!initiallyNonZero)
    var samples: [Float] = [0, 0.00000001, 0, 0]
    samples.withUnsafeMutableBufferPointer { buffer in
        var channel = UnsafePointer(buffer.baseAddress!)
        var stride = 1
        withUnsafePointer(to: &channel) { channels in
            withUnsafePointer(to: &stride) { strides in
                sink.receive(channels: channels, strides: strides, channelCount: 1,
                             frameCount: 4, startFrame: 4)
            }
        }
    }
    let receivedNonZero = sink.everNonZero.load(ordering: .acquiring)
    #expect(receivedNonZero)
    let monitor = SystemAudioOutputMonitor(provider: OutputSnapshots([[42], [42], [42], [42]]),
                                           captureStartMillis: 0)
    #expect(!(await monitor.poll(nowMillis: 3_000, everNonZero: false)))
    #expect(!(await monitor.poll(nowMillis: 4_000, everNonZero: sink.everNonZero.load(ordering: .acquiring))))
    #expect(!(await monitor.poll(nowMillis: 5_000, everNonZero: false)))
}
