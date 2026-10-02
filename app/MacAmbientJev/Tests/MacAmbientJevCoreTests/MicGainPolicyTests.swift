import Foundation
import Testing
@testable import MacAmbientJevCore

private func meanSquare(_ dBFS: Double) -> Double { pow(10, dBFS / 10) }

private func speech(_ start: Double, seconds: Double, dBFS: Double, peak: Float) -> MicLevelWindow {
    MicLevelWindow(startSeconds: start, endSeconds: start + 0.25, speechSeconds: seconds,
                   speechMeanSquare: meanSquare(dBFS), speechPeak: peak,
                   inputPeak: 0, clippedFraction: 0)
}

private func raw(_ start: Double, peak: Float, clipped: Double) -> MicLevelWindow {
    MicLevelWindow(startSeconds: start, endSeconds: start + 0.1, speechSeconds: 0,
                   speechMeanSquare: nil, speechPeak: 0, inputPeak: peak, clippedFraction: clipped)
}

private struct Driver {
    var policy = MicGainPolicy()
    var scalars: [Float]
    var canAdjust: Bool

    mutating func feed(_ window: MicLevelWindow, latency: Double) -> MicGainDecision {
        policy.observe(window, currentScalars: scalars, canAdjust: canAdjust,
                       nowSeconds: window.endSeconds + latency)
    }

    /// Contiguous 250-ms fully voiced windows; returns (window end, decision) per window.
    mutating func speak(from start: Double, windows: Int, dBFS: Double, peak: Float) -> [(Double, MicGainDecision)] {
        (0..<windows).map { index in
            let window = speech(start + Double(index) * 0.25, seconds: 0.25, dBFS: dBFS, peak: peak)
            return (window.endSeconds, feed(window, latency: 0.05))
        }
    }

    mutating func rawRun(from start: Double, windows: Int, clipped: Double) -> [(Double, MicGainDecision)] {
        (0..<windows).map { index in
            let window = raw(start + Double(index) * 0.1, peak: clipped > 0 ? 1 : 0.2, clipped: clipped)
            return (window.endSeconds, feed(window, latency: 0.02))
        }
    }
}

/// Requested steps keyed by the index of the window that produced them.
private func deltas(_ run: [(Double, MicGainDecision)]) -> [Int: Float] {
    Dictionary(uniqueKeysWithValues: run.enumerated().compactMap { index, item in
        item.1.volumeDelta.map { (index, $0) }
    })
}

@Suite struct MicGainPolicyTests {
    @Test("Quiet confirmed speech requests one +0.05 step once three seconds of evidence exist")
    func quietSpeechRaisesAfterThreeSeconds() {
        var driver = Driver(scalars: [0.53], canAdjust: true)
        let run = driver.speak(from: 0, windows: 20, dBFS: -40, peak: 0.1)
        #expect(deltas(run) == [11: 0.05])
        #expect(run.allSatisfy { $0.1.warning == nil })
    }

    @Test("Silence, noise peaks and unconfirmed zero windows never raise or warn low")
    func nonSpeechNeverRaises() {
        var driver = Driver(scalars: [0.2], canAdjust: true)
        let zeros = driver.rawRun(from: 0, windows: 100, clipped: 0)
        let noise = (0..<100).map { index in
            driver.feed(raw(10 + Double(index) * 0.1, peak: 0.6, clipped: 0), latency: 0.02)
        }
        #expect(zeros.allSatisfy { $0.1 == MicGainDecision(volumeDelta: nil, warning: nil) })
        #expect(noise.allSatisfy { $0 == MicGainDecision(volumeDelta: nil, warning: nil) })
    }

