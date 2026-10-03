/// A nil snapshot means the output state could not be established. Implementations must
/// exclude this app's PID and every process descended from it before returning a snapshot.
protocol SystemAudioOutputProcessProviding: Sendable {
    func runningExternalOutputPIDs() async -> Set<Int32>?
}

/// Samples process output at the caller's polling cadence; no work is done on an audio callback.
@MainActor
final class SystemAudioOutputMonitor {
    private let provider: any SystemAudioOutputProcessProviding
    private let captureStartMillis: Int64
    private var runningSinceMillis: [Int32: Int64] = [:]
    private var disabled = false
    private var warned = false

    init(
        provider: any SystemAudioOutputProcessProviding,
        captureStartMillis: Int64
    ) {
        self.provider = provider
        self.captureStartMillis = captureStartMillis
    }

    /// Returns true exactly once if an external process has been observed running output
    /// continuously for at least two seconds, after the capture's three-second grace period.
    /// An unknown poll breaks continuity; once a nonzero captured sample is observed, the
    /// monitor is permanently disabled for this capture.
    func poll(nowMillis: Int64, everNonZero: Bool) async -> Bool {
        if everNonZero {
            disabled = true
            runningSinceMillis.removeAll()
        }
        guard !disabled, !warned else { return false }
        guard let active = await provider.runningExternalOutputPIDs() else {
            runningSinceMillis.removeAll()
            return false
        }
        guard !disabled, !warned, nowMillis >= captureStartMillis else {
            runningSinceMillis.removeAll()
            return false
        }
        let (captureDuration, captureOverflow) = nowMillis.subtractingReportingOverflow(captureStartMillis)

        runningSinceMillis = runningSinceMillis.filter { active.contains($0.key) }
        for pid in active where pid > 0 {
            let since = runningSinceMillis[pid] ?? nowMillis
            runningSinceMillis[pid] = since
            let (duration, overflow) = nowMillis.subtractingReportingOverflow(since)
            if nowMillis < since { runningSinceMillis[pid] = nowMillis; continue }
            if !overflow, !captureOverflow, duration >= 2_000, captureDuration >= 3_000 {
                warned = true
                runningSinceMillis.removeAll()
                return true
            }
        }
        return false
    }
}
