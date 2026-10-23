import Foundation
import Synchronization
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
#if os(Windows)
import MacAmbientJevWindowsSupport
#elseif os(macOS)
import MacAmbientJevAppleSupport
#elseif os(Linux)
#else
#error("FileCaptureProvider requires macOS, Windows, or Linux")
#endif

enum FileCaptureError: LocalizedError, Equatable {
    case invalidFixtureURL
    case symbolicLink
    case notRegularFile
    case unreadableFile
    case emptyFixture
    case invalidFrameLength
    case unsupportedSampleRate(Double)
    case unsupportedChannelCount(Int)
    case linuxResamplingUnavailable(Double)
    case invalidSample(frame: Int64, channel: Int)
    case fixtureChanged
    case invalidDevice
    case captureAlreadyActive
    case cleanupFailed(primary: String, cleanup: [String])

    var errorDescription: String? {
        switch self {
        case .invalidFixtureURL:
            "The capture fixture URL must identify a local file"
        case .symbolicLink:
            "The capture fixture must not be a symbolic link"
        case .notRegularFile:
            "The capture fixture must be a regular file"
        case .unreadableFile:
            "The capture fixture is not readable"
        case .emptyFixture:
            "The capture fixture must not be empty"
        case .invalidFrameLength:
            "The capture fixture byte length must contain whole interleaved Float32 frames"
        case .unsupportedSampleRate(let rate):
            "The capture fixture sample rate is unsupported: \(rate)"
        case .unsupportedChannelCount(let channels):
            "The capture fixture channel count must be between 1 and 8: \(channels)"
        case .linuxResamplingUnavailable(let rate):
            "Linux file capture supports only canonical 16000 Hz fixtures; received \(rate) Hz"
        case .invalidSample(let frame, let channel):
            "The capture fixture contains a non-finite Float32 sample at frame \(frame), channel \(channel)"
        case .fixtureChanged:
            "The capture fixture changed or ended unexpectedly while being read"
        case .invalidDevice:
            "The requested device is not the file-capture test endpoint"
        case .captureAlreadyActive:
            "This file-capture provider already has an active capture"
        case .cleanupFailed(let primary, let cleanup):
            "File capture failed: \(primary). Cleanup also failed: \(cleanup.joined(separator: "; "))"
        }
    }
}

private struct FileCaptureStartupCleanupError: LocalizedError {
    let primary: String
    let cleanupFailures: [String]

    var errorDescription: String? {
        guard !cleanupFailures.isEmpty else { return primary }
        return "File capture startup failed: \(primary). Cleanup also failed: \(cleanupFailures.joined(separator: "; "))"
    }
}

/// Deterministic file-backed capture for engine end-to-end tests.
/// The fixture format is interleaved little-endian Float32 at `sampleRate`.
@MainActor
public final class FileCaptureProvider: EngineCaptureProviding {
    public static let testDeviceID = "file-capture-fixture"
    public static let testDeviceName = "File capture fixture"

    public let expectedSourceFrames: Int64

    private let fixtureURL: URL
    private let sampleRate: Double
    private let channelCount: Int
    private var isStarting = false
    private var activeSession: FileCaptureSession?

    public init(fixtureURL: URL, sampleRate: Double, channels: Int) throws {
        guard [16_000.0, 44_100.0, 48_000.0].contains(sampleRate) else {
            throw FileCaptureError.unsupportedSampleRate(sampleRate)
        }
        guard (1...8).contains(channels) else {
            throw FileCaptureError.unsupportedChannelCount(channels)
        }
        #if os(Linux)
        guard sampleRate == CanonicalAudio.sampleRate else {
            throw FileCaptureError.linuxResamplingUnavailable(sampleRate)
        }
        #endif

        self.fixtureURL = fixtureURL
        self.sampleRate = sampleRate
        self.channelCount = channels
        expectedSourceFrames = try Self.validateFixture(at: fixtureURL, channels: channels)
    }

    public func devices(source: EngineSource) throws -> EngineDevicesResult {
        let device = try EngineDeviceInfo(
            id: Self.testDeviceID, name: Self.testDeviceName, isDefault: true
        )
        return try EngineDevicesResult(
            source: source, devices: [device], defaultDeviceID: Self.testDeviceID
        )
    }

