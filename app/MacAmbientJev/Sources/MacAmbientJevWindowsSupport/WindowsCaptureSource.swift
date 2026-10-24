import Foundation
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
        case stopping
        case stopped
    }

    private let source: CaptureSource
    private let selection: WindowsCaptureDeviceSelection
    private let directory: URL
    private let writer: any AudioCaptureWriting
    private let factory: any WindowsCaptureSourceFactory
    private let diskSpace: any CaptureDiskSpaceProviding
    private let power: any WindowsCapturePowerProviding
    private let clock: any CaptureClock
    private let qpc100ns: @Sendable () throws -> UInt64
    private let onWarning: @MainActor @Sendable (String) -> Void
    private let onFailure: @MainActor @Sendable (String) -> Void
    private let onDropouts: @MainActor @Sendable (UInt64) -> Void
    private let onSilenceChanged: @MainActor @Sendable (Bool) -> Void

    private var state: State = .new
    private var device: (any WindowsCaptureDevice)?
    private var powerAcquired = false
    private var ring: AudioBlockRing?
    private var sink: TimestampedMonoSink?
    private var drain: AudioCaptureDrain?
    private var healthMonitor: CaptureHealthMonitor?
    private var drainTask: Task<Void, Never>?
    private var cleanupTask: Task<WindowsCaptureStopResult, Never>?
    private var pendingErrors: [String] = []
    private var terminalFailureNotified = false
    private nonisolated(unsafe) var hasLiveCaptureOrPower = false

    public private(set) var ingress: WindowsCaptureIngress?
    public private(set) var lastStopResult: WindowsCaptureStopResult?

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
        onWarning: @escaping @MainActor @Sendable (String) -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onDropouts: @escaping @MainActor @Sendable (UInt64) -> Void,
        onSilenceChanged: @escaping @MainActor @Sendable (Bool) -> Void
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
        self.onWarning = onWarning
        self.onFailure = onFailure
        self.onDropouts = onDropouts
        self.onSilenceChanged = onSilenceChanged
    }

    deinit {
        precondition(!hasLiveCaptureOrPower, "WindowsCaptureSource requires explicit stop before deinitialization")
    }

    /// Performs the disk preflight, acquires power, opens native capture, and waits for a
    /// valid packet (including ingress-generated idle system-audio silence) before succeeding.
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

            if case .endpointID(let id) = selection {
                guard !id.isEmpty, !id.contains("\0") else {
                    throw WindowsCaptureAdapterError.invalidConfiguration(
                        "A selected capture endpoint ID must be nonempty and contain no embedded NUL"
                    )
                }
            }

            let openedDevice = try factory.open(source: source, device: selection)
            device = openedDevice
            try Self.validateFormat(sampleRate: openedDevice.sampleRate, channels: openedDevice.channels)

            let blockCapacity = 512
            let ring = AudioBlockRing(
                capacity: AudioBlockRing.capacityForDuration(
                    sampleRate: openedDevice.sampleRate,
                    blockFrameCapacity: blockCapacity
                ),
                blockFrameCapacity: blockCapacity,
                sampleRate: openedDevice.sampleRate
            )
            let sink = TimestampedMonoSink(
                ring: ring,
                frameCapacity: blockCapacity,
                clock: clock,
                meter: nil
            )
            self.ring = ring
            self.sink = sink
            let converter = try CanonicalAudioResampler(sampleRate: openedDevice.sampleRate)
            let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: converter)
            self.drain = drain

            let healthStart = clock.now()
            let monitor = CaptureHealthMonitor(
                source: source,
                clock: clock,
                diskSpace: diskSpace,
                directory: directory,
                startedAt: healthStart,
                onFailure: { [weak self] message in
                    self?.scheduleTerminalFailure(message)
                },
                onWarning: { [onWarning] message in onWarning(message) },
                onDropouts: onDropouts,
                onSilenceChanged: { [onSilenceChanged] silent in onSilenceChanged(silent) }
            )
            healthMonitor = monitor

            // Take the QPC epoch immediately before creating the ingress and starting native
            // capture. The ingress is the only producer-facing object passed to the device.
            let epoch = try qpc100ns()
            let ingress = try WindowsCaptureIngress(
                sink: sink,
                sampleRate: openedDevice.sampleRate,
                channels: openedDevice.channels,
                epochQPC100ns: epoch,
                clock: clock,
                loopback: source == .systemAudio
            )
            self.ingress = ingress
            try openedDevice.start(ingress: ingress)

            launchDrainTask(drain: drain, ingress: ingress, sink: sink, ring: ring, monitor: monitor)
            try await waitForFirstBuffer(startedAt: healthStart, sink: sink, ingress: ingress)
            guard case .starting = state else {
                throw AudioCaptureEngineError.cancelled
            }
            state = .running
        } catch {
            try await finishFailedStart(error)
        }
    }

    /// Joins native capture before finishing the ring and writer. Concurrent stop and automatic
    /// failure paths share one cleanup task and therefore one power release.
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
        return await beginCleanup().value
    }

    public func committedSnapshot() async throws -> AudioCheckpoint {
        guard case .running = state, let drain else {
            throw AudioCaptureEngineError.notRecording
        }
        return try await drain.committedSnapshot()
    }

    private func waitForFirstBuffer(
        startedAt: TimeInterval,
        sink: TimestampedMonoSink,
        ingress: WindowsCaptureIngress
    ) async throws {
        while true {
            if Task.isCancelled { throw AudioCaptureEngineError.cancelled }
            switch state {
            case .starting:
                break
            case .stopping, .stopped:
                if let failure = pendingErrors.first {
                    throw WindowsCaptureAdapterError.health(failure)
                }
                throw AudioCaptureEngineError.cancelled
            case .new, .running:
                throw AudioCaptureEngineError.cancelled
            }

            let status = CaptureStartStatus.evaluate(
                startedAt: startedAt,
                now: clock.now(),
                lastBufferMillis: sink.lastBufferMillis.load(ordering: .acquiring),
                cancelled: false,
                failure: ingress.failure.map { Self.describeIngressFailure($0, ingress: ingress) }
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

    private func launchDrainTask(
        drain: AudioCaptureDrain,
        ingress: WindowsCaptureIngress,
        sink: TimestampedMonoSink,
        ring: AudioBlockRing,
        monitor: CaptureHealthMonitor
    ) {
        let clock = clock
        drainTask = Task { @MainActor [weak self, drain, ingress, sink, ring, monitor, clock] in
            while !Task.isCancelled {
                do {
                    _ = try await drain.drainAvailable()
                } catch {
                    guard let owner = self else { return }
                    if Task.isCancelled && owner.isStopping {
                        if !(error is CancellationError) {
                            owner.appendError("Audio capture drain failed: \(error.localizedDescription)")
                        }
                    } else {
                        owner.scheduleTerminalFailure(
                            "Audio capture drain failed: \(error.localizedDescription)"
                        )
                    }
                    return
                }

                if Task.isCancelled {
                    if let owner = self, !owner.isStopping {
                        owner.scheduleTerminalFailure("The Windows capture drain task was unexpectedly cancelled")
                    }
                    return
                }
                do {
                    guard let owner = self else { return }
                    if let failure = ingress.poll(now: clock.now()) {
                        owner.scheduleTerminalFailure(Self.describeIngressFailure(failure, ingress: ingress))
                        return
                    }
                    if !monitor.poll(
                        lastBufferMillis: sink.lastBufferMillis.load(ordering: .acquiring),
                        silentSinceMillis: sink.silentSinceMillis.load(ordering: .acquiring),
                        dropouts: ring.dropoutCount
                    ) {
                        return
                    }
                }

                do {
                    try await Task.sleep(nanoseconds: 20_000_000)
                } catch {
                    if let owner = self, !owner.isStopping {
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

    private var isStopping: Bool {
        switch state {
        case .stopping, .stopped: true
        case .new, .starting, .running: false
        }
    }

    private func scheduleTerminalFailure(_ message: String) {
        guard case .starting = state else {
            guard case .running = state else { return }
            appendError(message)
            if !terminalFailureNotified {
                terminalFailureNotified = true
                onFailure(message)
            }
            _ = beginCleanup()
            return
        }
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
        let needsCleanup = device != nil || powerAcquired || ring != nil || drain != nil
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

    private func beginCleanup() -> Task<WindowsCaptureStopResult, Never> {
        if let cleanupTask { return cleanupTask }
        state = .stopping
        let task = Task { @MainActor [self] in
            await performCleanup()
        }
        cleanupTask = task
        return task
    }

    private func performCleanup() async -> WindowsCaptureStopResult {
        if let device {
            do {
                try device.stopJoin()
            } catch {
                appendError("Native capture stop failed: \(Self.message(for: error))")
            }
        }
        device = nil

        if let ring {
            guard let sink else {
                preconditionFailure("Windows capture ring requires its paired timestamped sink during cleanup")
            }
            ring.finish(tailFrame: sink.lastEndFrame)
        }

        drainTask?.cancel()
        if let drainTask { await drainTask.value }
        drainTask = nil

        var checkpoint: AudioCheckpoint?
        var healthyPrefixOnly = false
        if let drain {
            do {
                checkpoint = try await drain.finish()
            } catch {
                healthyPrefixOnly = true
                appendError("Audio writer finish failed: \(Self.message(for: error))")
                checkpoint = await drain.durableCheckpoint()
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
        healthMonitor = nil
        sink = nil
        ring = nil
        drain = nil
        hasLiveCaptureOrPower = false
        state = .stopped
        return result
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
