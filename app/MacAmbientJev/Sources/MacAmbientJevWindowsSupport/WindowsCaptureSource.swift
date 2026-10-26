import Foundation
import CMiniaudio
import MacAmbientJevCore
import MacAmbientJevPipeline

public enum WindowsCaptureDeviceSelection: Sendable, Equatable {
    case systemDefault
    case endpointID(String)
}

public struct WindowsCaptureEndpoint: Sendable, Equatable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// `stopJoin()` must fence every native callback before returning, including when it throws.
@MainActor
public protocol WindowsCaptureDevice: AnyObject {
    var endpointID: String { get }
    var sampleRate: Double { get }
    var channels: Int { get }
    func start(ingress: WindowsCaptureIngress) throws
    func stopJoin() throws
}

@MainActor
public protocol WindowsCaptureSourceFactory {
    func open(source: CaptureSource, device: WindowsCaptureDeviceSelection) throws -> any WindowsCaptureDevice
    func devices(source: CaptureSource) throws -> [WindowsCaptureEndpoint]
}

public struct WindowsCaptureStopResult: Sendable {
    public let checkpoint: AudioCheckpoint?
    public let healthyPrefixOnly: Bool
    public let errors: [String]

    public init(checkpoint: AudioCheckpoint?, healthyPrefixOnly: Bool, errors: [String]) {
        self.checkpoint = checkpoint
        self.healthyPrefixOnly = healthyPrefixOnly
        self.errors = errors
    }
}

/// Owns the one-shot lifetime from native Windows capture through durable audio finalization.
/// The caller must explicitly stop this object before releasing its last external reference.
@MainActor
public final class WindowsCaptureSource {
    private enum State {
        case new
        case starting
        case running
        case waitingForDevice
        case stopping
        case stopped
    }

    @MainActor
    private final class Segment {
        var device: (any WindowsCaptureDevice)?
        let endpointID: String
        let epochQPC100ns: UInt64
        let sampleRate: Double
        let channels: Int
        let ring: AudioBlockRing
        let sink: TimestampedMonoSink
        let drain: AudioCaptureDrain
        let ingress: WindowsCaptureIngress?
        let healthMonitor: CaptureHealthMonitor?

        init(
            device: (any WindowsCaptureDevice)?,
            endpointID: String,
            epochQPC100ns: UInt64,
            sampleRate: Double,
            channels: Int,
            ring: AudioBlockRing,
            sink: TimestampedMonoSink,
            drain: AudioCaptureDrain,
            ingress: WindowsCaptureIngress?,
            healthMonitor: CaptureHealthMonitor?
        ) {
            self.device = device
            self.endpointID = endpointID
            self.epochQPC100ns = epochQPC100ns
            self.sampleRate = sampleRate
            self.channels = channels
            self.ring = ring
            self.sink = sink
            self.drain = drain
            self.ingress = ingress
            self.healthMonitor = healthMonitor
        }
    }

    private static let qpcUnitsPerSecond: Double = 10_000_000
    private static let waitQPCUnits: UInt64 = 300_000_000
    private static let retryInterval: TimeInterval = 0.25
    private static let blockFrameCapacity = 512

    private let source: CaptureSource
    private let selection: WindowsCaptureDeviceSelection
    private let directory: URL
    private let writer: any AudioCaptureWriting
    private let factory: any WindowsCaptureSourceFactory
    private let diskSpace: any CaptureDiskSpaceProviding
    private let power: any WindowsCapturePowerProviding
    private let clock: any CaptureClock
    private let qpc100ns: @Sendable () throws -> UInt64
    private let automaticPolling: Bool
    private let onWarning: @MainActor @Sendable (String) -> Void
    private let onFailure: @MainActor @Sendable (String) -> Void
    private let onDropouts: @MainActor @Sendable (UInt64) -> Void
    private let onSilenceChanged: @MainActor @Sendable (Bool) -> Void
    private let onDeviceWaitingChanged: @MainActor @Sendable (Bool) -> Void
    private let onDeviceLost: @MainActor @Sendable (String?) -> Void

    private var state: State = .new
    private var currentSegment: Segment?
    private var openingDevice: (any WindowsCaptureDevice)?
    private var latestDrain: AudioCaptureDrain?
    private var reconnectPolicy: CaptureDeviceReconnect?
    private var lastEndEpochQPC100ns: UInt64?
    private var lastSampleRate: Double?
    private var lastChannels: Int?
    private var lastEndpointID: String?
    private var deadlineQPC100ns: UInt64?
    private var nextRetryAt: TimeInterval?
    private var waitingHealthMonitor: CaptureHealthMonitor?
    private var waitingEndQPC100ns: UInt64?
    private var waitingGapFinalized = false
    private var waitingCallbackIsSet = false
    private var deviceLostNotified = false
    private var cumulativeDropouts: UInt64 = 0
    private var reportedDropouts: UInt64 = 0
    private var powerAcquired = false
    private var drainTask: Task<Void, Never>?
    private var cleanupTask: Task<WindowsCaptureStopResult, Never>?
    private var pendingErrors: [String] = []
    private var terminalFailureNotified = false
    private var pollInProgress = false
    private var pollWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopRequested = false
    private nonisolated(unsafe) var hasLiveCaptureOrPower = false

    public private(set) var ingress: WindowsCaptureIngress?
    public private(set) var lastStopResult: WindowsCaptureStopResult?
    private var lastReopenError: String?

    public init(
        source: CaptureSource,
        device: WindowsCaptureDeviceSelection,
        directory: URL,
        writer: any AudioCaptureWriting,
        factory: any WindowsCaptureSourceFactory,
        diskSpace: any CaptureDiskSpaceProviding,
        power: any WindowsCapturePowerProviding,
        clock: any CaptureClock,
        qpc100ns: @escaping @Sendable () throws -> UInt64,
        automaticPolling: Bool,
        onWarning: @escaping @MainActor @Sendable (String) -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onDropouts: @escaping @MainActor @Sendable (UInt64) -> Void,
        onSilenceChanged: @escaping @MainActor @Sendable (Bool) -> Void,
        onDeviceWaitingChanged: @escaping @MainActor @Sendable (Bool) -> Void,
        onDeviceLost: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        self.source = source
        selection = device
        self.directory = directory
        self.writer = writer
        self.factory = factory
        self.diskSpace = diskSpace
        self.power = power
        self.clock = clock
        self.qpc100ns = qpc100ns
        self.automaticPolling = automaticPolling
        self.onWarning = onWarning
        self.onFailure = onFailure
        self.onDropouts = onDropouts
        self.onSilenceChanged = onSilenceChanged
        self.onDeviceWaitingChanged = onDeviceWaitingChanged
        self.onDeviceLost = onDeviceLost
    }

    deinit {
        precondition(!hasLiveCaptureOrPower, "WindowsCaptureSource requires explicit stop before deinitialization")
    }