    @Test("Speech energy is weighted by confirmed speech duration, not by window count")
    func energyIsDurationWeighted() {
        func decisions(loudSpeechSeconds: Double) -> [Float] {
            var driver = Driver(scalars: [0.5], canAdjust: true)
            var result: [Float] = []
            for index in 0..<11 {
                let window = speech(Double(index) * 0.25, seconds: 0.25, dBFS: -40, peak: 0.1)
                if let delta = driver.feed(window, latency: 0.05).volumeDelta { result.append(delta) }
            }
            let loud = speech(2.75, seconds: loudSpeechSeconds, dBFS: -20, peak: 0.3)
            if let delta = driver.feed(loud, latency: 0.05).volumeDelta { result.append(delta) }
            let quiet = speech(3.0, seconds: 0.25, dBFS: -40, peak: 0.1)
            if let delta = driver.feed(quiet, latency: 0.05).volumeDelta { result.append(delta) }
            return result
        }
        // 2.75 s at -40 dBFS plus 0.25 s at -20 dBFS weighs to about -30.3 dBFS: not low.
        #expect(decisions(loudSpeechSeconds: 0.25).isEmpty)
        // With 0.02 s of loud speech the weighted level is about -37.8 dBFS, although a
        // per-window average would still read about -30.7 dBFS.
        #expect(decisions(loudSpeechSeconds: 0.02) == [0.05])
    }

    @Test("A speech gap over two seconds discards earlier low evidence")
    func speechGapResetsEvidence() {
        func raised(gap: Double) -> Bool {
            var driver = Driver(scalars: [0.5], canAdjust: true)
            let before = driver.speak(from: 0, windows: 10, dBFS: -40, peak: 0.1)
            let after = driver.speak(from: 2.5 + gap, windows: 2, dBFS: -40, peak: 0.1)
            return !(deltas(before).isEmpty && deltas(after).isEmpty)
        }
        #expect(raised(gap: 1.9))
        #expect(!raised(gap: 2.1))
    }

    @Test("Speech windows arriving more than two seconds late cannot command a change")
    func lateSpeechIsIgnored() {
        func raised(latency: Double) -> Bool {
            var driver = Driver(scalars: [0.5], canAdjust: true)
            return (0..<16).contains { index in
                let window = speech(Double(index) * 0.25, seconds: 0.25, dBFS: -40, peak: 0.1)
                return driver.feed(window, latency: latency).volumeDelta != nil
            }
        }
        #expect(raised(latency: 1.9))
        #expect(!raised(latency: 2.1))
    }

    @Test("After an applied change, pre-settle speech is excluded and rises keep a five-second cadence")
    func settlingAndRiseCadence() {
        var driver = Driver(scalars: [0.5], canAdjust: true)
        #expect(deltas(driver.speak(from: 0, windows: 12, dBFS: -40, peak: 0.1)) == [11: 0.05])
        driver.policy.didApplyVolumeChange(atSeconds: 3.05)
        driver.scalars = [0.55]
        // Speech starting before 4.55 s is discarded, so fresh evidence completes with the
        // window ending at 7.75 s; the rise requested at 3.05 s blocks another until 8.05 s.
        let run = driver.speak(from: 3.0, windows: 24, dBFS: -40, peak: 0.1)
        #expect(deltas(run) == [19: 0.05])
    }

    @Test("Quiet speech with a peak at or above 0.80 warns instead of raising")
    func peakHeadroomBlocksRise() {
        var guarded = Driver(scalars: [0.5], canAdjust: true)
        let run = guarded.speak(from: 0, windows: 16, dBFS: -40, peak: 0.8)
        #expect(deltas(run).isEmpty)
        #expect(run.last?.1.warning == .low)
        var unguarded = Driver(scalars: [0.5], canAdjust: true)
        #expect(deltas(unguarded.speak(from: 0, windows: 12, dBFS: -40, peak: 0.79)) == [11: 0.05])
    }

    @Test("Only every managed control at 1.0 counts as maxed")
    func ceilingRequiresEveryChannel() {
        var partial = Driver(scalars: [1, 0.6], canAdjust: true)
        #expect(deltas(partial.speak(from: 0, windows: 12, dBFS: -40, peak: 0.1)) == [11: 0.05])
        var maxed = Driver(scalars: [1, 1], canAdjust: true)
        let run = maxed.speak(from: 0, windows: 12, dBFS: -40, peak: 0.1)
        #expect(deltas(run).isEmpty)
        #expect(run.map(\.1.warning).firstIndex(of: .low) == 11)
    }

