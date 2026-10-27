#if os(Windows)
import Foundation
import Synchronization
import Testing
import CMiniaudio
import MacAmbientJevCore
import MacAmbientJevPipeline
import MacAmbientJevWindowsSupport

@MainActor
struct WindowsCaptureReconnectTests {
    @Test func explicitMicrophoneReconnectsToSameEndpointAndKeepsOneSession() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        let waitingCheckpoint = try await harness.source.committedSnapshot()
        #expect(harness.probe.waitingFlags == [true])
        #expect(originalDevice.isFenced)
        #expect(originalDevice.stopJoinCount == 1)
        #expect(harness.probe.powerAcquireCount == 1)
        #expect(harness.probe.powerReleaseCount == 0)
        #expect(waitingCheckpoint.committedFrames == 512)
        #expect(harness.factory.openSelections == [.endpointID("mic-A")])

        harness.clock.set(seconds: 112.532)
        harness.factory.nextSampleValue = -0.5
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        await harness.source.poll()
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.factory.openSelections == [
            .endpointID("mic-A"), .endpointID("mic-A")
        ])

        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let audio = try readCommittedAudio(checkpoint, root: harness.root)

        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 200_000, reason: .missingCallback)
        ])
        #expect(checkpoint.committedFrames == 201_024)
        #expect(audio.count == 201_024)
        #expect(audio.prefix(512).allSatisfy { abs($0 - 0.25) < 0.0001 })
        #expect(audio.suffix(512).allSatisfy { abs($0 + 0.5) < 0.0001 })
        #expect(harness.probe.silenceFlags.allSatisfy { !$0 })
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)
        #expect(harness.probe.dropoutCounts.last == 1)
        #expect(harness.probe.powerReleaseCount == 1)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.isEmpty)
    }

    @Test(arguments: [ReconnectEnumerationFault.native, .malformed])
    fileprivate func enumerationFailureRetriesAndResumesSameSession(_ fault: ReconnectEnumerationFault) async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()
        #expect(harness.factory.devicesCallCount == 1)

        installEnumerationFault(fault, on: harness.factory)
        harness.clock.set(seconds: 101.032)
        await harness.source.poll()
        #expect(harness.probe.waitingFlags == [true])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)
        #expect(harness.factory.openSelections == [.endpointID("mic-A")])
        #expect(harness.factory.devicesCallCount == 2)

        harness.clock.set(seconds: 101.281)
        await harness.source.poll()
        #expect(harness.factory.devicesCallCount == 2)
        #expect(harness.factory.openedDevices.count == 1)
        #expect(harness.probe.waitingFlags == [true])

        harness.factory.devicesError = nil
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.nextSampleValue = -0.5
        harness.clock.set(seconds: 101.282)
        await harness.source.poll()
        let resumedDevice = try #require(harness.factory.openedDevices.last)
        #expect(resumedDevice !== originalDevice)
        #expect(harness.factory.devicesCallCount == 3)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)

        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 20_000, reason: .missingCallback)
        ])
        #expect(checkpoint.gapEvents.count == 1)
        #expect(checkpoint.committedFrames == 21_024)
        #expect(harness.probe.dropoutCounts.last == 1)
        #expect(harness.probe.dropoutCounts.allSatisfy { $0 <= 1 })
        #expect(originalDevice.isFenced)
        #expect(originalDevice.stopJoinCount == 1)
        #expect(resumedDevice.isFenced)
        #expect(resumedDevice.stopJoinCount == 1)
        #expect(harness.probe.powerAcquireCount == 1)
        #expect(harness.probe.powerReleaseCount == 1)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.isEmpty)
    }

    @Test(arguments: [ReconnectEnumerationFault.native, .malformed])
    fileprivate func repeatedEnumerationFailureExpiresAtOriginalDeadline(_ fault: ReconnectEnumerationFault) async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()
        installEnumerationFault(fault, on: harness.factory)

        for second in [101.032, 101.282, 120.032, 129.999] {
            harness.clock.set(seconds: second)
            await harness.source.poll()
            #expect(harness.probe.waitingFlags == [true])
            #expect(harness.probe.failures.isEmpty)
            #expect(harness.probe.deviceLostCount == 0)
        }
        let callsBeforeExpiry = harness.factory.devicesCallCount
        #expect(callsBeforeExpiry == 5)

        harness.clock.set(seconds: 130.032)
        await harness.source.poll()
        #expect(harness.factory.devicesCallCount == callsBeforeExpiry)
        let expectedDiagnostic = fault.diagnostic
        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.deviceLostDetails == [expectedDiagnostic])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.callbackEvents == ["waiting:true", "deviceLost", "waiting:false"])

        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 480_000, reason: .missingCallback)
        ])
        #expect(checkpoint.gapEvents.count == 1)
        #expect(checkpoint.committedFrames == 480_512)
        #expect(harness.probe.dropoutCounts.last == 1)
        #expect(originalDevice.isFenced)
        #expect(originalDevice.stopJoinCount == 1)
        #expect(harness.probe.powerAcquireCount == 1)
        #expect(harness.probe.powerReleaseCount == 1)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.isEmpty)

        await harness.source.poll()
        #expect(harness.factory.devicesCallCount == callsBeforeExpiry)
        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.powerReleaseCount == 1)
    }

    @Test func startupDefaultMicrophoneEnumerationFailureRemainsThrown() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .systemDefault,
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }
        let expectedDiagnostic = WindowsCaptureAdapterError.native(
            operation: "mja_capture_enumerate",
            code: -22
        ).localizedDescription
        harness.factory.devicesError = WindowsCaptureAdapterError.native(
            operation: "mja_capture_enumerate",
            code: -22
        )

        var startError: (any Error)?
        do {
            try await harness.source.start()
        } catch {
            startError = error
        }

        #expect(startError?.localizedDescription.contains(expectedDiagnostic) == true)
        #expect(harness.factory.devicesCallCount == 1)
        #expect(harness.factory.openSelections.isEmpty)
        #expect(harness.factory.openedDevices.isEmpty)
        #expect(harness.probe.waitingFlags.isEmpty)
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)
        #expect(harness.probe.powerAcquireCount == 1)
        #expect(harness.probe.powerReleaseCount == 1)
    }

    @Test func missingDeviceExpiresAtOriginalDeadlineAndRecoversDurableCheckpoint() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()
        #expect(harness.probe.waitingFlags == [true])
        #expect(originalDevice.isFenced)

        harness.clock.set(seconds: 130.032)
        await harness.source.poll()
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let recovered = try #require(try AudioCheckpoint.loadRecovered(
            from: harness.root.appending(path: "audio", directoryHint: .isDirectory),
            relativeTo: harness.root
        ))

        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.deviceLostDetails == [nil])
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.callbackEvents == ["waiting:true", "deviceLost", "waiting:false"])
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 480_000, reason: .missingCallback)
        ])
        #expect(checkpoint.committedFrames == 480_512)
        #expect(recovered == checkpoint)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.isEmpty)
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.powerReleaseCount == 1)
        #expect(harness.probe.powerAcquireCount == 1)

        await harness.source.poll()
        let repeated = await harness.source.stop()
        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.powerReleaseCount == 1)
        #expect(repeated.checkpoint == checkpoint)
    }

    @Test func stalledCandidateThenGoodCandidateResumesSameSession() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()
        harness.clock.set(seconds: 101.032)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.startsWithPacketForNextDevice = false
        await harness.source.poll()
        let stalledCandidate = try #require(harness.factory.openedDevices.last)
        #expect(stalledCandidate.firstBufferTime == nil)
        #expect(stalledCandidate.lastBufferMillis == 0)
        #expect(harness.probe.waitingFlags == [true])

        for second in [102.032, 103.032] {
            harness.clock.set(seconds: second)
            stalledCandidate.emitHealthyHeartbeat()
            await harness.source.poll()
            #expect(stalledCandidate.firstBufferTime == nil)
            #expect(stalledCandidate.lastBufferMillis == 0)
            #expect(harness.probe.waitingFlags == [true])
        }

        harness.clock.set(seconds: 104.032)
        await harness.source.poll()
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)
        #expect(harness.probe.waitingFlags == [true])
        #expect(stalledCandidate.isFenced)
        #expect(stalledCandidate.stopJoinCount == 1)

        harness.clock.set(seconds: 104.281)
        await harness.source.poll()
        #expect(harness.factory.openedDevices.count == 2)
        #expect(harness.probe.waitingFlags == [true])

        harness.clock.set(seconds: 104.282)
        harness.factory.nextSampleValue = -0.5
        await harness.source.poll()
        let resumedCandidate = try #require(harness.factory.openedDevices.last)
        #expect(resumedCandidate !== stalledCandidate)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)

        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let recovered = try #require(try AudioCheckpoint.loadRecovered(
            from: harness.root.appending(path: "audio", directoryHint: .isDirectory),
            relativeTo: harness.root
        ))
        let audio = try readCommittedAudio(checkpoint, root: harness.root)
        #expect(recovered == checkpoint)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 68_000, reason: .missingCallback)
        ])
        #expect(checkpoint.gapEvents.count == 1)
        #expect(checkpoint.gapEvents[0].startFrame + checkpoint.gapEvents[0].frameCount == 68_512)
        #expect(checkpoint.committedFrames == 69_024)
        #expect(audio.count == 69_024)
        #expect(audio.prefix(512).allSatisfy { abs($0 - 0.25) < 0.0001 })
        #expect(audio[512..<68_512].allSatisfy { abs($0) < 0.0001 })
        #expect(audio.suffix(512).allSatisfy { abs($0 + 0.5) < 0.0001 })
        #expect(harness.probe.dropoutCounts.last == 1)
        #expect(result.errors.isEmpty)
        #expect(!result.healthyPrefixOnly)
        #expect(harness.probe.powerReleaseCount == 1)
    }

    @Test func activeLoopbackStallBeforeFirstBufferRetriesAfterBackoff() async throws {
        let harness = try makeReconnectHarness(
            source: .systemAudio,
            selection: .systemDefault,
            endpoints: [endpoint("render-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(-11003)
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 101.032)
        harness.factory.endpoints = [endpoint("render-A", isDefault: true)]
        harness.factory.startsWithPacketForNextDevice = false
        await harness.source.poll()
        let stalledCandidate = try #require(harness.factory.openedDevices.last)
        stalledCandidate.emitActiveOutputHeartbeat()
        await harness.source.poll()
        harness.clock.set(seconds: 102.032)
        stalledCandidate.emitActiveOutputHeartbeat()
        await harness.source.poll()
        harness.clock.set(seconds: 104.032)
        stalledCandidate.emitActiveOutputHeartbeat()
        await harness.source.poll()

        #expect(stalledCandidate.isFenced)
        #expect(stalledCandidate.stopJoinCount == 1)
        #expect(harness.probe.waitingFlags == [true])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)

        harness.clock.set(seconds: 104.281)
        await harness.source.poll()
        #expect(harness.factory.openedDevices.count == 2)
        harness.clock.set(seconds: 104.282)
        harness.factory.nextSampleValue = -0.5
        await harness.source.poll()
        let resumedCandidate = try #require(harness.factory.openedDevices.last)

        #expect(resumedCandidate !== stalledCandidate)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)

        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 68_000, reason: .missingCallback)
        ])
        #expect(checkpoint.gapEvents.count == 1)
        #expect(result.errors.isEmpty)
    }

    @Test func suspendedPendingCandidateExpiresAsDeviceLost() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 101.032)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.startsWithPacketForNextDevice = false
        await harness.source.poll()
        let candidate = try #require(harness.factory.openedDevices.last)
        candidate.emitHealthyHeartbeat()
        await harness.source.poll()

        harness.clock.set(seconds: 130.032)
        candidate.emitHealthyHeartbeat()
        await harness.source.poll()
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)

        #expect(candidate.isFenced)
        #expect(candidate.stopJoinCount == 1)
        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.deviceLostDetails == [
            "Windows capture timing was suspended or discontinuous"
        ])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.callbackEvents == ["waiting:true", "deviceLost", "waiting:false"])
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 480_000, reason: .missingCallback)
        ])
        #expect(result.errors.isEmpty)
    }

    @Test func candidateNativeFailureBeforeAudioRetriesAfterBackoff() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 101.032)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.startsWithPacketForNextDevice = false
        await harness.source.poll()
        let rejectedCandidate = try #require(harness.factory.openedDevices.last)
        rejectedCandidate.emitHealthError(-22)
        await harness.source.poll()
        #expect(rejectedCandidate.firstBufferTime == nil)
        #expect(rejectedCandidate.isFenced)
        #expect(rejectedCandidate.stopJoinCount == 1)
        #expect(harness.probe.waitingFlags == [true])
        #expect(harness.probe.failures.isEmpty)

        harness.clock.set(seconds: 101.281)
        await harness.source.poll()
        #expect(harness.factory.openedDevices.count == 2)
        harness.clock.set(seconds: 101.282)
        await harness.source.poll()
        #expect(harness.factory.openedDevices.count == 3)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)

        let result = await harness.source.stop()
        #expect(result.errors.isEmpty)
        #expect(!result.healthyPrefixOnly)
        #expect(harness.probe.powerReleaseCount == 1)
    }

    @Test func candidateUnavailableStartBeforeAudioRetriesAfterBackoff() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 101.032)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.nextStartFailureCode = -401
        await harness.source.poll()
        let rejectedCandidate = try #require(harness.factory.openedDevices.last)
        #expect(rejectedCandidate.firstBufferTime == nil)
        #expect(rejectedCandidate.isFenced)
        #expect(rejectedCandidate.stopJoinCount == 1)
        #expect(harness.probe.waitingFlags == [true])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)

        harness.clock.set(seconds: 101.281)
        await harness.source.poll()
        #expect(harness.factory.openedDevices.count == 2)
        harness.clock.set(seconds: 101.282)
        await harness.source.poll()
        #expect(harness.factory.openedDevices.count == 3)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)

        let result = await harness.source.stop()
        #expect(result.errors.isEmpty)
        #expect(!result.healthyPrefixOnly)
        #expect(harness.probe.powerReleaseCount == 1)
    }

    @Test func candidateRepeatedUnavailableFailuresExpireWithLastReopenError() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()
        harness.clock.set(seconds: 110.032)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.nextOpenFailure = .unavailable(-401)
        await harness.source.poll()
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)

        harness.clock.set(seconds: 110.282)
        harness.factory.nextOpenFailure = .unavailable(-22)
        await harness.source.poll()
        let lastError = WindowsCaptureAdapterError.native(operation: "mja_capture_open", code: -22).localizedDescription
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)
        #expect(harness.probe.waitingFlags == [true])

        for time in [120.032, 129.999] {
            harness.clock.set(seconds: time)
            harness.factory.endpoints = []
            await harness.source.poll()
            #expect(harness.probe.deviceLostCount == 0)
            #expect(harness.probe.failures.isEmpty)
        }
        harness.clock.set(seconds: 130.032)
        await harness.source.poll()
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let recovered = try #require(try AudioCheckpoint.loadRecovered(
            from: harness.root.appending(path: "audio", directoryHint: .isDirectory),
            relativeTo: harness.root
        ))

        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.deviceLostDetails == [lastError])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.callbackEvents == ["waiting:true", "deviceLost", "waiting:false"])
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 480_000, reason: .missingCallback)
        ])
        #expect(checkpoint.gapEvents.count == 1)
        #expect(checkpoint.committedFrames == 480_512)
        #expect(recovered == checkpoint)
        #expect(result.errors.isEmpty)
        #expect(!result.healthyPrefixOnly)
        #expect(harness.probe.powerReleaseCount == 1)
    }

    @Test func startupUnavailableOpenFailureRemainsThrown() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }
        harness.factory.nextOpenFailure = .unavailable(-401)
        let expectedError = WindowsCaptureAdapterError.native(
            operation: "mja_capture_open",
            code: -401
        ).localizedDescription

        do {
            try await harness.source.start()
            Issue.record("Initial native open failure was swallowed")
        } catch {
            #expect(error.localizedDescription.contains(expectedError))
            #expect(error.localizedDescription.contains("mja_capture_open"))
            #expect(error.localizedDescription.contains("-401"))
        }
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)
        #expect(harness.probe.powerAcquireCount == 1)
        #expect(harness.probe.powerReleaseCount == 1)
    }

    @Test func runningWorkerStallRemainsFatalWithoutDeviceLost() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let device = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 103.0)
        await harness.source.poll()
        let result = await harness.source.stop()

        #expect(device.isFenced)
        #expect(harness.probe.failures.count == 1)
        #expect(harness.probe.failures[0].contains("worker stopped reporting a healthy heartbeat"))
        #expect(harness.probe.deviceLostCount == 0)
        #expect(result.errors.contains { $0.contains("worker stopped reporting a healthy heartbeat") })
        #expect(harness.probe.waitingFlags.isEmpty)
        #expect(harness.probe.powerReleaseCount == 1)
    }

    @Test func qpcDeadlineExpiresAfterSleepWithoutReopening() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 101.032)
        harness.clock.advanceElapsedQPC(seconds: 3_600)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        await harness.source.poll()
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let recovered = try #require(try AudioCheckpoint.loadRecovered(
            from: harness.root.appending(path: "audio", directoryHint: .isDirectory),
            relativeTo: harness.root
        ))
        let audio = try readCommittedAudio(checkpoint, root: harness.root)

        #expect(harness.factory.openSelections == [.endpointID("mic-A")])
        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.callbackEvents == ["waiting:true", "deviceLost", "waiting:false"])
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 480_000, reason: .missingCallback)
        ])
        #expect(checkpoint.committedFrames == 480_512)
        #expect(recovered == checkpoint)
        #expect(audio.count == 480_512)
        #expect(audio.suffix(480_000).allSatisfy { abs($0) < 0.0001 })
        #expect(harness.probe.failures.isEmpty)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.isEmpty)
    }

    @Test func lateQPCPacketFencesPendingCandidateAfterSleep() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 101.032)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.startsWithPacketForNextDevice = false
        await harness.source.poll()
        let candidate = try #require(harness.factory.openedDevices.last)
        #expect(candidate.firstBufferTime == nil)

        harness.clock.set(seconds: 102.032)
        harness.clock.advanceElapsedQPC(seconds: 3_600)
        let latePacketQPC100ns = harness.clock.qpc100ns
        candidate.emitPacket(
            devicePosition: 0,
            qpc100ns: latePacketQPC100ns,
            flags: 0,
            sampleValue: -0.5
        )
        #expect(abs(try #require(candidate.firstBufferTime) - 102.032) < 0.000001)
        #expect(candidate.firstBufferQPC100ns == latePacketQPC100ns)

        await harness.source.poll()
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let recovered = try #require(try AudioCheckpoint.loadRecovered(
            from: harness.root.appending(path: "audio", directoryHint: .isDirectory),
            relativeTo: harness.root
        ))
        let audio = try readCommittedAudio(checkpoint, root: harness.root)

        #expect(candidate.isFenced)
        #expect(candidate.stopJoinCount == 1)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.callbackEvents == ["waiting:true", "deviceLost", "waiting:false"])
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 480_000, reason: .missingCallback)
        ])
        #expect(checkpoint.committedFrames == 480_512)
        #expect(recovered == checkpoint)
        #expect(audio.count == 480_512)
        #expect(!audio.contains { abs($0 + 0.5) < 0.0001 })
        #expect(harness.probe.failures.isEmpty)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.isEmpty)
    }

    @Test func delayedLossAfterSleepCapsDeadlineAtLastCapturedAudio() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.clock.advanceElapsedQPC(seconds: 3_600)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        await harness.source.poll()
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let recovered = try #require(try AudioCheckpoint.loadRecovered(
            from: harness.root.appending(path: "audio", directoryHint: .isDirectory),
            relativeTo: harness.root
        ))

        #expect(harness.factory.openSelections == [.endpointID("mic-A")])
        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 480_000, reason: .missingCallback)
        ])
        #expect(checkpoint.committedFrames == 480_512)
        #expect(recovered == checkpoint)
        #expect(harness.probe.failures.isEmpty)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.isEmpty)
    }

    @Test func openCrossingQPCDeadlineIsFencedWithoutStarting() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 129.999)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.qpcAdvanceOnNextOpen = 0.034
        await harness.source.poll()
        let expiredCandidate = try #require(harness.factory.openedDevices.last)
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)

        #expect(expiredCandidate.isFenced)
        #expect(expiredCandidate.stopJoinCount == 1)
        #expect(expiredCandidate.startCount == 0)
        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 480_000, reason: .missingCallback)
        ])
        #expect(harness.probe.failures.isEmpty)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.isEmpty)
    }

    @Test func enumerationCrossingQPCDeadlineExpiresWithoutOpeningCandidate() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 129.999)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.qpcAdvanceOnNextDevices = 0.034
        await harness.source.poll()
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)

        #expect(harness.factory.openSelections == [.endpointID("mic-A")])
        #expect(harness.factory.openedDevices.count == 1)
        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.failures.isEmpty)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 480_000, reason: .missingCallback)
        ])
        #expect(result.errors.isEmpty)
    }

    @Test func unavailableOpenCrossingQPCDeadlineRetainsLastError() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 129.999)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.nextOpenFailure = .unavailable(-22)
        harness.factory.qpcAdvanceOnNextOpenFailure = 0.034
        await harness.source.poll()
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let lastError = WindowsCaptureAdapterError.native(operation: "mja_capture_open", code: -22).localizedDescription

        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.deviceLostDetails == [lastError])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.callbackEvents == ["waiting:true", "deviceLost", "waiting:false"])
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 480_000, reason: .missingCallback)
        ])
        #expect(result.errors.isEmpty)
    }

    @Test func startCrossingQPCDeadlineExpiresWithoutAcceptingCandidateAudio() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 129.999)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.qpcAdvanceAfterStartOnNextDevice = 0.034
        harness.factory.nextSampleValue = -0.5
        await harness.source.poll()
        let expiredCandidate = try #require(harness.factory.openedDevices.last)
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let audio = try readCommittedAudio(checkpoint, root: harness.root)

        #expect(expiredCandidate.startCount == 1)
        #expect(expiredCandidate.isFenced)
        #expect(expiredCandidate.stopJoinCount == 1)
        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 480_000, reason: .missingCallback)
        ])
        #expect(!audio.contains { abs($0 + 0.5) < 0.0001 })
        #expect(harness.probe.failures.isEmpty)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.isEmpty)
    }

    @Test func latePacketThenUnavailableStartExpiresWithoutDrainingCandidateAudio() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 129.999)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.nextStartFailureCode = -401
        harness.factory.nextSampleValue = -0.5
        harness.factory.emitPacketBeforeNextStartFailure = true
        harness.factory.qpcAdvanceBeforeNextStartFailure = 0.034
        await harness.source.poll()
        let lateCandidate = try #require(harness.factory.openedDevices.last)
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let audio = try readCommittedAudio(checkpoint, root: harness.root)
        let lastError = WindowsCaptureAdapterError.native(operation: "mja_capture_start", code: -401).localizedDescription

        #expect(lateCandidate.startCount == 1)
        #expect(abs(try #require(lateCandidate.firstBufferTime) - 129.999) < 0.000001)
        #expect(lateCandidate.firstBufferQPC100ns == harness.clock.qpc100ns)
        #expect(lateCandidate.isFenced)
        #expect(lateCandidate.stopJoinCount == 1)
        #expect(harness.probe.deviceLostCount == 1)
        #expect(harness.probe.deviceLostDetails == [lastError])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.callbackEvents == ["waiting:true", "deviceLost", "waiting:false"])
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 480_000, reason: .missingCallback)
        ])
        #expect(checkpoint.committedFrames == 480_512)
        #expect(audio.count == 480_512)
        #expect(!audio.contains { abs($0 + 0.5) < 0.0001 })
        #expect(result.errors.isEmpty)
    }

    @Test func timelyPacketThenUnavailableStartRemainsFatal() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 101.032)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.nextStartFailureCode = -401
        harness.factory.nextSampleValue = -0.5
        harness.factory.emitPacketBeforeNextStartFailure = true
        await harness.source.poll()
        let candidate = try #require(harness.factory.openedDevices.last)
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let recovered = try #require(try AudioCheckpoint.loadRecovered(
            from: harness.root.appending(path: "audio", directoryHint: .isDirectory),
            relativeTo: harness.root
        ))
        let audio = try readCommittedAudio(checkpoint, root: harness.root)

        #expect(try #require(candidate.firstBufferQPC100ns) < 1_300_320_000)
        #expect(candidate.isFenced)
        #expect(candidate.stopJoinCount == 1)
        #expect(harness.probe.failures.count == 1)
        #expect(harness.probe.failures[0].contains(
            "Windows capture start reported device loss after delivering audio"
        ))
        #expect(harness.probe.failures[0].contains("mja_capture_start"))
        #expect(harness.probe.failures[0].contains("-401"))
        #expect(harness.probe.deviceLostCount == 0)
        #expect(harness.probe.callbackEvents == ["waiting:true", "waiting:false"])
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 16_000, reason: .missingCallback)
        ])
        #expect(checkpoint.gapEvents.count == 1)
        #expect(checkpoint.committedFrames == 17_024)
        #expect(recovered == checkpoint)
        #expect(audio.count == 17_024)
        #expect(audio.prefix(512).allSatisfy { abs($0 - 0.25) < 0.0001 })
        #expect(audio[512..<16_512].allSatisfy { abs($0) < 0.0001 })
        #expect(audio.suffix(512).allSatisfy { abs($0 + 0.5) < 0.0001 })
        #expect(harness.probe.dropoutCounts.last == 1)
        #expect(result.errors.contains {
            $0.contains("Windows capture start reported device loss after delivering audio")
        })
    }

    @Test func delayedFirstReconnectPacketAccountsForFullGapExactlyOnce() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 105.032)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.startsWithPacketForNextDevice = false
        await harness.source.poll()
        let candidate = try #require(harness.factory.openedDevices.last)
        #expect(candidate.firstBufferTime == nil)
        #expect(harness.probe.waitingFlags == [true])

        harness.clock.set(seconds: 105.157)
        candidate.emitPacket(
            devicePosition: 0,
            qpc100ns: harness.clock.qpc100ns,
            flags: 0,
            sampleValue: -0.5
        )
        await harness.source.poll()
        #expect(abs(try #require(candidate.firstBufferTime) - 105.157) < 0.000001)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)

        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let recovered = try #require(try AudioCheckpoint.loadRecovered(
            from: harness.root.appending(path: "audio", directoryHint: .isDirectory),
            relativeTo: harness.root
        ))
        let audio = try readCommittedAudio(checkpoint, root: harness.root)
        let reconnectPacketStart = 512 + 82_000
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 82_000, reason: .missingCallback)
        ])
        #expect(checkpoint.committedFrames == 83_024)
        #expect(recovered == checkpoint)
        #expect(audio.count == 83_024)
        #expect(audio.prefix(512).allSatisfy { abs($0 - 0.25) < 0.0001 })
        #expect(audio[512..<reconnectPacketStart].allSatisfy { abs($0) < 0.0001 })
        #expect(audio[reconnectPacketStart..<83_024].allSatisfy { abs($0 + 0.5) < 0.0001 })
        #expect(harness.probe.dropoutCounts.last == 1)
        #expect(harness.probe.dropoutCounts.allSatisfy { $0 <= 1 })
        #expect(candidate.isFenced)
        #expect(candidate.stopJoinCount == 1)
        #expect(harness.probe.powerAcquireCount == 1)
        #expect(harness.probe.powerReleaseCount == 1)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.isEmpty)
    }

    @Test func timelyReconnectEvidenceResumesAfterDelayedControlTick() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 129.032)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        harness.factory.startsWithPacketForNextDevice = false
        await harness.source.poll()
        let candidate = try #require(harness.factory.openedDevices.last)
        #expect(candidate.firstBufferTime == nil)

        harness.clock.set(seconds: 129.9)
        let firstReconnectPacketQPC100ns = harness.clock.qpc100ns
        candidate.emitPacket(
            devicePosition: 0,
            qpc100ns: firstReconnectPacketQPC100ns,
            flags: 0,
            sampleValue: 0.25
        )
        harness.clock.set(seconds: 132.0)
        candidate.emitPacket(
            devicePosition: 512,
            qpc100ns: firstReconnectPacketQPC100ns + 320_000,
            flags: 0,
            sampleValue: -0.5
        )
        candidate.emitHealthyHeartbeat()
        #expect(abs(try #require(candidate.firstBufferTime) - 129.9) < 0.000001)
        #expect(candidate.lastBufferMillis == 132_000)

        await harness.source.poll()
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.deviceLostCount == 0)
        #expect(harness.probe.failures.isEmpty)
        #expect(abs(try #require(candidate.firstBufferTime) - 129.9) < 0.000001)
        #expect(candidate.lastBufferMillis == 132_000)

        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let recovered = try #require(try AudioCheckpoint.loadRecovered(
            from: harness.root.appending(path: "audio", directoryHint: .isDirectory),
            relativeTo: harness.root
        ))
        let audio = try readCommittedAudio(checkpoint, root: harness.root)
        let firstReconnectPacketStart = 512 + 477_888
        let secondReconnectPacketStart = firstReconnectPacketStart + 512
        #expect(recovered == checkpoint)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 477_888, reason: .missingCallback)
        ])
        #expect(checkpoint.gapEvents.count == 1)
        #expect(checkpoint.gapEvents[0].startFrame + checkpoint.gapEvents[0].frameCount
            == Int64(firstReconnectPacketStart))
        #expect(checkpoint.committedFrames == 479_424)
        #expect(audio.count == Int(checkpoint.committedFrames))
        #expect(audio.prefix(512).allSatisfy { abs($0 - 0.25) < 0.0001 })
        #expect(audio[firstReconnectPacketStart..<(firstReconnectPacketStart + 512)]
            .allSatisfy { abs($0 - 0.25) < 0.0001 })
        #expect(audio[secondReconnectPacketStart..<(secondReconnectPacketStart + 512)]
            .allSatisfy { abs($0 + 0.5) < 0.0001 })
        #expect(harness.probe.dropoutCounts.last == 1)
        #expect(harness.probe.dropoutCounts.allSatisfy { $0 <= 1 })
        #expect(harness.probe.powerReleaseCount == 1)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.isEmpty)
    }

    @Test func defaultOutputLoopbackReopensNewDefaultAndConvertsChangedFormat() async throws {
        let harness = try makeReconnectHarness(
            source: .systemAudio,
            selection: .systemDefault,
            endpoints: [endpoint("render-old", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        #expect(originalDevice.endpointID == "render-old")
        #expect(harness.factory.openSelections == [.systemDefault])

        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(-11003)
        harness.factory.endpoints = []
        await harness.source.poll()

        harness.clock.set(seconds: 101.032)
        harness.factory.endpoints = [endpoint("render-new", isDefault: true)]
        harness.factory.setFormat(sampleRate: 48_000, channels: 2, for: "render-new")
        harness.factory.setSampleValue(0.25, for: "render-new")
        await harness.source.poll()
        let resumedDevice = try #require(harness.factory.openedDevices.last)
        #expect(resumedDevice !== originalDevice)
        #expect(resumedDevice.endpointID == "render-new")
        #expect(resumedDevice.sampleRate == 48_000)
        #expect(resumedDevice.channels == 2)
        #expect(harness.factory.openSelections == [.systemDefault, .systemDefault])
        #expect(harness.probe.waitingFlags == [true, false])

        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let resumedCanonicalFrames = try CanonicalAudio.boundary(512, sampleRate: 48_000)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 16_000, reason: .missingCallback)
        ])
        #expect(checkpoint.committedFrames == 512 + 16_000 + resumedCanonicalFrames)
        let audio = try readCommittedAudio(checkpoint, root: harness.root)
        #expect(audio.suffix(Int(resumedCanonicalFrames)).contains { $0 > 0.1 })
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)
        #expect(result.errors.isEmpty)
        #expect(harness.probe.powerReleaseCount == 1)
    }

    @Test(arguments: [1.0, 5.0], [false, true])
    func idleLoopbackReconnectPreservesMissingIntervalBeforeHealthSilence(
        waitSeconds: Double,
        initiallyActive: Bool
    ) async throws {
        let harness = try makeReconnectHarness(
            source: .systemAudio,
            selection: .systemDefault,
            endpoints: [endpoint("render-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(-11003)
        harness.factory.endpoints = []
        await harness.source.poll()
        #expect(harness.probe.waitingFlags == [true])

        let reopenTime = 100.032 + waitSeconds
        harness.clock.set(seconds: reopenTime)
        harness.factory.endpoints = [endpoint("render-A", isDefault: true)]
        harness.factory.startsWithPacketForNextDevice = false
        await harness.source.poll()
        let candidate = try #require(harness.factory.openedDevices.last)
        #expect(candidate !== originalDevice)
        #expect(candidate.endpointID == "render-A")
        #expect(harness.factory.openSelections == [.systemDefault, .systemDefault])
        if initiallyActive {
            candidate.emitActiveOutputHeartbeat()
        } else {
            candidate.emitHealthyHeartbeat()
        }
        await harness.source.poll()

        #expect(candidate.firstBufferTime == nil)
        #expect(harness.probe.waitingFlags == [true])

        harness.clock.set(seconds: reopenTime + 0.5)
        candidate.emitHealthyHeartbeat()
        await harness.source.poll()
        let expectedReadinessTime = reopenTime + (initiallyActive ? 0.75 : 0.5)
        if initiallyActive {
            #expect(candidate.firstBufferTime == nil)
            #expect(harness.probe.waitingFlags == [true])
            harness.clock.set(seconds: reopenTime + 0.75)
            candidate.emitHealthyHeartbeat()
            await harness.source.poll()
        }
        if let firstBufferTime = candidate.firstBufferTime {
            #expect(abs(firstBufferTime - expectedReadinessTime) < 0.000001)
        } else {
            Issue.record("Idle reconnect did not publish first-buffer evidence")
        }
        #expect(candidate.firstBufferQPC100ns == harness.clock.qpc100ns)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.failures.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)
        #expect(harness.probe.callbackEvents == ["waiting:true", "waiting:false"])

        harness.clock.set(seconds: expectedReadinessTime + 0.25)
        candidate.emitPacket(
            devicePosition: 0,
            qpc100ns: harness.clock.qpc100ns,
            flags: 0,
            sampleValue: -0.5
        )
        await harness.source.poll()

        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let recovered = try #require(try AudioCheckpoint.loadRecovered(
            from: harness.root.appending(path: "audio", directoryHint: .isDirectory),
            relativeTo: harness.root
        ))
        let audio = try readCommittedAudio(checkpoint, root: harness.root)
        let waitFrames = Int64(waitSeconds * 16_000)
        let expectedGapFrames = waitFrames + (initiallyActive ? 4_000 : 0)
        let expectedFramesBeforePacket = 512 + expectedGapFrames + 4_000
        let resumedPacketStart = Int(expectedFramesBeforePacket + 8_000)
        let expectedFrames = expectedFramesBeforePacket + 8_000 + 512

        #expect(recovered == checkpoint)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: expectedGapFrames, reason: .missingCallback)
        ])
        #expect(checkpoint.gapEvents.count == 1)
        #expect(checkpoint.committedFrames == expectedFrames)
        #expect(audio.count == Int(expectedFrames))
        #expect(audio.prefix(512).allSatisfy { abs($0 - 0.25) < 0.0001 })
        #expect(audio[512..<resumedPacketStart].allSatisfy { abs($0) < 0.0001 })
        #expect(audio.suffix(512).allSatisfy { abs($0 + 0.5) < 0.0001 })
        #expect(harness.probe.dropoutCounts.last == 1)
        #expect(harness.probe.dropoutCounts.allSatisfy { $0 <= 1 })
        #expect(originalDevice.isFenced)
        #expect(originalDevice.stopJoinCount == 1)
        #expect(candidate.isFenced)
        #expect(candidate.stopJoinCount == 1)
        #expect(harness.probe.powerAcquireCount == 1)
        #expect(harness.probe.powerReleaseCount == 1)
        #expect(!result.healthyPrefixOnly)
        #expect(result.errors.isEmpty)
    }

    @Test func explicitlySelectedMicrophoneDoesNotSwitchToDifferentEndpoint() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = [endpoint("mic-B", isDefault: true)]
        await harness.source.poll()
        #expect(harness.probe.waitingFlags == [true])
        #expect(harness.factory.openSelections == [.endpointID("mic-A")])

        harness.clock.set(seconds: 102.032)
        await harness.source.poll()
        #expect(harness.probe.waitingFlags == [true])
        #expect(harness.factory.openSelections == [.endpointID("mic-A")])
        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)

        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 32_000, reason: .missingCallback)
        ])
        #expect(checkpoint.committedFrames == 32_512)
        #expect(harness.factory.openSelections == [.endpointID("mic-A")])
        #expect(harness.factory.openedDevices.count == 1)
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.deviceLostCount == 0)
        #expect(result.errors.isEmpty)
        #expect(harness.probe.powerReleaseCount == 1)
    }

    @Test func defaultMicrophoneRemainsPinnedToInitiallyResolvedEndpoint() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .systemDefault,
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        #expect(originalDevice.endpointID == "mic-A")
        #expect(harness.factory.openSelections == [.endpointID("mic-A")])

        harness.clock.set(seconds: 100.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = [endpoint("mic-B", isDefault: true)]
        await harness.source.poll()
        #expect(harness.factory.openSelections == [.endpointID("mic-A")])

        harness.clock.set(seconds: 102.032)
        harness.factory.endpoints = [
            endpoint("mic-B", isDefault: true), endpoint("mic-A", isDefault: false)
        ]
        harness.factory.nextSampleValue = -0.5
        await harness.source.poll()
        #expect(harness.factory.openSelections == [
            .endpointID("mic-A"), .endpointID("mic-A")
        ])
        #expect(harness.factory.openedDevices.last?.endpointID == "mic-A")

        let result = await harness.source.stop()
        let checkpoint = try #require(result.checkpoint)
        let audio = try readCommittedAudio(checkpoint, root: harness.root)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 512, frameCount: 32_000, reason: .missingCallback)
        ])
        #expect(checkpoint.committedFrames == 33_024)
        #expect(audio.count == 33_024)
        #expect(audio.prefix(512).allSatisfy { abs($0 - 0.25) < 0.0001 })
        #expect(audio.suffix(512).allSatisfy { abs($0 + 0.5) < 0.0001 })
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.failures.isEmpty)
        #expect(result.errors.isEmpty)
    }

    @Test func silenceWarningDoesNotAccumulateDuringWaitAndResetsOnReturnedZeroAudio() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: ["mic-A": 0]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let originalDevice = try #require(harness.factory.openedDevices.first)
        for second in 1...30 {
            harness.clock.set(seconds: 100 + Double(second))
            originalDevice.emitPacket(
                devicePosition: 0,
                qpc100ns: harness.clock.qpc100ns,
                flags: 1
            )
            originalDevice.emitHealthyHeartbeat()
            await harness.source.poll()
            if second < 30 {
                #expect(harness.probe.silenceFlags.isEmpty)
            }
        }
        #expect(harness.probe.silenceFlags == [true])

        harness.clock.set(seconds: 130.032)
        originalDevice.emitHealthError(Int32(bitPattern: 0x88890004))
        harness.factory.endpoints = []
        await harness.source.poll()
        #expect(harness.probe.waitingFlags == [true])
        #expect(harness.probe.silenceFlags == [true, false])

        harness.clock.set(seconds: 159.032)
        harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
        await harness.source.poll()
        let resumedDevice = try #require(harness.factory.openedDevices.last)
        resumedDevice.emitHealthyHeartbeat()
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.silenceFlags == [true, false])
        #expect(harness.probe.warnings.isEmpty)
        #expect(harness.probe.failures.isEmpty)

        for second in 1...30 {
            harness.clock.set(seconds: 159.032 + Double(second))
            resumedDevice.emitPacket(
                devicePosition: 0,
                qpc100ns: harness.clock.qpc100ns,
                flags: 1
            )
            resumedDevice.emitHealthyHeartbeat()
            await harness.source.poll()
            if second < 30 {
                #expect(harness.probe.silenceFlags == [true, false])
            }
        }
        #expect(harness.probe.silenceFlags == [true, false, true])
        #expect(harness.probe.waitingFlags == [true, false])
        #expect(harness.probe.failures.isEmpty)

        let result = await harness.source.stop()
        #expect(result.errors.isEmpty)
        #expect(harness.probe.deviceLostCount == 0)
        #expect(harness.probe.powerReleaseCount == 1)
    }

    @Test func reopenUnavailablePreservesDeadlineWhileOtherReconnectErrorsFailNormally() async throws {
        do {
            let harness = try makeReconnectHarness(
                source: .microphone,
                selection: .endpointID("mic-A"),
                endpoints: [endpoint("mic-A", isDefault: true)],
                formats: [:],
                sampleValues: [:]
            )
            defer { removeReconnectTestDirectory(harness.root) }
            try await harness.source.start()
            let device = try #require(harness.factory.openedDevices.first)
            harness.clock.set(seconds: 100.032)
            device.emitHealthError(Int32(bitPattern: 0x88890004))
            harness.factory.endpoints = []
            await harness.source.poll()

            harness.clock.set(seconds: 110.032)
            harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
            harness.factory.nextOpenFailure = .unavailable(-204)
            await harness.source.poll()
            #expect(harness.probe.failures.isEmpty)
            #expect(harness.probe.deviceLostCount == 0)
            #expect(harness.probe.waitingFlags == [true])
            #expect(harness.factory.openSelections.count == 2)

            harness.clock.set(seconds: 129.999)
            harness.factory.endpoints = []
            await harness.source.poll()
            #expect(harness.probe.deviceLostCount == 0)
            #expect(harness.probe.failures.isEmpty)

            harness.clock.set(seconds: 130.032)
            await harness.source.poll()
            let result = await harness.source.stop()
            #expect(harness.probe.deviceLostCount == 1)
            #expect(harness.probe.failures.isEmpty)
            #expect(result.errors.isEmpty)
            #expect(harness.probe.powerReleaseCount == 1)
        }

        do {
            let harness = try makeReconnectHarness(
                source: .microphone,
                selection: .endpointID("mic-A"),
                endpoints: [endpoint("mic-A", isDefault: true)],
                formats: [:],
                sampleValues: [:]
            )
            defer { removeReconnectTestDirectory(harness.root) }
            try await harness.source.start()
            let device = try #require(harness.factory.openedDevices.first)
            harness.clock.set(seconds: 100.032)
            device.emitHealthError(Int32(bitPattern: 0x88890004))
            harness.factory.endpoints = []
            await harness.source.poll()
            harness.clock.set(seconds: 101.032)
            harness.factory.endpoints = [endpoint("mic-A", isDefault: true)]
            harness.factory.nextOpenFailure = .generic
            await harness.source.poll()
            let result = await harness.source.stop()

            #expect(harness.probe.failures.count == 1)
            #expect(harness.probe.deviceLostCount == 0)
            #expect(result.errors.contains { $0.contains("scripted generic reopen failure") })
            #expect(harness.probe.powerReleaseCount == 1)
        }

        do {
            let harness = try makeReconnectHarness(
                source: .microphone,
                selection: .endpointID("mic-A"),
                endpoints: [endpoint("mic-A", isDefault: true)],
                formats: [:],
                sampleValues: [:]
            )
            defer { removeReconnectTestDirectory(harness.root) }
            try await harness.source.start()
            let device = try #require(harness.factory.openedDevices.first)
            device.stopFailure = true
            harness.clock.set(seconds: 100.032)
            device.emitHealthError(Int32(bitPattern: 0x88890004))
            await harness.source.poll()
            let result = await harness.source.stop()

            #expect(device.isFenced)
            #expect(harness.probe.failures.count == 1)
            #expect(harness.probe.deviceLostCount == 0)
            #expect(result.errors.contains { $0.contains("Native capture stop failed") })
            #expect(harness.probe.powerReleaseCount == 1)
        }
    }

    @Test func accessDeniedHealthFailureDoesNotReconnect() async throws {
        let harness = try makeReconnectHarness(
            source: .microphone,
            selection: .endpointID("mic-A"),
            endpoints: [endpoint("mic-A", isDefault: true)],
            formats: [:],
            sampleValues: [:]
        )
        defer { removeReconnectTestDirectory(harness.root) }

        try await harness.source.start()
        let device = try #require(harness.factory.openedDevices.first)
        harness.clock.set(seconds: 100.032)
        device.emitHealthError(Int32(bitPattern: 0x80070005))
        await harness.source.poll()
        let result = await harness.source.stop()

        #expect(device.isFenced)
        #expect(harness.factory.openSelections == [.endpointID("mic-A")])
        #expect(harness.factory.openedDevices.count == 1)
        #expect(harness.probe.failures.count == 1)
        #expect(harness.probe.deviceLostCount == 0)
        #expect(result.errors.count == 1)
        #expect(harness.probe.powerReleaseCount == 1)
    }
}

