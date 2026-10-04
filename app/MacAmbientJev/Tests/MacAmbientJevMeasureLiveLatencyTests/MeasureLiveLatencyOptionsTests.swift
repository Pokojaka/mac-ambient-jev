import Foundation
import Testing
@testable import MacAmbientJevMeasureLiveLatency

@Test
func sampleRateRejectsNonfiniteAndOutOfRangeValues() throws {
    for value in ["nan", "inf", "-inf", "999", "768001"] {
        do {
            _ = try Options.parse(["--sessions-root", "/tmp/sessions", "--sample-rate", value, "/tmp/input.wav"])
            Issue.record("sample rate \(value) must be rejected")
        } catch ReplayError.invalidOption(let option) {
            #expect(option == "--sample-rate")
        } catch {
            Issue.record("unexpected error for \(value): \(error)")
        }
    }
}

@Test
func sampleRateAcceptsInclusiveBounds() throws {
    for value in ["1000", "768000"] {
        let options = try Options.parse(["--sessions-root", "/tmp/sessions", "--sample-rate", value, "/tmp/input.wav"])
        #expect(options.sampleRate == Double(value))
    }
}

@Test
func sessionsRootIsRequiredAndMustBeUniqueAndNonempty() {
    for arguments in [
        ["/tmp/input.wav"],
        ["--sessions-root", "/tmp/sessions", "--sessions-root", "/tmp/other", "/tmp/input.wav"],
        ["--sessions-root", "", "/tmp/input.wav"],
        ["--sessions-root", "/tmp/sessions"]
    ] {
        #expect(throws: ReplayError.self) {
            _ = try Options.parse(arguments)
        }
    }
}
