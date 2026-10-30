import Foundation
import WinSDK
import MacAmbientJevPipeline

struct WindowsResourceMonitorError: Error, LocalizedError, Sendable {
    let diagnostic: String

    var errorDescription: String? {
        diagnostic
    }
}

struct WindowsResourceMonitorCalls: Sendable {
    let create: @Sendable (Bool) throws -> UInt
    let query: @Sendable (UInt) throws -> Bool
    let close: @Sendable (UInt) throws -> Void
    let memory: @Sendable () throws -> InferenceMemoryFacts
    let now: @Sendable () -> Double
    let sleep: @Sendable (Double) -> Void

    static let live = WindowsResourceMonitorCalls(
        create: { low in
            let type = low ? LowMemoryResourceNotification : HighMemoryResourceNotification
            guard let handle = CreateMemoryResourceNotification(type) else {
                throw WindowsResourceMonitorError(diagnostic: "CreateMemoryResourceNotification failed (Win32 \(GetLastError()))")
            }
            return UInt(bitPattern: handle)
        },
        query: { value in
            guard let handle = HANDLE(bitPattern: Int(bitPattern: value)) else {
                throw WindowsResourceMonitorError(diagnostic: "QueryMemoryResourceNotification received a nil handle")
            }
            var state: WindowsBool = false
            guard QueryMemoryResourceNotification(handle, &state) else {
                throw WindowsResourceMonitorError(diagnostic: "QueryMemoryResourceNotification failed (Win32 \(GetLastError()))")
            }
            return state.boolValue
        },
        close: { value in
            guard let handle = HANDLE(bitPattern: Int(bitPattern: value)) else {
                throw WindowsResourceMonitorError(diagnostic: "CloseHandle received a nil handle")
            }
            guard CloseHandle(handle) else {
                throw WindowsResourceMonitorError(diagnostic: "CloseHandle failed (Win32 \(GetLastError()))")
            }
        },
        memory: {
            var status = MEMORYSTATUSEX()
            status.dwLength = DWORD(MemoryLayout<MEMORYSTATUSEX>.size)
            guard GlobalMemoryStatusEx(&status) else {
                throw WindowsResourceMonitorError(diagnostic: "GlobalMemoryStatusEx failed (Win32 \(GetLastError()))")
            }
            return InferenceMemoryFacts(
                physicalMemoryBytes: status.ullTotalPhys,
                freePhysicalMemoryBytes: status.ullAvailPhys,
                commitHeadroomBytes: status.ullAvailPageFile,
                lowMemorySignal: false
            )
        },
        now: { Double(GetTickCount64()) / 1_000 },
        sleep: { Thread.sleep(forTimeInterval: $0) }
    )
}