    public func startCapture(
        sessionID _: UUID,
        sessionURL: URL,
        source _: EngineSource,
        device: EngineDevice,
        callbacks _: EngineCaptureCallbacks
    ) async throws -> any EngineCaptureSession {
        guard !isStarting, activeSession == nil else {
            throw FileCaptureError.captureAlreadyActive
        }
        switch device {
        case .default:
            break
        case .id(let id):
            guard id == Self.testDeviceID else { throw FileCaptureError.invalidDevice }
        }

        isStarting = true
        defer { isStarting = false }

        var openedHandle: FileHandle?
        var writer: DurableAudioWriter?
        var ring: AudioBlockRing?
        var sink: TimestampedMonoSink?
        var drain: AudioCaptureDrain?

        do {
            let handle = try FileHandle(forReadingFrom: fixtureURL)
            openedHandle = handle

            let createdWriter = try DurableAudioWriter(
                directory: SessionLayout(sessionURL: sessionURL).processingDirectory,
                chunkDurationSeconds: 0.5,
                sessionURL: sessionURL
            )
            writer = createdWriter

            let converter = try Self.makeConverter(sampleRate: sampleRate)
            let createdRing = AudioBlockRing(
                capacity: AudioBlockRing.capacityForDuration(
                    sampleRate: sampleRate, blockFrameCapacity: 512
                ),
                blockFrameCapacity: 512,
                sampleRate: sampleRate
            )
            ring = createdRing
            let clock = VirtualFrameCaptureClock(sampleRate: sampleRate)
            let createdSink = TimestampedMonoSink(
                ring: createdRing, frameCapacity: 512, clock: clock, meter: nil
            )
            sink = createdSink
            let createdDrain = AudioCaptureDrain(
                ring: createdRing, writer: createdWriter, converter: converter
            )
            drain = createdDrain

            var sourceFrame: Int64 = 0
            while sourceFrame < expectedSourceFrames {
                let packetFrameCount = Int(min(512, expectedSourceFrames - sourceFrame))
                let packetByteCount = packetFrameCount * channelCount * MemoryLayout<UInt32>.size
                let bytes = try Self.readExactly(handle, byteCount: packetByteCount)
                let samples = try Self.decode(
                    bytes, frameCount: packetFrameCount, channels: channelCount,
                    firstFrame: sourceFrame
                )
                let remainingFrames = expectedSourceFrames - sourceFrame
                if sourceFrame > 0, remainingFrames <= 512 {
                    // The previous packet was drained above. Persist the writer's real checkpoint
                    // before delivering the final packet, leaving that packet's tail for stop().
                    _ = try await createdWriter.checkpoint()
                }
                let (nextSourceFrame, overflow) = sourceFrame.addingReportingOverflow(Int64(packetFrameCount))
                guard !overflow else { throw FileCaptureError.fixtureChanged }
                clock.advance(to: nextSourceFrame)
                try Self.deliver(
                    samples, frameCount: packetFrameCount, channels: channelCount,
                    startFrame: sourceFrame, to: createdSink
                )
                sourceFrame = nextSourceFrame
                // Each bounded packet is fully drained before the next producer write.
                try await createdDrain.drainAvailable()
            }

            try Self.requireEndOfFile(handle)
            try handle.close()
            openedHandle = nil

            let session = FileCaptureSession(
                ring: createdRing, sink: createdSink, drain: createdDrain,
                onStopped: { [weak self] in self?.activeSession = nil }
            )
            activeSession = session
            // The finite fixture is completely streamed before start returns. Keep the ring and
            // writer open until stop: the explicit checkpoint before the final packet is durable,
            // while that packet's tail remains uncommitted until stop().
            return session
        } catch {
            let primaryError = error
            var cleanupFailures: [String] = []

            if let openedHandle {
                do {
                    try openedHandle.close()
                } catch {
                    cleanupFailures.append("closing fixture: \(error)")
                }
            }

            if let ring, let sink, let drain {
                ring.finish(tailFrame: sink.lastEndFrame)
                do {
                    _ = try await drain.finish()
                } catch {
                    cleanupFailures.append("finishing capture drain: \(error)")
                    if let writer {
                        do {
                            _ = try await writer.finish()
                        } catch {
                            cleanupFailures.append("finishing durable writer: \(error)")
                        }
                    }
                }
            } else if let writer {
                do {
                    _ = try await writer.finish()
                } catch {
                    cleanupFailures.append("finishing durable writer: \(error)")
                }
            }

            if cleanupFailures.isEmpty { throw primaryError }
            throw FileCaptureStartupCleanupError(
                primary: String(describing: primaryError), cleanupFailures: cleanupFailures
            )
        }
    }

