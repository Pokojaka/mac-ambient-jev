import Foundation
import MacAmbientJevCore
@testable import MacAmbientJevCapture
import MacAmbientJevPipeline
import Testing

private actor OutputSnapshots: SystemAudioOutputProcessProviding {
    private var snapshots: [Set<Int32>?]
    init(_ snapshots: [Set<Int32>?]) { self.snapshots = snapshots }
    func runningExternalOutputPIDs() async -> Set<Int32>? {
        guard !snapshots.isEmpty else { return nil }
        return snapshots.removeFirst()
    }
}

@MainActor
@Test("Own PID and nested descendants are excluded, while unrelated output remains external")
func ownProcessTreeIsNotExternalOutput() async {
    let parents: [Int32: Int32] = [101: 100, 102: 101, 103: 1]
    let parent: (Int32) -> Int32? = { parents[$0] }
    #expect(CoreAudioOutputProcesses.isDescendantOrSelf(100, of: 100, parent: parent) == true)
    #expect(CoreAudioOutputProcesses.isDescendantOrSelf(102, of: 100, parent: parent) == true)
    #expect(CoreAudioOutputProcesses.isDescendantOrSelf(103, of: 100, parent: parent) == false)
    #expect(CoreAudioOutputProcesses.isDescendantOrSelf(104, of: 100, parent: parent) == nil)
    let tree = Set([100, 101, 102]).filter {
        CoreAudioOutputProcesses.isDescendantOrSelf($0, of: 100, parent: parent) == false
    }
    let monitor = SystemAudioOutputMonitor(provider: OutputSnapshots([tree, tree, tree, tree]),
                                           captureStartMillis: 0)
    #expect(!(await monitor.poll(nowMillis: 1_000, everNonZero: false)))
    #expect(!(await monitor.poll(nowMillis: 2_000, everNonZero: false)))
    #expect(!(await monitor.poll(nowMillis: 3_000, everNonZero: false)))
}
