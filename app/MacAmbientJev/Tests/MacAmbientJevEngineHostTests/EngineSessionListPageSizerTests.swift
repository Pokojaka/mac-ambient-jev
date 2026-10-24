import Foundation
import Testing
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

struct EngineSessionListPageSizerTests {
    @Test func boundariesMatchWholePageEncodingForEveryStartAndLimit() throws {
        let sessions = try makeSummaries(count: 10, repeatedTextCount: 16_000)
        let escapedUnicodeSummary = String(decoding: try canonicalSummaryEncoding(sessions[2]), as: UTF8.self)
        #expect(escapedUnicodeSummary.contains("界😀"))
        #expect(escapedUnicodeSummary.contains(#"\"quoted\""#))
        let escapedControlSummary = String(decoding: try canonicalSummaryEncoding(sessions[4]), as: UTF8.self)
        #expect(escapedControlSummary.contains(#"\n\t\r"#))

        let sizer = try EngineSessionListPageSizer(sessions: sessions, encodeSummary: canonicalSummaryEncoding)

        for start in 0...sessions.count {
            for limit in [0, 1, 4, 100, 140] {
                let expected = try wholePageOracleEnd(sessions: sessions, start: start, limit: limit)
                if let expected {
                    #expect(try sizer.end(from: start, limit: limit) == expected)
                } else {
                    do {
                        _ = try sizer.end(from: start, limit: limit)
                        Issue.record("an oversized first summary should fail")
                    } catch let error as EngineCommandError {
                        #expect(error.code == .filesystem)
                        #expect(error.message == "保存済み録音の情報が大きすぎて一覧を返せません")
                        #expect(error.stage == .recovery)
                        #expect(error.recoveryAction == .inspectSession)
                    }
                }
            }
        }
    }

    @Test func exactLineByteLimitMatchesWholePageEncoding() throws {
        let originalSummary = try makeSummaries(count: 3, repeatedTextCount: 0)[2]
        let escapedFixture = String(decoding: try canonicalSummaryEncoding(originalSummary), as: UTF8.self)
        #expect(escapedFixture.contains("完了"))
        #expect(escapedFixture.contains(#"\"quoted\""#))
        let singleCharacterSummary = try replacingDisplayName("a", in: originalSummary)
        let singleCharacterEnvelopeByteCount = try encodeWholePage([singleCharacterSummary]).count - 1
        let additionalPaddingByteCount = EngineLineFramer.maxLineBytes - singleCharacterEnvelopeByteCount
        let exactDisplayName = String(repeating: "a", count: 1 + additionalPaddingByteCount)
        let exactSummary = try replacingDisplayName(exactDisplayName, in: originalSummary)
        let exactLine = try encodeWholePage([exactSummary])

        #expect(exactLine.count == EngineLineFramer.maxLineBytes + 1)
        #expect(try wholePageOracleEnd(sessions: [exactSummary], start: 0, limit: 1) == 1)
        let exactSizer = try EngineSessionListPageSizer(
            sessions: [exactSummary],
            encodeSummary: canonicalSummaryEncoding
        )
        #expect(try exactSizer.end(from: 0, limit: 1) == 1)

        let belowSummary = try replacingDisplayName(String(exactDisplayName.dropLast()), in: originalSummary)
        let belowLine = try encodeWholePage([belowSummary])
        #expect(belowLine.count == EngineLineFramer.maxLineBytes)
        #expect(try wholePageOracleEnd(sessions: [belowSummary], start: 0, limit: 1) == 1)
        let belowSizer = try EngineSessionListPageSizer(
            sessions: [belowSummary],
            encodeSummary: canonicalSummaryEncoding
        )
        #expect(try belowSizer.end(from: 0, limit: 1) == 1)

        let oversizedSummary = try replacingDisplayName(exactDisplayName + "a", in: originalSummary)
        #expect(try wholePageOracleEnd(sessions: [oversizedSummary], start: 0, limit: 1) == nil)
        let oversizedSizer = try EngineSessionListPageSizer(
            sessions: [oversizedSummary],
            encodeSummary: canonicalSummaryEncoding
        )
        do {
            _ = try oversizedSizer.end(from: 0, limit: 1)
            Issue.record("a page one byte over the line limit should fail")
        } catch let error as EngineCommandError {
            #expect(error.code == .filesystem)
        }
    }

    @Test func summaryEncodingOccursExactlyOnceAcrossRepeatedPageBoundaries() throws {
        let sessions = try makeSummaries(count: 7, repeatedTextCount: 0)
        var encodeCount = 0
        let sizer = try EngineSessionListPageSizer(sessions: sessions) { summary in
            encodeCount += 1
            return try canonicalSummaryEncoding(summary)
        }

        let starts = Array(0...sessions.count) + Array((0...sessions.count).reversed())
        for start in starts {
            for limit in [1, 3, 100] {
                _ = try sizer.end(from: start, limit: limit)
            }
        }

        #expect(encodeCount == sessions.count)
    }

