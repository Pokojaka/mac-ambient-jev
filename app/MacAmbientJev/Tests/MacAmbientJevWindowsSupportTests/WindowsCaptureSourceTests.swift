import Foundation
import Testing
@testable import MacAmbientJevWindowsSupport
import MacAmbientJevCore
import MacAmbientJevPipeline

@MainActor
struct WindowsCaptureSourceTests {
    @Test func fileBackedMultichannelCaptureCommitsCanonicalFramesAndDownmix() async throws {
        for (sampleRate, channels, sourceFrames, channelValues) in [
            (44_100.0, 3, 44_101, [Float(0.2), 0.4, 0.6]),
            (48_000.0, 2, 48_017, [Float(0.25), 0.75])
        ] {
            let root = try makeWindowsCaptureTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = root.appending(path: "input-\(Int(sampleRate)).f32le")
            let interleaved = (0..<sourceFrames).flatMap { _ in channelValues }
            try writeScriptedFloatFixture(interleaved, to: fixture)
            let events = scriptedPacketFragments(
                file: fixture,
                sourceFrames: sourceFrames,
                devicePosition: 0,
                qpc100ns: 10_000_000
            )
            let probe = ScriptedCaptureProbe()
            let harness = try makeWindowsCaptureTestSource(
                root: root,
                source: .microphone,
                sampleRate: sampleRate,
                channels: channels,
                events: events,
                probe: probe
            )

            try await harness.source.start()
            let fakeDevice = try #require(harness.factory.openedDevice)
            for _ in 1..<events.count { try await fakeDevice.step() }
            let result = await harness.source.stop()
            let checkpoint = try #require(result.checkpoint)
            let expectedFrames = try CanonicalAudio.boundary(Int64(sourceFrames), sampleRate: sampleRate)
            let audio = try checkpoint.chunkFiles.flatMap {
                try readFloat32LEFile(root.appending(path: "audio").appending(path: $0))
            }
            let expectedMean = channelValues.reduce(Float.zero, +) / Float(channels)
            let interior = audio.dropFirst(256).dropLast(256)

            #expect(checkpoint.committedFrames == expectedFrames)
            #expect(Int64(audio.count) == expectedFrames)
            #expect(checkpoint.chunkFrameCounts.reduce(0, +) == audio.count)
            #expect(interior.count > 1_000)
            #expect(interior.allSatisfy { abs($0 - expectedMean) < 0.002 })
            #expect(result.errors.isEmpty)
            #expect(!result.healthyPrefixOnly)
        }
    }

    @Test func knownMissingExtentAndTrustedRestartPersistDurableGaps() async throws {
        let root = try makeWindowsCaptureTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFixture = root.appending(path: "first.f32le")
        let gapFixture = root.appending(path: "missing.f32le")
        let restartFixture = root.appending(path: "restart.f32le")
        try writeScriptedFloatFixture([Float](repeating: 0.25, count: 512), to: firstFixture)
        try writeScriptedFloatFixture([Float](repeating: 0, count: 128), to: gapFixture)
        try writeScriptedFloatFixture([Float](repeating: -0.25, count: 512), to: restartFixture)
        let rate = 48_000.0
        let events: [ScriptedFileCaptureEvent] = [
            .packet(
                file: firstFixture, frameCount: 512, devicePosition: 0,
                qpc100ns: 10_000_000, flags: 0, originalOffset: 0,
                originalFrames: 512, delivery: .step
            ),
            .packet(
                file: gapFixture, frameCount: 128, devicePosition: 512,
                qpc100ns: scriptedQPC(frame: 512, sampleRate: rate), flags: 8,
                originalOffset: 0, originalFrames: 128, delivery: .step
            ),
            .packet(
                file: restartFixture, frameCount: 512, devicePosition: 0,
                qpc100ns: scriptedQPC(frame: 1_024, sampleRate: rate), flags: 1,
                originalOffset: 0, originalFrames: 512, delivery: .step
            )
        ]
        let probe = ScriptedCaptureProbe()
        let harness = try makeWindowsCaptureTestSource(
            root: root,
            source: .microphone,
            sampleRate: rate,
            channels: 1,
            events: events,
            probe: probe
        )

        try await harness.source.start()
        let device = try #require(harness.factory.openedDevice)
        try await device.step()
        try await device.step()
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)

