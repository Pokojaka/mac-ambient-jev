import Foundation
import Synchronization
import MacAmbientJevPipeline

/// A borrowed native audio packet. `samples` is valid only for the synchronous
/// duration of `WindowsCaptureIngress.receive(_:)` and must address this fragment's
/// first sample in packed interleaved Float32 layout.
public struct WindowsCapturePacket {
    public let samples: UnsafePointer<Float>?
    public let frameCount: Int
    public let channels: Int
    public let sampleRate: Double
    public let flags: UInt32
    public let devicePosition: UInt64
    public let qpc100ns: UInt64
    public let packetOffset: Int
    public let packetFrames: Int

    public init(
        samples: UnsafePointer<Float>?, frameCount: Int, channels: Int, sampleRate: Double,
        flags: UInt32, devicePosition: UInt64, qpc100ns: UInt64,
        packetOffset: Int, packetFrames: Int
    ) {
        self.samples = samples
        self.frameCount = frameCount
        self.channels = channels
        self.sampleRate = sampleRate
        self.flags = flags
        self.devicePosition = devicePosition
        self.qpc100ns = qpc100ns
        self.packetOffset = packetOffset
        self.packetFrames = packetFrames
    }
}

public enum WindowsCaptureIngressFailure: Int32, Sendable, Equatable {
    case none = 0
    case invalidPacket = 1
    case timestamp = 2
    case unknownOutput = 3
    case workerStall = 4
    case activeOutputStall = 5
    case suspended = 6
    case native = 7
}

/// Fixed callback-path diagnostics. Names are formatted only on the control lane.
public enum WindowsCaptureTimestampCheck: Int32, Sendable, Equatable {
    case unspecified = 0
    case nativeTimestampError
    case fragmentStart
    case packetEnd
    case pcmOverlap
    case completedPacketEnd
    case activeIntervalState
    case reconnectWatermark
    case activeTailWatermark
    case activeTailCount
    case reconnectIdleExtent
    case packetQPC
    case qpcRegression
    case deviceReset
    case qpcDelta
    case clockMismatch
    case anchorDevicePosition
    case anchorDelta
    case mappedFrame
    case anchorFrame
    case idleGapOrder
    case idleGapExtent
    case idleGapCount
    case idleAnchorOverlap
    case startupExtent
    case missingGapExtent
}

/// Fixed-size timestamp evidence published with the first producer failure.
/// A delta is nil when no preceding packet or representable QPC frame exists.
/// Health failures carry no packet evidence and are identified separately.
public struct WindowsCaptureTimestampDetails: Sendable, Equatable {
    public let qpcDeltaFrames: Int64?
    public let deviceDeltaFrames: Int64?
    public let packetFlags: UInt32
    public let idleObserved: Bool
    public let fromHealth: Bool
}

/// Allocation-free producer evidence. Frame coordinates and deltas use the device rate.
public enum WindowsCaptureGapCheck: Int32, Sendable, Equatable {
    case qpcForward
    case deviceReset
    case knownMissing
    case activeTail
    case packetTimeline
    case reconnectIdle
}

public struct WindowsCaptureGapDetails: Sendable, Equatable {
    public let check: WindowsCaptureGapCheck
    public let startFrame: Int64
    public let endFrame: Int64
    public let qpcDeltaFrames: Int64?
    public let deviceDeltaFrames: Int64?
    public let packetFlags: UInt32
    public let idleObserved: Bool
    public let fromHealth: Bool
}

/// Synchronous, single-producer bridge from native Windows packet coordinates to the
/// platform-free timestamped mono sink. It does not retain a packet's borrowed sample pointer.
public final class WindowsCaptureIngress: @unchecked Sendable {
    private static let discontinuityFlag: UInt32 = 1
    private static let silentFlag: UInt32 = 2
    private static let timestampErrorFlag: UInt32 = 4
    private static let knownMissingFlag: UInt32 = 8
    private static let maximumCallbackFrames = 512
    private static let maximumPacketFrames = 65_536
    private static let qpcUnitsPerSecond = 10_000_000.0
    private static let healthInterval: TimeInterval = CaptureHealth.stallInterval
    /// The 250 ms grace bounds normal delivery delay and observation lag for health fills;
    /// it does not guarantee late packets cannot arrive after a fill. An idle reanchor may
    /// move forward by at most this grace to preserve every PCM frame after synthesized silence.
    private static let deliveryGraceSeconds = 0.25

    private enum PacketGap {
        case none
        case silence
        case missing(WindowsCaptureGapCheck)
    }

    private struct PacketStartMapping {
        let frame: Int64
        let gap: PacketGap
    }

    public let sink: TimestampedMonoSink
    public let sampleRate: Double
    public let channels: Int

    private let epochQPC100ns: UInt64
    private let clock: any CaptureClock
    private let loopback: Bool
    private let isInitialCapture: Bool
    private let deliveryGraceFrames: Int64
    private let channelPointers: UnsafeMutablePointer<UnsafePointer<Float>>
    private let strides: UnsafeMutablePointer<Int>
    private var channelPointersInitialized = false