    @Test func emptyRangeReturnsStartWithoutEncodingSummaries() throws {
        var encodeCount = 0
        let sizer = try EngineSessionListPageSizer(sessions: []) { _ in
            encodeCount += 1
            return Data()
        }

        #expect(try sizer.end(from: 0, limit: 100) == 0)
        #expect(encodeCount == 0)
    }

    @Test func oversizedFirstSummaryThrowsTheRecoveryCommandError() throws {
        let sessions = try makeSummaries(count: 1, repeatedTextCount: 250_000)
        let sizer = try EngineSessionListPageSizer(sessions: sessions, encodeSummary: canonicalSummaryEncoding)

        do {
            _ = try sizer.end(from: 0, limit: 1)
            Issue.record("an individually oversized summary should fail")
        } catch let error as EngineCommandError {
            #expect(error.code == .filesystem)
            #expect(error.message == "保存済み録音の情報が大きすぎて一覧を返せません")
            #expect(error.stage == .recovery)
            #expect(error.recoveryAction == .inspectSession)
        }
    }

    @Test func injectedSummaryEncoderErrorPropagates() throws {
        let sessions = try makeSummaries(count: 2, repeatedTextCount: 0)

        do {
            let sizer = try EngineSessionListPageSizer(sessions: sessions) { _ in
                throw SizerTestError.injected
            }
            _ = try sizer.end(from: 0, limit: 1)
            Issue.record("the injected encoder error should propagate")
        } catch let error as SizerTestError {
            #expect(error == .injected)
        }
    }
}

private enum SizerTestError: Error, Equatable {
    case injected
}

private func canonicalSummaryEncoding(_ summary: EngineSessionSummary) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(summary)
}

private func replacingDisplayName(
    _ displayName: String,
    in summary: EngineSessionSummary
) throws -> EngineSessionSummary {
    try EngineSessionSummary(
        folderID: summary.folderID,
        sessionID: summary.sessionID,
        status: summary.status,
        error: summary.error,
        displayName: displayName,
        statusText: summary.statusText,
        folderPath: summary.folderPath,
        exportPath: summary.exportPath,
        canReprocess: summary.canReprocess,
        canRetryDecisions: summary.canRetryDecisions,
        canExport: summary.canExport,
        metadata: summary.metadata
    )
}

private func makeSummaries(count: Int, repeatedTextCount: Int) throws -> [EngineSessionSummary] {
    let variants = ["日本語", "😀🎙️", "\"quoted\"", "slash\\backslash", "line\n\t\rcontrol"]
    return try (0..<count).map { index in
        let variant = variants[index % variants.count]
        let repeatedText = String(repeating: "界😀", count: repeatedTextCount)
        return try EngineSessionSummary(
            folderID: "folder-\(index)",
            sessionID: "session-\(index)",
            status: .finalized,
            error: nil,
            displayName: "\(variant)-\(repeatedText)-\(variant)",
            statusText: "完了 \(variant)",
            folderPath: "/sessions/\(variant)/folder-\(index)",
            exportPath: nil,
            canReprocess: true,
            canRetryDecisions: true,
            canExport: true,
            metadata: .readable(
                createdAt: 1_700_000_000.0 + Double(index),
                source: .microphone,
                audio: .available,
                hasTranscript: true
            )
        )
    }
}

private func wholePageOracleEnd(sessions: [EngineSessionSummary], start: Int, limit: Int) throws -> Int? {
    let maximumEnd = min(sessions.count, start + min(limit, 100))
    var end = start
    while end < maximumEnd {
        let candidate = Array(sessions[start...end])
        do {
            let line = try encodeWholePage(candidate)
            if line.count - 1 <= EngineLineFramer.maxLineBytes {
                end += 1
            } else if end == start {
                return nil
            } else {
                break
            }
        } catch EngineProtocolError.lineTooLong {
            if end == start { return nil }
            break
        }
    }
    return end
}

private func encodeWholePage(_ sessions: [EngineSessionSummary]) throws -> Data {
    let list = try EngineSessionListResult(
        sessions: sessions,
        nextCursor: "00000000-0000-0000-0000-000000000000",
        previousCursor: "00000000-0000-0000-0000-000000000000"
    )
    let maximumID = try EngineID(UInt64.max)
    let output = try EngineOutput(
        version: 1,
        sequence: maximumID,
        requestID: maximumID,
        event: .completed(.sessionList(list))
    )
    return try EngineCodec.encodeOutput(output)
}