private struct ReconnectHarness {
    let root: URL
    let source: WindowsCaptureSource
    let factory: ReconnectFakeFactory
    let clock: ReconnectCaptureClock
    let probe: ReconnectProbe
}

private struct ReconnectDeviceFormat {
    let sampleRate: Double
    let channels: Int
}

private enum ReconnectEnumerationFault: Sendable {
    case native
    case malformed

    var diagnostic: String {
        switch self {
        case .native:
            WindowsCaptureAdapterError.native(
                operation: "mja_capture_enumerate",
                code: -22
            ).localizedDescription
        case .malformed:
            WindowsCaptureAdapterError.invalidConfiguration(
                "Capture enumeration returned duplicate endpoints or multiple defaults"
            ).localizedDescription
        }
    }
}

@MainActor
private func installEnumerationFault(_ fault: ReconnectEnumerationFault, on factory: ReconnectFakeFactory) {
    switch fault {
    case .native:
        factory.devicesError = WindowsCaptureAdapterError.native(
            operation: "mja_capture_enumerate",
            code: -22
        )
    case .malformed:
        factory.endpoints = [
            endpoint("mic-A", isDefault: true), endpoint("mic-A", isDefault: false)
        ]
    }
}

private enum ReconnectOpenFailure {
    case unavailable(Int32)
    case generic
}

