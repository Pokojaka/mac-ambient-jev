import Foundation
import MacAmbientJevEngineProtocol

struct EngineSessionListPageSizer {
    private static let representativeCursor = "00000000-0000-0000-0000-000000000000"

    private let summaryByteCounts: [Int]
    private let fixedByteCount: Int

    init(
        sessions: [EngineSessionSummary],
        encodeSummary: (EngineSessionSummary) throws -> Data
    ) throws {
        let fixedByteCount = try Self.fixedEnvelopeByteCount()
        var summaryByteCounts: [Int] = []
        summaryByteCounts.reserveCapacity(sessions.count)
        for summary in sessions {
            summaryByteCounts.append(try encodeSummary(summary).count)
        }

        self.summaryByteCounts = summaryByteCounts
        self.fixedByteCount = fixedByteCount
    }

    func end(from start: Int, limit: Int) throws -> Int {
        let maximumEnd = min(summaryByteCounts.count, start + min(limit, 100))
        var end = start
        var pageByteCount = fixedByteCount

        while end < maximumEnd {
            let candidateByteCount = pageByteCount + summaryByteCounts[end] + (end == start ? 0 : 1)
            guard candidateByteCount <= EngineLineFramer.maxLineBytes else {
                guard end > start else {
                    throw Self.summaryTooLargeError()
                }
                break
            }

            pageByteCount = candidateByteCount
            end += 1
        }

        return end
    }

    private static func fixedEnvelopeByteCount() throws -> Int {
        let emptyList = try EngineSessionListResult(
            sessions: [],
            nextCursor: representativeCursor,
            previousCursor: representativeCursor
        )
        let maximumID = try EngineID(UInt64.max)
        let output = try EngineOutput(
            version: 1,
            sequence: maximumID,
            requestID: maximumID,
            event: .completed(.sessionList(emptyList))
        )
        return try EngineCodec.encodeOutput(output).count - 1
    }

    private static func summaryTooLargeError() -> EngineCommandError {
        EngineFailures.commandError(
            .filesystem,
            "保存済み録音の情報が大きすぎて一覧を返せません",
            stage: .recovery,
            recoveryAction: .inspectSession
        )
    }
}