    private static func validateFixture(at url: URL, channels: Int) throws -> Int64 {
        guard url.isFileURL else { throw FileCaptureError.invalidFixtureURL }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileCaptureError.unreadableFile
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink == false else { throw FileCaptureError.symbolicLink }
        guard values.isRegularFile == true else { throw FileCaptureError.notRegularFile }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw FileCaptureError.unreadableFile
        }
        guard let fileSize = values.fileSize, fileSize > 0 else {
            throw FileCaptureError.emptyFixture
        }

        let bytesPerFrame = channels * MemoryLayout<UInt32>.size
        guard fileSize % bytesPerFrame == 0 else { throw FileCaptureError.invalidFrameLength }
        let frameCount = fileSize / bytesPerFrame
        guard let expectedFrames = Int64(exactly: frameCount), expectedFrames > 0 else {
            throw FileCaptureError.invalidFrameLength
        }

        let handle = try FileHandle(forReadingFrom: url)
        do {
            var firstFrame: Int64 = 0
            while firstFrame < expectedFrames {
                let count = Int(min(512, expectedFrames - firstFrame))
                let byteCount = count * bytesPerFrame
                let packet = try readExactly(handle, byteCount: byteCount)
                try validateFiniteSamples(
                    packet, frameCount: count, channels: channels, firstFrame: firstFrame
                )
                firstFrame += Int64(count)
            }
            try requireEndOfFile(handle)
            try handle.close()
        } catch {
            let primaryError = error
            do {
                try handle.close()
            } catch {
                throw FileCaptureError.cleanupFailed(
                    primary: String(describing: primaryError),
                    cleanup: ["closing fixture after validation: \(error)"]
                )
            }
            throw primaryError
        }
        return expectedFrames
    }

    private static func readExactly(_ handle: FileHandle, byteCount: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(byteCount)
        while result.count < byteCount {
            guard let next = try handle.read(upToCount: byteCount - result.count), !next.isEmpty else {
                throw FileCaptureError.fixtureChanged
            }
            result.append(next)
        }
        return result
    }

    private static func requireEndOfFile(_ handle: FileHandle) throws {
        guard let trailingBytes = try handle.read(upToCount: 1) else { return }
        guard trailingBytes.isEmpty else { throw FileCaptureError.fixtureChanged }
    }

    private static func validateFiniteSamples(
        _ bytes: Data, frameCount: Int, channels: Int, firstFrame: Int64
    ) throws {
        for frame in 0..<frameCount {
            for channel in 0..<channels {
                let sampleIndex = frame * channels + channel
                let byteOffset = sampleIndex * MemoryLayout<UInt32>.size
                let sample = Float(bitPattern: littleEndianUInt32(in: bytes, at: byteOffset))
                guard sample.isFinite else {
                    throw FileCaptureError.invalidSample(
                        frame: firstFrame + Int64(frame), channel: channel
                    )
                }
            }
        }
    }

    private static func decode(
        _ bytes: Data, frameCount: Int, channels: Int, firstFrame: Int64
    ) throws -> [Float] {
        try validateFiniteSamples(bytes, frameCount: frameCount, channels: channels, firstFrame: firstFrame)
        let sampleCount = frameCount * channels
        return (0..<sampleCount).map { index in
            Float(bitPattern: littleEndianUInt32(in: bytes, at: index * MemoryLayout<UInt32>.size))
        }
    }

    private static func littleEndianUInt32(in bytes: Data, at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func deliver(
        _ samples: [Float], frameCount: Int, channels: Int, startFrame: Int64,
        to sink: TimestampedMonoSink
    ) throws {
        try samples.withUnsafeBufferPointer { sampleBuffer in
            guard let baseAddress = sampleBuffer.baseAddress else {
                throw FileCaptureError.fixtureChanged
            }
            let channelPointers = (0..<channels).map { baseAddress.advanced(by: $0) }
            let strides = [Int](repeating: channels, count: channels)
            try channelPointers.withUnsafeBufferPointer { pointerBuffer in
                guard let pointerAddress = pointerBuffer.baseAddress else {
                    throw FileCaptureError.fixtureChanged
                }
                try strides.withUnsafeBufferPointer { strideBuffer in
                    guard let strideAddress = strideBuffer.baseAddress else {
                        throw FileCaptureError.fixtureChanged
                    }
                    sink.receive(
                        channels: pointerAddress, strides: strideAddress,
                        channelCount: channels, frameCount: frameCount, startFrame: startFrame
                    )
                }
            }
        }
    }

    private static func makeConverter(sampleRate: Double) throws -> any CanonicalAudioConverting {
        #if os(Windows)
        return try MacAmbientJevWindowsSupport.CanonicalAudioResampler(sampleRate: sampleRate)
        #elseif os(macOS)
        return try MacAmbientJevAppleSupport.CanonicalAudioResampler(sampleRate: sampleRate)
        #elseif os(Linux)
        guard sampleRate == CanonicalAudio.sampleRate else {
            throw FileCaptureError.linuxResamplingUnavailable(sampleRate)
        }
        return try LinuxCanonicalIdentityConverter(sampleRate: sampleRate)
        #endif
    }
}