        #expect(checkpoint.committedFrames == 512)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 171, frameCount: 42, reason: .invalidBuffer),
            AudioGapEvent(startFrame: 213, frameCount: 128, reason: .missingCallback)
        ])
        #expect(result.errors.isEmpty)
    }

    @Test func idleLoopbackAndSilentPacketsPersistSilenceWithoutDropouts() async throws {
        let root = try makeWindowsCaptureTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let silenceFixture = root.appending(path: "silent-packet.f32le")
        try writeScriptedFloatFixture([Float](repeating: 0, count: 512), to: silenceFixture)
        let rate = 48_000.0
        let events: [ScriptedFileCaptureEvent] = [
            .heartbeat(
                watermarkQPC100ns: scriptedQPC(frame: 512, sampleRate: rate),
                outputState: 0, error: 0
            ),
            .packet(
                file: silenceFixture, frameCount: 512, devicePosition: 512,
                qpc100ns: scriptedQPC(frame: 512, sampleRate: rate), flags: 2,
                originalOffset: 0, originalFrames: 512, delivery: .step
            ),
            .heartbeat(
                watermarkQPC100ns: scriptedQPC(frame: 1_024, sampleRate: rate),
                outputState: 0, error: 0
            )
        ]
        let probe = ScriptedCaptureProbe()
        let harness = try makeWindowsCaptureTestSource(
            root: root,
            source: .systemAudio,
            sampleRate: rate,
            channels: 1,
            events: events,
            probe: probe
        )

        try await harness.source.start()
        let device = try #require(harness.factory.openedDevice)
        try await device.step()
        try await device.step()
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let audio = try checkpoint.chunkFiles.flatMap {
            try readFloat32LEFile(root.appending(path: "audio").appending(path: $0))
        }

        #expect(checkpoint.committedFrames == 341)
        #expect(audio.count == 341)
        #expect(audio.allSatisfy { $0 == 0 })
        #expect(checkpoint.gapEvents.isEmpty)
        #expect(result.errors.isEmpty)
    }

    @Test func unknownLoopbackHealthStopsAndRetainsDurableAudio() async throws {
        let root = try makeWindowsCaptureTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appending(path: "known-audio.f32le")
        try writeScriptedFloatFixture([Float](repeating: 0.125, count: 512), to: fixture)
        let events: [ScriptedFileCaptureEvent] = scriptedPacketFragments(
            file: fixture,
            sourceFrames: 512,
            devicePosition: 0,
            qpc100ns: 10_000_000
        ) + [
            .heartbeat(watermarkQPC100ns: 10_000_000, outputState: 2, error: 0)
        ]
        let probe = ScriptedCaptureProbe()
        let harness = try makeWindowsCaptureTestSource(
            root: root,
            source: .systemAudio,
            sampleRate: 48_000,
            channels: 1,
            events: events,
            probe: probe
        )

        try await harness.source.start()
        let device = try #require(harness.factory.openedDevice)
        try await device.step()
        await waitForWindowsCaptureTestCondition {
            harness.source.lastStopResult != nil
        }
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)

        #expect(checkpoint.committedFrames == 171)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.contains { $0.contains("unknown output state") })
        #expect(probe.stopJoinCalls.load(ordering: .relaxed) == 1)
    }

    @Test func stopJoinIncludesFinalPacketFencesEvenOnFailureAndStopsIdempotently() async throws {
        let root = try makeWindowsCaptureTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appending(path: "final-packet.f32le")
        try writeScriptedFloatFixture([Float](repeating: 0.375, count: 768), to: fixture)
        let checkpointURL = root.appending(path: "audio/checkpoint.json")
        let probe = ScriptedCaptureProbe(checkpointAtPowerRelease: checkpointURL)
        let rate = 48_000.0
        let events: [ScriptedFileCaptureEvent] = [
            .packet(
                file: fixture, frameCount: 512, devicePosition: 0,
                qpc100ns: 10_000_000, flags: 0, originalOffset: 0,
                originalFrames: 512, delivery: .step
            ),
            .packet(
                file: fixture, frameCount: 256, devicePosition: 512,
                qpc100ns: scriptedQPC(frame: 512, sampleRate: rate), flags: 0,
                originalOffset: 0, originalFrames: 256, delivery: .stopJoin
            ),
            .failure(.stop)
        ]
        let harness = try makeWindowsCaptureTestSource(
            root: root,
            source: .microphone,
            sampleRate: rate,
            channels: 1,
            events: events,
            probe: probe
        )

        try await harness.source.start()
        let device = try #require(harness.factory.openedDevice)
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let callbacksAtFence = probe.packetCallbacks.load(ordering: .relaxed)
        try await device.step()
        let repeated = await harness.source.stop()

        #expect(checkpoint.committedFrames == 256)
        #expect(probe.packetCallbacks.load(ordering: .relaxed) == callbacksAtFence)
        #expect(device.isFenced)
        #expect(probe.stopJoinCalls.load(ordering: .relaxed) == 1)
        #expect(probe.powerReleaseCalls.load(ordering: .relaxed) == 1)
        #expect(probe.checkpointFramesAtPowerRelease.load(ordering: .acquiring) == 256)
        #expect(result.errors.contains { $0.contains("Native capture stop failed") })
        #expect(repeated.checkpoint == result.checkpoint)
        #expect(repeated.errors == result.errors)
        #expect(probe.powerReleaseOrder > 0)
    }

    @Test func diskPreflightFailureAndLowSpaceNeverAcquirePowerOrOpenFactory() async throws {
        for probe in [
            ScriptedCaptureProbe(failDiskQuery: true),
            ScriptedCaptureProbe(freeBytes: CaptureDiskPolicy.requiredStartBytes - 1)
        ] {
            let root = try makeWindowsCaptureTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let harness = try makeWindowsCaptureTestSource(
                root: root,
                source: .microphone,
                sampleRate: 48_000,
                channels: 1,
                events: [],
                probe: probe
            )

            do {
                try await harness.source.start()
                Issue.record("disk preflight unexpectedly allowed capture startup")
            } catch { }
            _ = await harness.source.stop()
            #expect(probe.diskQueries.load(ordering: .relaxed) == 1)
            #expect(probe.powerAcquireCalls.load(ordering: .relaxed) == 0)
            #expect(probe.powerReleaseCalls.load(ordering: .relaxed) == 0)
            #expect(probe.openCalls.load(ordering: .relaxed) == 0)
        }
    }

    @Test func powerAcquireOpenAndStartFailuresCleanOnlyOwnedResources() async throws {
        do {
            let root = try makeWindowsCaptureTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let probe = ScriptedCaptureProbe(failPowerAcquire: true)
            let harness = try makeWindowsCaptureTestSource(
                root: root, source: .microphone, sampleRate: 48_000, channels: 1,
                events: [.failure(.open)], probe: probe
            )
            do {
                try await harness.source.start()
                Issue.record("power acquisition unexpectedly succeeded")
            } catch { }
            _ = await harness.source.stop()
            #expect(probe.powerAcquireCalls.load(ordering: .relaxed) == 1)
            #expect(probe.powerReleaseCalls.load(ordering: .relaxed) == 0)
            #expect(probe.openCalls.load(ordering: .relaxed) == 0)
        }

        do {
            let root = try makeWindowsCaptureTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let probe = ScriptedCaptureProbe()
            let harness = try makeWindowsCaptureTestSource(
                root: root, source: .microphone, sampleRate: 48_000, channels: 1,
                events: [.failure(.open)], probe: probe
            )
            do {
                try await harness.source.start()
                Issue.record("scripted open unexpectedly succeeded")
            } catch { }
            let result = await harness.source.stop()
            #expect(result.checkpoint == nil)
            #expect(probe.openCalls.load(ordering: .relaxed) == 1)
            #expect(probe.startCalls.load(ordering: .relaxed) == 0)
            #expect(probe.stopJoinCalls.load(ordering: .relaxed) == 0)
            #expect(probe.powerReleaseCalls.load(ordering: .relaxed) == 1)
        }

        do {
            let root = try makeWindowsCaptureTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let probe = ScriptedCaptureProbe()
            let harness = try makeWindowsCaptureTestSource(
                root: root, source: .microphone, sampleRate: 48_000, channels: 1,
                events: [.failure(.start)], probe: probe
            )
            do {
                try await harness.source.start()
                Issue.record("scripted start unexpectedly succeeded")
            } catch { }
            let result = await harness.source.stop()
            #expect(result.checkpoint?.committedFrames == 0)
            #expect(probe.openCalls.load(ordering: .relaxed) == 1)
            #expect(probe.startCalls.load(ordering: .relaxed) == 1)
            #expect(probe.stopJoinCalls.load(ordering: .relaxed) == 1)
            #expect(probe.powerReleaseCalls.load(ordering: .relaxed) == 1)
        }
    }

    @Test func powerReleaseFailureIsReportedWithoutDiscardingHealthyCheckpoint() async throws {
        let root = try makeWindowsCaptureTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appending(path: "power-release.f32le")
        try writeScriptedFloatFixture([Float](repeating: 0.2, count: 512), to: fixture)
        let events = scriptedPacketFragments(
            file: fixture, sourceFrames: 512, devicePosition: 0, qpc100ns: 10_000_000
        )
        let probe = ScriptedCaptureProbe(failPowerRelease: true)
        let harness = try makeWindowsCaptureTestSource(
            root: root, source: .microphone, sampleRate: 48_000, channels: 1,
            events: events, probe: probe
        )

        try await harness.source.start()
        let result = await harness.source.stop()

        #expect(result.checkpoint?.committedFrames == 171)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.contains { $0.contains("Recording power release failed") })
        #expect(probe.powerReleaseCalls.load(ordering: .relaxed) == 1)
        #expect((await harness.source.stop()).checkpoint == result.checkpoint)
        #expect(probe.powerReleaseCalls.load(ordering: .relaxed) == 1)
    }

    @Test func writerAppendAndFinishFailureReturnOnlyCommittedHealthyPrefix() async throws {
        let root = try makeWindowsCaptureTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appending(path: "writer-failure.f32le")
        try writeScriptedFloatFixture([Float](repeating: 0.3, count: 512), to: fixture)
        let events = scriptedPacketFragments(
            file: fixture, sourceFrames: 512, devicePosition: 0, qpc100ns: 10_000_000
        )
        let probe = ScriptedCaptureProbe()
        let harness = try makeWindowsCaptureTestSource(
            root: root, source: .microphone, sampleRate: 48_000, channels: 1,
            events: events, probe: probe, chunkDurationSeconds: 0.01
        )
        let failingWriter = ScriptedFailingFinishAudioWriter(
            base: harness.writer, probe: probe, appendFailures: 1
        )
        // Rebuild the source with the forwarding failure decorator while retaining its real file writer.
        let decorated = try makeWindowsCaptureTestSource(
            root: root,
            source: .microphone,
            sampleRate: 48_000,
            channels: 1,
            events: events,
            probe: probe,
            writer: failingWriter,
            durableWriter: harness.writer,
            chunkDurationSeconds: 0.01
        )

        try await decorated.source.start()
        await waitForWindowsCaptureTestCondition {
            decorated.source.lastStopResult != nil
        }
        let result = await decorated.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let committed = await harness.writer.committedSnapshot()

        #expect(result.healthyPrefixOnly)
        #expect(probe.writerAppendFailures.load(ordering: .relaxed) == 1)
        #expect(checkpoint == committed)
        #expect(checkpoint.committedFrames == 160)
        #expect(result.errors.contains { $0.contains("Audio writer finish failed") })
        #expect(result.errors.contains { $0.contains("Audio capture drain failed") })
        #expect(probe.writerFinishOrder > 0)
        #expect(probe.powerReleaseOrder > probe.writerFinishOrder)
    }

    @Test func cancellingWaitForFirstBufferJoinsDeviceAndReleasesPower() async throws {
        let root = try makeWindowsCaptureTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rate = 48_000.0
        let events: [ScriptedFileCaptureEvent] = [
            .heartbeat(watermarkQPC100ns: 10_000_000, outputState: 0, error: 0)
        ]
        let probe = ScriptedCaptureProbe()
        let harness = try makeWindowsCaptureTestSource(
            root: root,
            source: .microphone,
            sampleRate: rate,
            channels: 1,
            events: events,
            probe: probe
        )
        let startTask = Task { try await harness.source.start() }
        await waitForWindowsCaptureTestCondition {
            probe.startCalls.load(ordering: .relaxed) == 1
        }
        harness.clock.setMillis(4_000)
        startTask.cancel()
        await waitForWindowsCaptureTestCondition {
            harness.source.lastStopResult != nil
        }
        let result = await harness.source.stop()
        do {
            try await startTask.value
            Issue.record("cancelled startup unexpectedly succeeded")
        } catch { }

        #expect(result.checkpoint?.committedFrames == 0)
        #expect(probe.stopJoinCalls.load(ordering: .relaxed) == 1)
        #expect(probe.powerAcquireCalls.load(ordering: .relaxed) == 1)
        #expect(probe.powerReleaseCalls.load(ordering: .relaxed) == 1)
        #expect(harness.factory.openedDevice?.isFenced == true)
    }
}
