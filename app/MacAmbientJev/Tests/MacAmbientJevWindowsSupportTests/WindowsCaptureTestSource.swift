import Foundation
import Synchronization
import MacAmbientJevCore
import MacAmbientJevPipeline
import MacAmbientJevWindowsSupport

/// Test-only failures injected at a specific edge of the scripted capture lifetime.
enum ScriptedCaptureFailure: Error, LocalizedError, Equatable {
    case open
    case start
    case stop
    case powerAcquire
    case powerRelease
    case diskQuery
    case writerAppend
    case writerFinish

    var errorDescription: String? {
        switch self {
        case .open: "scripted capture open failure"
        case .start: "scripted capture start failure"
        case .stop: "scripted capture stop failure"
        case .powerAcquire: "scripted recording-power acquire failure"
        case .powerRelease: "scripted recording-power release failure"
        case .diskQuery: "scripted disk query failure"
        case .writerAppend: "scripted audio writer append failure"
        case .writerFinish: "scripted audio writer finish failure"
        }
    }
}

/// One callback fragment. The fixture contains the original interleaved packet; offsets and
/// packet-wide metadata deliberately remain explicit for fragment validation in the ingress.
enum ScriptedFileCaptureEvent {
    enum Delivery {
        case step
        case stopJoin
    }

    case packet(
        file: URL,
        frameCount: Int,
        devicePosition: UInt64,
        qpc100ns: UInt64,
        flags: UInt32,
        originalOffset: Int,
        originalFrames: Int,
        delivery: Delivery
    )
    case heartbeat(watermarkQPC100ns: UInt64, outputState: Int32, error: Int32)
    case failure(ScriptedCaptureFailure)
}

/// Atomic time source shared by the fake producer and production capture consumers.
final class ScriptedCaptureClock: CaptureClock, @unchecked Sendable {
    private let millis: Atomic<Int64>

    init(millis: Int64 = 1_000) {
        self.millis = Atomic(millis)
    }

    func now() -> TimeInterval {
        Double(millis.load(ordering: .acquiring)) / 1_000
    }

    func setMillis(_ value: Int64) {
        millis.store(value, ordering: .releasing)
    }
}

/// Shared observability for factory, power, disk, fake-device, and writer assertions.
final class ScriptedCaptureProbe: @unchecked Sendable {
    let openCalls = Atomic<Int>(0)
    let startCalls = Atomic<Int>(0)
    let stopJoinCalls = Atomic<Int>(0)
    let packetCallbacks = Atomic<Int>(0)
    let heartbeatCallbacks = Atomic<Int>(0)
    let powerAcquireCalls = Atomic<Int>(0)
    let powerReleaseCalls = Atomic<Int>(0)
    let diskQueries = Atomic<Int>(0)
    let writerAppendFailures = Atomic<Int>(0)
    private let orderCounter = Atomic<Int64>(0)
    private let writerFinishOrderValue = Atomic<Int64>(0)
    private let powerReleaseOrderValue = Atomic<Int64>(0)
    private let freeBytes: Atomic<Int64>
    private let checkpointAtPowerRelease: URL?
    let checkpointFramesAtPowerRelease = Atomic<Int64>(-1)

    let failDiskQuery: Bool
    let failPowerAcquire: Bool
    let failPowerRelease: Bool

    init(
        freeBytes: Int64 = CaptureDiskPolicy.requiredStartBytes,
        failDiskQuery: Bool = false,
        failPowerAcquire: Bool = false,
        failPowerRelease: Bool = false,
        checkpointAtPowerRelease: URL? = nil
    ) {
        self.freeBytes = Atomic(freeBytes)
        self.checkpointAtPowerRelease = checkpointAtPowerRelease
        self.failDiskQuery = failDiskQuery
        self.failPowerAcquire = failPowerAcquire
        self.failPowerRelease = failPowerRelease
    }

    var writerFinishOrder: Int64 { writerFinishOrderValue.load(ordering: .acquiring) }
    var powerReleaseOrder: Int64 { powerReleaseOrderValue.load(ordering: .acquiring) }

    func availableBytes() throws -> UInt64 {
        _ = diskQueries.add(1, ordering: .relaxed)
        if failDiskQuery { throw ScriptedCaptureFailure.diskQuery }
        return UInt64(freeBytes.load(ordering: .acquiring))
    }

    func acquirePower() throws {
        _ = powerAcquireCalls.add(1, ordering: .relaxed)
        if failPowerAcquire { throw ScriptedCaptureFailure.powerAcquire }
    }