    @Test("Without control the low warning needs speech evidence and clears on recovery or silence")
    func unsupportedWarningLifecycle() {
        var driver = Driver(scalars: [], canAdjust: false)
        #expect(driver.rawRun(from: 0, windows: 50, clipped: 0).allSatisfy { $0.1.warning == nil })
        let quiet = driver.speak(from: 5, windows: 12, dBFS: -40, peak: 0.1)
        #expect(quiet.map(\.1.warning).firstIndex(of: .low) == 11)
        let transient = driver.speak(from: 8, windows: 4, dBFS: -25, peak: 0.2)
        #expect(transient.last?.1.warning == .low)
        let recovered = driver.speak(from: 9, windows: 8, dBFS: -28, peak: 0.2)
        #expect(recovered.map(\.1.warning).firstIndex(of: nil) == 3)

        var silent = Driver(scalars: [], canAdjust: false)
        #expect(silent.speak(from: 0, windows: 12, dBFS: -40, peak: 0.1).last?.1.warning == .low)
        #expect(silent.feed(raw(10.8, peak: 0, clipped: 0), latency: 0.05).warning == .low)
        #expect(silent.feed(raw(11.0, peak: 0, clipped: 0), latency: 0.02).warning == nil)
    }

    @Test("Comfortable speech between -30 and -18 dBFS keeps the volume")
    func comfortableBandKeeps() {
        var driver = Driver(scalars: [0.5], canAdjust: true)
        let run = driver.speak(from: 0, windows: 40, dBFS: -25, peak: 0.4)
        #expect(run.allSatisfy { $0.1 == MicGainDecision(volumeDelta: nil, warning: nil) })
    }

    @Test("Sustained loud speech lowers by 0.05 at most every two seconds")
    func loudSpeechLowers() {
        var driver = Driver(scalars: [0.8], canAdjust: true)
        let run = driver.speak(from: 0, windows: 12, dBFS: -10, peak: 0.7)
        #expect(deltas(run) == [3: -0.05, 11: -0.05])
        var rearm = Driver(scalars: [0.8], canAdjust: true)
        #expect(deltas(rearm.speak(from: 0, windows: 3, dBFS: -10, peak: 0.7)).isEmpty)
        _ = rearm.speak(from: 0.75, windows: 1, dBFS: -20, peak: 0.2)
        #expect(deltas(rearm.speak(from: 1.0, windows: 3, dBFS: -10, peak: 0.7)).isEmpty)
    }

    @Test("Raw clipping lowers by 0.10 immediately, every half second, and its warning persists and clears")
    func clippingLowersAndWarns() {
        var driver = Driver(scalars: [0.9], canAdjust: true)
        let clipping = driver.rawRun(from: 0, windows: 12, clipped: 0.001)
        #expect(deltas(clipping) == [0: -0.1, 5: -0.1, 10: -0.1])
        #expect(clipping.map(\.1.warning).firstIndex(of: .clipping) == 9)
        let clean = driver.rawRun(from: 1.2, windows: 30, clipped: 0.0009)
        #expect(clean.map(\.1.warning).firstIndex(of: nil) == 29)

        var fixed = Driver(scalars: [], canAdjust: false)
        let immediate = fixed.feed(raw(0, peak: 1, clipped: 0.01), latency: 0.02)
        #expect(immediate == MicGainDecision(volumeDelta: nil, warning: .clipping))
        var floor = Driver(scalars: [0, 0], canAdjust: true)
        #expect(floor.feed(raw(0, peak: 1, clipped: 0.01), latency: 0.02).warning == .clipping)
    }

    @Test("Clipping takes precedence over low evidence and blocks rises")
    func clippingPrecedence() {
        var driver = Driver(scalars: [], canAdjust: false)
        #expect(driver.speak(from: 0, windows: 12, dBFS: -40, peak: 0.1).last?.1.warning == .low)
        #expect(driver.feed(raw(3.0, peak: 1, clipped: 0.5), latency: 0.02).warning == .clipping)

        var adjustable = Driver(scalars: [0.5], canAdjust: true)
        _ = adjustable.feed(raw(0, peak: 1, clipped: 0.5), latency: 0.02)
        #expect(deltas(adjustable.speak(from: 0, windows: 16, dBFS: -40, peak: 0.1)).isEmpty)
    }

