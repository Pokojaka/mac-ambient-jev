import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol

/// The rows P5 shows. Row content comes from `LiveTranscriptProjection`, the projection the Mac screen and
/// `transcript.txt` share, so filler removal, number formatting and speaker labels are decided here once.
enum EngineTranscriptProjection {
    struct RowFailure: Sendable {
        let rowID: String
        let error: any Error
    }

    /// Failed rows plus successful work that remains useful when the update is retried.
    struct Failures: Error {
        let rows: [RowFailure]
        let validatedIDs: Set<String>
        let deletedIDs: Set<String>
        let rowlessIDs: Set<String>
        let changes: Changes?
    }

    struct Update {
        let rows: [EngineTranscriptRow]
        let changes: Changes
        let validatedIDs: Set<String>
        let deletedIDs: Set<String>
        let rowlessIDs: Set<String>
    }

    /// Encoded bytes of a page beyond which it is cut, kept well inside the 1 MiB record limit.
    static let pageByteBudget = 700_000

    static func rows(for segments: [MaterializedTranscriptSegment]) throws -> [EngineTranscriptRow] {
        try LiveTranscriptProjection().rows(for: segments).map(row(for:))
    }

    private static func row(for row: LiveTranscriptRow) throws -> EngineTranscriptRow {
        let headings = try row.displaySpeakerLabels.map { label in
            guard let heading = EngineSpeakerLabel(rawValue: label) else {
                throw EngineTranscriptProjectionError.unknownSpeakerLabel(label)
            }
            return heading
        }
        guard let clauseState = EngineClauseState(rawValue: row.clauseState.rawValue) else {
            throw EngineTranscriptProjectionError.unknownClauseState(row.clauseState.rawValue)
        }
        return try EngineTranscriptRow(
            rowID: row.segmentID,
            startMS: row.startMilliseconds,
            endMS: row.endMilliseconds,
            text: row.text,
            headings: headings,
            clauseState: clauseState
        )
    }

    @MainActor
    final class Incremental {
        private var sourceByID: [String: MaterializedTranscriptSegment] = [:]
        private var observedIDs: Set<String> = []
        private var rowByID: [String: EngineTranscriptRow] = [:]
        private var committedRowByID: [String: EngineTranscriptRow] = [:]
        private var dirtyIDs: Set<String> = []
        private var orderedIDs: [String] = []
        private var speakerLabels: [String: String] = [:]
        private var speakerContextWasUncertain = false
        private var unprojectedIDs: Set<String> = []
        private var committedOrderedIDs: [String] = []
        private var cachedRows: [EngineTranscriptRow] = []
        private var cachedRowsNeedsRebuild = false
        private(set) var totalProjectedSegments = 0
        private(set) var totalDiffedRows = 0

        init(rows: [EngineTranscriptRow]) {
            let rowsByID = rows.reduce(into: [String: EngineTranscriptRow]()) { result, row in
                result[row.rowID] = row
            }
            rowByID = rowsByID
            committedRowByID = rowsByID
            dirtyIDs = Set(rows.map(\.rowID))
            orderedIDs = rows.map(\.rowID)
            committedOrderedIDs = rows.map(\.rowID)
            cachedRows = rows
        }