    /// The ring holds at least the native period-group duration while accommodating 512-frame fragments.
    public static func ringCapacity(sampleRate: Double) -> Int {
        precondition(sampleRate.isFinite && sampleRate > 0)
        let periodMilliseconds = Double(MJA_CAPTURE_PERIOD_MILLISECONDS)
        let periods = Int(MJA_CAPTURE_PERIODS)
        precondition(periodMilliseconds > 0 && periods > 0)

        let periodFramesValue = (sampleRate * periodMilliseconds / 1_000).rounded(.up)
        precondition(periodFramesValue.isFinite && periodFramesValue > 0 && periodFramesValue < Double(Int.max))
        let slotsPerPeriodValue = (periodFramesValue / Double(Self.blockFrameCapacity)).rounded(.up)
        let groupDuration = periodMilliseconds / 1_000 * Double(periods)
        let bufferedPeriodGroupsValue = (AudioBlockRing.minimumBufferedSeconds / groupDuration).rounded(.up)
        precondition(slotsPerPeriodValue >= 1 && slotsPerPeriodValue < Double(Int.max))
        precondition(bufferedPeriodGroupsValue >= 1 && bufferedPeriodGroupsValue < Double(Int.max))

        let slotsPerPeriod = Int(slotsPerPeriodValue)
        let bufferedPeriodGroups = Int(bufferedPeriodGroupsValue)
        let (periodCapacity, periodOverflow) = slotsPerPeriod.multipliedReportingOverflow(by: periods)
        precondition(!periodOverflow)
        let (capacity, groupOverflow) = periodCapacity.multipliedReportingOverflow(by: bufferedPeriodGroups)
        precondition(!groupOverflow && capacity > 0)
        let (_, storageOverflow) = capacity.multipliedReportingOverflow(by: Self.blockFrameCapacity)
        precondition(!storageOverflow)
        return capacity
    }

    /// Performs disk preflight, acquires power, opens native capture, and waits for a valid packet
    /// (including ingress-generated idle system-audio silence) before succeeding.
    public func start() async throws {
        guard case .new = state else {
            throw AudioCaptureEngineError.alreadyRecording
        }
        state = .starting

        do {
            try CaptureDiskPolicy.checkStart(diskSpace: diskSpace, directory: directory)
            try power.acquire()
            powerAcquired = true
            hasLiveCaptureOrPower = true

            var expectedEndpointID: String?
            var initialSelection = selection
            if source == .microphone, case .systemDefault = selection {
                let endpoints = try factory.devices(source: source)
                try Self.validateEndpoints(endpoints)
                let defaults = endpoints.filter(\.isDefault)
                guard defaults.count == 1 else {
                    throw WindowsCaptureAdapterError.invalidConfiguration(
                        "Microphone capture requires exactly one default endpoint"
                    )
                }
                expectedEndpointID = defaults[0].id
                initialSelection = .endpointID(defaults[0].id)
            } else if case .endpointID(let id) = selection {
                try Self.validateEndpointID(id)
                expectedEndpointID = id
            }

            let openedDevice = try factory.open(source: source, device: initialSelection)
            openingDevice = openedDevice
            try Self.validateEndpointID(openedDevice.endpointID)
            if let expectedEndpointID, openedDevice.endpointID != expectedEndpointID {
                throw WindowsCaptureAdapterError.invalidConfiguration(
                    "Opened capture endpoint does not match the requested endpoint"
                )
            }
            try Self.validateFormat(sampleRate: openedDevice.sampleRate, channels: openedDevice.channels)

            let endpointID = openedDevice.endpointID
            let epoch = try qpc100ns()
            let healthStart = clock.now()
            let openedSegment = try makeSegment(
                device: openedDevice,
                endpointID: endpointID,
                epochQPC100ns: epoch,
                sampleRate: openedDevice.sampleRate,
                channels: openedDevice.channels,
                gapFrameCount: nil,
                monitorStartedAt: healthStart
            )
            currentSegment = openedSegment
            latestDrain = openedSegment.drain
            lastSampleRate = openedSegment.sampleRate
            lastChannels = openedSegment.channels
            lastEndpointID = endpointID
            openingDevice = nil
            ingress = openedSegment.ingress
            let followsDefaultOutput = source == .systemAudio && selection == .systemDefault
            reconnectPolicy = CaptureDeviceReconnect(
                endpointID: endpointID,
                followsDefaultOutput: followsDefaultOutput
            )
            guard let openedIngress = openedSegment.ingress else {
                preconditionFailure("A live Windows capture segment requires an ingress")
            }
            try openedDevice.start(ingress: openedIngress)

            if automaticPolling {
                launchDrainTask()
            }
            try await waitForFirstBuffer(startedAt: healthStart)
            switch state {
            case .starting:
                state = .running
            case .running:
                break
            case .new, .waitingForDevice, .stopping, .stopped:
                throw AudioCaptureEngineError.cancelled
            }
        } catch {
            try await finishFailedStart(error)
        }
    }

    /// Drives one control and drain tick. Calls never overlap, including across actor awaits.
    public func poll() async {
        guard !pollInProgress, !stopRequested, !isStopping else { return }
        switch state {
        case .starting, .running, .waitingForDevice:
            break
        case .new, .stopping, .stopped:
            return
        }
        pollInProgress = true
        defer {
            pollInProgress = false
            let waiters = pollWaiters
            pollWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters { waiter.resume() }
        }

        do {
            switch state {
            case .starting, .running:
                try await pollActiveSegment()
            case .waitingForDevice:
                try await pollWaitingForDevice()
            case .new, .stopping, .stopped:
                return
            }
        } catch {
            scheduleTerminalFailure("Windows capture reconnect failed: \(Self.message(for: error))")
        }
    }

    /// Concurrent callers share one cleanup operation and one power release.
    public func stop() async -> WindowsCaptureStopResult {
        if let cleanupTask { return await cleanupTask.value }
        if case .stopped = state {
            if let lastStopResult { return lastStopResult }
            let result = WindowsCaptureStopResult(checkpoint: nil, healthyPrefixOnly: false, errors: [])
            lastStopResult = result
            return result
        }
        if case .new = state {
            state = .stopped
            let result = WindowsCaptureStopResult(checkpoint: nil, healthyPrefixOnly: false, errors: [])
            lastStopResult = result
            return result
        }

        stopRequested = true
        await waitForPollToFinish()
        if let cleanupTask { return await cleanupTask.value }
        if case .waitingForDevice = state {
            setDeviceWaiting(false)
        }
        return await beginCleanup().value
    }

    public func committedSnapshot() async throws -> AudioCheckpoint {
        switch state {
        case .running:
            guard let currentSegment else { throw AudioCaptureEngineError.notRecording }
            return try await currentSegment.drain.committedSnapshot()
        case .waitingForDevice:
            return await writer.committedSnapshot()
        case .new, .starting, .stopping, .stopped:
            throw AudioCaptureEngineError.notRecording
        }
    }

