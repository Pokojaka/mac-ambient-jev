import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineE2ESupport
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

@MainActor
@Suite("File capture acceptance")
struct FileCaptureAcceptanceTests {
    @Test func canonicalStereoCaptureIsDurableAndReusable() async throws {
        let root = try captureAcceptanceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fixtureURL = root.appending(path: "stereo.f32le")
        try writeStereoFixture(frameCount: 33_000, left: 0.125, right: 0.375, to: fixtureURL)
        let provider = try FileCaptureProvider(fixtureURL: fixtureURL, sampleRate: 16_000, channels: 2)
        let paths = captureAcceptancePaths(root: root)
        let callbacks = EngineCaptureCallbacks(
            onFailure: { _ in }, onWarning: { _ in }, onDropouts: { _ in },
            onSilenceChanged: { _ in }, onDeviceWaitingChanged: { _ in }, onDeviceLost: { _ in }
        )
        let device = EngineDevice.id(FileCaptureProvider.testDeviceID)

        let first = try createCaptureAcceptanceSession(paths: paths)
        let firstCapture = try await provider.startCapture(
            sessionID: first.id, sessionURL: first.url, source: .microphone,
            device: device, callbacks: callbacks
        )
        let committedBeforeStop = try await firstCapture.committedCheckpoint()
        #expect(committedBeforeStop.committedFrames > 0)
        #expect(committedBeforeStop.committedFrames < 33_000)

        let stopped = try await firstCapture.stop()
        #expect(stopped.checkpoint.committedFrames == 33_000)
        #expect(committedBeforeStop.committedFrames < stopped.checkpoint.committedFrames)
        #expect(stopped.checkpoint.gapEvents.isEmpty)
        #expect(!stopped.didOverflow)
        #expect(stopped.dropoutCount == 0)
        #expect(stopped.gapCount == 0)
        #expect(stopped.totalGapFrames == 0)
        #expect(try await firstCapture.stop() == stopped)

        let layout = SessionLayout(sessionURL: first.url)
        let reader = try ProcessingTimelineReader(
            directory: layout.processingDirectory,
            checkpoint: stopped.checkpoint,
            sessionURL: first.url
        )
        let samples = try reader.readSamples(frameRange: 0..<stopped.checkpoint.committedFrames)
        #expect(samples.count == 33_000)
        #expect(samples.allSatisfy { $0 == 0.25 })

        let second = try createCaptureAcceptanceSession(paths: paths)
        let secondCapture = try await provider.startCapture(
            sessionID: second.id, sessionURL: second.url, source: .microphone,
            device: device, callbacks: callbacks
        )
        let secondStop = try await secondCapture.stop()
        #expect(secondStop.checkpoint.committedFrames == 33_000)
        #expect(secondStop.checkpoint.gapEvents.isEmpty)
        #expect(!secondStop.didOverflow)
    }