private enum ReconnectFixtureError: Error, LocalizedError {
    case genericOpen
    case stopJoin

    var errorDescription: String? {
        switch self {
        case .genericOpen: "scripted generic reopen failure"
        case .stopJoin: "scripted stopJoin failure"
        }
    }
}

private final class ReconnectCaptureClock: CaptureClock, @unchecked Sendable {
    private let nanoseconds = Atomic<Int64>(100_000_000_000)
    private let elapsedQPC100ns = Atomic<UInt64>(1_000_000_000)

    func now() -> TimeInterval {
        Double(nanoseconds.load(ordering: .acquiring)) / 1_000_000_000
    }

    var qpc100ns: UInt64 {
        elapsedQPC100ns.load(ordering: .acquiring)
    }

    func set(seconds: TimeInterval) {
        precondition(seconds.isFinite && seconds >= 0 && seconds < Double(Int64.max) / 1_000_000_000)
        let qpc = seconds * 10_000_000
        precondition(qpc.isFinite && qpc >= 0 && qpc < Double(UInt64.max))
        nanoseconds.store(Int64((seconds * 1_000_000_000).rounded()), ordering: .releasing)
        elapsedQPC100ns.store(UInt64(qpc.rounded()), ordering: .releasing)
    }

    func advanceElapsedQPC(seconds: TimeInterval) {
        let duration = seconds * 10_000_000
        precondition(duration.isFinite && duration >= 0 && duration < Double(UInt64.max))
        let (advanced, overflow) = elapsedQPC100ns.load(ordering: .acquiring)
            .addingReportingOverflow(UInt64(duration.rounded()))
        precondition(!overflow)
        elapsedQPC100ns.store(advanced, ordering: .releasing)
    }
}