    func releasePower() throws {
        _ = powerReleaseCalls.add(1, ordering: .relaxed)
        let order = orderCounter.add(1, ordering: .acquiringAndReleasing).newValue
        powerReleaseOrderValue.store(order, ordering: .releasing)
        if let checkpointAtPowerRelease,
           let data = try? Data(contentsOf: checkpointAtPowerRelease),
           let checkpoint = try? JSONDecoder().decode(AudioCheckpoint.self, from: data) {
            checkpointFramesAtPowerRelease.store(checkpoint.committedFrames, ordering: .releasing)
        }
        if failPowerRelease { throw ScriptedCaptureFailure.powerRelease }
    }

    func writerDidFinish() {
        let order = orderCounter.add(1, ordering: .acquiringAndReleasing).newValue
        writerFinishOrderValue.store(order, ordering: .releasing)
    }
}

/// Exactly one main-actor producer: start(), step(), and stopJoin() serialize all ingress calls.
@MainActor
final class ScriptedFileCaptureDevice: WindowsCaptureDevice {
    let sampleRate: Double
    let channels: Int
    private let events: [ScriptedFileCaptureEvent]
    private let probe: ScriptedCaptureProbe
    private var nextEvent = 0
    private var ingress: WindowsCaptureIngress?
    private var hasStarted = false
    private(set) var isFenced = false

    init(
        sampleRate: Double,
        channels: Int,
        events: [ScriptedFileCaptureEvent],
        probe: ScriptedCaptureProbe
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.events = events
        self.probe = probe
    }

    func start(ingress: WindowsCaptureIngress) throws {
        guard !hasStarted else { throw WindowsCaptureAdapterError.invalidConfiguration("fake device started twice") }
        hasStarted = true
        self.ingress = ingress
        _ = probe.startCalls.add(1, ordering: .relaxed)
        guard !events.isEmpty else {
            throw WindowsCaptureAdapterError.invalidConfiguration("script has no synchronous startup event")
        }
        let first = events[0]
        nextEvent = 1
        if case .failure(.start) = first { throw ScriptedCaptureFailure.start }
        if case .failure = first {
            throw WindowsCaptureAdapterError.invalidConfiguration("only start failure may be the startup event")
        }
        try emit(first)
    }

    /// Emits one remaining scripted event and yields so the real drain can consume the ring.
    func step() async throws {
        guard hasStarted, !isFenced, nextEvent < events.count else { return }
        let event = events[nextEvent]
        if case .packet(_, _, _, _, _, _, _, .stopJoin) = event {
            // Stop-only events are withheld until stopJoin() establishes the producer fence.
            await Task.yield()
            return
        }
        nextEvent += 1
        switch event {
        case .failure(let failure): throw failure
        default: try emit(event)
        }
        await Task.yield()
    }

    /// A stop-time fragment is delivered before returning. The fence is set even if the scripted
    /// native stop reports an error, matching the production protocol's required contract.
    func stopJoin() throws {
        guard !isFenced else { return }
        defer { isFenced = true }
        _ = probe.stopJoinCalls.add(1, ordering: .relaxed)
        var stopFailure: ScriptedCaptureFailure?
        if hasStarted {
            for event in events.dropFirst(nextEvent) {
                switch event {
                case .packet(_, _, _, _, _, _, _, .stopJoin):
                    try emit(event)
                case .failure(.stop):
                    stopFailure = .stop
                default:
                    break
                }
            }
        }
        if let stopFailure { throw stopFailure }
    }

    private func emit(_ event: ScriptedFileCaptureEvent) throws {
        guard !isFenced, let ingress else { return }
        switch event {
        case .packet(
            let file, let frameCount, let devicePosition, let qpc100ns, let flags,
            let originalOffset, let originalFrames, _
        ):
            guard (1...512).contains(frameCount), originalOffset >= 0,
                  originalFrames > 0, originalOffset <= originalFrames,
                  frameCount <= originalFrames - originalOffset else {
                throw WindowsCaptureAdapterError.invalidConfiguration("invalid scripted packet fragment")
            }
            let carriesSamples = flags & 0b1010 == 0
            let samples = carriesSamples ? try readFixtureFragment(
                from: file, frameCount: frameCount, offset: originalOffset, channels: channels
            ) : nil
            _ = probe.packetCallbacks.add(1, ordering: .relaxed)
            let packet = WindowsCapturePacket(
                samples: nil,
                frameCount: frameCount,
                channels: channels,
                sampleRate: sampleRate,
                flags: flags,
                devicePosition: devicePosition,
                qpc100ns: qpc100ns,
                packetOffset: originalOffset,
                packetFrames: originalFrames
            )
            guard let samples else {
                ingress.receive(packet)
                return
            }
            samples.withUnsafeBufferPointer { buffer in
                let borrowedPacket = WindowsCapturePacket(
                    samples: UnsafePointer(buffer.baseAddress!),
                    frameCount: frameCount,
                    channels: channels,
                    sampleRate: sampleRate,
                    flags: flags,
                    devicePosition: devicePosition,
                    qpc100ns: qpc100ns,
                    packetOffset: originalOffset,
                    packetFrames: originalFrames
                )
                ingress.receive(borrowedPacket)
            }
        case .heartbeat(let watermarkQPC100ns, let outputState, let error):
            _ = probe.heartbeatCallbacks.add(1, ordering: .relaxed)
            ingress.health(watermarkQPC100ns: watermarkQPC100ns, outputState: outputState, error: error)
        case .failure(let failure):
            throw failure
        }
    }
}

