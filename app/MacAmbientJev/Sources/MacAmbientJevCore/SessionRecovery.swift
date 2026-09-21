import Foundation

public enum SessionRecoveryError: Error, Equatable {
    case corruptIntermediateLine(index: Int)
}

public struct RecoveredJSONL: Sendable {
    public let lines: [Data]
    public let lastEventSequence: UInt64?
    public let droppedIncompleteTail: Bool

    public var normalizedData: Data {
        guard !lines.isEmpty else { return Data() }
        var output = Data()
        for line in lines {
            output.append(line)
            output.append(0x0A)
        }
        return output
    }
}

public enum SessionRecovery {
    public static func recoverJSONL(_ data: Data) throws -> RecoveredJSONL {
        guard !data.isEmpty else {
            return RecoveredJSONL(lines: [], lastEventSequence: nil, droppedIncompleteTail: false)
        }

        let split = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let nonEmptyIndices = split.indices.filter { !split[$0].isEmpty }
        let lastNonEmptyIndex = nonEmptyIndices.last
        var validLines: [Data] = []
        var lastSequence: UInt64?
        var droppedTail = false

        for index in nonEmptyIndices {
            let line = Data(split[index])
            do {
                let object = try JSONSerialization.jsonObject(with: line)
                guard let dictionary = object as? [String: Any] else {
                    throw SessionRecoveryError.corruptIntermediateLine(index: index)
                }
                if let number = dictionary["event_seq"] as? NSNumber {
                    lastSequence = number.uint64Value
                }
                validLines.append(line)
            } catch {
                if index == lastNonEmptyIndex {
                    droppedTail = true
                    continue
                }
                throw SessionRecoveryError.corruptIntermediateLine(index: index)
            }
        }

        return RecoveredJSONL(
            lines: validLines,
            lastEventSequence: lastSequence,
            droppedIncompleteTail: droppedTail
        )
    }
}