        func update(_ segments: [MaterializedTranscriptSegment]) throws(Failures) -> Update {
            var nextOrderedIDs: [String] = []
            nextOrderedIDs.reserveCapacity(segments.count)
            var seenIDs: Set<String> = []
            seenIDs.reserveCapacity(segments.count)
            var duplicateIDs: [String] = []
            var recordedDuplicateIDs: Set<String> = []
            var segmentsByID: [String: MaterializedTranscriptSegment] = [:]
            segmentsByID.reserveCapacity(segments.count)
            var duplicateGroups: [String: [MaterializedTranscriptSegment]] = [:]
            for segment in segments {
                let id = segment.segmentID
                if seenIDs.insert(id).inserted {
                    nextOrderedIDs.append(id)
                    segmentsByID[id] = segment
                } else {
                    if recordedDuplicateIDs.insert(id).inserted {
                        duplicateIDs.append(id)
                        duplicateGroups[id] = [segmentsByID[id]!]
                    }
                    duplicateGroups[id, default: []].append(segment)
                }
            }

            var changedSegments: [String: MaterializedTranscriptSegment] = [:]
            changedSegments.reserveCapacity(segmentsByID.count)
            for (id, segment) in segmentsByID where !recordedDuplicateIDs.contains(id) {
                if sourceByID[id] != segment {
                    changedSegments[id] = segment
                }
            }

            let removedIDs = observedIDs.filter { !seenIDs.contains($0) }
            let removedBaselineIDs = dirtyIDs.filter {
                sourceByID[$0] == nil && !seenIDs.contains($0) && rowByID[$0] != nil
            }
            let deletedIDs = Set(removedIDs).union(removedBaselineIDs)
            let removedRowCandidates = deletedIDs
            let speakerContextUncertain = duplicateIDs.contains { id in
                duplicateGroups[id, default: []].contains { !$0.speakers.isEmpty }
                    || sourceByID[id]?.speakers.isEmpty == false
            }
            let speakerContextChanged = speakerContextUncertain || changedSegments.contains { id, segment in
                (sourceByID[id]?.speakers ?? []) != segment.speakers
            } || removedIDs.contains { sourceByID[$0]?.speakers.isEmpty == false }
            let sourceChanged = !changedSegments.isEmpty || !removedIDs.isEmpty
            let orderChanged = nextOrderedIDs != orderedIDs

            if duplicateIDs.isEmpty, !sourceChanged, !orderChanged, unprojectedIDs.isEmpty, dirtyIDs.isEmpty {
                return Update(
                    rows: cachedRows, changes: Changes(upserts: [], removedRowIDs: []),
                    validatedIDs: Set(sourceByID.keys), deletedIDs: [],
                    rowlessIDs: Set(sourceByID.keys).subtracting(Set(rowByID.keys))
                )
            }

            for id in removedIDs {
                sourceByID.removeValue(forKey: id)
            }
            for (id, segment) in changedSegments {
                sourceByID[id] = segment
            }
            observedIDs = seenIDs
            orderedIDs = nextOrderedIDs
            dirtyIDs.formUnion(changedSegments.keys)
            dirtyIDs.formUnion(removedRowCandidates)
            unprojectedIDs.formUnion(changedSegments.keys)
            for id in duplicateIDs where sourceByID[id] != nil {
                dirtyIDs.insert(id)
                unprojectedIDs.insert(id)
            }
            if orderChanged {
                cachedRowsNeedsRebuild = true
            }
            for id in removedRowCandidates {
                if rowByID.removeValue(forKey: id) != nil {
                    cachedRowsNeedsRebuild = true
                }
                unprojectedIDs.remove(id)
            }

            if speakerContextUncertain {
                speakerContextWasUncertain = true
                let diarizedIDs = sourceByID.values.filter(\.isDiarized).map(\.segmentID)
                dirtyIDs.formUnion(diarizedIDs)
                unprojectedIDs.formUnion(diarizedIDs)
            } else if speakerContextChanged || speakerContextWasUncertain {
                let spans = nextOrderedIDs
                    .filter { !recordedDuplicateIDs.contains($0) }
                    .compactMap { sourceByID[$0] }
                    .flatMap(\.speakers).map { speaker in
                        SpeakerSpan(
                            speakerID: speaker.id,
                            startFrame: speaker.startMilliseconds,
                            endFrame: speaker.endMilliseconds,
                            confidence: speaker.confidence
                        )
                    }
                let nextLabels = SpeakerDisplayMapper.makeLabels(spans: spans)
                speakerContextWasUncertain = false
                if nextLabels != speakerLabels {
                    speakerLabels = nextLabels
                    let diarizedIDs = sourceByID.values.filter(\.isDiarized).map(\.segmentID)
                    dirtyIDs.formUnion(diarizedIDs)
                    unprojectedIDs.formUnion(diarizedIDs)
                }
            }

            let pendingIDs = orderedIDs.filter { unprojectedIDs.contains($0) }
            var projectedRows: [(id: String, row: EngineTranscriptRow?)] = []
            projectedRows.reserveCapacity(pendingIDs.count)
            var projectedIDs: Set<String> = []
            var rowFailures = duplicateIDs.map { id in
                RowFailure(rowID: id, error: EngineTranscriptProjectionError.duplicateSegmentID(id))
            }
            for id in pendingIDs {
                guard !recordedDuplicateIDs.contains(id), let segment = sourceByID[id] else { continue }
                if speakerContextUncertain, segment.isDiarized { continue }
                totalProjectedSegments += 1
                do {
                    let projectedRow: EngineTranscriptRow?
                    if segment.isDiarized {
                        if segment.hasRecognizedText, !ClauseTextComposer.isBlank(segment.displayText) {
                            let liveRow = try LiveTranscriptRow(
                                segment: segment,
                                displaySpeakerLabels: SpeakerDisplayMapper.turnLabels(for: segment, labels: speakerLabels)
                            )
                            projectedRow = try EngineTranscriptProjection.row(for: liveRow)
                        } else {
                            projectedRow = nil
                        }
                    } else {
                        let liveRows = try LiveTranscriptProjection().rows(for: [segment])
                        if let liveRow = liveRows.first {
                            projectedRow = try EngineTranscriptProjection.row(for: liveRow)
                        } else {
                            projectedRow = nil
                        }
                    }
                    projectedRows.append((id, projectedRow))
                    projectedIDs.insert(id)
                } catch {
                    rowFailures.append(RowFailure(rowID: id, error: error))
                }
            }
            for (id, projectedRow) in projectedRows {
                if rowByID[id] != projectedRow {
                    cachedRowsNeedsRebuild = true
                }
                if let projectedRow {
                    rowByID[id] = projectedRow
                } else {
                    rowByID.removeValue(forKey: id)
                }
                unprojectedIDs.remove(id)
            }

            if cachedRowsNeedsRebuild {
                cachedRows = orderedIDs.compactMap { rowByID[$0] }
                cachedRowsNeedsRebuild = false
            }

            let validatedIDs = Set(sourceByID.keys.filter {
                !unprojectedIDs.contains($0) && !recordedDuplicateIDs.contains($0)
            }).union(projectedIDs)
            let rowlessIDs = validatedIDs.subtracting(Set(rowByID.keys))
            let changes = pendingChanges(validatedIDs: validatedIDs)
            let sourcePositions = Dictionary(uniqueKeysWithValues: nextOrderedIDs.enumerated().map { offset, id in (id, offset) })
            rowFailures.sort {
                (sourcePositions[$0.rowID] ?? Int.max) < (sourcePositions[$1.rowID] ?? Int.max)
            }
            if !rowFailures.isEmpty {
                throw Failures(
                    rows: rowFailures, validatedIDs: validatedIDs, deletedIDs: deletedIDs,
                    rowlessIDs: rowlessIDs, changes: changes
                )
            }
            return Update(
                rows: cachedRows, changes: changes, validatedIDs: validatedIDs,
                deletedIDs: deletedIDs, rowlessIDs: rowlessIDs
            )
        }

