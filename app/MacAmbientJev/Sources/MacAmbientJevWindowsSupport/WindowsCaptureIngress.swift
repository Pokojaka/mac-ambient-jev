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
    /// it does not guarantee late packets cannot arrive after a fill. Real PCM overlapping an
    /// already synthesized fill fails with `.timestamp` rather than being silently discarded.
    private static let deliveryGraceSeconds = 0.25

    private struct PacketStartMapping {
        let frame: Int64
        let fillsIdleGap: Bool
    }

    public let sink: TimestampedMonoSink
    public let sampleRate: Double
    public let channels: Int

    private let epochQPC100ns: UInt64
    private let clock: any CaptureClock
    private let loopback: Bool
    private let deliveryGraceFrames: Int64
    private let channelPointers: UnsafeMutablePointer<UnsafePointer<Float>>
    private let strides: UnsafeMutablePointer<Int>
    private var channelPointersInitialized = false

    private let failureCode = Atomic<Int32>(WindowsCaptureIngressFailure.none.rawValue)
    private let nativeError = Atomic<Int32>(0)
    private let heartbeatMillis = Atomic<Int64>(0)
    private let heartbeatSeen = Atomic(false)
    private let firstBufferQPCBits = Atomic<UInt64>(UInt64.max)
    private let firstBufferTimeBits = Atomic<UInt64>(UInt64.max)

    // All fields below are owned by the serialized receive/health producer.
    private let startedAt: TimeInterval
    private var lastHealthTime: TimeInterval?
    private var anchorDevicePosition: UInt64?
    private var anchorFrame: Int64?
    private var previousDevicePosition: UInt64?
    private var previousDeviceEnd: UInt64?
    private var previousQPC100ns: UInt64?
    private var previousQPCFrame: Int64?
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

    public init(
        sink: TimestampedMonoSink, sampleRate: Double, channels: Int,
        epochQPC100ns: UInt64, clock: any CaptureClock, loopback: Bool
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
        deliveryGraceFrames = Int64((sampleRate * Self.deliveryGraceSeconds).rounded(.up))
        startedAt = clock.now()
        channelPointers = .allocate(capacity: channels)
        strides = .allocate(capacity: channels)
        strides.initialize(repeating: channels, count: channels)
    }

    deinit {
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

    /// Consumes one native fragment synchronously. No callback-path error strings or arrays
    /// are created; all failures are represented by the fixed failure code.
    public func receive(_ packet: WindowsCapturePacket) {
        producerActivity = true
        guard failure == nil else { return }
        guard packet.flags <= 15 else {
            fail(.invalidPacket)
            return
        }
        if packet.flags & Self.timestampErrorFlag != 0 {
            fail(.timestamp)
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
        let fillsIdleGap: Bool
        if isNewPacket {
            guard !packetInProgress else {
                fail(.invalidPacket)
                return
            }
            guard let mapped = mapPacketStart(packet) else { return }
            packetStart = mapped.frame
            fillsIdleGap = mapped.fillsIdleGap
        } else {
            fillsIdleGap = false
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
                fail(.timestamp)
                return
            }
            packetStart = mapped
        }

        let (wholePacketEnd, wholePacketOverflow) = packetStart.addingReportingOverflow(
            Int64(packet.packetFrames)
        )
        guard !wholePacketOverflow, wholePacketEnd >= 0, wholePacketEnd < Int64.max else {
            fail(.timestamp)
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

        if fillsIdleGap, !fillIdleReanchorGap(upTo: packetStart) { return }
        if !isSilent && !isKnownMissing, packetStart < sink.lastEndFrame {
            fail(.timestamp)
            return
        }

        reconnectStartFrame = nil
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
                fail(.timestamp)
                return
            }
            previousDevicePosition = packet.devicePosition
            previousDeviceEnd = deviceEnd
            previousQPC100ns = packet.qpc100ns
            previousQPCFrame = qpcFrame
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

        if outputState == 1 {
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
                    fail(.timestamp)
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
                    fail(.timestamp)
                    return
                }
                self.reconnectStartFrame = max(reconnectStartFrame, settledFrame)
                activeOutput = false
                activeIntervalHadPacket = false
                self.activeWithoutPacketsSince = nil
                return
            }
            guard let settledFrame = settledFrame(forWatermark: watermarkQPC100ns) else {
                fail(.timestamp)
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
                    fail(.timestamp)
                    return
                }
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
                fail(.timestamp)
                return
            }
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
            fail(.timestamp)
            return nil
        }
        let idleLoopback = loopback && lastHealthTime != nil && !activeOutput
        guard let anchorDevicePosition, let anchorFrame,
              let previousDevicePosition,
              let previousDeviceEnd,
              let previousQPC100ns,
              let previousQPCFrame else {
            guard resetAnchor(devicePosition: packet.devicePosition, frame: hostFrame) != nil else {
                return nil
            }
            return PacketStartMapping(
                frame: hostFrame, fillsIdleGap: idleLoopback && sink.lastEndFrame > 0
            )
        }
        guard packet.qpc100ns >= previousQPC100ns else {
            fail(.timestamp)
            return nil
        }
        if packet.devicePosition < previousDeviceEnd {
            guard packet.flags & Self.discontinuityFlag != 0,
                  packet.qpc100ns > previousQPC100ns,
                  hostFrame >= sink.lastEndFrame else {
                fail(.timestamp)
                return nil
            }
            guard resetAnchor(devicePosition: packet.devicePosition, frame: hostFrame) != nil else {
                return nil
            }
            return PacketStartMapping(frame: hostFrame, fillsIdleGap: idleLoopback)
        }

        let deviceDelta = packet.devicePosition - previousDevicePosition
        let (qpcDelta, qpcOverflow) = hostFrame.subtractingReportingOverflow(previousQPCFrame)
        guard !qpcOverflow, qpcDelta >= 0 else {
            fail(.timestamp)
            return nil
        }
        let tolerance = max(2.0, sampleRate * 0.002)
        let difference = abs(Double(qpcDelta) - Double(deviceDelta))
        if difference > tolerance {
            // Loopback QPC can advance while device position counts only delivered frames.
            // An unflagged jump is trustworthy only after an observed idle health state;
            // discontinuity-flagged jumps retain their existing acceptance constraints.
            let flagged = packet.flags & Self.discontinuityFlag != 0
            if Double(qpcDelta) > Double(deviceDelta),
               (flagged || idleLoopback),
               hostFrame >= sink.lastEndFrame {
                guard resetAnchor(devicePosition: packet.devicePosition, frame: hostFrame) != nil else {
                    return nil
                }
                return PacketStartMapping(frame: hostFrame, fillsIdleGap: idleLoopback)
            }
            fail(.timestamp)
            return nil
        }

        guard packet.devicePosition >= anchorDevicePosition else {
            fail(.timestamp)
            return nil
        }
        let anchorDelta = packet.devicePosition - anchorDevicePosition
        guard anchorDelta < UInt64(Int64.max) else {
            fail(.timestamp)
            return nil
        }
        let (mapped, overflow) = anchorFrame.addingReportingOverflow(Int64(anchorDelta))
        guard !overflow, mapped >= 0 else {
            fail(.timestamp)
            return nil
        }
        return PacketStartMapping(frame: mapped, fillsIdleGap: false)
    }

    private func resetAnchor(devicePosition: UInt64, frame: Int64) -> Int64? {
        guard frame >= 0 else {
            fail(.timestamp)
            return nil
        }
        anchorDevicePosition = devicePosition
        anchorFrame = frame
        return frame
    }

    private func fillIdleReanchorGap(upTo frame: Int64) -> Bool {
        let endFrame = sink.lastEndFrame
        guard frame >= endFrame else {
            fail(.timestamp)
            return false
        }
        let (uncovered, overflow) = frame.subtractingReportingOverflow(endFrame)
        guard !overflow else {
            fail(.timestamp)
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
            fail(.timestamp)
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