private final class ReconnectProbe: @unchecked Sendable {
    private struct State {
        var waitingFlags: [Bool] = []
        var silenceFlags: [Bool] = []
        var warnings: [String] = []
        var failures: [String] = []
        var dropoutCounts: [UInt64] = []
        var deviceLostCount = 0
        var deviceLostDetails: [String?] = []
        var callbackEvents: [String] = []
    }

    private let state = Mutex(State())
    private let powerAcquire = Atomic<Int>(0)
    private let powerRelease = Atomic<Int>(0)

    var waitingFlags: [Bool] { state.withLock { $0.waitingFlags } }
    var silenceFlags: [Bool] { state.withLock { $0.silenceFlags } }
    var warnings: [String] { state.withLock { $0.warnings } }
    var failures: [String] { state.withLock { $0.failures } }
    var dropoutCounts: [UInt64] { state.withLock { $0.dropoutCounts } }
    var deviceLostCount: Int { state.withLock { $0.deviceLostCount } }
    var deviceLostDetails: [String?] { state.withLock { $0.deviceLostDetails } }
    var callbackEvents: [String] { state.withLock { $0.callbackEvents } }
    var powerAcquireCount: Int { powerAcquire.load(ordering: .acquiring) }
    var powerReleaseCount: Int { powerRelease.load(ordering: .acquiring) }

