import Foundation
import Synchronization
import Testing
import MacAmbientJevPipeline

private final class MutableReconnectClock: CaptureClock {
    private let milliseconds: Atomic<Int64>

    init(milliseconds: Int64) {
        self.milliseconds = Atomic(milliseconds)
    }

    func set(milliseconds: Int64) {
        self.milliseconds.store(milliseconds, ordering: .relaxed)
    }

    func now() -> TimeInterval {
        Double(milliseconds.load(ordering: .relaxed)) / 1_000
    }
}

struct CaptureDeviceReconnectTests {
    @Test("the pinned endpoint resumes at 29.999 seconds")
    func pinnedEndpointResumesBeforeDeadline() {
        let clock = MutableReconnectClock(milliseconds: 0)
        let endpoint = CaptureReconnectEndpoint(id: "speaker-output", isDefault: true)
        var reconnect = CaptureDeviceReconnect(endpointID: endpoint.id, followsDefaultOutput: false)

        let startedWaiting = reconnect.deviceLost(now: clock.now())
        #expect(startedWaiting)
        clock.set(milliseconds: 29_999)
        let reopenAction = reconnect.poll(now: clock.now(), endpoints: [endpoint])
        #expect(reopenAction == .reopen(endpointID: endpoint.id))
        #expect(reconnect.state == .waiting(endpointID: endpoint.id, startedAt: 0, deadline: 30))
        let resumed = reconnect.didResume(endpointID: endpoint.id, now: clock.now())
        #expect(resumed)
        #expect(reconnect.state == .capturing(endpointID: endpoint.id))
    }

    @Test("the exact deadline expires before considering an available endpoint")
    func deadlineExpiresAtThirtySeconds() {
        let clock = MutableReconnectClock(milliseconds: 0)
        let endpoint = CaptureReconnectEndpoint(id: "speaker-output", isDefault: true)
        var reconnect = CaptureDeviceReconnect(endpointID: endpoint.id, followsDefaultOutput: false)

        let startedWaiting = reconnect.deviceLost(now: clock.now())
        #expect(startedWaiting)
        clock.set(milliseconds: 30_000)
        let expirationAction = reconnect.poll(now: clock.now(), endpoints: [endpoint])
        #expect(expirationAction == .deviceLost)
        #expect(reconnect.state == .stopped)
    }

    @Test("pinned reconnect ignores an unrelated microphone endpoint")
    func pinnedReconnectIgnoresUnrelatedMicrophone() {
        let clock = MutableReconnectClock(milliseconds: 0)
        var reconnect = CaptureDeviceReconnect(endpointID: "speaker-output", followsDefaultOutput: false)
        let startedWaiting = reconnect.deviceLost(now: clock.now())
        #expect(startedWaiting)

        clock.set(milliseconds: 5_000)
        let microphone = CaptureReconnectEndpoint(id: "microphone-input", isDefault: true)
        let action = reconnect.poll(now: clock.now(), endpoints: [microphone])
        #expect(action == .none)
        #expect(reconnect.state == .waiting(endpointID: "speaker-output", startedAt: 0, deadline: 30))
    }

    @Test("following the default output selects its new endpoint ID")
    func followsDefaultOutputAfterDeviceChange() {
        let clock = MutableReconnectClock(milliseconds: 0)
        var reconnect = CaptureDeviceReconnect(endpointID: "old-output", followsDefaultOutput: true)
        let startedWaiting = reconnect.deviceLost(now: clock.now())
        #expect(startedWaiting)

        clock.set(milliseconds: 1_000)
        let microphone = CaptureReconnectEndpoint(id: "microphone-input", isDefault: false)
        let newDefault = CaptureReconnectEndpoint(id: "new-output", isDefault: true)
        let action = reconnect.poll(now: clock.now(), endpoints: [microphone, newDefault])
        #expect(action == .reopen(endpointID: "new-output"))
        #expect(reconnect.state == .waiting(endpointID: "old-output", startedAt: 0, deadline: 30))
        let resumed = reconnect.didResume(endpointID: newDefault.id, now: clock.now())
        #expect(resumed)
        #expect(reconnect.state == .capturing(endpointID: newDefault.id))
    }

    @Test("a repeated loss does not extend the original deadline")
    func repeatedLossKeepsOriginalDeadline() {
        let clock = MutableReconnectClock(milliseconds: 0)
        let endpoint = CaptureReconnectEndpoint(id: "speaker-output", isDefault: false)
        var reconnect = CaptureDeviceReconnect(endpointID: endpoint.id, followsDefaultOutput: false)

        let startedWaiting = reconnect.deviceLost(now: clock.now())
        #expect(startedWaiting)
        clock.set(milliseconds: 10_000)
        let repeatedLossStarted = reconnect.deviceLost(now: clock.now())
        #expect(!repeatedLossStarted)
        #expect(reconnect.state == .waiting(endpointID: endpoint.id, startedAt: 0, deadline: 30))

        clock.set(milliseconds: 30_000)
        let expirationAction = reconnect.poll(now: clock.now(), endpoints: [endpoint])
        #expect(expirationAction == .deviceLost)
        #expect(reconnect.state == .stopped)
    }

    @Test("a failed reopen remains waiting and expires at the original deadline")
    func failedReopenRemainsWaitingUntilDeadline() {
        let clock = MutableReconnectClock(milliseconds: 0)
        let endpoint = CaptureReconnectEndpoint(id: "speaker-output", isDefault: false)
        var reconnect = CaptureDeviceReconnect(endpointID: endpoint.id, followsDefaultOutput: false)

        let startedWaiting = reconnect.deviceLost(now: clock.now())
        #expect(startedWaiting)
        clock.set(milliseconds: 29_999)
        let firstAction = reconnect.poll(now: clock.now(), endpoints: [endpoint])
        #expect(firstAction == .reopen(endpointID: endpoint.id))
        #expect(reconnect.state == .waiting(endpointID: endpoint.id, startedAt: 0, deadline: 30))
        let retryAction = reconnect.poll(now: clock.now(), endpoints: [endpoint])
        #expect(retryAction == .reopen(endpointID: endpoint.id))
        #expect(reconnect.state == .waiting(endpointID: endpoint.id, startedAt: 0, deadline: 30))

        clock.set(milliseconds: 30_000)
        let expirationAction = reconnect.poll(now: clock.now(), endpoints: [endpoint])
        #expect(expirationAction == .deviceLost)
        #expect(reconnect.state == .stopped)
    }

    @Test("stopped reconnect policy never reopens an endpoint")
    func stoppedReconnectDoesNotReopen() {
        let clock = MutableReconnectClock(milliseconds: 0)
        var reconnect = CaptureDeviceReconnect(endpointID: "speaker-output", followsDefaultOutput: false)
        reconnect.stop()

        let endpoint = CaptureReconnectEndpoint(id: "speaker-output", isDefault: true)
        let action = reconnect.poll(now: clock.now(), endpoints: [endpoint])
        #expect(action == .none)
        #expect(reconnect.state == .stopped)
    }
}
