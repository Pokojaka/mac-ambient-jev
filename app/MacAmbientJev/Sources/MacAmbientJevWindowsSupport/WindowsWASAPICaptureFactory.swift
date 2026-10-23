#if os(Windows)
import Foundation
import CMiniaudio
import MacAmbientJevCore
import WinSDK

// These diagnostic helpers run on the capture control lane, never on native packet callbacks.
private func captureCleanupMessages(
    _ errors: mja_capture_cleanup_errors,
    operation: String
) -> [String] {
    var messages: [String] = []
    if errors.stop != 0 {
        messages.append(
            WindowsCaptureAdapterError.native(
                operation: "\(operation).cleanup.stop",
                code: errors.stop
            ).localizedDescription
        )
    }
    if errors.environment != 0 {
        messages.append(
            WindowsCaptureAdapterError.native(
                operation: "\(operation).cleanup.environment",
                code: errors.environment
            ).localizedDescription
        )
    }
    if errors.context != 0 {
        messages.append(
            WindowsCaptureAdapterError.native(
                operation: "\(operation).cleanup.context",
                code: errors.context
            ).localizedDescription
        )
    }
    return messages
}

private func nativeFailureMessages(
    operation: String,
    code: Int32,
    diagnostics: [String]
) -> [String] {
    var messages: [String] = []
    if code != 0 {
        messages.append(
            WindowsCaptureAdapterError.native(operation: operation, code: code).localizedDescription
        )
    }
    messages.append(contentsOf: diagnostics)
    return uniqueFailureMessages(messages)
}

private func uniqueFailureMessages(_ messages: [String]) -> [String] {
    var uniqueMessages: [String] = []
    for message in messages where !uniqueMessages.contains(message) {
        uniqueMessages.append(message)
    }
    return uniqueMessages
}

@MainActor
public final class WindowsWASAPICaptureFactory: WindowsCaptureSourceFactory {
    public init() {}

    public func devices(source: CaptureSource) throws -> [WindowsCaptureEndpoint] {
        let collector = WindowsCaptureDeviceCollector()
        let user = Unmanaged.passUnretained(collector).toOpaque()
        let loopback: Int32 = source == .systemAudio ? 1 : 0
        let result = mja_capture_enumerate(
            loopback,
            windowsCaptureEnumerationCallback,
            user
        )
        guard result == 0 else {
            throw WindowsCaptureAdapterError.native(
                operation: "mja_capture_enumerate",
                code: result
            )
        }
        if let error = collector.validationError { throw error }
        return collector.endpoints
    }

    public func open(
        source: CaptureSource,
        device: WindowsCaptureDeviceSelection
    ) throws -> any WindowsCaptureDevice {
        let loopback: Int32 = source == .systemAudio ? 1 : 0
        let callbackHolder = WindowsCaptureCallbackHolder()
        let user = Unmanaged.passUnretained(callbackHolder).toOpaque()
        var openedCapture: OpaquePointer?
        var sampleRate: UInt32 = 0
        var channels: UInt32 = 0
        var openCleanupErrors = mja_capture_cleanup_errors(stop: 0, environment: 0, context: 0)

        let result: Int32
        switch device {
        case .systemDefault:
            result = mja_capture_open(
                loopback,
                nil,
                1,
                windowsCapturePacketCallback,
                windowsCaptureHealthCallback,
                user,
                &openedCapture,
                &sampleRate,
                &channels,
                &openCleanupErrors
            )
        case .endpointID(let endpointID):
            guard !endpointID.isEmpty, !endpointID.contains("\0") else {
                throw WindowsCaptureAdapterError.invalidConfiguration(
                    "A capture endpoint ID must be nonempty and contain no embedded NUL"
                )
            }
            result = endpointID.withCString { endpointIDPointer in
                mja_capture_open(
                    loopback,
                    endpointIDPointer,
                    0,
                    windowsCapturePacketCallback,
                    windowsCaptureHealthCallback,
                    user,
                    &openedCapture,
                    &sampleRate,
                    &channels,
                    &openCleanupErrors
                )
            }
        }

        let openFailures = nativeFailureMessages(
            operation: "mja_capture_open",
            code: result,
            diagnostics: captureCleanupMessages(openCleanupErrors, operation: "mja_capture_open")
        )
        if result != 0 {
            // C owns and frees partial-open resources before returning a failure.
            throw WindowsCaptureAdapterError.combined(openFailures)
        }
        if !openFailures.isEmpty {
            guard let openedCapture else {
                throw WindowsCaptureAdapterError.combined(openFailures)
            }
            var stopCleanupErrors = mja_capture_cleanup_errors(stop: 0, environment: 0, context: 0)
            let stopResult = mja_capture_stop_join(openedCapture, &stopCleanupErrors)
            mja_capture_destroy(openedCapture)
            let failures = uniqueFailureMessages(
                openFailures + nativeFailureMessages(
                    operation: "mja_capture_stop_join",
                    code: stopResult,
                    diagnostics: captureCleanupMessages(
                        stopCleanupErrors,
                        operation: "mja_capture_stop_join"
                    )
                )
            )
            throw WindowsCaptureAdapterError.combined(failures)
        }
        guard let openedCapture else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "mja_capture_open succeeded without returning a capture handle"
            )
        }

        guard sampleRate > 0, (1...254).contains(channels) else {
            let formatError = WindowsCaptureAdapterError.invalidConfiguration(
                "mja_capture_open returned an invalid sample rate or channel count"
            )
            var cleanupErrors = mja_capture_cleanup_errors(stop: 0, environment: 0, context: 0)
            let stopResult = mja_capture_stop_join(openedCapture, &cleanupErrors)
            mja_capture_destroy(openedCapture)
            let cleanupFailures = nativeFailureMessages(
                operation: "mja_capture_stop_join",
                code: stopResult,
                diagnostics: captureCleanupMessages(
                    cleanupErrors,
                    operation: "mja_capture_stop_join"
                )
            )
            guard cleanupFailures.isEmpty else {
                throw WindowsCaptureAdapterError.combined(
                    uniqueFailureMessages([formatError.localizedDescription] + cleanupFailures)
                )
            }
            throw formatError
        }

        return WindowsWASAPICaptureDevice(
            capture: openedCapture,
            callbackHolder: callbackHolder,
            sampleRate: Double(sampleRate),
            channels: Int(channels)
        )
    }
}