    func recordWaiting(_ value: Bool) {
        state.withLock {
            $0.waitingFlags.append(value)
            $0.callbackEvents.append("waiting:\(value)")
        }
    }
    func recordSilence(_ value: Bool) { state.withLock { $0.silenceFlags.append(value) } }
    func recordWarning(_ value: String) { state.withLock { $0.warnings.append(value) } }
    func recordFailure(_ value: String) { state.withLock { $0.failures.append(value) } }
    func recordDropouts(_ value: UInt64) { state.withLock { $0.dropoutCounts.append(value) } }
    func recordDeviceLost(_ detail: String?) {
        state.withLock {
            $0.deviceLostCount += 1
            $0.deviceLostDetails.append(detail)
            $0.callbackEvents.append("deviceLost")
        }
    }
    func acquirePower() { _ = powerAcquire.add(1, ordering: .relaxed) }
    func releasePower() { _ = powerRelease.add(1, ordering: .relaxed) }
}

@MainActor
private final class ReconnectFakeDevice: WindowsCaptureDevice {
    let endpointID: String
    let sampleRate: Double
    let channels: Int
    private let clock: ReconnectCaptureClock
    private let initialSampleValue: Float
    private let startsWithPacket: Bool
    private let startFailureCode: Int32?
    private let emitPacketBeforeStartFailure: Bool
    private let qpcAdvanceBeforeStartFailureSeconds: TimeInterval?
    private let qpcAdvanceAfterStartSeconds: TimeInterval?
    private var ingress: WindowsCaptureIngress?
    private(set) var isFenced = false
    private(set) var startCount = 0
    private(set) var stopJoinCount = 0
    var stopFailure = false
    var firstBufferTime: TimeInterval? { ingress?.firstBufferTime }
    var firstBufferQPC100ns: UInt64? { ingress?.firstBufferQPC100ns }
    var lastBufferMillis: Int64 {
        guard let ingress else { preconditionFailure("fake capture device has not started") }
        return ingress.sink.lastBufferMillis.load(ordering: .acquiring)
    }

