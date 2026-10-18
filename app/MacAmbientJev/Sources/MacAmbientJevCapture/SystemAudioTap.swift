import AudioToolbox
import CoreAudio
import Foundation
import MacAmbientJevPipeline
import Synchronization

@MainActor
protocol SystemAudioTapProviding: AnyObject {
    var sampleRate: Double { get }
    func start(sink: TimestampedMonoSink, onFailure: @escaping @MainActor @Sendable (String) -> Void) throws
    /// Attempts every release, then throws `releaseFailed` naming each operation Core Audio refused.
    func stop() throws
}

enum SystemAudioTapError: LocalizedError {
    case permissionDenied
    case unavailable(String)
    /// `after` is the failure that triggered the release, when one did.
    case releaseFailed(operations: [String], after: String?)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "システム音声の録音が許可されていません。システム設定の「プライバシーとセキュリティ」→「画面収録とシステムオーディオ録音」で許可してください。許可しても録音を開始できない場合は、アプリを終了して開き直してください。"
        case .unavailable(let detail):
            "システム音声を取得できませんでした: \(detail)"
        case .releaseFailed(let operations, let after):
            (after.map { "\($0)。" } ?? "")
                + "システム音声の取得資源を解放できませんでした（\(operations.joined(separator: "、"))）。アプリを終了して開き直してください"
        }
    }

    /// Releases `tap` after `error`; a refused release is reported together with that error.
    @MainActor
    static func releasing(_ tap: (any SystemAudioTapProviding)?, after error: any Error) -> any Error {
        guard let tap else { return error }
        do {
            try tap.stop()
            return error
        } catch SystemAudioTapError.releaseFailed(let operations, _) {
            return SystemAudioTapError.releaseFailed(operations: operations, after: error.localizedDescription)
        } catch {
            preconditionFailure("SystemAudioTapProviding.stop throws only releaseFailed")
        }
    }
}