    private func waitForFirstBuffer(startedAt: TimeInterval) async throws {
        while true {
            if Task.isCancelled { throw AudioCaptureEngineError.cancelled }
            switch state {
            case .running:
                return
            case .starting:
                break
            case .waitingForDevice:
                let message = "Windows capture device was lost during initial startup"
                scheduleTerminalFailure(message)
                throw WindowsCaptureAdapterError.health(message)
            case .stopping, .stopped:
                if let failure = pendingErrors.first {
                    throw WindowsCaptureAdapterError.health(failure)
                }
                throw AudioCaptureEngineError.cancelled
            case .new:
                throw AudioCaptureEngineError.cancelled
            }

            guard let currentSegment, let activeIngress = currentSegment.ingress else {
                try await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            if let failure = activeIngress.failure {
                if isDeviceLoss(failure, ingress: activeIngress) {
                    let message = Self.describeIngressFailure(failure, ingress: activeIngress)
                    scheduleTerminalFailure(message)
                    throw WindowsCaptureAdapterError.health(message)
                }
                throw WindowsCaptureAdapterError.health(Self.describeIngressFailure(failure, ingress: activeIngress))
            }
            let status = CaptureStartStatus.evaluate(
                startedAt: startedAt,
                now: clock.now(),
                lastBufferMillis: currentSegment.sink.lastBufferMillis.load(ordering: .acquiring),
                cancelled: false,
                failure: nil
            )
            switch status {
            case .ready:
                return
            case .failed(let message):
                throw WindowsCaptureAdapterError.health(message)
            case .cancelled:
                throw AudioCaptureEngineError.cancelled
            case .timedOut:
                throw source == .systemAudio
                    ? AudioCaptureEngineError.noSystemAudioCaptured
                    : AudioCaptureEngineError.noAudioCaptured
            case .waiting:
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    private func makeSegment(
        device: (any WindowsCaptureDevice)?,
        endpointID: String,
        epochQPC100ns: UInt64,
        sampleRate: Double,
        channels: Int,
        gapFrameCount: Int?,
        monitorStartedAt: TimeInterval?
    ) throws -> Segment {
        try Self.validateEndpointID(endpointID)
        try Self.validateFormat(sampleRate: sampleRate, channels: channels)
        let ring = AudioBlockRing(
            capacity: Self.ringCapacity(sampleRate: sampleRate),
            blockFrameCapacity: Self.blockFrameCapacity,
            sampleRate: sampleRate
        )
        let sink = TimestampedMonoSink(
            ring: ring,
            frameCapacity: Self.blockFrameCapacity,
            clock: clock,
            meter: nil
        )
        if let gapFrameCount {
            sink.timestampGap(frameCount: gapFrameCount)
        }
        let converter = try CanonicalAudioResampler(sampleRate: sampleRate)
        let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: converter)
        let segmentIngress: WindowsCaptureIngress?
        if device != nil {
            segmentIngress = try WindowsCaptureIngress(
                sink: sink,
                sampleRate: sampleRate,
                channels: channels,
                epochQPC100ns: epochQPC100ns,
                clock: clock,
                loopback: source == .systemAudio
            )
        } else {
            segmentIngress = nil
        }

        let monitor: CaptureHealthMonitor?
        if let monitorStartedAt {
            monitor = CaptureHealthMonitor(
                source: source,
                clock: clock,
                diskSpace: diskSpace,
                directory: directory,
                startedAt: monitorStartedAt,
                onFailure: { [weak self] message in self?.scheduleTerminalFailure(message) },
                onWarning: { [onWarning] message in onWarning(message) },
                onDropouts: { [weak self] count in self?.reportDropouts(count) },
                onSilenceChanged: { [onSilenceChanged] silent in onSilenceChanged(silent) }
            )
        } else {
            monitor = nil
        }
        return Segment(
            device: device,
            endpointID: endpointID,
            epochQPC100ns: epochQPC100ns,
            sampleRate: sampleRate,
            channels: channels,
            ring: ring,
            sink: sink,
            drain: drain,
            ingress: segmentIngress,
            healthMonitor: monitor
        )
    }

    private func launchDrainTask() {
        drainTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let owner = self else { return }
                await owner.poll()
                if owner.isStopping { return }
                do {
                    try await Task.sleep(nanoseconds: 20_000_000)
                } catch {
                    if !owner.isStopping {
                        owner.scheduleTerminalFailure("The Windows capture drain task was unexpectedly cancelled")
                    }
                    return
                }
            }
            if let owner = self, !owner.isStopping {
                owner.scheduleTerminalFailure("The Windows capture drain task was unexpectedly cancelled")
            }
        }
    }

    private func pollActiveSegment() async throws {
        guard let currentSegment, let activeIngress = currentSegment.ingress else {
            scheduleTerminalFailure("Windows capture has no active ingress")
            return
        }
        if let failure = activeIngress.failure {
            let message = Self.describeIngressFailure(failure, ingress: activeIngress)
            if isDeviceLoss(failure, ingress: activeIngress), case .running = state {
                try await beginDeviceLoss(currentSegment)
            } else {
                scheduleTerminalFailure(message)
            }
            return
        }

        do {
            _ = try await currentSegment.drain.drainAvailable()
        } catch {
            scheduleTerminalFailure("Audio capture drain failed: \(error.localizedDescription)")
            return
        }
        guard !stopRequested, !isStopping else { return }
        if let failure = activeIngress.failure {
            let message = Self.describeIngressFailure(failure, ingress: activeIngress)
            if isDeviceLoss(failure, ingress: activeIngress), case .running = state {
                try await beginDeviceLoss(currentSegment)
            } else {
                scheduleTerminalFailure(message)
            }
            return
        }
        if let failure = activeIngress.poll(now: clock.now()) {
            let message = Self.describeIngressFailure(failure, ingress: activeIngress)
            if isDeviceLoss(failure, ingress: activeIngress), case .running = state {
                try await beginDeviceLoss(currentSegment)
            } else {
                scheduleTerminalFailure(message)
            }
            return
        }
        if let monitor = currentSegment.healthMonitor,
           !monitor.poll(
               lastBufferMillis: currentSegment.sink.lastBufferMillis.load(ordering: .acquiring),
               silentSinceMillis: currentSegment.sink.silentSinceMillis.load(ordering: .acquiring),
               dropouts: currentSegment.ring.dropoutCount
           ) {
            return
        }
    }

    private func beginDeviceLoss(_ lostSegment: Segment) async throws {
        guard case .running = state, var policy = reconnectPolicy else {
            scheduleTerminalFailure("Windows capture device loss occurred while capture was not running")
            return
        }
        let now = clock.now()
        guard policy.deviceLost(now: now) else { return }
        reconnectPolicy = policy
        lastReopenError = nil
        state = .waitingForDevice
        waitingGapFinalized = false
        waitingEndQPC100ns = nil
        deadlineQPC100ns = nil
        nextRetryAt = now
        setDeviceWaiting(true)
        onSilenceChanged(false)

        let lossQPC100ns: UInt64
        do {
            lossQPC100ns = try qpc100ns()
        } catch {
            scheduleTerminalFailure("Windows capture device-loss timestamp failed: \(Self.message(for: error))")
            return
        }
        makeWaitingHealthMonitor(startedAt: now)

        let errors = await finishCurrentSegment(lostSegment)
        guard let lastEndEpochQPC100ns else {
            let missingEnd = "Windows capture device loss produced no valid final QPC timestamp"
            scheduleTerminalFailure((errors + [missingEnd]).joined(separator: "; "))
            return
        }
        let (lossDeadlineQPC100ns, lossDeadlineOverflow) =
            lossQPC100ns.addingReportingOverflow(Self.waitQPCUnits)
        let (audioDeadlineQPC100ns, audioDeadlineOverflow) =
            lastEndEpochQPC100ns.addingReportingOverflow(Self.waitQPCUnits)
        guard !lossDeadlineOverflow, !audioDeadlineOverflow else {
            let overflow = "Windows capture device-loss deadline overflowed QPC UInt64"
            scheduleTerminalFailure((errors + [overflow]).joined(separator: "; "))
            return
        }
        deadlineQPC100ns = min(lossDeadlineQPC100ns, audioDeadlineQPC100ns)
        guard errors.isEmpty else {
            scheduleTerminalFailure(errors.joined(separator: "; "))
            return
        }
        guard case .waitingForDevice = state, !stopRequested else { return }
        try await pollWaitingForDevice()
    }

    private func pollWaitingForDevice() async throws {
        guard case .waitingForDevice = state, !stopRequested else { return }
        let nowQPC100ns: UInt64
        do {
            nowQPC100ns = try qpc100ns()
        } catch {
            throw WindowsCaptureAdapterError.timestamp(
                "Windows capture reconnect timestamp failed: \(Self.message(for: error))"
            )
        }
        let now = clock.now()
        guard var policy = reconnectPolicy,
              let deadlineQPC100ns else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Windows capture reconnect state is incomplete"
            )
        }
        guard case .waiting(_, _, let waitingDeadline) = policy.state else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Windows capture reconnect policy is not waiting"
            )
        }

        if let candidateSegment = currentSegment {
            guard let candidateIngress = candidateSegment.ingress else {
                scheduleTerminalFailure("Windows capture wait contains a segment without an ingress")
                return
            }
            let timelyReadiness = try candidateHasTimelyReadiness(candidateIngress)
            let deadlinePassed = nowQPC100ns >= deadlineQPC100ns || now >= waitingDeadline
            if let failure = candidateIngress.failure,
               Self.isFatalCandidateFailure(failure),
               !Self.isRetryableCandidateFailure(
                   failure,
                   ingress: candidateIngress,
                   timelyReadiness: timelyReadiness,
                   deadlinePassed: deadlinePassed
               ) {
                let message = Self.describeIngressFailure(failure, ingress: candidateIngress)
                let errors = discardCurrentCandidate(candidateSegment)
                scheduleTerminalFailure(([message] + errors).joined(separator: "; "))
                return
            }
            if timelyReadiness {
                guard let firstBufferTime = candidateIngress.firstBufferTime else {
                    preconditionFailure("A ready candidate must have a first-buffer time")
                }
                await resumeCandidate(candidateSegment, firstBufferTime: firstBufferTime)
                if case .running = state {
                    try await pollActiveSegment()
                }
                return
            }
            if deadlinePassed {
                if let failure = candidateIngress.failure,
                   Self.isRetryableCandidateFailure(
                       failure,
                       ingress: candidateIngress,
                       timelyReadiness: false,
                       deadlinePassed: true
                   ) {
                    lastReopenError = Self.describeIngressFailure(failure, ingress: candidateIngress)
                }
                await expireDeviceWait(deadlineQPC100ns: deadlineQPC100ns)
                return
            }
            if let failure = candidateIngress.poll(now: now) {
                let message = Self.describeIngressFailure(failure, ingress: candidateIngress)
                if Self.isRetryableCandidateFailure(
                    failure,
                    ingress: candidateIngress,
                    timelyReadiness: timelyReadiness,
                    deadlinePassed: false
                ) {
                    lastReopenError = message
                    let errors = discardCurrentCandidate(candidateSegment)
                    guard errors.isEmpty else {
                        scheduleTerminalFailure(([message] + errors).joined(separator: "; "))
                        return
                    }
                    try scheduleReconnectRetry(after: clock.now())
                } else {
                    let errors = discardCurrentCandidate(candidateSegment)
                    if isDeviceLoss(failure, ingress: candidateIngress) {
                        if !errors.isEmpty {
                            scheduleTerminalFailure(errors.joined(separator: "; "))
                            return
                        }
                    } else {
                        scheduleTerminalFailure(([message] + errors).joined(separator: "; "))
                        return
                    }
                }
            }
        }
        if nowQPC100ns >= deadlineQPC100ns || now >= waitingDeadline {
            await expireDeviceWait(deadlineQPC100ns: deadlineQPC100ns)
            return
        }
        let waitDropouts = max(currentSegment?.ring.dropoutCount ?? 0, 1)
        reportDropouts(waitDropouts)
        let (waitingDropouts, waitingDropoutsOverflow) = cumulativeDropouts.addingReportingOverflow(waitDropouts)
        if now < waitingDeadline,
           let waitingHealthMonitor,
           !waitingHealthMonitor.poll(
               lastBufferMillis: 0,
               silentSinceMillis: 0,
               dropouts: waitingDropoutsOverflow ? UInt64.max : waitingDropouts
           ) {
            return
        }

        let expiry = policy.poll(now: now, endpoints: [])
        reconnectPolicy = policy
        if case .deviceLost = expiry {
            await expireDeviceWait(deadlineQPC100ns: deadlineQPC100ns)
            return
        }
        if currentSegment != nil { return }

        guard let retryAt = nextRetryAt, now >= retryAt else { return }
        let nextRetry = now + Self.retryInterval
        guard nextRetry.isFinite else {
            throw WindowsCaptureAdapterError.timestamp("Capture reconnect retry deadline overflowed")
        }
        nextRetryAt = nextRetry

        let endpoints: [WindowsCaptureEndpoint]
        do {
            endpoints = try factory.devices(source: source)
            try Self.validateEndpoints(endpoints)
        } catch {
            lastReopenError = Self.message(for: error)
            if try reconnectQPCDeadlineHasPassed() {
                await expireDeviceWait(deadlineQPC100ns: deadlineQPC100ns)
            } else {
                try scheduleReconnectRetry(after: clock.now())
            }
            return
        }
        let reconnectEndpoints = endpoints.map {
            CaptureReconnectEndpoint(id: $0.id, isDefault: $0.isDefault)
        }
        guard var currentPolicy = reconnectPolicy else {
            throw WindowsCaptureAdapterError.invalidConfiguration("Windows capture reconnect policy disappeared")
        }
        let action = currentPolicy.poll(now: clock.now(), endpoints: reconnectEndpoints)
        reconnectPolicy = currentPolicy
        switch action {
        case .none:
            return
        case .deviceLost:
            await expireDeviceWait(deadlineQPC100ns: deadlineQPC100ns)
            return
        case .reopen(let candidateID):
            try await openReconnectCandidate(endpointID: candidateID)
        }
    }

    private func scheduleReconnectRetry(after now: TimeInterval) throws {
        let retryAt = now + Self.retryInterval
        guard retryAt.isFinite else {
            throw WindowsCaptureAdapterError.timestamp("Capture reconnect retry deadline overflowed")
        }
        nextRetryAt = retryAt
    }

    private func candidateHasTimelyReadiness(_ candidateIngress: WindowsCaptureIngress) throws -> Bool {
        guard let reconnectPolicy,
              case .waiting(_, _, let waitingDeadline) = reconnectPolicy.state,
              let deadlineQPC100ns else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Windows capture reconnect state is incomplete"
            )
        }
        guard candidateIngress.isReady,
              let firstBufferTime = candidateIngress.firstBufferTime,
              let firstBufferQPC100ns = candidateIngress.firstBufferQPC100ns else {
            return false
        }
        return firstBufferTime < waitingDeadline && firstBufferQPC100ns < deadlineQPC100ns
    }

    private func reconnectDeadlineHasPassed() throws -> Bool {
        guard let reconnectPolicy,
              case .waiting(_, _, let waitingDeadline) = reconnectPolicy.state else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Windows capture reconnect policy is not waiting"
            )
        }
        let qpcDeadlinePassed = try reconnectQPCDeadlineHasPassed()
        return qpcDeadlinePassed || clock.now() >= waitingDeadline
    }

    private func reconnectQPCDeadlineHasPassed() throws -> Bool {
        guard let deadlineQPC100ns else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Windows capture reconnect deadline is missing"
            )
        }
        let nowQPC100ns: UInt64
        do {
            nowQPC100ns = try qpc100ns()
        } catch {
            throw WindowsCaptureAdapterError.timestamp(
                "Windows capture reconnect timestamp failed: \(Self.message(for: error))"
            )
        }
        return nowQPC100ns >= deadlineQPC100ns
    }

    private func fenceUnassignedDeviceIfQPCDeadlinePassed(
        _ device: any WindowsCaptureDevice
    ) async throws -> Bool {
        let deadlinePassed: Bool
        do {
            deadlinePassed = try reconnectQPCDeadlineHasPassed()
        } catch {
            let cleanupErrors = await discardUnassignedDevice(device)
            throw WindowsCaptureAdapterError.combined([Self.message(for: error)] + cleanupErrors)
        }
        guard deadlinePassed else { return false }
        let cleanupErrors = await discardUnassignedDevice(device)
        guard cleanupErrors.isEmpty else {
            throw WindowsCaptureAdapterError.combined(cleanupErrors)
        }
        guard let deadlineQPC100ns else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Windows capture reconnect deadline is missing"
            )
        }
        await expireDeviceWait(deadlineQPC100ns: deadlineQPC100ns)
        return true
    }

    private func openReconnectCandidate(endpointID: String) async throws {
        if try reconnectQPCDeadlineHasPassed() {
            guard let deadlineQPC100ns else {
                throw WindowsCaptureAdapterError.invalidConfiguration(
                    "Windows capture reconnect deadline is missing"
                )
            }
            await expireDeviceWait(deadlineQPC100ns: deadlineQPC100ns)
            return
        }
        let followsDefaultOutput = source == .systemAudio && selection == .systemDefault
        let requested: WindowsCaptureDeviceSelection = followsDefaultOutput
            ? .systemDefault
            : .endpointID(endpointID)
        let openedDevice: any WindowsCaptureDevice
        do {
            openedDevice = try factory.open(source: source, device: requested)
        } catch WindowsCaptureAdapterError.native(let operation, let code) {
            let error = WindowsCaptureAdapterError.native(operation: operation, code: code)
            lastReopenError = error.localizedDescription
            if try reconnectQPCDeadlineHasPassed() {
                guard let deadlineQPC100ns else {
                    throw WindowsCaptureAdapterError.invalidConfiguration(
                        "Windows capture reconnect deadline is missing"
                    )
                }
                await expireDeviceWait(deadlineQPC100ns: deadlineQPC100ns)
                return
            }
            try scheduleReconnectRetry(after: clock.now())
            return
        }

        do {
            try Self.validateEndpointID(openedDevice.endpointID)
        } catch {
            let cleanupErrors = await discardUnassignedDevice(openedDevice)
            if cleanupErrors.isEmpty { throw error }
            throw WindowsCaptureAdapterError.combined([Self.message(for: error)] + cleanupErrors)
        }
        guard openedDevice.endpointID == endpointID else {
            let cleanupErrors = await discardUnassignedDevice(openedDevice)
            if followsDefaultOutput {
                guard cleanupErrors.isEmpty else {
                    throw WindowsCaptureAdapterError.combined(cleanupErrors)
                }
                if try reconnectQPCDeadlineHasPassed() {
                    guard let deadlineQPC100ns else {
                        throw WindowsCaptureAdapterError.invalidConfiguration(
                            "Windows capture reconnect deadline is missing"
                        )
                    }
                    await expireDeviceWait(deadlineQPC100ns: deadlineQPC100ns)
                }
                return
            }
            let mismatch = WindowsCaptureAdapterError.invalidConfiguration(
                "Reopened capture endpoint does not match the selected endpoint"
            )
            throw WindowsCaptureAdapterError.combined([mismatch.localizedDescription] + cleanupErrors)
        }
        do {
            try Self.validateFormat(sampleRate: openedDevice.sampleRate, channels: openedDevice.channels)
        } catch {
            let cleanupErrors = await discardUnassignedDevice(openedDevice)
            if cleanupErrors.isEmpty { throw error }
            throw WindowsCaptureAdapterError.combined([Self.message(for: error)] + cleanupErrors)
        }
        if try await fenceUnassignedDeviceIfQPCDeadlinePassed(openedDevice) { return }
        guard let epoch = lastEndEpochQPC100ns else {
            let cleanupErrors = await discardUnassignedDevice(openedDevice)
            let missingEpoch = WindowsCaptureAdapterError.timestamp(
                "Windows capture reconnect has no valid segment epoch"
            )
            throw WindowsCaptureAdapterError.combined([missingEpoch.localizedDescription] + cleanupErrors)
        }
        let candidate: Segment
        do {
            candidate = try makeSegment(
                device: openedDevice,
                endpointID: endpointID,
                epochQPC100ns: epoch,
                sampleRate: openedDevice.sampleRate,
                channels: openedDevice.channels,
                gapFrameCount: nil,
                monitorStartedAt: clock.now()
            )
            if source == .systemAudio {
                guard let candidateIngress = candidate.ingress else {
                    throw WindowsCaptureAdapterError.invalidConfiguration(
                        "A reopened loopback capture segment requires an ingress"
                    )
                }
                try candidateIngress.prepareReconnect(startQPC100ns: try qpc100ns())
            }
        } catch {
            let cleanupErrors = await discardUnassignedDevice(openedDevice)
            if cleanupErrors.isEmpty { throw error }
            throw WindowsCaptureAdapterError.combined([Self.message(for: error)] + cleanupErrors)
        }
        guard let candidateIngress = candidate.ingress else {
            preconditionFailure("A reopened Windows capture segment requires an ingress")
        }
        if try await fenceUnassignedDeviceIfQPCDeadlinePassed(openedDevice) { return }

        do {
            try openedDevice.start(ingress: candidateIngress)
        } catch WindowsCaptureAdapterError.native(let operation, let code) {
            let error = WindowsCaptureAdapterError.native(operation: operation, code: code)
            let stopErrors = await discardUnassignedDevice(openedDevice)
            guard stopErrors.isEmpty else {
                throw WindowsCaptureAdapterError.combined([error.localizedDescription] + stopErrors)
            }
            let timelyReadiness: Bool
            do {
                timelyReadiness = try candidateHasTimelyReadiness(candidateIngress)
            } catch let stateError {
                throw WindowsCaptureAdapterError.combined([
                    error.localizedDescription,
                    Self.message(for: stateError)
                ])
            }
            let message = error.localizedDescription
            lastReopenError = message
            if timelyReadiness {
                let audioErrors = await finishUnassignedCandidateIfNeeded(candidate)
                throw WindowsCaptureAdapterError.combined(
                    [
                        "Windows capture start reported device loss after delivering audio",
                        error.localizedDescription
                    ] + audioErrors
                )
            }
            if try reconnectQPCDeadlineHasPassed() {
                guard let deadlineQPC100ns else {
                    throw WindowsCaptureAdapterError.invalidConfiguration(
                        "Windows capture reconnect deadline is missing"
                    )
                }
                await expireDeviceWait(deadlineQPC100ns: deadlineQPC100ns)
                return
            }
            try scheduleReconnectRetry(after: clock.now())
            return
        } catch {
            let stopErrors = await discardUnassignedDevice(openedDevice)
            let capturedAudio = candidateIngress.isReady
            let audioErrors = await finishUnassignedCandidateIfNeeded(candidate)
            throw WindowsCaptureAdapterError.combined(
                [Self.message(for: error)] + stopErrors + audioErrors
                    + (capturedAudio ? ["Windows capture start failed after delivering audio"] : [])
            )
        }
        let candidateTimelyReadiness: Bool
        let candidateDeadlinePassed: Bool
        do {
            candidateTimelyReadiness = try candidateHasTimelyReadiness(candidateIngress)
            candidateDeadlinePassed = try reconnectDeadlineHasPassed()
        } catch {
            let cleanupErrors = await discardUnassignedDevice(openedDevice)
            throw WindowsCaptureAdapterError.combined([Self.message(for: error)] + cleanupErrors)
        }
        if let failure = candidateIngress.failure {
            let retryable = Self.isRetryableCandidateFailure(
                failure,
                ingress: candidateIngress,
                timelyReadiness: candidateTimelyReadiness,
                deadlinePassed: candidateDeadlinePassed
            )
            if retryable {
                lastReopenError = Self.describeIngressFailure(failure, ingress: candidateIngress)
            }
            if Self.isFatalCandidateFailure(failure), !retryable {
                let message = Self.describeIngressFailure(failure, ingress: candidateIngress)
                let cleanupErrors = await discardUnassignedDevice(openedDevice)
                throw WindowsCaptureAdapterError.combined([message] + cleanupErrors)
            }
        }
        if try await fenceUnassignedDeviceIfQPCDeadlinePassed(openedDevice) { return }

        currentSegment = candidate
        ingress = candidateIngress

        guard let currentPolicy = reconnectPolicy,
              case .waiting(_, _, let waitingDeadline) = currentPolicy.state,
              let deadlineQPC100ns else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Windows capture reconnect policy or deadline is not waiting"
            )
        }
        let now = clock.now()
        if try candidateHasTimelyReadiness(candidateIngress) {
            guard let firstBufferTime = candidateIngress.firstBufferTime else {
                preconditionFailure("A ready candidate must have a first-buffer time")
            }
            await resumeCandidate(candidate, firstBufferTime: firstBufferTime)
            if case .running = state {
                try await pollActiveSegment()
            }
            return
        }
        if now >= waitingDeadline {
            await expireDeviceWait(deadlineQPC100ns: deadlineQPC100ns)
            return
        }
        if let failure = candidateIngress.poll(now: now) {
            let message = Self.describeIngressFailure(failure, ingress: candidateIngress)
            if Self.isRetryableCandidateFailure(
                failure,
                ingress: candidateIngress,
                timelyReadiness: candidateTimelyReadiness,
                deadlinePassed: false
            ) {
                lastReopenError = message
                let errors = discardCurrentCandidate(candidate)
                guard errors.isEmpty else {
                    throw WindowsCaptureAdapterError.combined([message] + errors)
                }
                try scheduleReconnectRetry(after: clock.now())
                return
            }
            let errors = discardCurrentCandidate(candidate)
            if isDeviceLoss(failure, ingress: candidateIngress), errors.isEmpty { return }
            throw WindowsCaptureAdapterError.combined([message] + errors)
        }
    }

    private func resumeCandidate(_ candidate: Segment, firstBufferTime: TimeInterval) async {
        guard case .waitingForDevice = state,
              let currentPolicy = reconnectPolicy else { return }
        var policy = currentPolicy
        guard policy.didResume(endpointID: candidate.endpointID, now: firstBufferTime) else {
            reconnectPolicy = policy
            if let deadlineQPC100ns {
                await expireDeviceWait(deadlineQPC100ns: deadlineQPC100ns)
            } else {
                scheduleTerminalFailure("Windows capture reconnect deadline is missing")
            }
            return
        }
        reconnectPolicy = policy
        latestDrain = candidate.drain
        lastSampleRate = candidate.sampleRate
        lastChannels = candidate.channels
        lastEndpointID = candidate.endpointID
        state = .running
        waitingHealthMonitor = nil
        waitingEndQPC100ns = nil
        waitingGapFinalized = false
        setDeviceWaiting(false)
    }

    private func expireDeviceWait(deadlineQPC100ns: UInt64) async {
        guard case .waitingForDevice = state else { return }
        waitingEndQPC100ns = deadlineQPC100ns
        if let candidate = currentSegment {
            let errors = discardCurrentCandidate(candidate)
            guard errors.isEmpty else {
                scheduleTerminalFailure(errors.joined(separator: "; "))
                return
            }
        }
        guard !deviceLostNotified else { return }
        deviceLostNotified = true
        onDeviceLost(lastReopenError)
        _ = beginCleanup()
    }

    private func discardCurrentCandidate(_ candidate: Segment) -> [String] {
        precondition(currentSegment === candidate)
        var errors: [String] = []
        if let device = candidate.device {
            do {
                try device.stopJoin()
            } catch {
                errors.append("Native capture stop failed: \(Self.message(for: error))")
            }
            candidate.device = nil
        }
        currentSegment = nil
        ingress = nil
        return errors
    }

    private func finishCurrentSegment(_ segment: Segment) async -> [String] {
        guard currentSegment === segment else { return [] }
        var errors: [String] = []
        if let device = segment.device {
            do {
                try device.stopJoin()
            } catch {
                errors.append("Native capture stop failed: \(Self.message(for: error))")
            }
            segment.device = nil
        }
        segment.ring.finish(tailFrame: segment.sink.lastEndFrame)
        let (dropouts, dropoutOverflow) = cumulativeDropouts.addingReportingOverflow(segment.ring.dropoutCount)
        cumulativeDropouts = dropoutOverflow ? UInt64.max : dropouts
        reportDropouts(0)
        lastEndEpochQPC100ns = nil
        do {
            lastEndEpochQPC100ns = try Self.epoch(
                segment.epochQPC100ns,
                endFrame: segment.sink.lastEndFrame,
                sampleRate: segment.sampleRate
            )
        } catch {
            errors.append("Windows capture segment epoch failed: \(Self.message(for: error))")
        }
        lastSampleRate = segment.sampleRate
        lastChannels = segment.channels
        lastEndpointID = segment.endpointID
        latestDrain = segment.drain
        currentSegment = nil
        ingress = nil

        do {
            _ = try await segment.drain.finishSegment()
        } catch {
            errors.append("Audio capture segment finish failed: \(Self.message(for: error))")
        }
        return errors
    }

    private func discardUnassignedDevice(_ device: any WindowsCaptureDevice) async -> [String] {
        do {
            try device.stopJoin()
            return []
        } catch {
            return ["Native capture stop failed: \(Self.message(for: error))"]
        }
    }

    private func finishUnassignedCandidateIfNeeded(_ candidate: Segment) async -> [String] {
        guard candidate.ingress?.isReady == true else { return [] }
        waitingGapFinalized = true
        waitingEndQPC100ns = nil
        latestDrain = candidate.drain
        candidate.ring.finish(tailFrame: candidate.sink.lastEndFrame)
        let (dropouts, overflow) = cumulativeDropouts.addingReportingOverflow(candidate.ring.dropoutCount)
        cumulativeDropouts = overflow ? UInt64.max : dropouts
        reportDropouts(0)
        do {
            _ = try await candidate.drain.finishSegment()
            return []
        } catch {
            return ["Audio capture segment finish failed: \(Self.message(for: error))"]
        }
    }

    private func makeWaitingHealthMonitor(startedAt: TimeInterval) {
        waitingHealthMonitor = CaptureHealthMonitor(
            source: source,
            clock: clock,
            diskSpace: diskSpace,
            directory: directory,
            startedAt: startedAt,
            onFailure: { [weak self] message in self?.scheduleTerminalFailure(message) },
            onWarning: { [onWarning] message in onWarning(message) },
            onDropouts: { _ in },
            onSilenceChanged: { _ in }
        )
    }

    private func waitForPollToFinish() async {
        guard pollInProgress else { return }
        await withCheckedContinuation { continuation in
            pollWaiters.append(continuation)
        }
    }

    private func beginCleanup() -> Task<WindowsCaptureStopResult, Never> {
        if let cleanupTask { return cleanupTask }
        if case .waitingForDevice = state {
            if !waitingGapFinalized, waitingEndQPC100ns == nil {
                do {
                    let now = try qpc100ns()
                    guard let deadlineQPC100ns else {
                        throw WindowsCaptureAdapterError.timestamp("Windows capture wait deadline is missing")
                    }
                    waitingEndQPC100ns = min(now, deadlineQPC100ns)
                } catch {
                    appendError("Windows capture wait timestamp failed: \(Self.message(for: error))")
                }
            }
            reconnectPolicy?.stop()
            setDeviceWaiting(false)
        }
        stopRequested = true
        state = .stopping
        let task = Task { @MainActor [self] in
            await performCleanup()
        }
        cleanupTask = task
        return task
    }

    private func performCleanup() async -> WindowsCaptureStopResult {
        await waitForPollToFinish()
        var healthyPrefixOnly = false
        if let waitingEndQPC100ns, !waitingGapFinalized {
            do {
                try await finalizeWaitingGap(until: waitingEndQPC100ns)
            } catch {
                healthyPrefixOnly = true
                appendError("Windows capture wait-gap finalization failed: \(Self.message(for: error))")
                waitingGapFinalized = true
            }
        }

        if let openingDevice {
            do {
                try openingDevice.stopJoin()
            } catch {
                appendError("Native capture stop failed: \(Self.message(for: error))")
            }
            self.openingDevice = nil
        }
        if let currentSegment {
            if let device = currentSegment.device {
                do {
                    try device.stopJoin()
                } catch {
                    appendError("Native capture stop failed: \(Self.message(for: error))")
                }
                currentSegment.device = nil
            }
            currentSegment.ring.finish(tailFrame: currentSegment.sink.lastEndFrame)
            let (dropouts, overflow) = cumulativeDropouts.addingReportingOverflow(currentSegment.ring.dropoutCount)
            cumulativeDropouts = overflow ? UInt64.max : dropouts
            reportDropouts(0)
            latestDrain = currentSegment.drain
        }

        drainTask?.cancel()
        if let drainTask { await drainTask.value }
        drainTask = nil

        var checkpoint: AudioCheckpoint?
        if let latestDrain {
            do {
                checkpoint = try await latestDrain.finish()
            } catch {
                healthyPrefixOnly = true
                appendError("Audio writer finish failed: \(Self.message(for: error))")
                checkpoint = await latestDrain.durableCheckpoint()
            }
        }

        if powerAcquired {
            powerAcquired = false
            do {
                try power.release()
            } catch {
                appendError("Recording power release failed: \(Self.message(for: error))")
            }
        }

        let result = WindowsCaptureStopResult(
            checkpoint: checkpoint,
            healthyPrefixOnly: healthyPrefixOnly,
            errors: pendingErrors
        )
        lastStopResult = result
        ingress = nil
        currentSegment = nil
        latestDrain = nil
        waitingHealthMonitor = nil
        hasLiveCaptureOrPower = false
        state = .stopped
        return result
    }

    private func finalizeWaitingGap(until targetQPC100ns: UInt64) async throws {
        if let currentSegment {
            let errors = await finishCurrentSegment(currentSegment)
            guard errors.isEmpty else {
                throw WindowsCaptureAdapterError.combined(errors)
            }
        }
        guard let epoch = lastEndEpochQPC100ns,
              let sampleRate = lastSampleRate,
              let channels = lastChannels,
              let endpointID = lastEndpointID else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Windows capture wait cannot finish without a previous segment"
            )
        }
        let gapFrames = try Self.frameCount(from: epoch, to: targetQPC100ns, sampleRate: sampleRate)
        let gapSegment = try makeSegment(
            device: nil,
            endpointID: endpointID,
            epochQPC100ns: epoch,
            sampleRate: sampleRate,
            channels: channels,
            gapFrameCount: gapFrames,
            monitorStartedAt: nil
        )
        currentSegment = gapSegment
        latestDrain = gapSegment.drain
        ingress = nil
        waitingGapFinalized = true
        reportDropouts(1)
    }

    private func scheduleTerminalFailure(_ message: String) {
        guard !isStopping else { return }
        appendError(message)
        if !terminalFailureNotified {
            terminalFailureNotified = true
            onFailure(message)
        }
        _ = beginCleanup()
    }

    private func finishFailedStart(_ error: any Error) async throws -> Never {
        let originalMessage = Self.message(for: error)
        if let cleanupTask {
            let result = await cleanupTask.value
            throw WindowsCaptureAdapterError.combined(Self.unique([originalMessage] + result.errors))
        }
        let needsCleanup = openingDevice != nil || currentSegment != nil || powerAcquired || latestDrain != nil
        if needsCleanup {
            appendError(originalMessage)
            let result = await beginCleanup().value
            let combined = Self.unique([originalMessage] + result.errors)
            throw WindowsCaptureAdapterError.combined(combined)
        }

        state = .stopped
        let result = WindowsCaptureStopResult(checkpoint: nil, healthyPrefixOnly: false, errors: [])
        lastStopResult = result
        throw error
    }

    private var isStopping: Bool {
        switch state {
        case .stopping, .stopped: true
        case .new, .starting, .running, .waitingForDevice: false
        }
    }

    private func setDeviceWaiting(_ waiting: Bool) {
        guard waitingCallbackIsSet != waiting else { return }
        waitingCallbackIsSet = waiting
        onDeviceWaitingChanged(waiting)
    }

    private func reportDropouts(_ segmentDropouts: UInt64) {
        let (total, overflow) = cumulativeDropouts.addingReportingOverflow(segmentDropouts)
        let value = overflow ? UInt64.max : total
        let reported = max(reportedDropouts, value)
        reportedDropouts = reported
        onDropouts(reported)
    }

    private func appendError(_ message: String) {
        guard !pendingErrors.contains(message) else { return }
        pendingErrors.append(message)
    }

    private static func unique(_ messages: [String]) -> [String] {
        var seen = Set<String>()
        return messages.filter { seen.insert($0).inserted }
    }

    private static func message(for error: any Error) -> String {
        error.localizedDescription
    }

    private static func validateEndpointID(_ id: String) throws {
        guard !id.isEmpty, !id.contains("\0") else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "A capture endpoint ID must be nonempty and contain no embedded NUL"
            )
        }
    }

    private static func validateEndpoints(_ endpoints: [WindowsCaptureEndpoint]) throws {
        let ids = endpoints.map(\.id)
        guard Set(ids).count == ids.count,
              endpoints.filter(\.isDefault).count <= 1 else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Capture enumeration returned duplicate endpoints or multiple defaults"
            )
        }
        for id in ids { try validateEndpointID(id) }
    }

    private static func validateFormat(sampleRate: Double, channels: Int) throws {
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
    }

    private static func frameCount(from startQPC: UInt64, to endQPC: UInt64, sampleRate: Double) throws -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw WindowsCaptureAdapterError.timestamp("Capture segment sample rate is invalid")
        }
        guard endQPC >= startQPC else {
            throw WindowsCaptureAdapterError.timestamp("Capture QPC moved before the segment epoch")
        }
        let frameValue = (Double(endQPC - startQPC) * sampleRate / qpcUnitsPerSecond).rounded()
        guard frameValue.isFinite, frameValue >= 0, frameValue < Double(Int.max) else {
            throw WindowsCaptureAdapterError.timestamp("Capture timestamp gap exceeds Int bounds")
        }
        return Int(frameValue)
    }

    private static func epoch(_ epochQPC100ns: UInt64, endFrame: Int64, sampleRate: Double) throws -> UInt64 {
        guard endFrame >= 0, sampleRate.isFinite, sampleRate > 0 else {
            throw WindowsCaptureAdapterError.timestamp("Capture segment end coordinates are invalid")
        }
        let duration = (Double(endFrame) / sampleRate * qpcUnitsPerSecond).rounded()
        guard duration.isFinite, duration >= 0, duration < Double(UInt64.max) else {
            throw WindowsCaptureAdapterError.timestamp("Capture segment epoch exceeds QPC UInt64 bounds")
        }
        let (end, overflow) = epochQPC100ns.addingReportingOverflow(UInt64(duration))
        guard !overflow else {
            throw WindowsCaptureAdapterError.timestamp("Capture segment epoch overflowed QPC UInt64")
        }
        return end
    }

    private func isDeviceLoss(_ failure: WindowsCaptureIngressFailure, ingress: WindowsCaptureIngress) -> Bool {
        failure == .native && mja_capture_is_device_lost_error(ingress.nativeErrorCode) != 0
    }

    private static func isFatalCandidateFailure(_ failure: WindowsCaptureIngressFailure) -> Bool {
        switch failure {
        case .invalidPacket, .timestamp, .unknownOutput, .activeOutputStall, .suspended:
            true
        case .none, .workerStall, .native:
            false
        }
    }

    private static func isRetryableCandidateFailure(
        _ failure: WindowsCaptureIngressFailure,
        ingress: WindowsCaptureIngress,
        timelyReadiness: Bool,
        deadlinePassed: Bool
    ) -> Bool {
        guard !timelyReadiness,
              ingress.firstBufferTime == nil || deadlinePassed else {
            return false
        }
        return switch failure {
        case .workerStall, .activeOutputStall, .native, .suspended:
            true
        case .none, .invalidPacket, .timestamp, .unknownOutput:
            false
        }
    }

    private static func describeIngressFailure(
        _ failure: WindowsCaptureIngressFailure,
        ingress: WindowsCaptureIngress
    ) -> String {
        switch failure {
        case .none:
            return "Windows capture reported an empty failure state"
        case .invalidPacket:
            return "Windows capture received an invalid audio packet"
        case .timestamp:
            return "Windows capture received an invalid packet timestamp"
        case .unknownOutput:
            return "Windows loopback capture reported an unknown output state"
        case .workerStall:
            return "Windows capture worker stopped reporting a healthy heartbeat"
        case .activeOutputStall:
            return "Active system audio stopped producing capture packets"
        case .suspended:
            return "Windows capture timing was suspended or discontinuous"
        case .native:
            return WindowsCaptureAdapterError.native(
                operation: "Windows audio capture",
                code: ingress.nativeErrorCode
            ).localizedDescription
        }
    }
}
