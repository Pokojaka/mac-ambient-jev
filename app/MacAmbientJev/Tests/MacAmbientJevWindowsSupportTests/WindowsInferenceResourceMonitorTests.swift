import Testing
import Synchronization
import MacAmbientJevPipeline
@testable import MacAmbientJevWindowsSupport

private final class Fake: Sendable {
    private struct State {
        var low = false, high = false, now = 0.0
        var free: UInt64 = 8 * 1_073_741_824, commit: UInt64 = 8 * 1_073_741_824
        var failureOperation: String?
        var created: [UInt] = [], closed: [UInt] = []
    }
    private let state = Mutex(State())
    static let names = ["createLow":"CreateMemoryResourceNotification", "createHigh":"CreateMemoryResourceNotification", "queryLow":"QueryMemoryResourceNotification", "queryHigh":"QueryMemoryResourceNotification", "memory":"GlobalMemoryStatusEx", "close":"CloseHandle"]
    init(failure: String?) { state.withLock { $0.failureOperation = failure } }
    var calls: WindowsResourceMonitorCalls {
        WindowsResourceMonitorCalls(
            create: { low in try self.state.withLock { s in let op = low ? "createLow" : "createHigh"; try self.check(op, s); let handle: UInt = low ? 1 : 2; s.created.append(handle); return handle } },
            query: { handle in try self.state.withLock { s in let op = handle == 1 ? "queryLow" : "queryHigh"; try self.check(op, s); return handle == 1 ? s.low : s.high } },
            close: { handle in try self.state.withLock { s in s.closed.append(handle); try self.check("close", s) } },
            memory: { try self.state.withLock { s in try self.check("memory", s); return InferenceMemoryFacts(physicalMemoryBytes: 16 * 1_073_741_824, freePhysicalMemoryBytes: s.free, commitHeadroomBytes: s.commit, lowMemorySignal: false) } },
            now: { self.state.withLock { $0.now } },
            sleep: { _ in preconditionFailure("manual probe tests must not sleep") }
        )
    }
    private func check(_ operation: String, _ state: State) throws {
        guard state.failureOperation == operation else { return }
        throw WindowsResourceMonitorError(diagnostic: "\(Self.names[operation]!) failed (Win32 1234)")
    }
    func setSignals(_ low: Bool, _ high: Bool) { state.withLock { $0.low = low; $0.high = high } }
    func setNow(_ value: Double) { state.withLock { $0.now = value } }
    func setMemory(_ free: UInt64, _ commit: UInt64) { state.withLock { $0.free = free; $0.commit = commit } }
    func setFailure(_ value: String?) { state.withLock { $0.failureOperation = value } }
    var created: [UInt] { state.withLock { $0.created } }
    var closed: [UInt] { state.withLock { $0.closed } }
}