private final class WindowsCaptureDeviceCollector {
    private(set) var endpoints: [WindowsCaptureEndpoint] = []
    private(set) var validationError: WindowsCaptureAdapterError?
    private var endpointIDs = Set<String>()

    func append(id: UnsafePointer<CChar>?, name: UnsafePointer<CChar>?, isDefault: Int32) {
        guard validationError == nil else { return }
        guard let id, let name,
              let endpointID = String(validatingCString: id),
              let endpointName = String(validatingCString: name) else {
            validationError = .invalidConfiguration(
                "Native capture enumeration returned malformed UTF-8"
            )
            return
        }
        guard !endpointID.isEmpty else {
            validationError = .invalidConfiguration(
                "Native capture enumeration returned an empty endpoint ID"
            )
            return
        }
        guard isDefault == 0 || isDefault == 1 else {
            validationError = .invalidConfiguration(
                "Native capture enumeration returned an invalid default-device flag"
            )
            return
        }
        guard endpointIDs.insert(endpointID).inserted else {
            validationError = .invalidConfiguration(
                "Native capture enumeration returned a duplicate endpoint ID"
            )
            return
        }
        endpoints.append(
            WindowsCaptureEndpoint(
                id: endpointID,
                name: endpointName,
                isDefault: isDefault == 1
            )
        )
    }
}

private let windowsCaptureEnumerationCallback: mja_capture_device_fn = {
    user,
    id,
    name,
    isDefault in
    guard let user else {
        preconditionFailure("Native capture enumeration omitted its collector")
    }
    Unmanaged<WindowsCaptureDeviceCollector>
        .fromOpaque(user)
        .takeUnretainedValue()
        .append(id: id, name: name, isDefault: isDefault)
}

private final class WindowsCaptureCallbackHolder: @unchecked Sendable {
    // Lifecycle synchronization: installation precedes start and removal follows stop_join's
    // callback fence, so neither mutation overlaps native callback access. Native callbacks serialize.
    var ingress: WindowsCaptureIngress?

    func receive(_ packet: mja_capture_packet) {
        guard let ingress else {
            preconditionFailure("Native capture callback ran without an installed ingress")
        }
        ingress.receive(
            WindowsCapturePacket(
                samples: packet.samples,
                frameCount: Int(packet.frame_count),
                channels: Int(packet.channels),
                sampleRate: Double(packet.sample_rate),
                flags: packet.flags,
                devicePosition: packet.device_position,
                qpc100ns: packet.qpc_100ns,
                packetOffset: Int(packet.packet_offset),
                packetFrames: Int(packet.packet_frames)
            )
        )
    }

    func receiveHealth(watermarkQPC100ns: UInt64, outputState: Int32, error: Int32) {
        guard let ingress else {
            preconditionFailure("Native capture health callback ran without an installed ingress")
        }
        ingress.health(
            watermarkQPC100ns: watermarkQPC100ns,
            outputState: outputState,
            error: error
        )
    }
}

private let windowsCapturePacketCallback: mja_capture_packet_fn = { user, packet in
    guard let user, let packet else {
        preconditionFailure("Native capture callback omitted its context or packet")
    }
    Unmanaged<WindowsCaptureCallbackHolder>
        .fromOpaque(user)
        .takeUnretainedValue()
        .receive(packet.pointee)
}