        private func pendingChanges(validatedIDs: Set<String>) -> Changes {
            var upserts: [EngineTranscriptRow] = []
            for id in orderedIDs where dirtyIDs.contains(id) {
                guard validatedIDs.contains(id), let row = rowByID[id] else { continue }
                totalDiffedRows += 1
                if committedRowByID[id] != row {
                    upserts.append(row)
                }
            }
            let removedRowIDs = committedOrderedIDs.filter { id in
                dirtyIDs.contains(id) && rowByID[id] == nil && committedRowByID[id] != nil
            }
            return Changes(upserts: upserts, removedRowIDs: removedRowIDs)
        }

        func commit() {
            for id in dirtyIDs {
                if let row = rowByID[id] {
                    committedRowByID[id] = row
                } else {
                    committedRowByID.removeValue(forKey: id)
                }
            }
            committedOrderedIDs = orderedIDs
            dirtyIDs.removeAll()
        }
    }

    struct Changes {
        let upserts: [EngineTranscriptRow]
        let removedRowIDs: [String]

        var isEmpty: Bool { upserts.isEmpty && removedRowIDs.isEmpty }
        var count: Int { upserts.count + removedRowIDs.count }
    }

    static func changes(from old: [EngineTranscriptRow], to new: [EngineTranscriptRow]) -> Changes {
        var previous: [String: EngineTranscriptRow] = [:]
        for row in old { previous[row.rowID] = row }
        let upserts = new.filter { previous[$0.rowID] != $0 }
        let remaining = Set(new.map(\.rowID))
        let removed = old.map(\.rowID).filter { !remaining.contains($0) }
        return Changes(upserts: upserts, removedRowIDs: removed)
    }