    init(
        endpointID: String,
        sampleRate: Double,
        channels: Int,
        clock: ReconnectCaptureClock,
        initialSampleValue: Float,
        startsWithPacket: Bool,
        startFailureCode: Int32?,
        emitPacketBeforeStartFailure: Bool,
        qpcAdvanceBeforeStartFailureSeconds: TimeInterval?,
        qpcAdvanceAfterStartSeconds: TimeInterval?
    ) {
        self.endpointID = endpointID
        self.sampleRate = sampleRate
        self.channels = channels
        self.clock = clock
        self.initialSampleValue = initialSampleValue
        self.startsWithPacket = startsWithPacket
        self.startFailureCode = startFailureCode
        self.emitPacketBeforeStartFailure = emitPacketBeforeStartFailure
        self.qpcAdvanceBeforeStartFailureSeconds = qpcAdvanceBeforeStartFailureSeconds
        self.qpcAdvanceAfterStartSeconds = qpcAdvanceAfterStartSeconds
    }

    func start(ingress: WindowsCaptureIngress) throws {
        guard self.ingress == nil, !isFenced else {
            throw WindowsCaptureAdapterError.invalidConfiguration("fake capture device started twice")
        }
        self.ingress = ingress
        startCount += 1
        if let startFailureCode {
            if let qpcAdvanceBeforeStartFailureSeconds {
                clock.advanceElapsedQPC(seconds: qpcAdvanceBeforeStartFailureSeconds)
            }
            if emitPacketBeforeStartFailure && startsWithPacket {
                emitPacket(devicePosition: 0, qpc100ns: clock.qpc100ns, flags: 0)
            }
            throw WindowsCaptureAdapterError.native(operation: "mja_capture_start", code: startFailureCode)
        }
        if startsWithPacket {
            emitPacket(devicePosition: 0, qpc100ns: clock.qpc100ns, flags: 0)
        }
        if let qpcAdvanceAfterStartSeconds {
            clock.advanceElapsedQPC(seconds: qpcAdvanceAfterStartSeconds)
        }
    }

