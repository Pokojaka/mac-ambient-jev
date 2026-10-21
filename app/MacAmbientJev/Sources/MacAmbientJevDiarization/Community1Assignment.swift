import Foundation

enum AssignmentError: Error, CustomStringConvertible {
    case invalidInput(String)
    case numericalFailure(String)

    var description: String {
        switch self {
        case let .invalidInput(reason):
            "invalid assignment input: \(reason)"
        case let .numericalFailure(reason):
            "assignment numerical failure: \(reason)"
        }
    }
}

enum Community1Assignment {
    /// Assigns the local speakers in one window to distinct clusters.
    /// A result of -2 means that the row was assigned to a padded dummy column.
    ///
    /// Parity references, pinned FluidAudio 0.15.8 at revision
    /// 87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc:
    /// - Hungarian scoring and tie scan: HungarianAssignment.swift:8-96
    ///   https://github.com/FluidInference/FluidAudio/blob/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/Diarizer/HungarianAssignment.swift#L8-L96
    /// - Constrained rectangular assignment: ConstrainedClusterAssignment.swift:20-38
    ///   https://github.com/FluidInference/FluidAudio/blob/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/Diarizer/Offline/Clustering/ConstrainedClusterAssignment.swift#L20-L38
    static func assign(scores: [[Double]]) throws -> [Int] {
        let rows = scores.count
        guard rows > 0 else { return [] }
        guard rows <= Community1Profile.localSpeakers else {
            throw AssignmentError.invalidInput("a window cannot contain more than three local speakers")
        }

        let columns = scores[0].count
        guard columns > 0 else {
            throw AssignmentError.invalidInput("score rows must contain at least one cluster")
        }
        for (row, values) in scores.enumerated() where values.count != columns {
            throw AssignmentError.invalidInput("score row \(row) has inconsistent width")
        }

        var minimum = 0.0
        var maximum = 0.0
        var foundFiniteScore = false
        var hasNonfiniteScore = false
        for row in scores {
            for score in row {
                guard score.isFinite else {
                    hasNonfiniteScore = true
                    continue
                }
                if foundFiniteScore {
                    minimum = min(minimum, score)
                    maximum = max(maximum, score)
                } else {
                    minimum = score
                    maximum = score
                    foundFiniteScore = true
                }
            }
        }
        // The pinned scorer treats an all-nonfinite matrix as a tie after its
        // finite-score scan; its explicit zero extrema give every cell one cost.
        if !foundFiniteScore {
            minimum = 0
            maximum = 0
        }

        let sentinel: Double
        if hasNonfiniteScore {
            sentinel = minimum - 1
            guard sentinel.isFinite, sentinel < minimum else {
                throw AssignmentError.numericalFailure(
                    "nonfinite score sentinel is not finite and lower than finite scores"
                )
            }
        } else {
            // No cell will use the sentinel. Avoid rejecting a finite-only matrix
            // merely because subtracting one from its minimum would overflow.
            sentinel = 0
        }

        let scale = Community1Profile.hungarianQuantization
        guard scale.isFinite, scale > 0 else {
            throw AssignmentError.numericalFailure("invalid score quantization scale")
        }
        let maximumSafeCost = Double(Int.max / 16)
        var costs: [[Int]] = []
        costs.reserveCapacity(rows)
        for (rowIndex, row) in scores.enumerated() {
            var rowCosts: [Int] = []
            rowCosts.reserveCapacity(columns)
            for (columnIndex, rawScore) in row.enumerated() {
                let score = rawScore.isFinite ? rawScore : sentinel
                let rawDifference = maximum - score
                guard rawDifference.isFinite, rawDifference >= 0 else {
                    throw AssignmentError.numericalFailure(
                        "invalid score range at row \(rowIndex), cluster \(columnIndex)"
                    )
                }
                let scaled = rawDifference * scale
                guard scaled.isFinite else {
                    throw AssignmentError.numericalFailure(
                        "score quantization overflowed at row \(rowIndex), cluster \(columnIndex)"
                    )
                }
                let rounded = scaled.rounded(.toNearestOrAwayFromZero)
                // Double(Int.max / 16) rounds upward on common 64-bit platforms;
                // this strict bound keeps conversion and Hungarian arithmetic safe.
                guard rounded.isFinite, rounded >= 0, rounded < maximumSafeCost else {
                    throw AssignmentError.numericalFailure(
                        "quantized cost is outside the safe integer range at row \(rowIndex), cluster \(columnIndex)"
                    )
                }
                rowCosts.append(Int(rounded))
            }
            costs.append(rowCosts)
        }

        // The square reference uses n = max(rows, columns). For columns < rows,
        // the zero-cost padded columns are represented directly. For columns >
        // rows, it would add zero-cost rows only after the real rows. At that
        // point every unmatched column has v == 0; a zero-cost dummy row seeds
        // each free column with slack 0 and predecessor 0. Any explored real row
        // has nonnegative reduced costs, so strict '<' preserves that predecessor;
        // the dummy therefore attaches directly to a free column without changing
        // real matches or potentials. This preserves the exact real-row tie result
        // without K×K scratch storage. With at most three real rows the solver uses
        // O(rows² × max(rows, columns)) time and O(rows × columns + columns) space.
        let n = max(rows, columns)
        let infinity = Int.max / 4
        var u = [Int](repeating: 0, count: rows + 1)
        var v = [Int](repeating: 0, count: n + 1)
        var p = [Int](repeating: 0, count: n + 1)
        var way = [Int](repeating: 0, count: n + 1)

        func checkedAdd(_ lhs: Int, _ rhs: Int, context: String) throws -> Int {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else {
                throw AssignmentError.numericalFailure("integer arithmetic overflowed during \(context)")
            }
            return value
        }

        func checkedSubtract(_ lhs: Int, _ rhs: Int, context: String) throws -> Int {
            let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
            guard !overflow else {
                throw AssignmentError.numericalFailure("integer arithmetic overflowed during \(context)")
            }
            return value
        }

        for i in 1...rows {
            p[0] = i
            var j0 = 0
            var minv = [Int](repeating: infinity, count: n + 1)
            var used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = infinity
                var j1 = 0
                for j in 1...n where !used[j] {
                    let cellCost = j <= columns ? costs[i0 - 1][j - 1] : 0
                    let afterRowPotential = try checkedSubtract(
                        cellCost,
                        u[i0],
                        context: "reduced-cost calculation"
                    )
                    let current = try checkedSubtract(
                        afterRowPotential,
                        v[j],
                        context: "reduced-cost calculation"
                    )
                    guard current >= 0 else {
                        throw AssignmentError.numericalFailure("negative reduced cost in Hungarian solver")
                    }
                    if current < minv[j] {
                        minv[j] = current
                        way[j] = j0
                    }
                    if minv[j] < delta {
                        delta = minv[j]
                        j1 = j
                    }
                }
                guard delta != infinity, delta >= 0, j1 != 0 else {
                    throw AssignmentError.numericalFailure("Hungarian solver found no augmenting column")
                }
                for j in 0...n {
                    if used[j] {
                        u[p[j]] = try checkedAdd(u[p[j]], delta, context: "row-potential update")
                        v[j] = try checkedSubtract(v[j], delta, context: "column-potential update")
                    } else {
                        minv[j] = try checkedSubtract(minv[j], delta, context: "slack update")
                    }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }

        var assignments = [Int](repeating: -2, count: rows)
        for column in 1...n where p[column] != 0 {
            let assignedColumn = column - 1
            assignments[p[column] - 1] = assignedColumn < columns ? assignedColumn : -2
        }
        return assignments
    }

    /// Scores the active local speaker slots and assigns them to distinct clusters.
    static func assign(embeddings: [[Double]?], centroids: [[Double]]) throws -> [Int] {
        guard embeddings.count == Community1Profile.localSpeakers else {
            throw AssignmentError.invalidInput("embeddings must contain exactly three local speaker slots")
        }

        let activeEmbeddings = embeddings.compactMap { $0 }
        let scores = try Community1Centroids.scores(embeddings: activeEmbeddings, centroids: centroids)
        let activeAssignments = try assign(scores: scores)

        var assignments = [Int](repeating: -2, count: Community1Profile.localSpeakers)
        var activeIndex = 0
        for localSlot in embeddings.indices where embeddings[localSlot] != nil {
            assignments[localSlot] = activeAssignments[activeIndex]
            activeIndex += 1
        }
        return assignments
    }
}
