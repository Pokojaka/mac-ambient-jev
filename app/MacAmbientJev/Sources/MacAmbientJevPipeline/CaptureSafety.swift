import Foundation
import MacAmbientJevCore

@MainActor
public protocol RecordingPowerProviding {
    /// A failed system assertion is nonfatal: the App Nap activity is still held.
    func acquire() -> Bool
    func release()
}

@MainActor
public final class RecordingPowerLifetime {
    private let provider: any RecordingPowerProviding
    public private(set) var active = false

    public init(provider: any RecordingPowerProviding) { self.provider = provider }

    public func begin() -> Bool {
        precondition(!active)
        active = true
        return provider.acquire()
    }

    public func end() {
        guard active else { return }
        active = false
        provider.release()
    }
}

public protocol CaptureClock: Sendable {
    func now() -> TimeInterval
}

public struct SystemCaptureClock: CaptureClock {
    public init() {}

    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public struct CaptureHealth {
    public static let firstBufferDeadline: TimeInterval = 3
    public static let stallInterval: TimeInterval = 3

    public static func hasStalled(startedAt: TimeInterval, lastBufferMillis: Int64, now: TimeInterval) -> Bool {
        now - (lastBufferMillis == 0 ? startedAt : Double(lastBufferMillis) / 1_000)
            >= (lastBufferMillis == 0 ? firstBufferDeadline : stallInterval)
    }

    public static func isSilent(silentSinceMillis: Int64, now: TimeInterval) -> Bool {
        silentSinceMillis > 0 && now - Double(silentSinceMillis) / 1_000 >= 30
    }
}

public enum CaptureStartStatus: Equatable {
    case waiting, ready, cancelled, failed(String), timedOut

    public static func evaluate(
        startedAt: TimeInterval, now: TimeInterval, lastBufferMillis: Int64,
        cancelled: Bool, failure: String?
    ) -> Self {
        if cancelled { return .cancelled }
        if let failure { return .failed(failure) }
        if lastBufferMillis != 0 { return .ready }
        return now - startedAt >= CaptureHealth.firstBufferDeadline ? .timedOut : .waiting
    }
}

public protocol CaptureDiskSpaceProviding: Sendable {
    func availableBytes(at url: URL) throws -> Int64?
}

public struct CaptureDiskPolicy: Sendable {
    public static let sessionSeconds: Int64 = 90 * 60
    public static let marginBytes: Int64 = 256_000_000
    public static let stopFloorBytes: Int64 = 128_000_000

    public static let requiredStartBytes = Int64(
        (CanonicalAudio.sampleRate * Double(CanonicalAudio.channelCount) * 4 * Double(sessionSeconds)).rounded(.up)
    ) + marginBytes

    public static func mayStart(availableBytes: Int64) -> Bool {
        availableBytes >= requiredStartBytes
    }
    public static func checkStart(
        diskSpace: any CaptureDiskSpaceProviding, directory: URL
    ) throws {
        let available: Int64?
        do {
            available = try diskSpace.availableBytes(at: directory)
        } catch {
            throw AudioCaptureEngineError.diskSpaceUnavailable(error.localizedDescription)
        }
        guard let available else {
            throw AudioCaptureEngineError.diskSpaceUnavailable("ボリュームが空き容量を報告しませんでした")
        }
        guard mayStart(availableBytes: available)
        else {
            throw AudioCaptureEngineError.insufficientDiskSpace(
                requiredStartBytes
            )
        }
    }


    public static func mustStop(availableBytes: Int64) -> Bool {
        availableBytes < stopFloorBytes
    }
}

/// Poll-driven so capture timing and disk failure paths are testable without a device.
@MainActor
public final class CaptureHealthMonitor {
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

    public init(
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
    public func poll(lastBufferMillis: Int64, silentSinceMillis: Int64, dropouts: UInt64) -> Bool {
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
