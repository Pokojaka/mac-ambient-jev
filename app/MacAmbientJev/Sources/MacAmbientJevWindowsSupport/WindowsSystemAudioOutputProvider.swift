#if os(Windows)
import Foundation
import CMiniaudio
import MacAmbientJevPipeline

public struct WindowsSystemAudioOutputProvider: SystemAudioOutputProcessProviding, Sendable {
    private static let snapshotCapacity: UInt32 = 4_097

    private let endpointID: String
    private let onQueryError: @Sendable (String) -> Void

    public init(
        endpointID: String,
        onQueryError: @escaping @Sendable (String) -> Void
    ) throws {
        guard !endpointID.isEmpty, !endpointID.contains("\0") else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "A render endpoint ID must be nonempty and contain no embedded NUL"
            )
        }
        self.endpointID = endpointID
        self.onQueryError = onQueryError
    }

    public func runningExternalOutputPIDs() async -> Set<Int32>? {
        var pids = [UInt32](repeating: 0, count: Int(Self.snapshotCapacity))
        var count: UInt32 = 0
        let result = endpointID.withCString { endpointIDPointer in
            pids.withUnsafeMutableBufferPointer { buffer in
                mja_capture_output_pids(
                    endpointIDPointer,
                    buffer.baseAddress,
                    Self.snapshotCapacity,
                    &count
                )
            }
        }

        guard result == 0 else {
            if count > Self.snapshotCapacity {
                onQueryError(
                    "mja_capture_output_pids failed with code \(result); required count \(count) exceeds the fixed snapshot capacity \(Self.snapshotCapacity)"
                )
            } else {
                onQueryError("mja_capture_output_pids failed with code \(result)")
            }
            return nil
        }
        guard count <= Self.snapshotCapacity else {
            onQueryError(
                "mja_capture_output_pids returned an incomplete snapshot count \(count) for capacity \(Self.snapshotCapacity)"
            )
            return nil
        }

        var snapshot = Set<Int32>()
        for rawPID in pids.prefix(Int(count)) {
            guard let pid = Int32(exactly: rawPID) else {
                onQueryError(
                    "mja_capture_output_pids returned PID \(rawPID) outside the Int32 range; output state is uncertain"
                )
                return nil
            }
            snapshot.insert(pid)
        }
        return snapshot
    }
}
#endif
