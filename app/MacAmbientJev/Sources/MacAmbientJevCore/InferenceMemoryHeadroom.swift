public enum InferenceMemoryHeadroomError: Error, Sendable, Equatable {
    case invalidPhysicalMemory
}

/// Inference keeps at least the larger of 1 GiB and a tenth of physical memory free, in both available physical
/// memory and commit headroom.
public func inferenceMemoryHeadroomIsAdequate(
    physicalMemoryBytes: UInt64,
    freePhysicalMemoryBytes: UInt64,
    commitHeadroomBytes: UInt64
) throws -> Bool {
    guard physicalMemoryBytes > 0, freePhysicalMemoryBytes <= physicalMemoryBytes else {
        throw InferenceMemoryHeadroomError.invalidPhysicalMemory
    }
    let tenth = physicalMemoryBytes / 10 + (physicalMemoryBytes % 10 == 0 ? 0 : 1)
    let reserve = max(UInt64(1) << 30, tenth)
    return freePhysicalMemoryBytes >= reserve && commitHeadroomBytes >= reserve
}