private let windowsCaptureHealthCallback: mja_capture_health_fn = {
    user,
    watermarkQPC100ns,
    outputState,
    error in
    guard let user else {
        preconditionFailure("Native capture health callback omitted its context")
    }
    Unmanaged<WindowsCaptureCallbackHolder>
        .fromOpaque(user)
        .takeUnretainedValue()
        .receiveHealth(
            watermarkQPC100ns: watermarkQPC100ns,
            outputState: outputState,
            error: error
        )
}

@MainActor
private final class WindowsWASAPICaptureDevice: WindowsCaptureDevice {
    private var capture: OpaquePointer?
    private nonisolated(unsafe) var hasNativeCapture = true
    private let callbackHolder: WindowsCaptureCallbackHolder
    public let sampleRate: Double
    public let channels: Int

    init(
        capture: OpaquePointer,
        callbackHolder: WindowsCaptureCallbackHolder,
        sampleRate: Double,
        channels: Int
    ) {
        self.capture = capture
        self.callbackHolder = callbackHolder
        self.sampleRate = sampleRate
        self.channels = channels
    }

    func start(ingress: WindowsCaptureIngress) throws {
        guard let capture else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Cannot start a closed Windows capture device"
            )
        }
        guard callbackHolder.ingress == nil else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Windows capture ingress is already installed"
            )
        }
        callbackHolder.ingress = ingress
        let result = mja_capture_start(capture)
        guard result == 0 else {
            throw WindowsCaptureAdapterError.native(
                operation: "mja_capture_start",
                code: result
            )
        }
    }

    func stopJoin() throws {
        guard let capture else { return }
        var cleanupErrors = mja_capture_cleanup_errors(stop: 0, environment: 0, context: 0)
        let result = mja_capture_stop_join(capture, &cleanupErrors)
        let failures = nativeFailureMessages(
            operation: "mja_capture_stop_join",
            code: result,
            diagnostics: captureCleanupMessages(
                cleanupErrors,
                operation: "mja_capture_stop_join"
            )
        )
        // stop_join is the callback fence; destruction and Swift-side cleanup follow it even on errors.
        mja_capture_destroy(capture)
        self.capture = nil
        hasNativeCapture = false
        callbackHolder.ingress = nil
        guard failures.isEmpty else {
            throw WindowsCaptureAdapterError.combined(failures)
        }
    }

    deinit {
        precondition(
            !hasNativeCapture,
            "WindowsWASAPICaptureDevice requires explicit stopJoin() before deinitialization"
        )
    }
}

public enum WindowsCaptureQPCClock {
    private static let unitsPerSecond: UInt64 = 10_000_000

    /// Returns a QPC-derived 100-nanosecond epoch for recording start, never packet timestamps.
    public static func now100ns() throws -> UInt64 {
        var frequency = LARGE_INTEGER()
        guard QueryPerformanceFrequency(&frequency) else {
            let error = Int32(bitPattern: GetLastError())
            throw WindowsCaptureAdapterError.native(
                operation: "QueryPerformanceFrequency",
                code: error
            )
        }
        guard frequency.QuadPart > 0 else {
            throw WindowsCaptureAdapterError.timestamp(
                "QueryPerformanceFrequency returned a nonpositive frequency"
            )
        }

        var counter = LARGE_INTEGER()
        guard QueryPerformanceCounter(&counter) else {
            let error = Int32(bitPattern: GetLastError())
            throw WindowsCaptureAdapterError.native(
                operation: "QueryPerformanceCounter",
                code: error
            )
        }
        guard counter.QuadPart >= 0 else {
            throw WindowsCaptureAdapterError.timestamp(
                "QueryPerformanceCounter returned a negative counter"
            )
        }

        let rawCounter = UInt64(counter.QuadPart)
        let rawFrequency = UInt64(frequency.QuadPart)
        let wholeSeconds = rawCounter / rawFrequency
        let remainder = rawCounter % rawFrequency
        let (wholeUnits, wholeOverflow) = wholeSeconds.multipliedReportingOverflow(
            by: unitsPerSecond
        )
        guard !wholeOverflow else {
            throw WindowsCaptureAdapterError.timestamp(
                "QPC whole-second conversion overflowed UInt64"
            )
        }
        let (remainderUnits, remainderOverflow) = remainder.multipliedReportingOverflow(
            by: unitsPerSecond
        )
        guard !remainderOverflow else {
            throw WindowsCaptureAdapterError.timestamp(
                "QPC remainder conversion overflowed UInt64"
            )
        }
        let fractionalUnits = remainderUnits / rawFrequency
        let (timestamp, totalOverflow) = wholeUnits.addingReportingOverflow(fractionalUnits)
        guard !totalOverflow else {
            throw WindowsCaptureAdapterError.timestamp(
                "QPC timestamp conversion overflowed UInt64"
            )
        }
        return timestamp
    }
}
#endif