/// Only the Core Audio operations that acquire/release resources are replaceable in tests.
@MainActor
protocol SystemAudioTapHardware {
    func ownProcessObject() throws -> AudioObjectID
    func createTap(_ description: CATapDescription, _ tap: inout AudioObjectID) -> OSStatus
    func tapFormat(_ tap: AudioObjectID, _ format: inout AudioStreamBasicDescription) -> OSStatus
    func createAggregate(_ description: CFDictionary, _ device: inout AudioObjectID) -> OSStatus
    func addFormatListener(_ tap: AudioObjectID, _ queue: DispatchQueue,
                           _ listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    func removeFormatListener(_ tap: AudioObjectID, _ queue: DispatchQueue,
                              _ listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    func createIOProc(_ proc: inout AudioDeviceIOProcID?, _ device: AudioObjectID,
                      _ queue: DispatchQueue, _ callback: @escaping AudioDeviceIOBlock) -> OSStatus
    func start(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus
    func stop(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus
    func destroyIOProc(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus
    func destroyAggregate(_ device: AudioObjectID) -> OSStatus
    func destroyTap(_ tap: AudioObjectID) -> OSStatus
}

struct CoreAudioTapHardware: SystemAudioTapHardware {
    func ownProcessObject() throws -> AudioObjectID { try SystemAudioTap.ownProcessObject() }
    func createTap(_ description: CATapDescription, _ tap: inout AudioObjectID) -> OSStatus {
        AudioHardwareCreateProcessTap(description, &tap)
    }
    func tapFormat(_ tap: AudioObjectID, _ format: inout AudioStreamBasicDescription) -> OSStatus {
        var address = SystemAudioTap.address(kAudioTapPropertyFormat)
        var bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(tap, &address, 0, nil, &bytes, &format)
    }
    func createAggregate(_ description: CFDictionary, _ device: inout AudioObjectID) -> OSStatus {
        AudioHardwareCreateAggregateDevice(description, &device)
    }
    func addFormatListener(_ tap: AudioObjectID, _ queue: DispatchQueue,
                           _ listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        var address = SystemAudioTap.address(kAudioTapPropertyFormat)
        return AudioObjectAddPropertyListenerBlock(tap, &address, queue, listener)
    }
    func removeFormatListener(_ tap: AudioObjectID, _ queue: DispatchQueue,
                              _ listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        var address = SystemAudioTap.address(kAudioTapPropertyFormat)
        return AudioObjectRemovePropertyListenerBlock(tap, &address, queue, listener)
    }
    func createIOProc(_ proc: inout AudioDeviceIOProcID?, _ device: AudioObjectID,
                      _ queue: DispatchQueue, _ callback: @escaping AudioDeviceIOBlock) -> OSStatus {
        AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue, callback)
    }
    func start(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceStart(device, proc)
    }
    func stop(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceStop(device, proc)
    }
    func destroyIOProc(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceDestroyIOProcID(device, proc)
    }
    func destroyAggregate(_ device: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(device)
    }
    func destroyTap(_ tap: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyProcessTap(tap)
    }
}

/// Owns the tap, private aggregate, IOProc and listeners; every partial start is reversible.
@MainActor
final class SystemAudioTap: SystemAudioTapProviding {
    private let hardware: any SystemAudioTapHardware
    private var tapID: AudioObjectID = 0
    private var deviceID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var running = false
    private var listening = false
    private let tapUUID = UUID().uuidString
    private let deviceUID = UUID().uuidString
    private nonisolated(unsafe) var format: AudioStreamBasicDescription
    private let callbackQueue = DispatchQueue(label: "app.mac-ambient-jev.system-audio-tap")
    private let formatInvalid = Atomic(false)
    private nonisolated(unsafe) let pointers = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 32)
    private nonisolated(unsafe) let strides = UnsafeMutablePointer<Int>.allocate(capacity: 32)
    private let timestamps = CaptureFrameTimestampMapper()
    private var onFailure: (@MainActor @Sendable (String) -> Void)?
    private var formatListener: AudioObjectPropertyListenerBlock?
    var sampleRate: Double { format.mSampleRate }

    init(hardware: any SystemAudioTapHardware = CoreAudioTapHardware()) throws {
        self.hardware = hardware
        format = AudioStreamBasicDescription()
        do {
            let ownProcess = try hardware.ownProcessObject()
            let description = CATapDescription(monoGlobalTapButExcludeProcesses: [ownProcess])
            description.uuid = UUID(uuidString: tapUUID)!
            description.isPrivate = true
            description.muteBehavior = .unmuted
            let tapStatus = hardware.createTap(description, &tapID)
            guard tapStatus == noErr else {
                // The tap is the permission boundary; Core Audio does not promise
                // a stable denial status across supported macOS releases.
                throw SystemAudioTapError.permissionDenied
            }
            try Self.check(hardware.tapFormat(tapID, &format), "タップ形式の取得")
            guard format.mSampleRate > 0, format.mSampleRate.isFinite, format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0,
                  format.mChannelsPerFrame <= 32 else {
                throw SystemAudioTapError.unavailable("対応していないFloat32形式です")
            }
            let composition: [String: Any] = [
                "uid": deviceUID, "name": "MacAmbientJev System Audio Tap",
                "private": true, "stacked": false,
                "taps": [["uid": tapUUID, "drift": true]]
            ]
            try Self.check(hardware.createAggregate(composition as CFDictionary, &deviceID), "仮想デバイスの作成")
        } catch {
            throw SystemAudioTapError.releasing(self, after: error)
        }
    }

    fileprivate static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            if status == kAudioHardwareIllegalOperationError || status == -10867 {
                throw SystemAudioTapError.permissionDenied
            }
            throw SystemAudioTapError.unavailable("\(operation) (OSStatus \(status))")
        }
    }

    fileprivate static func ownProcessObject() throws -> AudioObjectID {
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var bytes = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &bytes, &object
        ), "このアプリのプロセス検索")
        guard object != kAudioObjectUnknown else {
            throw SystemAudioTapError.unavailable("このアプリのプロセスを除外できません")
        }
        var actualPID: pid_t = 0
        var actualBytes = UInt32(MemoryLayout<pid_t>.size)
        var pidAddress = Self.address(kAudioProcessPropertyPID)
        try check(AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &actualBytes, &actualPID),
                  "このアプリのプロセス検証")
        guard actualPID == pid else {
            throw SystemAudioTapError.unavailable("プロセスIDを確認できません")
        }
        return object
    }

    func start(sink: TimestampedMonoSink, onFailure: @escaping @MainActor @Sendable (String) -> Void) throws {
        self.onFailure = onFailure
        do {
            // A global tap follows the system mix when the output device changes.
            // Only changes to the tap's audio format require stopping.
            // Core Audio invokes these blocks on callbackQueue, not the starting actor.
            let formatListener: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
                self?.notifyChange("システム音声の形式が変わったため、録音を停止しました")
            }
            self.formatListener = formatListener
            try Self.check(hardware.addFormatListener(tapID, callbackQueue, formatListener), "タップ監視")
            listening = true
            var proc: AudioDeviceIOProcID?
            let procStatus = hardware.createIOProc(&proc, deviceID, callbackQueue) { @Sendable [weak self] _, input, timestamp, _, _ in
                self?.receive(input: input, timestamp: timestamp, sink: sink)
            }
            ioProc = proc
            try Self.check(procStatus, "音声コールバックの作成")
            guard let proc else { throw SystemAudioTapError.unavailable("音声コールバックがありません") }
            try Self.check(hardware.start(deviceID, proc), "録音の開始")
            running = true
        } catch {
            throw SystemAudioTapError.releasing(self, after: error)
        }
    }

    private nonisolated func notifyChange(_ message: String) {
        if !formatInvalid.exchange(true, ordering: .relaxed) {
            Task { @MainActor [weak self] in self?.onFailure?(message) }
        }
    }

    private nonisolated func receive(input: UnsafePointer<AudioBufferList>, timestamp: UnsafePointer<AudioTimeStamp>, sink: TimestampedMonoSink) {
        guard !formatInvalid.load(ordering: .relaxed) else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let channels = Int(format.mChannelsPerFrame)
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let buffersExpected = planar ? channels : 1
        guard list.count == buffersExpected, channels > 0, channels <= 32 else {
            notifyChange("システム音声の形式が変わったため、録音を停止しました")
            return
        }
        let first = list[0]
        let frameCount = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * (planar ? 1 : channels))
        guard frameCount > 0 else { return }
        let startFrame = timestamps.startFrame(
            sampleTime: timestamp.pointee.mFlags.contains(.sampleTimeValid)
                ? timestamp.pointee.mSampleTime : nil,
            hostTimeNanos: timestamp.pointee.mFlags.contains(.hostTimeValid)
                ? AudioConvertHostTimeToNanos(timestamp.pointee.mHostTime) : nil,
            sampleRate: format.mSampleRate,
            contiguousEndFrame: sink.lastEndFrame
        )
        if first.mData == nil {
            var allSilent = true
            for buffer in list where buffer.mData != nil { allSilent = false }
            if allSilent {
                sink.silence(startFrame: startFrame, frameCount: frameCount)
                return
            }
        }
        for channel in 0..<channels {
            let buffer = list[planar ? channel : 0]
            guard let data = buffer.mData,
                  Int(buffer.mDataByteSize) >= frameCount * MemoryLayout<Float>.size * (planar ? 1 : channels) else {
                sink.missing(startFrame: startFrame, frameCount: frameCount)
                return
            }
            pointers[channel] = UnsafePointer(data.assumingMemoryBound(to: Float.self)).advanced(by: planar ? 0 : channel)
            strides[channel] = planar ? 1 : channels
        }
        sink.receive(channels: UnsafePointer(pointers), strides: UnsafePointer(strides),
                     channelCount: channels, frameCount: frameCount, startFrame: startFrame)
    }


    /// Each resource is forgotten after one release attempt, so a repeated stop never retries
    /// a refused release on an ID Core Audio may have reused.
    func stop() throws {
        var failed: [String] = []
        func attempt(_ status: OSStatus, _ operation: String) {
            if status != noErr { failed.append("\(operation) OSStatus \(status)") }
        }
        if running, let ioProc { attempt(hardware.stop(deviceID, ioProc), "録音の停止"); running = false }
        if let ioProc { attempt(hardware.destroyIOProc(deviceID, ioProc), "音声コールバックの破棄"); self.ioProc = nil }
        if listening, let formatListener {
            attempt(hardware.removeFormatListener(tapID, callbackQueue, formatListener), "タップ監視の解除")
        }
        listening = false
        formatListener = nil
        onFailure = nil
        if deviceID != 0 { attempt(hardware.destroyAggregate(deviceID), "仮想デバイスの破棄"); deviceID = 0 }
        if tapID != 0 { attempt(hardware.destroyTap(tapID), "タップの破棄"); tapID = 0 }
        if !failed.isEmpty { throw SystemAudioTapError.releaseFailed(operations: failed, after: nil) }
    }

    deinit { pointers.deallocate(); strides.deallocate() }
}
