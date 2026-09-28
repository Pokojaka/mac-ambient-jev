import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

@MainActor
protocol SystemAudioTapProviding: AnyObject {
    var sampleRate: Double { get }
    func start(sink: TimestampedMonoSink, onFailure: @escaping @MainActor @Sendable (String) -> Void) throws
    func stop()
}

enum SystemAudioTapError: LocalizedError {
    case permissionDenied
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "システム音声の録音が許可されていません。システム設定の「プライバシーとセキュリティ」→「画面収録とシステムオーディオ録音」で許可してください"
        case .unavailable(let detail):
            "システム音声を取得できませんでした: \(detail)"
        }
    }
}

/// Owns the tap, private aggregate, IOProc and listeners; every partial start is reversible.
@MainActor
final class SystemAudioTap: SystemAudioTapProviding {
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
    private var deviceListener: AudioObjectPropertyListenerBlock?

    var sampleRate: Double { format.mSampleRate }

    init() throws {
        format = AudioStreamBasicDescription()
        do {
            let ownProcess = try Self.ownProcessObject()
            let description = CATapDescription(monoGlobalTapButExcludeProcesses: [ownProcess])
            description.uuid = UUID(uuidString: tapUUID)!
            description.isPrivate = true
            guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
                throw SystemAudioTapError.permissionDenied
            }
            var tapAddress = Self.address(kAudioTapPropertyFormat)
            var bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioObjectGetPropertyData(tapID, &tapAddress, 0, nil, &bytes, &format), "タップ形式の取得")
            guard format.mSampleRate > 0, format.mFormatID == kAudioFormatLinearPCM,
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
            try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &deviceID), "仮想デバイスの作成")
        } catch {
            stop()
            throw error
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
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

    private static func ownProcessObject() throws -> AudioObjectID {
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
            var tapAddress = Self.address(kAudioTapPropertyFormat)
            var outputAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            let formatListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.notifyChange("システム音声の形式が変わったため、録音を停止しました")
            }
            let deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.notifyChange("出力デバイスが切り替わったため、録音を停止しました")
            }
            self.formatListener = formatListener
            self.deviceListener = deviceListener
            try Self.check(AudioObjectAddPropertyListenerBlock(tapID, &tapAddress, callbackQueue, formatListener), "タップ監視")
            listening = true
            try Self.check(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, callbackQueue, deviceListener), "出力デバイス監視")
            var proc: AudioDeviceIOProcID?
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, callbackQueue) { [weak self] _, input, timestamp, _, _ in
                self?.receive(input: input, timestamp: timestamp, sink: sink)
            }, "音声コールバックの作成")
            ioProc = proc
            guard let proc else { throw SystemAudioTapError.unavailable("音声コールバックがありません") }
            try Self.check(AudioDeviceStart(deviceID, proc), "録音の開始")
            running = true
        } catch {
            stop()
            throw error
        }
    }

    private nonisolated func notifyChange(_ message: String) {
        if !formatInvalid.exchange(true, ordering: .relaxed) {
            Task { @MainActor [weak self] in self?.onFailure?(message) }
        }
    }

    private nonisolated func receive(input: UnsafePointer<AudioBufferList>, timestamp: UnsafePointer<AudioTimeStamp>, sink: TimestampedMonoSink) {
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
            fallbackEndFrame: sink.lastEndFrame
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


    func stop() {
        if running { _ = AudioDeviceStop(deviceID, ioProc); running = false }
        if let ioProc { _ = AudioDeviceDestroyIOProcID(deviceID, ioProc); self.ioProc = nil }
        if listening, let formatListener {
            var address = Self.address(kAudioTapPropertyFormat)
            _ = AudioObjectRemovePropertyListenerBlock(tapID, &address, callbackQueue, formatListener)
        }
        if let deviceListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, callbackQueue, deviceListener)
        }
        listening = false
        formatListener = nil
        deviceListener = nil
        onFailure = nil
        if deviceID != 0 { _ = AudioHardwareDestroyAggregateDevice(deviceID); deviceID = 0 }
        if tapID != 0 { _ = AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }

    deinit { pointers.deallocate(); strides.deallocate() }
}
