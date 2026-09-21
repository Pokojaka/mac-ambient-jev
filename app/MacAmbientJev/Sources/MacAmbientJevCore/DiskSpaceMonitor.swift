import Foundation

public enum DiskSpaceLevel: Sendable, Equatable {
    case normal
    case warning
    case critical
}

public struct DiskSpaceMonitor: Sendable {
    public let warningThresholdBytes: Int64
    public let criticalThresholdBytes: Int64

    public init(warningThresholdBytes: Int64, criticalThresholdBytes: Int64) {
        precondition(criticalThresholdBytes <= warningThresholdBytes)
        self.warningThresholdBytes = warningThresholdBytes
        self.criticalThresholdBytes = criticalThresholdBytes
    }

    public func level(forAvailableBytes bytes: Int64) -> DiskSpaceLevel {
        if bytes < criticalThresholdBytes { return .critical }
        if bytes < warningThresholdBytes { return .warning }
        return .normal
    }
}
