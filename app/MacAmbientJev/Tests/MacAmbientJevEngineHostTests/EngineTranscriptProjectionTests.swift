import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

@testable import MacAmbientJevEngineHost

@Suite struct EngineTranscriptProjectionTests {
    @Test func controlCharactersPageBelowTenAndEncodeAsCompleteWireEnvelopes() throws {
        let text = String(repeating: "\u{0001}", count: 30_000)
        let segments = try (0..<10).map { index in
            try segment(id: "control-\(index)", text: text)
        }
        let rows = try EngineTranscriptProjection.rows(for: segments)

        #expect(rows.count == 10)
        #expect(rows.allSatisfy { $0.text == text })
        let encodedText = try JSONEncoder().encode(text)
        #expect(encodedText.count == text.utf8.count * 6 + 2)
        #expect(try EngineTranscriptProjection.encodedRowBytes(rows[0]) <= EngineCodec.maxRowBytes)

        var offset = 0
        var pageCount = 0
        var reconstructed: [EngineTranscriptRow] = []
        while offset < rows.count {
            let pageRows = Array(try EngineTranscriptProjection.page(of: rows, from: offset, limit: 200))
            #expect(!pageRows.isEmpty)
            if pageCount == 0 {
                #expect(pageRows.count < rows.count)
            }

            let nextOffset = offset + pageRows.count
            let page = try EngineTranscriptPage(
                sessionID: "projection-test", revision: try EngineID(1), rows: pageRows,
                nextCursor: nextOffset < rows.count ? String(nextOffset) : nil, previousCursor: nil
            )
            let output = try EngineOutput(
                version: 1, sequence: try EngineID(UInt64(pageCount + 1)), requestID: try EngineID(1),
                event: .completed(.transcriptRead(page))
            )
            let envelope = try EngineCodec.encodeOutput(output)
            #expect(envelope.count <= 1_048_576)

            reconstructed.append(contentsOf: pageRows)
            offset = nextOffset
            pageCount += 1
        }

        #expect(pageCount < 10)
        #expect(reconstructed == rows)
        #expect(reconstructed.map(\.rowID) == segments.map(\.segmentID))
    }

    @Test func tailReturnsNewestSuffixIncludingFinalRow() throws {
        let segments = try (0..<10).map { index in
            try segment(id: "row-\(index)", text: "text-\(index)")
        }
        let rows = try EngineTranscriptProjection.rows(for: segments)
        let tail = try EngineTranscriptProjection.tail(of: rows, limit: 3)

        #expect(tail.map(\.rowID) == ["row-7", "row-8", "row-9"])
        #expect(tail.last?.rowID == "row-9")
        #expect(!tail.contains { $0.rowID == "row-0" })
    }

    @Test func oversizedSingleControlCharacterRowThrowsRowTooLarge() throws {
        let text = String(repeating: "\u{0001}", count: 60_000)
        let rows = try EngineTranscriptProjection.rows(for: [segment(id: "oversized", text: text)])

        do {
            _ = try EngineTranscriptProjection.page(of: rows, from: 0, limit: 200)
            Issue.record("oversized row must be rejected before paging")
        } catch let error as EngineCommandError {
            #expect(error.code == .rowTooLarge)
        } catch {
            Issue.record("expected EngineCommandError.rowTooLarge, got \(error)")
        }
    }

    @Test func encodedChangesExceedPageBudgetForIndividuallyLegalRows() throws {
        let text = String(repeating: "\u{0001}", count: 25_000)
        let segments = try (0..<5).map { index in
            try segment(id: "change-\(index)", text: text)
        }
        let rows = try EngineTranscriptProjection.rows(for: segments)
        let rowSizes = try rows.map(EngineTranscriptProjection.encodedRowBytes)

        #expect(rowSizes.allSatisfy { $0 <= EngineCodec.maxRowBytes })
        #expect(try EngineTranscriptProjection.encodedChangeBytes(upserts: rows, removedRowIDs: []) > 700_000)
    }

    @Test func encodedChangesCollectEveryOversizedRowFailure() throws {
        let text = String(repeating: "\u{0001}", count: 60_000)
        let segments = try [
            segment(id: "oversized-1", text: text),
            segment(id: "oversized-2", text: text)
        ]
        let rows = try EngineTranscriptProjection.rows(for: segments)

        do {
            _ = try EngineTranscriptProjection.encodedChangeBytes(upserts: rows, removedRowIDs: [])
            Issue.record("every oversized change row must be rejected")
        } catch let failures as EngineTranscriptProjection.Failures {
            #expect(failures.rows.map(\.rowID) == ["oversized-1", "oversized-2"])
            for failure in failures.rows {
                guard let error = failure.error as? EngineCommandError else {
                    Issue.record("expected EngineCommandError.rowTooLarge, got \(failure.error)")
                    continue
                }
                #expect(error.code == .rowTooLarge)
            }
        } catch {
            Issue.record("expected aggregated row failures, got \(error)")
        }
    }