    @Test func canonicalFinalPacketCheckpointIsPersistedBeforeStop() async throws {
        let root = try captureAcceptanceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fixtureURL = root.appending(path: "canonical.f32le")
        try writeStereoFixture(frameCount: 33_000, left: 0.125, right: 0.375, to: fixtureURL)
        let provider = try FileCaptureProvider(fixtureURL: fixtureURL, sampleRate: 16_000, channels: 2)
        let paths = captureAcceptancePaths(root: root)
        let session = try createCaptureAcceptanceSession(paths: paths)
        let callbacks = EngineCaptureCallbacks(
            onFailure: { _ in }, onWarning: { _ in }, onDropouts: { _ in },
            onSilenceChanged: { _ in }, onDeviceWaitingChanged: { _ in }, onDeviceLost: { _ in }
        )
        let capture = try await provider.startCapture(
            sessionID: session.id, sessionURL: session.url, source: .microphone,
            device: .id(FileCaptureProvider.testDeviceID), callbacks: callbacks
        )

        let committedBeforeStop = try await capture.committedCheckpoint()
        let layout = SessionLayout(sessionURL: session.url)
        let persistedCheckpoint = try #require(try AudioCheckpoint.loadRecovered(
            from: layout.processingDirectory, relativeTo: session.url
        ))
        #expect(committedBeforeStop.committedFrames == 32_768)
        #expect(committedBeforeStop.committedFrames > 0)
        #expect(committedBeforeStop.committedFrames < 33_000)
        #expect(persistedCheckpoint == committedBeforeStop)

        let stopped = try await capture.stop()
        #expect(stopped.checkpoint.committedFrames == 33_000)
        #expect(committedBeforeStop.committedFrames < stopped.checkpoint.committedFrames)
    }

    @Test func rejectsInvalidFixturesAndFormatsBeforeCapture() throws {
        let root = try captureAcceptanceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let nonfiniteURL = root.appending(path: "nonfinite.f32le")
        try writeFloat32LEFixture([0.25, .infinity], to: nonfiniteURL)
        #expect(throws: FileCaptureError.invalidSample(frame: 1, channel: 0)) {
            _ = try FileCaptureProvider(fixtureURL: nonfiniteURL, sampleRate: 16_000, channels: 1)
        }

        let malformedURL = root.appending(path: "malformed-interleaved.f32le")
        try writeFloat32LEFixture([0.25], to: malformedURL)
        #expect(throws: FileCaptureError.invalidFrameLength) {
            _ = try FileCaptureProvider(fixtureURL: malformedURL, sampleRate: 16_000, channels: 2)
        }

        let validURL = root.appending(path: "valid.f32le")
        try writeFloat32LEFixture([0.125, 0.375], to: validURL)
        #expect(throws: FileCaptureError.unsupportedSampleRate(32_000)) {
            _ = try FileCaptureProvider(fixtureURL: validURL, sampleRate: 32_000, channels: 2)
        }
        #expect(throws: FileCaptureError.unsupportedChannelCount(9)) {
            _ = try FileCaptureProvider(fixtureURL: validURL, sampleRate: 16_000, channels: 9)
        }

        let missingURL = root.appending(path: "missing.f32le")
        #expect(throws: FileCaptureError.unreadableFile) {
            _ = try FileCaptureProvider(fixtureURL: missingURL, sampleRate: 16_000, channels: 1)
        }

        let symlinkURL = root.appending(path: "fixture-link.f32le")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: validURL)
        #expect(throws: FileCaptureError.symbolicLink) {
            _ = try FileCaptureProvider(fixtureURL: symlinkURL, sampleRate: 16_000, channels: 2)
        }
    }
}

private func captureAcceptanceRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "file-capture-acceptance-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

private func captureAcceptancePaths(root: URL) -> AppPaths {
    AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: root.appending(path: "sessions", directoryHint: .isDirectory)
    )
}

private func createCaptureAcceptanceSession(paths: AppPaths) throws -> (id: UUID, url: URL) {
    let id = UUID()
    let url = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths,
        sessionID: id,
        source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        timeZone: TimeZone(secondsFromGMT: 0)!
    )
    return (id, url)
}

private func writeStereoFixture(frameCount: Int, left: Float, right: Float, to url: URL) throws {
    var data = Data()
    data.reserveCapacity(frameCount * 2 * MemoryLayout<UInt32>.size)
    for _ in 0..<frameCount {
        appendFloat32LE(left, to: &data)
        appendFloat32LE(right, to: &data)
    }
    try data.write(to: url)
}

private func writeFloat32LEFixture(_ samples: [Float], to url: URL) throws {
    var data = Data()
    data.reserveCapacity(samples.count * MemoryLayout<UInt32>.size)
    for sample in samples { appendFloat32LE(sample, to: &data) }
    try data.write(to: url)
}

private func appendFloat32LE(_ sample: Float, to data: inout Data) {
    let bits = sample.bitPattern
    data.append(UInt8(truncatingIfNeeded: bits))
    data.append(UInt8(truncatingIfNeeded: bits >> 8))
    data.append(UInt8(truncatingIfNeeded: bits >> 16))
    data.append(UInt8(truncatingIfNeeded: bits >> 24))
}