    private let failureCode = Atomic<Int32>(WindowsCaptureIngressFailure.none.rawValue)
    private let timestampCheckCode = Atomic<Int32>(WindowsCaptureTimestampCheck.unspecified.rawValue)
    // Int64.min cannot be a delta between validated nonnegative frame coordinates.
    private let timestampQPCDelta = Atomic<Int64>(Int64.min)
    private let timestampDeviceDelta = Atomic<Int64>(Int64.min)
    private let timestampPacketFlags = Atomic<UInt32>(0)
    private let timestampIdleObserved = Atomic(false)
    private let timestampFromHealth = Atomic(false)
    private let nativeError = Atomic<Int32>(0)
    private let heartbeatMillis = Atomic<Int64>(0)
    private let heartbeatSeen = Atomic(false)
    private let firstBufferQPCBits = Atomic<UInt64>(UInt64.max)
    private let firstBufferTimeBits = Atomic<UInt64>(UInt64.max)
    // Bounded SPSC evidence queue: producer publishes a complete fixed-size snapshot,
    // control lane acquires it before formatting. Never overwrite unread evidence.
    private static let gapDiagnosticCapacity = 64
    private let gapDiagnostics: UnsafeMutablePointer<WindowsCaptureGapDetails?>
    private let gapDiagnosticWrite = Atomic<UInt64>(0)
    private let gapDiagnosticRead = Atomic<UInt64>(0)
    private let droppedGapDiagnosticCount = Atomic<UInt64>(0)

    // All fields below are owned by the serialized receive/health producer.
    private let startedAt: TimeInterval
    private var lastHealthTime: TimeInterval?
    private var anchorDevicePosition: UInt64?
    private var anchorFrame: Int64?
    private var previousDevicePosition: UInt64?
    private var previousDeviceEnd: UInt64?
    private var previousQPC100ns: UInt64?
    private var previousQPCFrame: Int64?
    // Positive mapped-start lead over that packet's raw QPC, not a high-water mark.
    // Includes health-anchor shifts and device-clock drift; a reanchor consumes it.
    private var timelineLeadFrames: Int64 = 0
    private var currentPacketPosition: UInt64 = 0
    private var currentPacketQPC: UInt64 = 0
    private var currentPacketFrames = 0
    private var currentPacketFlags: UInt32 = 0
    private var currentPacketStartFrame: Int64 = 0
    private var expectedPacketOffset = 0
    private var packetInProgress = false
    private var producerActivity = false
    private var reconnectStartFrame: Int64?
    private var activeOutput = false
    private var activeIntervalHadPacket = false
    private var activeWithoutPacketsSince: TimeInterval?
    private var packetSinceHealth = false
    // Session activity may become active before the resumed stream's first packet.
    // Only completing a packet consumes the idle evidence, not an active health tick.
    private var idleObservedSincePacket = false
    private var packetQPCDeltaFrames: Int64?
    private var packetDeviceDeltaFrames: Int64?
    private var packetDiagnosticFlags: UInt32 = 0
    // Only health-generated idle silence permits a bounded forward anchor adjustment.
    // Packets and missing extents invalidate this evidence, even if their samples are zero.
    private var trailingIdleSilenceStartFrame: Int64?

