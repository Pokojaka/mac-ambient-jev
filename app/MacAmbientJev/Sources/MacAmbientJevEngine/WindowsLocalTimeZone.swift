import Foundation
import WinSDK

struct WindowsLocalTimeZoneError: Error, CustomStringConvertible {
    let description: String
}

/// The machine's local time zone. swift-corelibs-foundation's `TimeZone.current` reports GMT on Windows,
/// so the zone is read from the OS and mapped to its IANA identifier with ICU.
enum WindowsLocalTimeZone {
    static func current() throws -> TimeZone {
        var information = DYNAMIC_TIME_ZONE_INFORMATION()
        guard GetDynamicTimeZoneInformation(&information) != DWORD(TIME_ZONE_ID_INVALID) else {
            throw WindowsLocalTimeZoneError(
                description: "GetDynamicTimeZoneInformation failed (Win32 \(GetLastError()))"
            )
        }
        let windowsID = withUnsafePointer(to: &information.TimeZoneKeyName) { keyName in
            keyName.withMemoryRebound(to: UInt16.self, capacity: 128) {
                String(decodingCString: $0, as: UTF16.self)
            }
        }
        return try timeZone(windowsID: windowsID)
    }

    private typealias TimeZoneIDForWindowsID = @convention(c) (
        UnsafePointer<UInt16>?, Int32, UnsafePointer<CChar>?, UnsafeMutablePointer<UInt16>?, Int32,
        UnsafeMutablePointer<Int32>?
    ) -> Int32

    /// `ucal_getTimeZoneIDForWindowsID` is looked up in Foundation's ICU at run time. A static reference would
    /// bind to the system icu.dll that WinSDK links, which the staged engine must not depend on.
    private static func icuTimeZoneIDForWindowsID() throws -> TimeZoneIDForWindowsID {
        guard let module = GetModuleHandleW("_FoundationICU.dll".wide),
              let address = GetProcAddress(module, "ucal_getTimeZoneIDForWindowsID") else {
            throw WindowsLocalTimeZoneError(
                description: "_FoundationICU.dll does not export ucal_getTimeZoneIDForWindowsID"
            )
        }
        return unsafeBitCast(address, to: TimeZoneIDForWindowsID.self)
    }

    static func timeZone(windowsID: String) throws -> TimeZone {
        let lookup = try icuTimeZoneIDForWindowsID()
        var status: Int32 = 0
        var buffer = [UInt16](repeating: 0, count: 128)
        let length = lookup(Array(windowsID.utf16) + [0], -1, nil, &buffer, Int32(buffer.count), &status)
        guard status <= 0, length > 0, Int(length) <= buffer.count else {
            throw WindowsLocalTimeZoneError(
                description: "Windows time zone \"\(windowsID)\" has no IANA identifier (ICU status \(status))"
            )
        }
        let identifier = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
        guard let zone = TimeZone(identifier: identifier) else {
            throw WindowsLocalTimeZoneError(
                description: "Windows time zone \"\(windowsID)\" maps to unknown identifier \"\(identifier)\""
            )
        }
        return zone
    }
}

private extension String {
    var wide: [UInt16] { Array(utf16) + [0] }
}