    func stopJoin() throws {
        guard !isFenced else { return }
        isFenced = true
        stopJoinCount += 1
        if stopFailure { throw ReconnectFixtureError.stopJoin }
    }

    func emitHealthError(_ rawError: Int32) {
        guard !isFenced, let ingress else { return }
        ingress.health(watermarkQPC100ns: clock.qpc100ns, outputState: 0, error: rawError)
    }

    func emitHealthyHeartbeat() {
        guard !isFenced, let ingress else { return }
        ingress.health(watermarkQPC100ns: clock.qpc100ns, outputState: 0, error: 0)
    }

    func emitActiveOutputHeartbeat() {
        guard !isFenced, let ingress else { return }
        ingress.health(watermarkQPC100ns: clock.qpc100ns, outputState: 1, error: 0)
    }

    func emitPacket(devicePosition: UInt64, qpc100ns: UInt64, flags: UInt32) {
        emitPacket(
            devicePosition: devicePosition,
            qpc100ns: qpc100ns,
            flags: flags,
            sampleValue: initialSampleValue
        )
    }

    func emitPacket(devicePosition: UInt64, qpc100ns: UInt64, flags: UInt32, sampleValue: Float) {
        guard !isFenced, let ingress else { return }
        let samples = [Float](repeating: sampleValue, count: 512 * channels)
        samples.withUnsafeBufferPointer { buffer in
            let packet = WindowsCapturePacket(
                samples: buffer.baseAddress,
                frameCount: 512,
                channels: channels,
                sampleRate: sampleRate,
                flags: flags,
                devicePosition: devicePosition,
                qpc100ns: qpc100ns,
                packetOffset: 0,
                packetFrames: 512
            )
            ingress.receive(packet)
        }
    }
}