/// Test-only factory. Open failures happen before a device is returned; start failures happen
/// after the source owns a device and therefore exercise stopJoin cleanup.
@MainActor
final class ScriptedFileCaptureFactory: WindowsCaptureSourceFactory {
    let sampleRate: Double
    let channels: Int
    private let events: [ScriptedFileCaptureEvent]
    private let probe: ScriptedCaptureProbe
    private(set) var openedDevice: ScriptedFileCaptureDevice?

    init(
        sampleRate: Double,
        channels: Int,
        events: [ScriptedFileCaptureEvent],
        probe: ScriptedCaptureProbe
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.events = events
        self.probe = probe
    }

    func open(source: CaptureSource, device: WindowsCaptureDeviceSelection) throws -> any WindowsCaptureDevice {
        _ = probe.openCalls.add(1, ordering: .relaxed)
        if case .failure(.open)? = events.first { throw ScriptedCaptureFailure.open }
        let device = ScriptedFileCaptureDevice(
            sampleRate: sampleRate,
            channels: channels,
            events: events,
            probe: probe
        )
        openedDevice = device
        return device
    }

    func devices(source: CaptureSource) throws -> [WindowsCaptureEndpoint] { [] }
}

/// Writes interleaved Float32 samples as little-endian fixture bytes, outside production code.
func writeScriptedFloatFixture(_ samples: [Float], to url: URL) throws {
    var bytes = Data()
    bytes.reserveCapacity(samples.count * MemoryLayout<Float>.size)
    for sample in samples {
        let bits = sample.bitPattern
        bytes.append(UInt8(truncatingIfNeeded: bits))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 16))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 24))
    }
    try bytes.write(to: url, options: .atomic)
}

private func readFixtureFragment(from url: URL, frameCount: Int, offset: Int, channels: Int) throws -> [Float] {
    let (sampleOffset, offsetOverflow) = offset.multipliedReportingOverflow(by: channels)
    let (sampleCount, countOverflow) = frameCount.multipliedReportingOverflow(by: channels)
    let (byteOffset, byteOffsetOverflow) = sampleOffset.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
    let (byteCount, byteCountOverflow) = sampleCount.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
    guard !offsetOverflow, !countOverflow, !byteOffsetOverflow, !byteCountOverflow else {
        throw WindowsCaptureAdapterError.invalidConfiguration("scripted fixture range overflow")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(byteOffset))
    guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else {
        throw WindowsCaptureAdapterError.invalidConfiguration("scripted fixture is shorter than its packet range")
    }
    let bytes = [UInt8](data)
    var samples: [Float] = []
    samples.reserveCapacity(sampleCount)
    for index in stride(from: 0, to: bytes.count, by: 4) {
        let bits = UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
        samples.append(Float(bitPattern: bits))
    }
    return samples
}

func scriptedPacketFragments(
    file: URL,
    sourceFrames: Int,
    devicePosition: UInt64,
    qpc100ns: UInt64,
    flags: UInt32 = 0,
    maximumFragmentFrames: Int = 512
) -> [ScriptedFileCaptureEvent] {
    precondition(sourceFrames > 0 && sourceFrames <= 65_536)
    precondition((1...512).contains(maximumFragmentFrames))
    var events: [ScriptedFileCaptureEvent] = []
    var offset = 0
    while offset < sourceFrames {
        let count = min(maximumFragmentFrames, sourceFrames - offset)
        events.append(.packet(
            file: file,
            frameCount: count,
            devicePosition: devicePosition,
            qpc100ns: qpc100ns,
            flags: flags,
            originalOffset: offset,
            originalFrames: sourceFrames,
            delivery: .step
        ))
        offset += count
    }
    return events
}

func scriptedQPC(epoch: UInt64 = 10_000_000, frame: Int64, sampleRate: Double) -> UInt64 {
    precondition(frame >= 0 && sampleRate > 0)
    let elapsed = (Double(frame) * 10_000_000 / sampleRate).rounded()
    return epoch + UInt64(elapsed)
}

func makeWindowsCaptureTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "WindowsCaptureSource-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Creates real durable writer storage and wires production safety/power providers to probes.
@MainActor
func makeWindowsCaptureTestSource(
    root: URL,
    source: CaptureSource,
    sampleRate: Double,
    channels: Int,
    events: [ScriptedFileCaptureEvent],
    probe: ScriptedCaptureProbe,
    clock: ScriptedCaptureClock = ScriptedCaptureClock(),
    writer: (any AudioCaptureWriting)? = nil,
    durableWriter: DurableAudioWriter? = nil,
    chunkDurationSeconds: Double = 0.01
) throws -> (
    source: WindowsCaptureSource,
    factory: ScriptedFileCaptureFactory,
    clock: ScriptedCaptureClock,
    writer: DurableAudioWriter
) {
    let audioDirectory = root.appending(path: "audio", directoryHint: .isDirectory)
    let realWriter = try durableWriter ?? DurableAudioWriter(
        directory: audioDirectory,
        chunkDurationSeconds: chunkDurationSeconds,
        sessionURL: root
    )
    let diskSpace = WindowsCaptureDiskSpaceProvider(query: { _ in try probe.availableBytes() })
    let power = WindowsRecordingPowerProvider(
        acquire: { try probe.acquirePower() },
        release: { try probe.releasePower() }
    )
    let factory = ScriptedFileCaptureFactory(
        sampleRate: sampleRate,
        channels: channels,
        events: events,
        probe: probe
    )
    let source = WindowsCaptureSource(
        source: source,
        device: .systemDefault,
        directory: root,
        writer: writer ?? realWriter,
        factory: factory,
        diskSpace: diskSpace,
        power: power,
        clock: clock,
        qpc100ns: { 10_000_000 },
        onWarning: { _ in },
        onFailure: { _ in },
        onSilenceChanged: { _ in }
    )
    return (source, factory, clock, realWriter)
}

/// Repeatedly yields to main-actor cleanup and its production 20-ms drain cadence, always bounded.
@MainActor
func waitForWindowsCaptureTestCondition(
    attempts: Int = 50,
    _ condition: () -> Bool
) async {
    for _ in 0..<attempts {
        if condition() { return }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

func readFloat32LEFile(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count.isMultiple(of: 4) else {
        throw WindowsCaptureAdapterError.invalidConfiguration("durable float chunk is not Float32 aligned")
    }
    let bytes = [UInt8](data)
    return stride(from: 0, to: bytes.count, by: 4).map { index in
        let bits = UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
        return Float(bitPattern: bits)
    }
}

/// A failure-injection forwarding actor. Async appends reach the real writer; the synchronous
/// checkpoint APIs mirror its last committed snapshot, and finish deliberately fails after drain.
actor ScriptedFailingFinishAudioWriter: AudioCaptureWriting {
    private let base: DurableAudioWriter
    private let probe: ScriptedCaptureProbe
    private var appendFailuresRemaining: Int
    private var committed: AudioCheckpoint
    private var queuedGapWrites: [Task<Void, Error>] = []

    init(base: DurableAudioWriter, probe: ScriptedCaptureProbe, appendFailures: Int = 0) {
        self.base = base
        self.probe = probe
        appendFailuresRemaining = appendFailures
        committed = AudioCheckpoint(
            committedFrames: 0,
            sampleRate: CanonicalAudio.sampleRate,
            channelCount: CanonicalAudio.channelCount,
            sampleFormat: CanonicalAudio.sampleFormat,
            chunkFiles: [],
            chunkFrameCounts: [],
            gapEvents: []
        )
    }

    func append(samples: [Float]) async throws {
        try await finishQueuedGapWrites()
        if appendFailuresRemaining > 0 {
            appendFailuresRemaining -= 1
            _ = probe.writerAppendFailures.add(1, ordering: .relaxed)
            throw ScriptedCaptureFailure.writerAppend
        }
        try await base.append(samples: samples)
        committed = await base.committedSnapshot()
    }

    func recordGap(startFrame: Int64, frameCount: Int64, reason: AudioGapReason) throws {
        let base = base
        queuedGapWrites.append(Task {
            try await base.recordGap(startFrame: startFrame, frameCount: frameCount, reason: reason)
        })
    }

    func committedSnapshot() -> AudioCheckpoint { committed }

    func checkpoint() throws -> AudioCheckpoint { committed }

    func finish() throws -> AudioCheckpoint {
        probe.writerDidFinish()
        throw ScriptedCaptureFailure.writerFinish
    }

    private func finishQueuedGapWrites() async throws {
        for task in queuedGapWrites { try await task.value }
        queuedGapWrites.removeAll(keepingCapacity: true)
    }
}
