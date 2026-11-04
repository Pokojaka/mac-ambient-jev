import Foundation
import Testing
import WinSDK
@testable import MacAmbientJevEngine

@Suite struct WindowsLocalTimeZoneTests {
    @Test func theLocalZoneHasTheOffsetWindowsReports() throws {
        var information = TIME_ZONE_INFORMATION()
        let id = GetTimeZoneInformation(&information)
        #expect(id != DWORD(TIME_ZONE_ID_INVALID))
        let bias = Int(information.Bias) + Int(id == DWORD(TIME_ZONE_ID_DAYLIGHT) ? information.DaylightBias : information.StandardBias)

        let zone = try WindowsLocalTimeZone.current()

        #expect(zone.secondsFromGMT(for: Date()) == -bias * 60)
    }

    @Test func aWindowsZoneMapsToItsIANAZone() throws {
        #expect(try WindowsLocalTimeZone.timeZone(windowsID: "Tokyo Standard Time").identifier == "Asia/Tokyo")
    }

    @Test func anUnknownWindowsZoneFails() {
        #expect(throws: WindowsLocalTimeZoneError.self) {
            try WindowsLocalTimeZone.timeZone(windowsID: "Nowhere Standard Time")
        }
    }
}
