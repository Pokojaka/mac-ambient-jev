import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
import MacAmbientJevTestSupport
import MacAmbientJevWindowsSupport
@testable import MacAmbientJevEngine

@Suite(.timeLimit(.minutes(10))) @MainActor struct WindowsEngineCaptureTests {
    @Test func forwardsIngressDropoutsWhileCaptureIsActive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WindowsEngineCapture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
            let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            precondition(resolvedRoot.deletingLastPathComponent() == temporaryDirectory)
            precondition(resolvedRoot.lastPathComponent.hasPrefix("WindowsEngineCapture-"))
            try? FileManager.default.removeItem(at: resolvedRoot)
        }

        let paths = AppPaths(
            applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
            cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
            sessionsRootOverride: root.appending(path: "sessions", directoryHint: .isDirectory)
        )
        let sessionID = UUID()
        let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
            paths: paths,
            sessionID: sessionID,
            source: .recording(.microphone),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let device = WindowsEngineCaptureTestDevice()
        let factory = WindowsEngineCaptureTestFactory(device: device)
        let engine = WindowsEngineCapture(
            factory: factory,
            clock: WindowsEngineCaptureTestClock(),
            qpc100ns: { 10_000_000 },
            automaticPolling: false
        )
        let callbackProbe = WindowsEngineCaptureDropoutProbe()
        let callbacks = EngineCaptureCallbacks(
            onFailure: { _ in },
            onWarning: { _ in },
            onDropouts: { callbackProbe.record($0) },
            onSilenceChanged: { _ in },
            onDeviceWaitingChanged: { _ in },
            onDeviceLost: { _ in }
        )
        let capture = try await engine.startCapture(
            sessionID: sessionID,
            sessionURL: sessionURL,
            source: .microphone,
            device: .default,
            callbacks: callbacks
        )

        do {
            device.sendKnownMissingPacket()
            let session = try #require(capture as? WindowsEngineCaptureSession)
            await session.capture.poll()
            try await callbackProbe.changes.wait("Windows capture dropout callback") {
                callbackProbe.counts.contains { $0 > 0 }
            }
            #expect(callbackProbe.counts.contains { $0 > 0 })
            _ = try await capture.committedCheckpoint()
        } catch {
            _ = try? await capture.stop()
            throw error
        }

        let result = try await capture.stop()
        #expect(result.dropoutCount > 0)
        #expect(!result.checkpoint.gapEvents.isEmpty)
    }

    @Test func didOverflowReflectsAnyCheckpointGap() throws {
        let overflow = try WindowsEngineCaptureSession.stopResult(
            WindowsCaptureStopResult(
                checkpoint: checkpoint(gaps: [gap(.overflow, frames: 7)]),
                healthyPrefixOnly: false,
                errors: []
            )
        )
        let missingCallback = try WindowsEngineCaptureSession.stopResult(
            WindowsCaptureStopResult(
                checkpoint: checkpoint(gaps: [gap(.missingCallback, frames: 11)]),
                healthyPrefixOnly: false,
                errors: []
            )
        )
        let noGap = try WindowsEngineCaptureSession.stopResult(
            WindowsCaptureStopResult(
                checkpoint: checkpoint(gaps: []),
                healthyPrefixOnly: false,
                errors: []
            )
        )

        #expect(overflow.didOverflow)
        #expect(missingCallback.didOverflow)
        #expect(!noGap.didOverflow)
    }

    @Test func healthyPrefixMapsWriterDiagnosticsAndCheckpointStatistics() throws {
        let checkpoint = checkpoint(gaps: [
            gap(.overflow, frames: 7),
            gap(.missingCallback, frames: 11)
        ])
        let result = try WindowsEngineCaptureSession.stopResult(
            WindowsCaptureStopResult(
                checkpoint: checkpoint,
                healthyPrefixOnly: true,
                errors: ["writer append failed", "writer finish failed"]
            )
        )

        #expect(result.checkpoint == checkpoint)
        #expect(result.didOverflow)
        #expect(result.dropoutCount == 2)
        #expect(result.gapCount == 2)
        #expect(result.totalGapFrames == 18)
        #expect(!result.sleepAssertionHeld)
        #expect(result.writerFailure == "writer append failed; writer finish failed")
        #expect(result.systemAudioReleaseFailure == nil)
    }

    @Test func healthyPrefixWithoutErrorsIsRejectedAsCaptureFailure() {
        do {
            _ = try WindowsEngineCaptureSession.stopResult(
                WindowsCaptureStopResult(
                    checkpoint: checkpoint(gaps: []),
                    healthyPrefixOnly: true,
                    errors: []
                )
            )
            Issue.record("Expected a healthy-prefix result without diagnostics to fail")
        } catch let error as EngineAdapterError {
            #expect(error.code == .captureFailure)
            #expect(error.details.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func checkpointAbsenceIsRejectedWithStopErrorDetails() {
        do {
            _ = try WindowsEngineCaptureSession.stopResult(
                WindowsCaptureStopResult(
                    checkpoint: nil,
                    healthyPrefixOnly: false,
                    errors: ["native stop failed"]
                )
            )
            Issue.record("Expected a missing checkpoint to fail")
        } catch let error as EngineAdapterError {
            #expect(error.code == .captureFailure)
            #expect(error.details.map(\.message) == ["native stop failed"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func cleanupErrorDetailsRemainAvailable() throws {
        let result = try WindowsEngineCaptureSession.stopResult(
            WindowsCaptureStopResult(
                checkpoint: checkpoint(gaps: []),
                healthyPrefixOnly: false,
                errors: ["capture device release failed"]
            )
        )

        #expect(result.writerFailure == nil)
        #expect(result.systemAudioReleaseFailure == "capture device release failed")
    }
}

private func checkpoint(gaps: [AudioGapEvent]) -> AudioCheckpoint {
    AudioCheckpoint(
        committedFrames: 48_000,
        sampleRate: 16_000,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["00000000.caf"],
        chunkFrameCounts: [48_000],
        gapEvents: gaps
    )
}

private func gap(_ reason: AudioGapReason, frames: Int64) -> AudioGapEvent {
    AudioGapEvent(startFrame: 0, frameCount: frames, reason: reason)
}

@MainActor
private final class WindowsEngineCaptureDropoutProbe {
    let changes = ChangeSignal()
    private(set) var counts: [UInt64] = []

    func record(_ count: UInt64) {
        counts.append(count)
        changes.signal()
    }
}

private struct WindowsEngineCaptureTestClock: CaptureClock {
    func now() -> TimeInterval { 100 }
}

@MainActor
private final class WindowsEngineCaptureTestDevice: WindowsCaptureDevice {
    private static let packetFrameCount = 512
    private static let knownMissingPacketFlag: UInt32 = 8
    private static let qpcUnitsPerSecond: UInt64 = 10_000_000

    let endpointID = "engine-test-endpoint"
    let sampleRate = 16_000.0
    let channels = 1
    private var ingress: WindowsCaptureIngress?
    private var firstPacketQPC100ns: UInt64?
    private var isFenced = false

    func start(ingress: WindowsCaptureIngress) throws {
        guard self.ingress == nil, !isFenced else {
            throw WindowsCaptureAdapterError.invalidConfiguration("test capture device started more than once")
        }
        let qpc: UInt64 = 10_000_000
        firstPacketQPC100ns = qpc
        self.ingress = ingress
        let samples = [Float](repeating: 0.25, count: Self.packetFrameCount)
        samples.withUnsafeBufferPointer { buffer in
            ingress.receive(WindowsCapturePacket(
                samples: UnsafePointer(buffer.baseAddress!),
                frameCount: buffer.count,
                channels: channels,
                sampleRate: sampleRate,
                flags: 0,
                devicePosition: 0,
                qpc100ns: qpc,
                packetOffset: 0,
                packetFrames: buffer.count
            ))
        }
    }

    func sendKnownMissingPacket() {
        guard !isFenced, let ingress, let firstPacketQPC100ns else {
            preconditionFailure("test capture device must be running before emitting a gap")
        }
        let delta = UInt64(
            (Double(Self.packetFrameCount) * Double(Self.qpcUnitsPerSecond) / sampleRate).rounded()
        )
        let (qpc, overflow) = firstPacketQPC100ns.addingReportingOverflow(delta)
        precondition(!overflow, "test packet QPC must not overflow")
        ingress.receive(WindowsCapturePacket(
            samples: nil,
            frameCount: Self.packetFrameCount,
            channels: channels,
            sampleRate: sampleRate,
            flags: Self.knownMissingPacketFlag,
            devicePosition: UInt64(Self.packetFrameCount),
            qpc100ns: qpc,
            packetOffset: 0,
            packetFrames: Self.packetFrameCount
        ))
    }

    func stopJoin() throws {
        isFenced = true
        ingress = nil
    }
}

@MainActor
private final class WindowsEngineCaptureTestFactory: WindowsCaptureSourceFactory {
    let device: WindowsEngineCaptureTestDevice

    init(device: WindowsEngineCaptureTestDevice) {
        self.device = device
    }

    func open(source _: CaptureSource, device _: WindowsCaptureDeviceSelection) throws -> any WindowsCaptureDevice {
        device
    }

    func devices(source _: CaptureSource) throws -> [WindowsCaptureEndpoint] {
        [WindowsCaptureEndpoint(id: device.endpointID, name: "Engine test endpoint", isDefault: true)]
    }
}