    @Test @MainActor func incrementalProjectionOnlyProjectsChangedSegments() throws {
        let incremental = EngineTranscriptProjection.Incremental(rows: [])
        var segments = try (0..<1_000).map { index in
            try segment(id: "row-\(index)", text: "text-\(index)")
        }

        let initial = try incremental.update(segments)
        #expect(initial.rows == (try EngineTranscriptProjection.rows(for: segments)))
        #expect(initial.changes.upserts.count == 1_000)
        #expect(incremental.totalProjectedSegments == 1_000)
        incremental.commit()

        let projectedBeforeAppend = incremental.totalProjectedSegments
        let diffedBeforeAppend = incremental.totalDiffedRows
        let appended = try segment(id: "row-1000", text: "text-1000")
        segments.append(appended)
        let afterAppend = try incremental.update(segments)
        #expect(afterAppend.rows == (try EngineTranscriptProjection.rows(for: segments)))
        #expect(afterAppend.changes.upserts.map(\.rowID) == ["row-1000"])
        #expect(incremental.totalProjectedSegments - projectedBeforeAppend == 1)
        #expect(incremental.totalDiffedRows - diffedBeforeAppend == 1)
        #expect(incremental.totalProjectedSegments == 1_001)
        incremental.commit()

        segments[0] = try segment(id: "row-0", text: "edited early row")
        let afterEdit = try incremental.update(segments)
        #expect(afterEdit.rows == (try EngineTranscriptProjection.rows(for: segments)))
        #expect(afterEdit.changes.upserts.map(\.rowID) == ["row-0"])
        #expect(incremental.totalProjectedSegments == 1_002)
        incremental.commit()

        segments.remove(at: 1)
        segments[1] = try segment(id: "row-2", text: "")
        let afterRemovalAndHide = try incremental.update(segments)
        #expect(afterRemovalAndHide.rows == (try EngineTranscriptProjection.rows(for: segments)))
        #expect(afterRemovalAndHide.changes.removedRowIDs == ["row-1", "row-2"])
        #expect(incremental.totalProjectedSegments == 1_003)
        incremental.commit()

        let noOp = try incremental.update(segments)
        #expect(noOp.rows == afterRemovalAndHide.rows)
        #expect(noOp.changes.isEmpty)
        #expect(incremental.totalProjectedSegments == 1_003)
    }

    @Test @MainActor func incrementalUpdateRemovesRowsFromSeededBaseline() throws {
        let finalized = try segment(id: "finalized", text: "finalized cache")
        let baselineRows = try EngineTranscriptProjection.rows(for: [finalized])
        let incremental = EngineTranscriptProjection.Incremental(rows: baselineRows)
        let live = try segment(id: "live", text: "manual live row")

        let updated = try incremental.update([live])

        #expect(updated.rows == (try EngineTranscriptProjection.rows(for: [live])))
        #expect(updated.changes.upserts.map(\.rowID) == ["live"])
        #expect(updated.changes.removedRowIDs == ["finalized"])
    }

    @Test @MainActor func incrementalRowsAndChangesMatchFullProjectionAcrossLowPriorityChanges() throws {
        let incremental = EngineTranscriptProjection.Incremental(rows: [])
        let firstSegment = try segment(id: "a", text: "segment a", start: 100, end: 200)
        let secondSegment = try segment(id: "b", text: "segment b", start: 200, end: 300)
        let lowOnly = try lowPrioritySegment(id: "low", text: "はい。うん。")
        var segments = [firstSegment, secondSegment, lowOnly]

        let first = try incremental.update(segments)
        let fullFirst = try EngineTranscriptProjection.rows(for: segments)
        #expect(first.rows == fullFirst)
        #expect(first.changes.upserts == EngineTranscriptProjection.changes(from: [], to: fullFirst).upserts)
        #expect(first.changes.removedRowIDs.isEmpty)
        incremental.commit()

        let newFirst = try segment(id: "z", text: "segment z", start: 0)
        let visibleLow = try segment(id: "low", text: "はい。うん。")
        segments = [newFirst, firstSegment, secondSegment, visibleLow]
        let second = try incremental.update(segments)
        let fullSecond = try EngineTranscriptProjection.rows(for: segments)
        let expectedSecond = EngineTranscriptProjection.changes(from: fullFirst, to: fullSecond)
        #expect(second.rows == fullSecond)
        #expect(second.changes.upserts == expectedSecond.upserts)
        #expect(second.changes.removedRowIDs == expectedSecond.removedRowIDs)
        #expect(second.rows.map(\.rowID) == ["z", "a", "b", "low"])
        incremental.commit()

        segments = [firstSegment, secondSegment, visibleLow]
        let third = try incremental.update(segments)
        let fullThird = try EngineTranscriptProjection.rows(for: segments)
        let expectedThird = EngineTranscriptProjection.changes(from: fullSecond, to: fullThird)
        #expect(third.rows == fullThird)
        #expect(third.changes.upserts == expectedThird.upserts)
        #expect(third.changes.removedRowIDs == expectedThird.removedRowIDs)
        #expect(third.changes.removedRowIDs == ["z"])
    }