private final class VirtualFrameCaptureClock: CaptureClock, @unchecked Sendable {
    private let sampleRate: Double
    private let frame = Atomic<Int64>(0)

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func advance(to frame: Int64) {
        self.frame.store(frame, ordering: .releasing)
    }

    func now() -> TimeInterval {
        Double(frame.load(ordering: .acquiring)) / sampleRate
    }
}

#if os(Linux)
/// Linux deliberately has no substitute resampler: this accepts canonical identity input only.
private final class LinuxCanonicalIdentityConverter: CanonicalAudioConverting, @unchecked Sendable {
    let sourceSampleRate: Double
    private var sourceFrames: Int64 = 0
    private var isFinished = false

    init(sampleRate: Double) throws {
        guard sampleRate == CanonicalAudio.sampleRate else {
            throw FileCaptureError.linuxResamplingUnavailable(sampleRate)
        }
        sourceSampleRate = sampleRate
    }

    func convert(mono: [Float]) throws -> [Float] {
        guard !isFinished else { throw CanonicalAudioError.alreadyFinished }
        guard mono.allSatisfy(\.isFinite) else { throw CanonicalAudioError.invalidSamples }
        let (nextFrames, overflow) = sourceFrames.addingReportingOverflow(Int64(mono.count))
        guard !overflow else { throw CanonicalAudioError.invalidSamples }
        sourceFrames = nextFrames
        return mono
    }

    func finish() throws -> [Float] {
        guard !isFinished else { throw CanonicalAudioError.alreadyFinished }
        isFinished = true
        return []
    }
}
#endif

@MainActor
private final class FileCaptureSession: EngineCaptureSession {
    private let ring: AudioBlockRing
    private let sink: TimestampedMonoSink
    private let drain: AudioCaptureDrain
    private let onStopped: @MainActor () -> Void
    private var savedStopResult: AudioCaptureStopResult?
    private var stoppingTask: Task<AudioCaptureStopResult, any Error>?

    init(
        ring: AudioBlockRing, sink: TimestampedMonoSink, drain: AudioCaptureDrain,
        onStopped: @escaping @MainActor () -> Void
    ) {
        self.ring = ring
        self.sink = sink
        self.drain = drain
        self.onStopped = onStopped
    }

    func committedCheckpoint() async throws -> AudioCheckpoint {
        try await drain.committedSnapshot()
    }

    func stop() async throws -> AudioCaptureStopResult {
        if let savedStopResult { return savedStopResult }
        if let stoppingTask { return try await stoppingTask.value }

        // startCapture has already completed the sole producer before exposing this session.
        let task = Task { @MainActor [self] in
            ring.finish(tailFrame: sink.lastEndFrame)
            let checkpoint = try await drain.finish()
            let gaps = await drain.gapStatistics()
            return AudioCaptureStopResult(
                checkpoint: checkpoint,
                didOverflow: ring.overflowCount > 0,
                dropoutCount: ring.dropoutCount,
                gapCount: gaps.count,
                totalGapFrames: gaps.frames,
                sleepAssertionHeld: false,
                writerFailure: nil,
                systemAudioReleaseFailure: nil
            )
        }
        stoppingTask = task
        let result = try await task.value
        savedStopResult = result
        stoppingTask = nil
        onStopped()
        return result
    }
}
