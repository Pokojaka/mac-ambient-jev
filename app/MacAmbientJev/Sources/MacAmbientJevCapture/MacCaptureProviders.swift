import AVFoundation
import Foundation
import IOKit.audio
import IOKit.pwr_mgt
import MacAmbientJevCore
import MacAmbientJevPipeline

@MainActor
final class SystemRecordingPower: RecordingPowerProviding {
    private var assertionID: IOPMAssertionID?
    private var activity: NSObjectProtocol?
    private let reason = "録音中のためスリープを防止しています"

    func acquire() -> Bool {
        precondition(activity == nil)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
            reason: reason
        )
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if status == kIOReturnSuccess {
            assertionID = id
            return true
        }
        return false
    }

    func release() {
        if let assertionID {
            _ = IOPMAssertionRelease(assertionID)
            self.assertionID = nil
        }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

struct CaptureInputWarnings {
    static func isLowRateBluetooth(transportType: Int32, sampleRate: Double) -> Bool {
        transportType == Int32(kIOAudioDeviceTransportTypeBluetooth) && sampleRate <= 24_000
    }
}

struct VolumeCaptureDiskSpace: CaptureDiskSpaceProviding {
    func availableBytes(at url: URL) throws -> Int64? {
        try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}

protocol CaptureNotificationProviding: Sendable {
    func observe(
        _ name: Notification.Name,
        object: AnyObject?,
        using callback: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol
    func remove(_ token: NSObjectProtocol)
}

struct SystemCaptureNotifications: CaptureNotificationProviding {
    func observe(
        _ name: Notification.Name,
        object: AnyObject?,
        using callback: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: nil, using: callback)
    }

    func remove(_ token: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(token)
    }
}

@MainActor
final class CaptureFailureObservers {
    private let provider: any CaptureNotificationProviding
    private var tokens: [NSObjectProtocol] = []

    init(provider: any CaptureNotificationProviding) { self.provider = provider }

    func start(
        session: AnyObject,
        device: AnyObject,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) {
        precondition(tokens.isEmpty)
        tokens = [
            provider.observe(AVCaptureSession.runtimeErrorNotification, object: session) { _ in
                Task { @MainActor in onFailure("マイクの動作エラーが発生しました。録音を停止しました") }
            },
            provider.observe(AVCaptureSession.wasInterruptedNotification, object: session) { _ in
                Task { @MainActor in onFailure("マイク入力が中断されました。録音を停止しました") }
            },
            provider.observe(AVCaptureDevice.wasDisconnectedNotification, object: device) { _ in
                Task { @MainActor in onFailure("マイクが切断されました。録音を停止しました") }
            }
        ]
    }

    func stop() {
        for token in tokens { provider.remove(token) }
        tokens.removeAll()
    }
}