    @Test @MainActor func incrementalRetainsUncommittedDirtyRowsAcrossUpdates() throws {
        let incremental = EngineTranscriptProjection.Incremental(rows: [])
        let original = try segment(id: "first", text: "original")
        let first = try incremental.update([original])
        #expect(first.changes.upserts.map(\.rowID) == ["first"])

        let added = try segment(id: "second", text: "second")
        let second = try incremental.update([original, added])
        #expect(second.changes.upserts.map(\.rowID) == ["first", "second"])
        #expect(second.rows == (try EngineTranscriptProjection.rows(for: [original, added])))
        #expect(incremental.totalProjectedSegments == 2)
    }

    @Test @MainActor func incrementalCollectsDistinctDuplicateIDsAndCanRetryAfterRepair() throws {
        let incremental = EngineTranscriptProjection.Incremental(rows: [])
        let firstA = try segment(id: "a", text: "first a")
        let firstB = try segment(id: "b", text: "first b")
        let secondA = try segment(id: "a", text: "second a")
        let secondB = try segment(id: "b", text: "second b")

        do {
            _ = try incremental.update([firstA, firstB, secondA, secondB])
            Issue.record("all duplicate segment IDs must be rejected")
        } catch let failures as EngineTranscriptProjection.Failures {
            #expect(failures.rows.map(\.rowID) == ["a", "b"])
            for (failure, expectedID) in zip(failures.rows, ["a", "b"]) {
                #expect(failure.rowID == expectedID)
                guard let underlying = failure.error as? EngineTranscriptProjectionError else {
                    Issue.record("expected underlying duplicateSegmentID error")
                    continue
                }
                if case let .duplicateSegmentID(id) = underlying {
                    #expect(id == expectedID)
                } else {
                    Issue.record("expected duplicateSegmentID, got \(underlying)")
                }
            }
        } catch {
            Issue.record("expected aggregated duplicate segment ID errors, got \(error)")
        }

        let repaired = try incremental.update([firstA, firstB])
        #expect(repaired.rows.map(\.rowID) == ["a", "b"])
        #expect(repaired.changes.upserts.map(\.rowID) == ["a", "b"])
        #expect(incremental.totalProjectedSegments == 2)
    }
}

private func segment(
    id: String,
    text: String,
    start: Int64 = 0,
    end: Int64 = 100,
    clauseSlices: [ClauseRowSlice] = []
) throws -> MaterializedTranscriptSegment {
    let source = try SegmentTextReference(
        segmentationRunID: "segmentation-run", segmentID: id, asrRunID: "asr-run", asrEventSeq: 1
    )
    let projection = try TranscriptTextProjector().project(sourceText: text, fillerRanges: [])
    return try MaterializedTranscriptSegment(
        segmentID: id, source: source, startMilliseconds: start, endMilliseconds: end,
        text: text, textProjection: projection, clauseState: .classified, clauseSlices: clauseSlices
    )
}

private func lowPrioritySegment(id: String, text: String) throws -> MaterializedTranscriptSegment {
    let firstReference = try ClauseReference(boundaryRunID: "boundary", clauseID: "\(id)-0")
    let secondReference = try ClauseReference(boundaryRunID: "boundary", clauseID: "\(id)-1")
    let slices = [
        ClauseRowSlice(
            reference: firstReference, sourceRange: try TextUTF16Range(start: 0, end: 3),
            priority: .lowPriority, needsRetry: false
        ),
        ClauseRowSlice(
            reference: secondReference, sourceRange: try TextUTF16Range(start: 3, end: 6),
            priority: .lowPriority, needsRetry: false
        )
    ]
    return try segment(id: id, text: text, clauseSlices: slices)
}