@MainActor
private final class ReconnectFakeFactory: WindowsCaptureSourceFactory {
    var endpoints: [WindowsCaptureEndpoint]
    private var formats: [String: ReconnectDeviceFormat]
    private var sampleValues: [String: Float]
    private let clock: ReconnectCaptureClock
    private(set) var openSelections: [WindowsCaptureDeviceSelection] = []
    private(set) var openedDevices: [ReconnectFakeDevice] = []
    private(set) var devicesCallCount = 0
    var devicesError: (any Error)?
    var nextOpenFailure: ReconnectOpenFailure?
    var nextStartFailureCode: Int32?
    var nextSampleValue: Float?
    var startsWithPacketForNextDevice = true
    var qpcAdvanceOnNextOpen: TimeInterval?
    var qpcAdvanceOnNextOpenFailure: TimeInterval?
    var qpcAdvanceOnNextDevices: TimeInterval?
    var emitPacketBeforeNextStartFailure = false
    var qpcAdvanceBeforeNextStartFailure: TimeInterval?
    var qpcAdvanceAfterStartOnNextDevice: TimeInterval?

    init(
        endpoints: [WindowsCaptureEndpoint],
        formats: [String: ReconnectDeviceFormat],
        sampleValues: [String: Float],
        initialFormat: ReconnectDeviceFormat,
        initialSampleValue: Float,
        clock: ReconnectCaptureClock
    ) {
        self.endpoints = endpoints
        self.formats = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.id, initialFormat) })
        self.sampleValues = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.id, initialSampleValue) })
        for (endpointID, format) in formats { self.formats[endpointID] = format }
        for (endpointID, sampleValue) in sampleValues { self.sampleValues[endpointID] = sampleValue }
        self.clock = clock
    }

    func setFormat(sampleRate: Double, channels: Int, for endpointID: String) {
        formats[endpointID] = ReconnectDeviceFormat(sampleRate: sampleRate, channels: channels)
    }

    func setSampleValue(_ value: Float, for endpointID: String) {
        sampleValues[endpointID] = value
    }

    func open(source: CaptureSource, device: WindowsCaptureDeviceSelection) throws -> any WindowsCaptureDevice {
        openSelections.append(device)
        if let failure = nextOpenFailure {
            nextOpenFailure = nil
            if let qpcAdvanceOnNextOpenFailure {
                self.qpcAdvanceOnNextOpenFailure = nil
                clock.advanceElapsedQPC(seconds: qpcAdvanceOnNextOpenFailure)
            }
            switch failure {
            case .unavailable(let code):
                throw WindowsCaptureAdapterError.native(operation: "mja_capture_open", code: code)
            case .generic:
                throw ReconnectFixtureError.genericOpen
            }
        }

        let selectedEndpoint: WindowsCaptureEndpoint?
        switch device {
        case .systemDefault:
            selectedEndpoint = endpoints.first(where: \.isDefault)
        case .endpointID(let id):
            selectedEndpoint = endpoints.first(where: { $0.id == id })
        }
        guard let selectedEndpoint else {
            throw WindowsCaptureAdapterError.native(operation: "mja_capture_open", code: -204)
        }
        guard let format = formats[selectedEndpoint.id],
              let configuredSampleValue = sampleValues[selectedEndpoint.id] else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Fake capture endpoint has no scripted format or samples"
            )
        }
        let sampleValue: Float
        if let nextSampleValue {
            sampleValue = nextSampleValue
            self.nextSampleValue = nil
        } else {
            sampleValue = configuredSampleValue
        }
        let startsWithPacket = startsWithPacketForNextDevice
        startsWithPacketForNextDevice = true
        let startFailureCode = nextStartFailureCode
        nextStartFailureCode = nil
        let emitPacketBeforeStartFailure = emitPacketBeforeNextStartFailure
        emitPacketBeforeNextStartFailure = false
        let qpcAdvanceBeforeStartFailure = qpcAdvanceBeforeNextStartFailure
        qpcAdvanceBeforeNextStartFailure = nil
        let qpcAdvanceAfterStart = qpcAdvanceAfterStartOnNextDevice
        qpcAdvanceAfterStartOnNextDevice = nil
        let fake = ReconnectFakeDevice(
            endpointID: selectedEndpoint.id,
            sampleRate: format.sampleRate,
            channels: format.channels,
            clock: clock,
            initialSampleValue: sampleValue,
            startsWithPacket: startsWithPacket,
            startFailureCode: startFailureCode,
            emitPacketBeforeStartFailure: emitPacketBeforeStartFailure,
            qpcAdvanceBeforeStartFailureSeconds: qpcAdvanceBeforeStartFailure,
            qpcAdvanceAfterStartSeconds: qpcAdvanceAfterStart
        )
        openedDevices.append(fake)
        if let qpcAdvanceOnNextOpen {
            self.qpcAdvanceOnNextOpen = nil
            clock.advanceElapsedQPC(seconds: qpcAdvanceOnNextOpen)
        }
        return fake
    }

    func devices(source: CaptureSource) throws -> [WindowsCaptureEndpoint] {
        devicesCallCount += 1
        if let qpcAdvanceOnNextDevices {
            self.qpcAdvanceOnNextDevices = nil
            clock.advanceElapsedQPC(seconds: qpcAdvanceOnNextDevices)
        }
        if let devicesError { throw devicesError }
        return endpoints
    }
}

@MainActor
private func makeReconnectHarness(
    source: CaptureSource,
    selection: WindowsCaptureDeviceSelection,
    endpoints: [WindowsCaptureEndpoint],
    formats: [String: ReconnectDeviceFormat],
    sampleValues: [String: Float]
) throws -> ReconnectHarness {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "WindowsCaptureReconnect-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let audioDirectory = root.appending(path: "audio", directoryHint: .isDirectory)
    let writer = try DurableAudioWriter(
        directory: audioDirectory,
        chunkDurationSeconds: 1.0,
        sessionURL: root
    )
    let clock = ReconnectCaptureClock()
    let probe = ReconnectProbe()
    let factory = ReconnectFakeFactory(
        endpoints: endpoints,
        formats: formats,
        sampleValues: sampleValues,
        initialFormat: ReconnectDeviceFormat(sampleRate: 16_000, channels: 1),
        initialSampleValue: 0.25,
        clock: clock
    )
    let diskSpace = WindowsCaptureDiskSpaceProvider(query: { _ in
        UInt64(CaptureDiskPolicy.requiredStartBytes)
    })
    let power = WindowsRecordingPowerProvider(
        acquire: { probe.acquirePower() },
        release: { probe.releasePower() }
    )
    let capture = WindowsCaptureSource(
        source: source,
        device: selection,
        directory: root,
        writer: writer,
        factory: factory,
        diskSpace: diskSpace,
        power: power,
        clock: clock,
        qpc100ns: { clock.qpc100ns },
        automaticPolling: false,
        onWarning: { probe.recordWarning($0) },
        onFailure: { probe.recordFailure($0) },
        onDropouts: { probe.recordDropouts($0) },
        onSilenceChanged: { probe.recordSilence($0) },
        onDeviceWaitingChanged: { probe.recordWaiting($0) },
        onDeviceLost: { probe.recordDeviceLost($0) }
    )
    return ReconnectHarness(
        root: root,
        source: capture,
        factory: factory,
        clock: clock,
        probe: probe
    )
}

private func endpoint(_ id: String, isDefault: Bool) -> WindowsCaptureEndpoint {
    WindowsCaptureEndpoint(id: id, name: "Fake \(id)", isDefault: isDefault)
}

@MainActor
private func removeReconnectTestDirectory(_ directory: URL) {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
    precondition(resolvedDirectory.isFileURL && resolvedDirectory.baseURL == nil)
    precondition(resolvedDirectory.deletingLastPathComponent() == temporaryDirectory)
    precondition(resolvedDirectory.lastPathComponent.hasPrefix("WindowsCaptureReconnect-"))
    do {
        try fileManager.removeItem(at: resolvedDirectory)
    } catch {
        Issue.record("Could not remove reconnect test directory: \(error)")
    }
}

private func readCommittedAudio(_ checkpoint: AudioCheckpoint, root: URL) throws -> [Float] {
    try checkpoint.chunkFiles.flatMap {
        try readFloat32LEFile(root.appending(path: "audio").appending(path: $0))
    }
}
#endif
