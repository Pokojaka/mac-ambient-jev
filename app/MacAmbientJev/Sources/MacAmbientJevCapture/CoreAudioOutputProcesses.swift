import CoreAudio
import Darwin
import MacAmbientJevPipeline

/// Polls Core Audio process state without creating a tap or starting capture.
struct CoreAudioOutputProcesses: SystemAudioOutputProcessProviding {
    func runningExternalOutputPIDs() async -> Set<Int32>? {
        await Task.detached(priority: .utility) {
            Self.snapshotExternalOutputPIDs()
        }.value
    }

    private static func snapshotExternalOutputPIDs() -> Set<Int32>? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = address(kAudioHardwarePropertyProcessObjectList)
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &byteCount) == noErr,
              byteCount % UInt32(MemoryLayout<AudioObjectID>.stride) == 0 else {
            return nil
        }
        if byteCount == 0 { return [] }
        var objects = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(byteCount) / MemoryLayout<AudioObjectID>.stride
        )
        let listStatus = objects.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(system, &listAddress, 0, nil, &byteCount, buffer.baseAddress!)
        }
        guard listStatus == noErr,
              byteCount % UInt32(MemoryLayout<AudioObjectID>.stride) == 0,
              Int(byteCount) / MemoryLayout<AudioObjectID>.stride <= objects.count else {
            return nil
        }

        let ownPID = getpid()
        var external: Set<Int32> = []
        for object in objects.prefix(Int(byteCount) / MemoryLayout<AudioObjectID>.stride) {
            guard let running: UInt32 = property(kAudioProcessPropertyIsRunningOutput, of: object) else {
                return nil
            }
            guard running != 0 else { continue }
            guard let pid: pid_t = property(kAudioProcessPropertyPID, of: object), pid > 0,
                  let isDescendant = isDescendantOrSelf(pid, of: ownPID) else {
                return nil
            }
            if !isDescendant { external.insert(pid) }
        }
        return external
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func property<Value: FixedWidthInteger>(
        _ selector: AudioObjectPropertySelector, of object: AudioObjectID
    ) -> Value? {
        var value: Value = .zero
        var address = address(selector)
        var bytes = UInt32(MemoryLayout<Value>.size)
        guard AudioObjectGetPropertyData(
            object, &address, 0, nil, &bytes, &value
        ) == noErr, bytes == UInt32(MemoryLayout<Value>.size) else {
            return nil
        }
        return value
    }

    /// A failed parent lookup is unknown, not evidence that a process is external.
    static func isDescendantOrSelf(
        _ pid: pid_t, of ownPID: pid_t, parent: (pid_t) -> pid_t?
    ) -> Bool? {
        var current = pid
        var visited: Set<pid_t> = []
        while current > 1 {
            if current == ownPID { return true }
            guard visited.insert(current).inserted, let next = parent(current) else { return nil }
            current = next
        }
        return current == ownPID
    }

    private static func isDescendantOrSelf(_ pid: pid_t, of ownPID: pid_t) -> Bool? {
        isDescendantOrSelf(pid, of: ownPID) { current in
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            let result = mib.withUnsafeMutableBufferPointer { buffer in
                sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
            }
            guard result == 0, size == MemoryLayout<kinfo_proc>.size else { return nil }
            return info.kp_eproc.e_ppid
        }
    }
}