@Suite struct WindowsInferenceResourceMonitorTests {
    @Test func slowProbeThresholdAndExactBoundary() {
        let fake = Fake(failure: nil), monitor = WindowsInferenceResourceMonitor(calls: fake.calls, startWorker: false)
        fake.setNow(1)
        for _ in 0..<2 { #expect(monitor.probe(deadline: 0.249)); #expect(monitor.signal == .healthy) }
        fake.setNow(2); #expect(monitor.probe(deadline: 1.5))
        fake.setNow(3)
        for _ in 0..<2 { #expect(monitor.probe(deadline: 2.249)); #expect(monitor.signal == .healthy) }
        fake.setNow(4); #expect(monitor.probe(deadline: 3.249)); #expect(monitor.signal == .pressure)
        monitor.stop()
    }
    @Test func pressureRecoveryRequiresFortyEligibleQuarterSeconds() throws {
        let fake = Fake(failure: nil); fake.setSignals(true, false)
        let monitor = WindowsInferenceResourceMonitor(calls: fake.calls, startWorker: false)
        fake.setSignals(false, true); #expect(monitor.probe(deadline: 0))
        for step in 1...8 { fake.setNow(Double(step) * 0.25); #expect(monitor.probe(deadline: Double(step) * 0.25)) }
        fake.setSignals(false, false); fake.setNow(2.25); #expect(monitor.probe(deadline: 2.25))
        fake.setSignals(false, true); fake.setNow(2.5); #expect(monitor.probe(deadline: 2.5))
        fake.setNow(2.75); #expect(monitor.probe(deadline: 2.65))
        fake.setNow(3); #expect(monitor.probe(deadline: 3))
        fake.setMemory(0, 8 * 1_073_741_824); fake.setNow(3.25); #expect(monitor.probe(deadline: 3.25))
        fake.setMemory(8 * 1_073_741_824, 8 * 1_073_741_824); fake.setNow(3.5); #expect(monitor.probe(deadline: 3.5))
        for step in 1...39 { fake.setNow(3.5 + Double(step) * 0.25); #expect(monitor.probe(deadline: 3.5 + Double(step) * 0.25)) }
        #expect(monitor.signal == .pressure); #expect(try monitor.memoryFacts().lowMemorySignal == false)
        fake.setNow(13.5); #expect(monitor.probe(deadline: 13.5)); #expect(monitor.signal == .healthy)
        monitor.stop()
    }
    @Test func lowSignalReturnsExactFactsAndPressureStaysSticky() throws {
        let fake = Fake(failure: nil), monitor = WindowsInferenceResourceMonitor(calls: fake.calls, startWorker: false)
        fake.setSignals(true, false)
        #expect(try monitor.memoryFacts() == InferenceMemoryFacts(physicalMemoryBytes: 16 * 1_073_741_824, freePhysicalMemoryBytes: 8 * 1_073_741_824, commitHeadroomBytes: 8 * 1_073_741_824, lowMemorySignal: true))
        #expect(monitor.signal == .pressure)
        fake.setSignals(false, false)
        #expect(try monitor.memoryFacts().lowMemorySignal == false); #expect(monitor.signal == .pressure)
        monitor.stop()
    }
    @Test func neitherSignalIsHealthyAndBaselineShortagePressures() {
        let fake = Fake(failure: nil)
        do {
            let monitor = WindowsInferenceResourceMonitor(calls: fake.calls, startWorker: false)
            #expect(monitor.signal == .healthy)
            for now in [1.0, 2.0] { fake.setNow(now); #expect(monitor.probe(deadline: now)); #expect(monitor.signal == .healthy) }
        }
        #expect(fake.closed == [1, 2])
        for (free, commit) in [(UInt64(0), 8 * 1_073_741_824), (8 * 1_073_741_824, UInt64(0))] {
            let short = Fake(failure: nil); short.setSignals(false, true); short.setMemory(free, commit)
            let monitor = WindowsInferenceResourceMonitor(calls: short.calls, startWorker: false)
            #expect(monitor.signal == .pressure); monitor.stop()
        }
    }
    @Test func nativeFailuresAreStickyAndInitializationClosesPartialHandles() {
        for operation in ["createLow", "createHigh", "queryLow", "queryHigh", "memory"] {
            let fake = Fake(failure: operation), monitor = WindowsInferenceResourceMonitor(calls: fake.calls, startWorker: false)
            let native = Fake.names[operation]!, diagnostic = "\(native) failed (Win32 1234)"
            #expect(monitor.signal == .monitorFailed(diagnostic)); #expect(monitor.signal.holdReason == .monitorFailed)
            fake.setFailure(nil); #expect(!monitor.probe(deadline: 0)); #expect(throws: WindowsResourceMonitorError.self) { try monitor.memoryFacts() }
            monitor.stop(); monitor.stop()
            #expect(fake.closed == (operation == "createLow" ? [] : operation == "createHigh" ? [1] : [1, 2]))
        }
        for operation in ["queryLow", "queryHigh", "memory"] {
            for probing in [false, true] {
                let fake = Fake(failure: nil), monitor = WindowsInferenceResourceMonitor(calls: fake.calls, startWorker: false)
                fake.setFailure(operation)
                if probing { #expect(!monitor.probe(deadline: 0)) } else { #expect(throws: WindowsResourceMonitorError.self) { try monitor.memoryFacts() } }
                let diagnostic = "\(Fake.names[operation]!) failed (Win32 1234)"
                #expect(monitor.signal == .monitorFailed(diagnostic)); #expect(monitor.signal.holdReason == .monitorFailed)
                fake.setFailure(nil); #expect(!monitor.probe(deadline: 0)); #expect(throws: WindowsResourceMonitorError.self) { try monitor.memoryFacts() }
                monitor.stop(); #expect(fake.closed == [1, 2])
            }
        }
    }
    @Test func closeFailureAttemptsBothHandlesOnlyOnce() {
        let fake = Fake(failure: nil), monitor = WindowsInferenceResourceMonitor(calls: fake.calls, startWorker: false)
        fake.setFailure("close"); monitor.stop()
        let diagnostic = "CloseHandle failed (Win32 1234)"
        #expect(monitor.signal == .monitorFailed("\(diagnostic); \(diagnostic)")); #expect(monitor.signal.holdReason == .monitorFailed)
        #expect(fake.closed == [1, 2]); monitor.stop(); #expect(fake.closed == [1, 2])
    }
}
