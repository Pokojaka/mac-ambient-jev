#if os(Windows)
import Foundation
import Testing
import CMiniaudio
import MacAmbientJevCore
import MacAmbientJevWindowsSupport

@MainActor
struct WindowsCaptureConfigurationTests {
    @Test("production WASAPI configuration is conservative for capture and loopback")
    func productionConfigurationUsesConservativeSettings() {
        for loopback: Int32 in [0, 1] {
            var values = mja_capture_config_values(
                period_milliseconds: 0,
                periods: 0,
                conservative: 0,
                pro_audio: 0,
                no_auto_stream_routing: 0,
                period_frames: 0,
                loopback: 0
            )

            let result = mja_capture_inspect_config(loopback, &values)

            #expect(result == 0)
            #expect(values.period_milliseconds == 100)
            #expect(values.periods == 3)
            #expect(values.conservative == 1)
            #expect(values.pro_audio == 1)
            #expect(values.no_auto_stream_routing == 1)
            #expect(values.period_frames == 0)
            #expect(values.loopback == loopback)
        }
    }

    @Test("configuration inspection rejects invalid loopback modes")
    func rejectsInvalidLoopbackModes() {
        for loopback: Int32 in [-1, 2] {
            var values = mja_capture_config_values(
                period_milliseconds: 0,
                periods: 0,
                conservative: 0,
                pro_audio: 0,
                no_auto_stream_routing: 0,
                period_frames: 0,
                loopback: 0
            )

            #expect(mja_capture_inspect_config(loopback, &values) != 0)
        }
    }

    @Test("configuration inspection rejects a nil output")
    func rejectsNilOutput() {
        #expect(mja_capture_inspect_config(0, nil) != 0)
    }

    @Test("capture rings cover ten seconds and the native period-group minimum")
    func ringCapacityCoversPeriodGroupsAndTenSeconds() {
        let periodMilliseconds = Double(MJA_CAPTURE_PERIOD_MILLISECONDS)
        let periods = Double(MJA_CAPTURE_PERIODS)
        let periodGroupSeconds = periodMilliseconds / 1_000 * periods
        let bufferedGroups = (AudioBlockRing.minimumBufferedSeconds / periodGroupSeconds).rounded(.up)

        for sampleRate in [8_000.0, 16_000, 44_100, 48_000, 96_000] {
            let periodFrames = (sampleRate * periodMilliseconds / 1_000).rounded(.up)
            let slotsPerPeriod = (periodFrames / 512).rounded(.up)
            let expectedCapacity = Int(slotsPerPeriod * periods * bufferedGroups)
            let capacity = WindowsCaptureSource.ringCapacity(sampleRate: sampleRate)

            #expect(capacity == expectedCapacity)
            #expect(Double(capacity * 512) / sampleRate >= AudioBlockRing.minimumBufferedSeconds)
            #expect(capacity >= AudioBlockRing.capacityForDuration(
                sampleRate: sampleRate,
                blockFrameCapacity: 512
            ))
        }
    }

    @Test("an unresolved endpoint reports the native open operation and code")
    func startTimeOpenFailureNamesNativeOperationAndCode() async throws {
        let endpointID = "WindowsCaptureConfigurationTests-missing-\(UUID().uuidString)"
        let factory = WindowsWASAPICaptureFactory()

        let device: any WindowsCaptureDevice
        do {
            device = try factory.open(
                source: .microphone,
                device: .endpointID(endpointID)
            )
        } catch {
            let description = error.localizedDescription
            #expect(description.contains("mja_capture_open"))
            #expect(description.contains("-204"))
            return
        }

        do {
            try device.stopJoin()
        } catch {
            #expect(Bool(false), "Unexpected cleanup failure after opening a missing endpoint: \(error)")
        }
        #expect(Bool(false), "The factory unexpectedly opened a unique nonexistent endpoint")
    }

    @Test("device-loss classification uses a strict native error whitelist")
    func classifiesOnlyActualDeviceLossErrors() {
        let deviceLossErrors: [Int32] = [
            Int32(bitPattern: 0x88890004),
            1167,
            Int32(bitPattern: 0x80070490),
            -11003
        ]
        for error in deviceLossErrors {
            #expect(mja_capture_is_device_lost_error(error) != 0)
        }

        // Non-device-loss native errors stay outside the strict device-loss whitelist.
        let nonLossNativeFailures: [Int32] = [
            -401,
            -204,
            -22,
            Int32(bitPattern: 0x80070005),
            -77_777
        ]
        for error in nonLossNativeFailures {
            #expect(mja_capture_is_device_lost_error(error) == 0)
        }

        #expect(mja_capture_is_device_lost_error(0) == 0)
    }

    @Test("capture endpoint ID query accepts a nil capture")
    func endpointIDQueryAcceptsNilCapture() {
        #expect(mja_capture_endpoint_id(nil) == nil)
    }
}
#endif