    public init(
        sink: TimestampedMonoSink, sampleRate: Double, channels: Int,
        epochQPC100ns: UInt64, clock: any CaptureClock, loopback: Bool,
        isInitialCapture: Bool
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              sampleRate.rounded(.towardZero) == sampleRate,
              sampleRate <= Double(UInt32.max) else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Capture sample rate must be a positive integral UInt32 value"
            )
        }
        guard (1...254).contains(channels) else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Capture channel count must be between 1 and 254"
            )
        }
        guard epochQPC100ns > 0 else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Capture QPC epoch must be positive"
            )
        }

        self.sink = sink
        self.sampleRate = sampleRate
        self.channels = channels
        self.epochQPC100ns = epochQPC100ns
        self.clock = clock
        self.loopback = loopback
        self.isInitialCapture = isInitialCapture
        deliveryGraceFrames = Int64((sampleRate * Self.deliveryGraceSeconds).rounded(.up))
        startedAt = clock.now()
        gapDiagnostics = .allocate(capacity: Self.gapDiagnosticCapacity)
        gapDiagnostics.initialize(repeating: nil, count: Self.gapDiagnosticCapacity)
        channelPointers = .allocate(capacity: channels)
        strides = .allocate(capacity: channels)
        strides.initialize(repeating: channels, count: channels)
    }

    deinit {
        gapDiagnostics.deinitialize(count: Self.gapDiagnosticCapacity)
        gapDiagnostics.deallocate()
        if channelPointersInitialized {
            channelPointers.deinitialize(count: channels)
        }
        channelPointers.deallocate()
        strides.deinitialize(count: channels)
        strides.deallocate()
    }

    public var failure: WindowsCaptureIngressFailure? {
        let raw = failureCode.load(ordering: .acquiring)
        guard raw != WindowsCaptureIngressFailure.none.rawValue else { return nil }
        return WindowsCaptureIngressFailure(rawValue: raw)
    }

    public var timestampCheck: WindowsCaptureTimestampCheck {
        WindowsCaptureTimestampCheck(rawValue: timestampCheckCode.load(ordering: .acquiring))!
    }

    /// Read on the control lane after acquiring a timestamp failure.
    public var timestampDetails: WindowsCaptureTimestampDetails {
        let qpcDelta = timestampQPCDelta.load(ordering: .acquiring)
        let deviceDelta = timestampDeviceDelta.load(ordering: .acquiring)
        return WindowsCaptureTimestampDetails(
            qpcDeltaFrames: qpcDelta == Int64.min ? nil : qpcDelta,
            deviceDeltaFrames: deviceDelta == Int64.min ? nil : deviceDelta,
            packetFlags: timestampPacketFlags.load(ordering: .acquiring),
            idleObserved: timestampIdleObserved.load(ordering: .acquiring),
            fromHealth: timestampFromHealth.load(ordering: .acquiring)
        )
    }

    /// Single control-lane consumer only; also drain after fencing the native producer.
    public func takeGapDiagnostics() -> [WindowsCaptureGapDetails] {
        var result: [WindowsCaptureGapDetails] = []
        var read = gapDiagnosticRead.load(ordering: .relaxed)
        let write = gapDiagnosticWrite.load(ordering: .acquiring)
        while read < write {
            let slot = Int(read % UInt64(Self.gapDiagnosticCapacity))
            result.append(gapDiagnostics[slot]!)
            gapDiagnostics[slot] = nil
            read &+= 1
        }
        gapDiagnosticRead.store(read, ordering: .releasing)
        return result
    }

    /// Control-lane consumer only; atomically takes the producer's dropped snapshot count.
    public func takeDroppedGapDiagnosticCount() -> UInt64 {
        droppedGapDiagnosticCount.exchange(0, ordering: .acquiringAndReleasing)
    }

    private func recordGap(
        _ check: WindowsCaptureGapCheck, startFrame: Int64, endFrame: Int64,
        fromHealth: Bool = false
    ) {
        guard endFrame > startFrame else { return }
        let write = gapDiagnosticWrite.load(ordering: .relaxed)
        let read = gapDiagnosticRead.load(ordering: .acquiring)
        guard write &- read < UInt64(Self.gapDiagnosticCapacity) else {
            _ = droppedGapDiagnosticCount.add(1, ordering: .relaxed)
            return
        }
        gapDiagnostics[Int(write % UInt64(Self.gapDiagnosticCapacity))] = WindowsCaptureGapDetails(
            check: check, startFrame: startFrame, endFrame: endFrame,
            qpcDeltaFrames: fromHealth ? nil : packetQPCDeltaFrames,
            deviceDeltaFrames: fromHealth ? nil : packetDeviceDeltaFrames,
            packetFlags: fromHealth ? 0 : packetDiagnosticFlags,
            idleObserved: idleObservedSincePacket, fromHealth: fromHealth
        )
        gapDiagnosticWrite.store(write &+ 1, ordering: .releasing)
    }

    public var lastHeartbeatMillis: Int64 {
        heartbeatMillis.load(ordering: .acquiring)
    }

    public var nativeErrorCode: Int32 {
        nativeError.load(ordering: .acquiring)
    }

    public var isReady: Bool {
        sink.lastBufferMillis.load(ordering: .acquiring) != 0
    }

    public var firstBufferQPC100ns: UInt64? {
        let qpc = firstBufferQPCBits.load(ordering: .acquiring)
        guard qpc != UInt64.max else { return nil }
        return qpc
    }

    public var firstBufferTime: TimeInterval? {
        let bits = firstBufferTimeBits.load(ordering: .acquiring)
        guard bits != UInt64.max else { return nil }
        return Double(bitPattern: bits)
    }

    /// Configures the initial timeline position for a reopened loopback ingress.
    /// Call only on the control lane, before the capture producer starts.
    public func prepareReconnect(startQPC100ns: UInt64) throws {
        guard loopback else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Reconnect timeline preparation requires loopback capture"
            )
        }
        guard reconnectStartFrame == nil else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Reconnect timeline has already been prepared"
            )
        }
        guard !producerActivity, !packetInProgress,
              previousDevicePosition == nil,
              sink.lastEndFrame == 0,
              sink.lastBufferMillis.load(ordering: .acquiring) == 0,
              sink.invalidBufferCount.load(ordering: .acquiring) == 0,
              failure == nil else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Reconnect timeline must be prepared before ingress activity"
            )
        }
        guard startQPC100ns >= epochQPC100ns else {
            throw WindowsCaptureAdapterError.timestamp(
                "Reconnect start QPC precedes the capture epoch"
            )
        }
        guard let frame = frameForQPC(startQPC100ns), Int(exactly: frame) != nil else {
            throw WindowsCaptureAdapterError.timestamp(
                "Reconnect start QPC does not map to a representable frame"
            )
        }
        reconnectStartFrame = frame
    }

    /// Latches only the first failure. Safe for a consumer to call while the producer runs.
    public func fail(_ failure: WindowsCaptureIngressFailure) {
        guard failure != .none else { return }
        _ = failureCode.compareExchange(
            expected: WindowsCaptureIngressFailure.none.rawValue,
            desired: failure.rawValue,
            ordering: .acquiringAndReleasing
        )
    }

    private func failTimestamp(_ check: WindowsCaptureTimestampCheck, fromHealth: Bool = false) {
        guard failure == nil else { return }
        // Only the serialized producer writes these details. Publish before the failure so
        // an acquiring control-lane read of `.timestamp` sees one matching snapshot.
        timestampQPCDelta.store(
            fromHealth ? Int64.min : (packetQPCDeltaFrames ?? Int64.min), ordering: .releasing
        )
        timestampDeviceDelta.store(
            fromHealth ? Int64.min : (packetDeviceDeltaFrames ?? Int64.min), ordering: .releasing
        )
        timestampPacketFlags.store(fromHealth ? 0 : packetDiagnosticFlags, ordering: .releasing)
        timestampIdleObserved.store(idleObservedSincePacket, ordering: .releasing)
        timestampFromHealth.store(fromHealth, ordering: .releasing)
        timestampCheckCode.store(check.rawValue, ordering: .releasing)
        fail(.timestamp)
    }

    /// Consumes one native fragment synchronously. No callback-path error strings or arrays
    /// are created; all failures are represented by the fixed failure code.
    public func receive(_ packet: WindowsCapturePacket) {
        producerActivity = true
        guard failure == nil else { return }
        packetDiagnosticFlags = packet.flags
        if let previousQPCFrame, let frame = frameForQPC(packet.qpc100ns) {
            packetQPCDeltaFrames = frame - previousQPCFrame
        } else {
            packetQPCDeltaFrames = nil
        }
        if let previousDevicePosition, let position = Int64(exactly: packet.devicePosition) {
            packetDeviceDeltaFrames = position - Int64(previousDevicePosition)
        } else {
            packetDeviceDeltaFrames = nil
        }
        guard packet.flags <= 15 else {
            fail(.invalidPacket)
            return
        }
        if packet.flags & Self.timestampErrorFlag != 0 {
            failTimestamp(.nativeTimestampError)
            return
        }
        guard packet.frameCount > 0, packet.frameCount <= Self.maximumCallbackFrames,
              packet.channels == channels, packet.sampleRate == sampleRate,
              packet.packetFrames >= 1, packet.packetFrames <= Self.maximumPacketFrames,
              packet.packetOffset >= 0,
              packet.packetOffset <= packet.packetFrames,
              packet.frameCount <= packet.packetFrames - packet.packetOffset,
              packet.devicePosition <= UInt64(Int64.max), packet.qpc100ns > 0,
              packet.packetOffset.addingReportingOverflow(packet.frameCount).overflow == false,
              packet.devicePosition.addingReportingOverflow(UInt64(packet.packetFrames)).overflow == false else {
            fail(.invalidPacket)
            return
        }
        if packet.flags & Self.silentFlag != 0,
           packet.flags & Self.knownMissingFlag != 0 {
            fail(.invalidPacket)
            return
        }

        let isNewPacket = packet.packetOffset == 0
        let packetStart: Int64
        let gap: PacketGap
        if isNewPacket {
            guard !packetInProgress else {
                fail(.invalidPacket)
                return
            }
            guard let mapped = mapPacketStart(packet) else { return }
            packetStart = mapped.frame
            gap = mapped.gap
        } else {
            gap = .none
            guard packetInProgress,
                  packet.devicePosition == currentPacketPosition,
                  packet.qpc100ns == currentPacketQPC,
                  packet.packetFrames == currentPacketFrames,
                  packet.flags == currentPacketFlags,
                  packet.packetOffset == expectedPacketOffset else {
                fail(.invalidPacket)
                return
            }
            let (mapped, overflow) = currentPacketStartFrame.addingReportingOverflow(
                Int64(packet.packetOffset)
            )
            guard !overflow, mapped >= 0 else {
                failTimestamp(.fragmentStart)
                return
            }
            packetStart = mapped
        }

        let (wholePacketEnd, wholePacketOverflow) = packetStart.addingReportingOverflow(
            Int64(packet.packetFrames)
        )
        guard !wholePacketOverflow, wholePacketEnd >= 0, wholePacketEnd < Int64.max else {
            failTimestamp(.packetEnd)
            return
        }

        let isSilent = packet.flags & Self.silentFlag != 0
        let isKnownMissing = packet.flags & Self.knownMissingFlag != 0
        if !isSilent && !isKnownMissing {
            guard let samples = packet.samples else {
                fail(.invalidPacket)
                return
            }
            let (sampleCount, overflow) = packet.frameCount.multipliedReportingOverflow(by: channels)
            guard !overflow else {
                fail(.invalidPacket)
                return
            }
            for index in 0..<sampleCount where !samples[index].isFinite {
                fail(.invalidPacket)
                return
            }
        }

        if isInitialCapture, reconnectStartFrame == nil, !isKnownMissing,
           isNewPacket, previousDevicePosition == nil,
           sink.lastEndFrame == 0, packetStart > 0 {
            let now = clock.now()
            guard now.isFinite, now >= startedAt,
                  now - startedAt < CaptureHealth.firstBufferDeadline else {
                fail(.workerStall)
                return
            }
            guard Double(packetStart) < sampleRate * CaptureHealth.firstBufferDeadline,
                  let count = Int(exactly: packetStart) else {
                failTimestamp(.startupExtent)
                return
            }
            // The epoch precedes native start. This is startup latency, not lost audio.
            // Reconnect segments retain this span as missingCallback instead.
            sink.silence(startFrame: 0, frameCount: count)
        }
        switch gap {
        case .none:
            // This path can also carry an ordinary device-timeline hole (including
            // reconnect/startup); ring reconstruction counts it as missingCallback.
            if packetStart - sink.lastEndFrame > 1 {
                recordGap(.packetTimeline, startFrame: sink.lastEndFrame, endFrame: packetStart)
            }
        case .silence:
            if !fillIdleReanchorGap(upTo: packetStart) { return }
        case .missing(let check):
            let endFrame = sink.lastEndFrame
            guard packetStart >= endFrame,
                  let count = Int(exactly: packetStart - endFrame) else {
                failTimestamp(.missingGapExtent)
                return
            }
            recordGap(check, startFrame: endFrame, endFrame: packetStart)
            trailingIdleSilenceStartFrame = nil
            sink.missing(startFrame: endFrame, frameCount: count)
        }
        if !isSilent && !isKnownMissing, packetStart < sink.lastEndFrame {
            failTimestamp(.pcmOverlap)
            return
        }

        reconnectStartFrame = nil
        trailingIdleSilenceStartFrame = nil
        if isNewPacket {
            currentPacketPosition = packet.devicePosition
            currentPacketQPC = packet.qpc100ns
            currentPacketFrames = packet.packetFrames
            currentPacketFlags = packet.flags
            currentPacketStartFrame = packetStart
            expectedPacketOffset = 0
            packetInProgress = true
        }

        if isSilent {
            sink.silence(startFrame: packetStart, frameCount: packet.frameCount)
        } else if isKnownMissing {
            let endFrame = packetStart + Int64(packet.frameCount)
            recordGap(
                .knownMissing, startFrame: max(packetStart, sink.lastEndFrame), endFrame: endFrame
            )
            sink.missing(startFrame: packetStart, frameCount: packet.frameCount)
        } else {
            let samples = packet.samples!
            for channel in 0..<channels {
                let channelPointer = samples.advanced(by: channel)
                if channelPointersInitialized {
                    channelPointers[channel] = channelPointer
                } else {
                    channelPointers.advanced(by: channel).initialize(to: channelPointer)
                }
            }
            channelPointersInitialized = true
            sink.receive(
                channels: UnsafePointer(channelPointers), strides: UnsafePointer(strides),
                channelCount: channels, frameCount: packet.frameCount, startFrame: packetStart
            )
        }

        expectedPacketOffset += packet.frameCount
        if expectedPacketOffset == packet.packetFrames {
            let (deviceEnd, deviceEndOverflow) = packet.devicePosition.addingReportingOverflow(
                UInt64(packet.packetFrames)
            )
            guard !deviceEndOverflow, let qpcFrame = frameForQPC(packet.qpc100ns) else {
                failTimestamp(.completedPacketEnd)
                return
            }
            previousDevicePosition = packet.devicePosition
            previousDeviceEnd = deviceEnd
            previousQPC100ns = packet.qpc100ns
            previousQPCFrame = qpcFrame
            idleObservedSincePacket = false
            packetInProgress = false
            if !isKnownMissing {
                packetSinceHealth = true
            }
        }
        recordReadiness(qpc100ns: packet.qpc100ns)
    }

    /// Drains output health on the producer thread after native packet delivery.
    public func health(watermarkQPC100ns: UInt64, outputState: Int32, error: Int32) {
        producerActivity = true
        guard failure == nil else { return }
        guard error == 0 else {
            nativeError.store(error, ordering: .releasing)
            fail(.native)
            return
        }
        guard outputState == 0 || outputState == 1 else {
            fail(.unknownOutput)
            return
        }
        guard !packetInProgress else {
            fail(.invalidPacket)
            return
        }

        let now = clock.now()
        guard now.isFinite, now >= startedAt,
              let nowMillis = Self.milliseconds(now) else {
            fail(.suspended)
            return
        }
        if let lastHealthTime {
            let elapsed = now - lastHealthTime
            guard elapsed >= 0, elapsed < Self.healthInterval else {
                fail(.suspended)
                return
            }
        }
        lastHealthTime = now
        heartbeatMillis.store(nowMillis, ordering: .releasing)
        heartbeatSeen.store(true, ordering: .releasing)
        let hadPacket = packetSinceHealth
        packetSinceHealth = false
        guard loopback else { return }
        if outputState == 0 { idleObservedSincePacket = true }

        if outputState == 1 {
            // Activity can precede delivery of a resumed stream. It starts a fresh stall
            // interval but neither consumes prior idle evidence nor writes over its silence.
            if !activeOutput {
                activeOutput = true
                activeIntervalHadPacket = hadPacket
                activeWithoutPacketsSince = now
            } else if hadPacket {
                activeIntervalHadPacket = true
                activeWithoutPacketsSince = now
            } else if activeWithoutPacketsSince == nil {
                activeWithoutPacketsSince = now
            }
            if let activeWithoutPacketsSince,
               now - activeWithoutPacketsSince >= CaptureHealth.stallInterval {
                fail(.activeOutputStall)
            }
            return
        }

        if activeOutput {
            if let reconnectStartFrame {
                guard let activeWithoutPacketsSince else {
                    failTimestamp(.activeIntervalState, fromHealth: true)
                    return
                }
                let activeWithoutPacketsDuration = now - activeWithoutPacketsSince
                guard activeWithoutPacketsDuration >= 0 else {
                    fail(.suspended)
                    return
                }
                guard activeWithoutPacketsDuration < CaptureHealth.stallInterval else {
                    fail(.activeOutputStall)
                    return
                }
                guard let settledFrame = settledFrame(forWatermark: watermarkQPC100ns) else {
                    failTimestamp(.reconnectWatermark, fromHealth: true)
                    return
                }
                self.reconnectStartFrame = max(reconnectStartFrame, settledFrame)
                activeOutput = false
                activeIntervalHadPacket = false
                self.activeWithoutPacketsSince = nil
                return
            }
            guard let settledFrame = settledFrame(forWatermark: watermarkQPC100ns) else {
                failTimestamp(.activeTailWatermark, fromHealth: true)
                return
            }
            let endFrame = sink.lastEndFrame
            if settledFrame > endFrame {
                let missing = settledFrame - endFrame
                let threeSecondFrames = Int64(
                    (sampleRate * CaptureHealth.stallInterval).rounded(.up)
                )
                guard missing < threeSecondFrames else {
                    fail(.activeOutputStall)
                    return
                }
                guard let missingCount = Int(exactly: missing) else {
                    failTimestamp(.activeTailCount, fromHealth: true)
                    return
                }
                recordGap(
                    .activeTail, startFrame: endFrame, endFrame: settledFrame, fromHealth: true
                )
                trailingIdleSilenceStartFrame = nil
                sink.missing(startFrame: endFrame, frameCount: missingCount)
            }
            activeOutput = false
            activeIntervalHadPacket = false
            activeWithoutPacketsSince = nil
            return
        }

        guard let settledFrame = settledFrame(forWatermark: watermarkQPC100ns) else {
            return
        }
        if let reconnectStartFrame {
            guard settledFrame > reconnectStartFrame else { return }
            guard sink.lastEndFrame == 0,
                  let gapFrameCount = Int(exactly: reconnectStartFrame) else {
                failTimestamp(.reconnectIdleExtent, fromHealth: true)
                return
            }
            recordGap(
                .reconnectIdle, startFrame: 0, endFrame: reconnectStartFrame, fromHealth: true
            )
            trailingIdleSilenceStartFrame = nil
            sink.timestampGap(frameCount: gapFrameCount)
            self.reconnectStartFrame = nil
        }
        let endFrame = sink.lastEndFrame
        guard settledFrame > endFrame else { return }
        let uncoveredFrames = settledFrame - endFrame
        let threeSecondFrames = Int64((sampleRate * CaptureHealth.stallInterval).rounded(.up))
        guard uncoveredFrames < threeSecondFrames else {
            fail(.suspended)
            return
        }
        let halfSecondFrames = Int((sampleRate * 0.5).rounded(.down))
        guard halfSecondFrames > 0 else { return }
        let count = Int(min(uncoveredFrames, Int64(halfSecondFrames)))
        if trailingIdleSilenceStartFrame == nil { trailingIdleSilenceStartFrame = endFrame }
        sink.silence(startFrame: endFrame, frameCount: count)
        recordReadiness(qpc100ns: watermarkQPC100ns)
    }

    /// The health-fill boundary at the watermark, excluding the 250 ms delivery grace.
    private func settledFrame(forWatermark watermark: UInt64) -> Int64? {
        guard watermark >= epochQPC100ns, let frame = frameForQPC(watermark) else { return nil }
        return max(0, frame - deliveryGraceFrames)
    }

    /// Consumer-side liveness check. `now` is supplied explicitly for deterministic tests.
    @discardableResult
    public func poll(now: TimeInterval) -> WindowsCaptureIngressFailure? {
        if let failure { return failure }
        guard now.isFinite, now >= 0 else {
            fail(.suspended)
            return failure
        }
        if now < startedAt {
            fail(.suspended)
            return failure
        }
        if !isReady, now - startedAt >= CaptureHealth.firstBufferDeadline {
            fail(.workerStall)
            return failure
        }
        if heartbeatSeen.load(ordering: .acquiring) {
            let last = heartbeatMillis.load(ordering: .acquiring)
            let lastSeconds = Double(last) / 1_000
            if now >= lastSeconds,
               now - lastSeconds >= CaptureHealth.stallInterval {
                fail(.workerStall)
                return failure
            }
        }
        if !loopback,
           CaptureHealth.hasStalled(
               startedAt: startedAt,
               lastBufferMillis: sink.lastBufferMillis.load(ordering: .acquiring),
               now: now
           ) {
            fail(.workerStall)
        }
        return failure
    }

    private func mapPacketStart(_ packet: WindowsCapturePacket) -> PacketStartMapping? {
        guard let hostFrame = frameForQPC(packet.qpc100ns) else {
            failTimestamp(.packetQPC)
            return nil
        }
        let idleLoopback = loopback && idleObservedSincePacket
        let reanchorGap: PacketGap = loopback
            ? (idleLoopback ? .silence : .missing(.qpcForward)) : .none
        guard let anchorDevicePosition, let anchorFrame,
              let previousDevicePosition,
              let previousDeviceEnd,
              let previousQPC100ns,
              let previousQPCFrame else {
            guard let frame = idleReanchorFrame(hostFrame),
                  resetAnchor(
                       devicePosition: packet.devicePosition, frame: frame, hostFrame: hostFrame
                   ) != nil else {
                return nil
            }
            return PacketStartMapping(
                frame: frame, gap: idleLoopback && sink.lastEndFrame > 0 ? .silence : .none
            )
        }
        guard packet.qpc100ns >= previousQPC100ns else {
            failTimestamp(.qpcRegression)
            return nil
        }
        if packet.devicePosition < previousDeviceEnd {
            guard packet.flags & Self.discontinuityFlag != 0,
                  packet.qpc100ns > previousQPC100ns else {
                failTimestamp(.deviceReset)
                return nil
            }
            guard let frame = idleReanchorFrame(hostFrame),
                  resetAnchor(
                       devicePosition: packet.devicePosition, frame: frame, hostFrame: hostFrame
                   ) != nil else {
                return nil
            }
            return PacketStartMapping(
                frame: frame,
                gap: loopback ? (idleLoopback ? .silence : .missing(.deviceReset)) : .none
            )
        }

        let deviceDelta = packet.devicePosition - previousDevicePosition
        let (qpcDelta, qpcOverflow) = hostFrame.subtractingReportingOverflow(previousQPCFrame)
        guard !qpcOverflow, qpcDelta >= 0 else {
            failTimestamp(.qpcDelta)
            return nil
        }
        guard packet.devicePosition >= anchorDevicePosition else {
            failTimestamp(.anchorDevicePosition)
            return nil
        }
        let anchorDelta = packet.devicePosition - anchorDevicePosition
        guard anchorDelta < UInt64(Int64.max) else {
            failTimestamp(.anchorDelta)
            return nil
        }
        let (mapped, overflow) = anchorFrame.addingReportingOverflow(Int64(anchorDelta))
        guard !overflow, mapped >= 0 else {
            failTimestamp(.mappedFrame)
            return nil
        }

        let tolerance = max(2.0, sampleRate * 0.002)
        let forwardExcess = Double(qpcDelta) - Double(deviceDelta)
        // The completed native packet, not its <=512-frame callback fragments, gives
        // an observed device period. Contiguous unflagged loopback packets can have
        // sub-period QPC jitter at stream start without losing any device frames.
        // Bound both this delta and the total lag so repeated jitter cannot drift
        // indefinitely behind QPC; a larger mismatch takes the usual reanchor path.
        let devicePeriod = previousDeviceEnd - previousDevicePosition
        let timestampJitter = loopback && packet.flags & Self.discontinuityFlag == 0
            && packet.devicePosition == previousDeviceEnd
            && forwardExcess > 0 && forwardExcess < Double(devicePeriod)
            && hostFrame - mapped < Int64(devicePeriod)
        let difference = abs(forwardExcess)
        if difference > tolerance && !timestampJitter {
            // Loopback device position counts delivered frames, not elapsed time. QPC
            // therefore advances across pauses even if session activity is already active.
            // Prior idle evidence selects silence; without it the span is counted missing.
            let flagged = packet.flags & Self.discontinuityFlag != 0
            if Double(qpcDelta) > Double(deviceDelta), loopback || flagged {
                guard let frame = forwardReanchorFrame(hostFrame, tolerance: tolerance),
                      resetAnchor(
                          devicePosition: packet.devicePosition, frame: frame, hostFrame: hostFrame
                      ) != nil else {
                    return nil
                }
                return PacketStartMapping(frame: frame, gap: reanchorGap)
            }
            failTimestamp(.clockMismatch)
            return nil
        }

        timelineLeadFrames = max(0, mapped - hostFrame)
        // Device and QPC can both advance across idle, so no clock-mismatch reanchor
        // is needed. The uncovered suffix is still observed idle, even when it is only
        // a few milliseconds and the resumed packet is SILENT or DISCONTINUITY flagged.
        return PacketStartMapping(
            frame: mapped, gap: idleLoopback && mapped > sink.lastEndFrame ? .silence : .none
        )
    }

    private func forwardReanchorFrame(_ hostFrame: Int64, tolerance: Double) -> Int64? {
        let endFrame = sink.lastEndFrame
        // A short pause can advance raw QPC without catching up with a timeline led
        // by an earlier health-anchor shift or accumulated device-clock drift.
        // Only the measured current lead permits overlap with PCM or missing audio.
        if loopback, hostFrame < endFrame,
           Double(endFrame - hostFrame) <= Double(timelineLeadFrames) + tolerance {
            return endFrame
        }
        return idleReanchorFrame(hostFrame)
    }

    private func idleReanchorFrame(_ hostFrame: Int64) -> Int64? {
        let endFrame = sink.lastEndFrame
        guard hostFrame < endFrame else { return hostFrame }
        // Health's watermark is not a packet-delivery fence. A packet can start inside
        // already published idle silence. Preserve all its PCM by advancing the anchor,
        // but only within the grace and only across a proven synthesized idle suffix.
        let (overlap, overflow) = endFrame.subtractingReportingOverflow(hostFrame)
        guard loopback, let idleStart = trailingIdleSilenceStartFrame,
              hostFrame >= idleStart, !overflow, overlap <= deliveryGraceFrames else {
            failTimestamp(.idleAnchorOverlap)
            return nil
        }
        return endFrame
    }

    private func resetAnchor(
        devicePosition: UInt64, frame: Int64, hostFrame: Int64
    ) -> Int64? {
        guard frame >= 0 else {
            failTimestamp(.anchorFrame)
            return nil
        }
        anchorDevicePosition = devicePosition
        anchorFrame = frame
        timelineLeadFrames = max(0, frame - hostFrame)
        return frame
    }

    private func fillIdleReanchorGap(upTo frame: Int64) -> Bool {
        let endFrame = sink.lastEndFrame
        guard frame >= endFrame else {
            failTimestamp(.idleGapOrder)
            return false
        }
        let (uncovered, overflow) = frame.subtractingReportingOverflow(endFrame)
        guard !overflow else {
            failTimestamp(.idleGapExtent)
            return false
        }
        guard uncovered > 0 else { return true }
        let threeSecondFrames = Int64(
            (sampleRate * CaptureHealth.stallInterval).rounded(.up)
        )
        guard uncovered < threeSecondFrames else {
            fail(.suspended)
            return false
        }
        guard let count = Int(exactly: uncovered) else {
            failTimestamp(.idleGapCount)
            return false
        }
        sink.silence(startFrame: endFrame, frameCount: count)
        return true
    }

    private func frameForQPC(_ qpc: UInt64) -> Int64? {
        guard qpc >= epochQPC100ns else { return nil }
        let elapsed = Double(qpc - epochQPC100ns) / Self.qpcUnitsPerSecond
        let rawFrames = elapsed * sampleRate
        guard rawFrames.isFinite, rawFrames >= 0,
              rawFrames < Double(Int64.max) else { return nil }
        let rounded = rawFrames.rounded()
        guard rounded >= 0, rounded < Double(Int64.max) else { return nil }
        return Int64(rounded)
    }

    private func recordReadiness(qpc100ns: UInt64) {
        guard sink.lastBufferMillis.load(ordering: .acquiring) != 0,
              failure == nil else { return }
        let now = clock.now()
        guard now.isFinite, now >= 0 else { return }
        _ = firstBufferQPCBits.compareExchange(
            expected: UInt64.max,
            desired: qpc100ns,
            ordering: .acquiringAndReleasing
        )
        _ = firstBufferTimeBits.compareExchange(
            expected: UInt64.max,
            desired: now.bitPattern,
            ordering: .acquiringAndReleasing
        )
    }

    private static func milliseconds(_ time: TimeInterval) -> Int64? {
        let value = time * 1_000
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return nil }
        let rounded = value.rounded(.towardZero)
        guard rounded < Double(Int64.max) else { return nil }
        return Int64(rounded)
    }
}