    /// Encoded size of a row using the wire encoder's canonical JSON formatting.
    static func encodedRowBytes(_ row: EngineTranscriptRow) throws -> Int {
        let bytes = try encoder().encode(row).count
        guard bytes <= EngineCodec.maxRowBytes else {
            let message = "文字起こし行「\(row.rowID)」が大きすぎます（\(bytes) バイト、上限 \(EngineCodec.maxRowBytes) バイト）"
            throw EngineFailures.commandError(
                .rowTooLarge, message, stage: .finalization, recoveryAction: .inspectSession,
                details: [EngineFailures.detail(domain: "transcript", code: "row_too_large", message: message)]
            )
        }
        return bytes
    }

    /// Encoded data bytes carried by a changes event, excluding JSON array brackets.
    static func encodedChangeBytes(upserts: [EngineTranscriptRow], removedRowIDs: [String]) throws(Failures) -> Int {
        var bytes = 0
        var failures: [RowFailure] = []
        for row in upserts {
            do {
                bytes += try encodedRowBytes(row)
            } catch {
                failures.append(RowFailure(rowID: row.rowID, error: error))
            }
        }
        if upserts.count > 1 { bytes += upserts.count - 1 }

        let idEncoder = encoder()
        for rowID in removedRowIDs {
            do {
                bytes += try idEncoder.encode(rowID).count
            } catch {
                failures.append(RowFailure(rowID: rowID, error: error))
            }
        }
        if removedRowIDs.count > 1 { bytes += removedRowIDs.count - 1 }
        if !failures.isEmpty {
            throw Failures(
                rows: failures, validatedIDs: [], deletedIDs: [], rowlessIDs: [], changes: nil
            )
        }
        return bytes
    }

    /// The longest run of rows from `offset` within `limit` rows and the encoded byte budget.
    static func page(of rows: [EngineTranscriptRow], from offset: Int, limit: Int) throws -> ArraySlice<EngineTranscriptRow> {
        var end = offset
        var bytes = 0
        while end < rows.count, end - offset < limit {
            let rowBytes = try encodedRowBytes(rows[end])
            let commaBytes = end > offset ? 1 : 0
            if end > offset, bytes + rowBytes + commaBytes > pageByteBudget { break }
            bytes += rowBytes + commaBytes
            end += 1
        }
        return rows[offset..<end]
    }

    /// The newest suffix within `limit` rows and the encoded byte budget, returned chronologically.
    static func tail(of rows: [EngineTranscriptRow], limit: Int) throws -> ArraySlice<EngineTranscriptRow> {
        var start = rows.count
        var bytes = 0
        while start > 0, rows.count - start < limit {
            let candidate = start - 1
            let rowBytes = try encodedRowBytes(rows[candidate])
            let commaBytes = start < rows.count ? 1 : 0
            if start < rows.count, bytes + rowBytes + commaBytes > pageByteBudget { break }
            bytes += rowBytes + commaBytes
            start = candidate
        }
        return rows[start..<rows.count]
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

enum EngineTranscriptProjectionError: Error, LocalizedError {
    case unknownSpeakerLabel(String)
    case unknownClauseState(String)
    case duplicateSegmentID(String)

    var errorDescription: String? {
        switch self {
        case let .unknownSpeakerLabel(label): "話者ラベル「\(label)」はプロトコルにありません"
        case let .unknownClauseState(state): "clause の状態「\(state)」はプロトコルにありません"
        case let .duplicateSegmentID(id): "文字起こし segment ID「\(id)」が重複しています"
        }
    }
}
