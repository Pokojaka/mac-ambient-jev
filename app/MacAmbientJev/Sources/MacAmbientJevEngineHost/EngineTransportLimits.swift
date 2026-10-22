import Foundation

/// The bounds of the stdin/stdout transport. All values are explicit; tests build their own.
public struct EngineTransportLimits: Sendable, Equatable {
    /// Hard cap on encoded records waiting for the writer.
    public let maxQueuedRecords: Int
    /// Hard cap on encoded bytes waiting for the writer.
    public let maxQueuedBytes: Int
    /// Records kept free of replaceable events so accepted/completed/error/ready always have room.
    public let reservedControlRecords: Int
    /// Bytes kept free of replaceable events for the same purpose.
    public let reservedControlBytes: Int
    /// Input lines handed to the controller but not yet reported handled. The input lane blocks beyond it.
    public let maxPendingInputLines: Int
    /// Largest single read from the input source.
    public let readChunkBytes: Int
    /// A write that accepts no byte for this long fails the transport.
    public let writeDeadlineNanoseconds: UInt64

    public init(
        maxQueuedRecords: Int,
        maxQueuedBytes: Int,
        reservedControlRecords: Int,
        reservedControlBytes: Int,
        maxPendingInputLines: Int,
        readChunkBytes: Int,
        writeDeadlineNanoseconds: UInt64
    ) {
        precondition(maxQueuedRecords > reservedControlRecords && reservedControlRecords > 0)
        precondition(maxQueuedBytes > reservedControlBytes && reservedControlBytes > 0)
        precondition(maxPendingInputLines > 0 && readChunkBytes > 0 && writeDeadlineNanoseconds > 0)
        self.maxQueuedRecords = maxQueuedRecords
        self.maxQueuedBytes = maxQueuedBytes
        self.reservedControlRecords = reservedControlRecords
        self.reservedControlBytes = reservedControlBytes
        self.maxPendingInputLines = maxPendingInputLines
        self.readChunkBytes = readChunkBytes
        self.writeDeadlineNanoseconds = writeDeadlineNanoseconds
    }

    /// 128 records / 8 MiB, of which 32 records (two per admitted request) and 2 MiB stay reserved for
    /// terminal and control messages. The write deadline is five seconds.
    public static let production = EngineTransportLimits(
        maxQueuedRecords: 128,
        maxQueuedBytes: 8 * 1_048_576,
        reservedControlRecords: 32,
        reservedControlBytes: 2 * 1_048_576,
        maxPendingInputLines: 32,
        readChunkBytes: 65_536,
        writeDeadlineNanoseconds: 5_000_000_000
    )

    var replaceableRecordLimit: Int { maxQueuedRecords - reservedControlRecords }
    var replaceableByteLimit: Int { maxQueuedBytes - reservedControlBytes }
}

/// Admission bounds for the dispatcher.
public struct EngineAdmissionLimits: Sendable, Equatable {
    /// Admitted requests that have not yet reached their terminal reply.
    public let maxAdmittedRequests: Int
    /// Slots only `recording.stop` and `shutdown` may use, so they are never refused for load.
    public let reservedControlRequests: Int

    public init(maxAdmittedRequests: Int, reservedControlRequests: Int) {
        precondition(maxAdmittedRequests > reservedControlRequests && reservedControlRequests > 0)
        self.maxAdmittedRequests = maxAdmittedRequests
        self.reservedControlRequests = reservedControlRequests
    }

    public static let production = EngineAdmissionLimits(maxAdmittedRequests: 16, reservedControlRequests: 2)
}