    @Test("Clipping can lower during settling from post-change raw windows only")
    func clippingDuringSettling() {
        var driver = Driver(scalars: [0.9], canAdjust: true)
        #expect(driver.feed(raw(0, peak: 1, clipped: 0.2), latency: 0.02).volumeDelta == -0.1)
        driver.policy.didApplyVolumeChange(atSeconds: 0.5)
        driver.scalars = [0.8]
        #expect(driver.feed(raw(0.45, peak: 1, clipped: 0.2), latency: 0.2).volumeDelta == nil)
        #expect(driver.feed(raw(0.5, peak: 1, clipped: 0.2), latency: 0.02).volumeDelta == -0.1)
    }

    @Test("Malformed, non-finite, out-of-order and duplicate windows never produce a write")
    func invalidWindowsCannotWrite() {
        var driver = Driver(scalars: [0.5], canAdjust: true)
        _ = driver.speak(from: 0, windows: 11, dBFS: -40, peak: 0.1)
        let last = speech(2.5, seconds: 0.25, dBFS: -40, peak: 0.1)
        let malformed: [MicLevelWindow] = [
            last,
            speech(2.0, seconds: 0.25, dBFS: -40, peak: 0.1),
            MicLevelWindow(startSeconds: .nan, endSeconds: 3, speechSeconds: 0.25,
                           speechMeanSquare: 1e-4, speechPeak: 0.1, inputPeak: 0, clippedFraction: 0),
            MicLevelWindow(startSeconds: 2.75, endSeconds: 3, speechSeconds: 0.25,
                           speechMeanSquare: .infinity, speechPeak: 0.1, inputPeak: 0, clippedFraction: 0),
            MicLevelWindow(startSeconds: 3, endSeconds: 2.75, speechSeconds: 0.25,
                           speechMeanSquare: 1e-4, speechPeak: 0.1, inputPeak: 0, clippedFraction: 0),
            MicLevelWindow(startSeconds: 2.75, endSeconds: 3, speechSeconds: 0.5,
                           speechMeanSquare: 1e-4, speechPeak: 0.1, inputPeak: 0, clippedFraction: 0),
            MicLevelWindow(startSeconds: 2.75, endSeconds: 3, speechSeconds: 0.25,
                           speechMeanSquare: nil, speechPeak: 0.1, inputPeak: 0, clippedFraction: 0),
            MicLevelWindow(startSeconds: 2.75, endSeconds: 3, speechSeconds: 0.25,
                           speechMeanSquare: 1e-4, speechPeak: 0.1, inputPeak: 0.9, clippedFraction: 0.5),
            MicLevelWindow(startSeconds: 2.75, endSeconds: 3, speechSeconds: 0.25,
                           speechMeanSquare: 1e-4, speechPeak: .nan, inputPeak: 0, clippedFraction: 0)
        ]
        for window in malformed {
            #expect(driver.feed(window, latency: 0.05).volumeDelta == nil)
        }
        let rawMalformed: [MicLevelWindow] = [
            MicLevelWindow(startSeconds: 3, endSeconds: 3.1, speechSeconds: 0, speechMeanSquare: nil,
                           speechPeak: 0, inputPeak: 1, clippedFraction: 1.5),
            MicLevelWindow(startSeconds: 3, endSeconds: 3.1, speechSeconds: 0, speechMeanSquare: nil,
                           speechPeak: 0, inputPeak: .infinity, clippedFraction: 0.5),
            MicLevelWindow(startSeconds: 3, endSeconds: 3.1, speechSeconds: 0, speechMeanSquare: nil,
                           speechPeak: 0.5, inputPeak: 1, clippedFraction: 0.5)
        ]
        for window in rawMalformed {
            #expect(driver.feed(window, latency: 0.02).volumeDelta == nil)
        }
        var badScalars = Driver(scalars: [.nan], canAdjust: true)
        #expect(badScalars.feed(raw(0, peak: 1, clipped: 0.5), latency: 0.02).volumeDelta == nil)
        #expect(driver.policy.observe(raw(3.2, peak: 1, clipped: 0.5), currentScalars: [0.5],
                                      canAdjust: true, nowSeconds: .infinity).volumeDelta == nil)
        // The valid next window still completes the evidence exactly once.
        #expect(driver.feed(speech(2.75, seconds: 0.25, dBFS: -40, peak: 0.1), latency: 0.05).volumeDelta == 0.05)
    }
}
