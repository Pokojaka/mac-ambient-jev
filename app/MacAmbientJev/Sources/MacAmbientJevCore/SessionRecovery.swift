import Foundation

public enum SessionRecoveryError: Error, Equatable {
    case corruptIntermediateLine(index: Int)
    case invalidEventSequence(index: Int)
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
        let unterminatedIndex = data.last == 0x0A ? nil : split.indices.last
        var validLines: [Data] = []
        var lastSequence: UInt64?
        var droppedTail = false

        for index in nonEmptyIndices {
            let line = Data(split[index])
            guard let dictionary = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                if index == unterminatedIndex {
                    droppedTail = true
                    continue
                }
                throw SessionRecoveryError.corruptIntermediateLine(index: index)
            }
            if let value = dictionary["event_seq"] {
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) == CFNumberGetTypeID(),
                      !CFNumberIsFloatType(number),
                      number.int64Value > 0,
                      number == NSNumber(value: number.int64Value) else {
                    throw SessionRecoveryError.invalidEventSequence(index: index)
                }
                lastSequence = UInt64(number.int64Value)
            }
            validLines.append(line)
        }

        return RecoveredJSONL(
            lines: validLines,
            lastEventSequence: lastSequence,
            droppedIncompleteTail: droppedTail
        )
    }
}
