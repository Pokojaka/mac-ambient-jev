import AVFoundation
import Foundation
import IOKit.audio
import IOKit.pwr_mgt
import MacAmbientJevCore

@MainActor
protocol RecordingPowerProviding {
    /// A failed system assertion is nonfatal: the App Nap activity is still held.
    func acquire() -> Bool
    func release()
}

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

@MainActor
final class RecordingPowerLifetime {
    private let provider: any RecordingPowerProviding
    private(set) var active = false

    init(provider: any RecordingPowerProviding) { self.provider = provider }

    func begin() -> Bool {
        precondition(!active)
        active = true
        return provider.acquire()
    }

    func end() {
        guard active else { return }
        active = false
        provider.release()
    }
}

protocol CaptureClock: Sendable {
    func now() -> TimeInterval
}

struct SystemCaptureClock: CaptureClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

struct CaptureHealth {
    static let firstBufferDeadline: TimeInterval = 3
    static let stallInterval: TimeInterval = 3

    static func hasStalled(startedAt: TimeInterval, lastBufferMillis: Int64, now: TimeInterval) -> Bool {
        now - (lastBufferMillis == 0 ? startedAt : Double(lastBufferMillis) / 1_000)
            >= (lastBufferMillis == 0 ? firstBufferDeadline : stallInterval)
    }

    static func isSilent(silentSinceMillis: Int64, now: TimeInterval) -> Bool {
        silentSinceMillis > 0 && now - Double(silentSinceMillis) / 1_000 >= 30
    }
}

enum CaptureStartStatus: Equatable {
    case waiting, ready, cancelled, failed(String), timedOut

    static func evaluate(
        startedAt: TimeInterval, now: TimeInterval, lastBufferMillis: Int64,
        cancelled: Bool, failure: String?
    ) -> Self {
        if cancelled { return .cancelled }
        if let failure { return .failed(failure) }
        if lastBufferMillis != 0 { return .ready }
        return now - startedAt >= CaptureHealth.firstBufferDeadline ? .timedOut : .waiting
    }
}

struct CaptureInputWarnings {
    static func isLowRateBluetooth(transportType: Int32, sampleRate: Double) -> Bool {
        transportType == Int32(kIOAudioDeviceTransportTypeBluetooth) && sampleRate <= 24_000
    }
}

protocol CaptureDiskSpaceProviding: Sendable {
    func availableBytes(at url: URL) throws -> Int64?
}

struct VolumeCaptureDiskSpace: CaptureDiskSpaceProviding {
    func availableBytes(at url: URL) throws -> Int64? {
        try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}

struct CaptureDiskPolicy: Sendable {
    static let sessionSeconds: Int64 = 90 * 60
    static let marginBytes: Int64 = 256_000_000
    static let stopFloorBytes: Int64 = 128_000_000

    static func requiredStartBytes(sampleRate: Double, channelCount: Int) -> Int64 {
        Int64((sampleRate * Double(channelCount) * 4 * Double(sessionSeconds)).rounded(.up))
            + marginBytes
    }
    static func mayStart(availableBytes: Int64, sampleRate: Double, channelCount: Int) -> Bool {
        availableBytes >= requiredStartBytes(sampleRate: sampleRate, channelCount: channelCount)
    }
    static func checkStart(
        diskSpace: any CaptureDiskSpaceProviding, directory: URL,
        sampleRate: Double, channelCount: Int,
        onWarning: (String) -> Void
    ) throws {
        let available: Int64?
        do {
            available = try diskSpace.availableBytes(at: directory)
        } catch {
            onWarning("録音開始前の空き容量を確認できませんでした")
            return
        }
        guard let available else {
            onWarning("録音開始前の空き容量を確認できませんでした")
            return
        }
        guard mayStart(availableBytes: available, sampleRate: sampleRate, channelCount: channelCount)
        else {
            throw AudioCaptureEngineError.insufficientDiskSpace(
                requiredStartBytes(sampleRate: sampleRate, channelCount: channelCount)
            )
        }
    }


    static func mustStop(availableBytes: Int64) -> Bool {
        availableBytes < stopFloorBytes
    }
}

/// Poll-driven so capture timing and disk failure paths are testable without a device.
@MainActor
final class CaptureHealthMonitor {
    private let source: CaptureSource
    private let clock: any CaptureClock
    private let diskSpace: any CaptureDiskSpaceProviding
    private let directory: URL
    private let onFailure: @MainActor @Sendable (String) -> Void
    private let onWarning: @MainActor @Sendable (String) -> Void
    private let onDropouts: @MainActor @Sendable (UInt64) -> Void
    private let onSilenceChanged: @MainActor @Sendable (Bool) -> Void
    private let startedAt: TimeInterval
    private var lastDiskCheck: TimeInterval
    private var warnedSilence = false

    init(
        source: CaptureSource,
        clock: any CaptureClock, diskSpace: any CaptureDiskSpaceProviding, directory: URL,
        startedAt: TimeInterval,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onWarning: @escaping @MainActor @Sendable (String) -> Void,
        onDropouts: @escaping @MainActor @Sendable (UInt64) -> Void,
        onSilenceChanged: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        self.source = source
        self.clock = clock
        self.diskSpace = diskSpace
        self.directory = directory
        self.onFailure = onFailure
        self.onWarning = onWarning
        self.onDropouts = onDropouts
        self.onSilenceChanged = onSilenceChanged
        self.startedAt = startedAt
        lastDiskCheck = startedAt
    }

    /// Returns false after a fatal failure; the owner stops and finalizes capture.
    func poll(lastBufferMillis: Int64, silentSinceMillis: Int64, dropouts: UInt64) -> Bool {
        let now = clock.now()
        // Polling starts only once the first buffer has arrived.
        if lastBufferMillis != 0,
           CaptureHealth.hasStalled(startedAt: startedAt, lastBufferMillis: lastBufferMillis, now: now) {
            switch source {
            case .microphone: onFailure("マイクから音声が届かなくなりました。録音を停止しました")
            case .systemAudio: onFailure("システム音声が届かなくなりました。録音を停止しました")
            }
            return false
        }
        if !warnedSilence, CaptureHealth.isSilent(silentSinceMillis: silentSinceMillis, now: now) {
            warnedSilence = true
            onSilenceChanged(true)
        } else if warnedSilence, silentSinceMillis == 0 {
            warnedSilence = false
            onSilenceChanged(false)
        }
        onDropouts(dropouts)
        if now - lastDiskCheck >= 30 {
            lastDiskCheck = now
            do {
                guard let free = try diskSpace.availableBytes(at: directory) else {
                    onWarning("録音中の空き容量を確認できませんでした")
                    return true
                }
                if CaptureDiskPolicy.mustStop(availableBytes: free) {
                    onFailure("空き容量が不足しています。録音を停止して保存しました")
                    return false
                }
            } catch {
                onWarning("録音中の空き容量を確認できませんでした")
            }
        }
        return true
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
