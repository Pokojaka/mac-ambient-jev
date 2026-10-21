// AHC parity anchor: FluidAudio 0.15.8 (revision 87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc),
// Sources/FastClusterWrapper/fastcluster_internal.hpp (`binary_min_heap` and
// `generic_linkage_vector_alternative`):
// https://github.com/FluidInference/FluidAudio/blob/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FastClusterWrapper/fastcluster_internal.hpp
// Swift adaptation of the cited fastcluster implementation; its heap, list, and
// algorithm logic is translated from C++ into a source-shaped Swift port.
/*
Copyright:
  * Until package version 1.1.23: © 2011 Daniel Müllner <https://danifold.net>
  * All changes from version 1.1.24 on: © Google Inc. <https://www.google.com>
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
import Foundation

internal struct Community1AHCMerge {
    let left: Int
    let right: Int
    let height: Double
    let size: Int
}

internal struct Community1AHCResult {
    let linkage: [Community1AHCMerge]
    let labels: [Int]
}

internal enum AHCError: Error, CustomStringConvertible {
    case invalidInput(String)
    case numericalFailure(String)

    var description: String {
        switch self {
        case let .invalidInput(message):
            return "Invalid AHC input: \(message)"
        case let .numericalFailure(message):
            return "AHC numerical failure: \(message)"
        }
    }
}

internal enum Community1AHC {
    static func checkedShape(pointCount: Int, dimension: Int) throws -> (nodeCount: Int, coordinateCount: Int) {
        guard pointCount > 0 else {
            throw AHCError.invalidInput("point count must be positive")
        }
        guard dimension > 0 else {
            throw AHCError.invalidInput("embedding dimension must be positive")
        }

        let (doubledPointCount, nodeCountOverflow) = pointCount.multipliedReportingOverflow(by: 2)
        guard !nodeCountOverflow else {
            throw AHCError.invalidInput("node count overflows Int")
        }
        let nodeCount = doubledPointCount - 1
        let (coordinateCount, coordinateOverflow) = nodeCount.multipliedReportingOverflow(by: dimension)
        guard !coordinateOverflow else {
            throw AHCError.invalidInput("coordinate count overflows Int")
        }
        let mergeCount = pointCount - 1

        // Preflight both each Array's byte count and the sum of all algorithm storage
        // before allocating any of the O(ND) coordinate or O(N) bookkeeping arrays.
        var totalBytes = 0
        func includeStorage(count: Int, stride: Int) throws {
            let (byteCount, byteOverflow) = count.multipliedReportingOverflow(by: stride)
            guard !byteOverflow else {
                throw AHCError.invalidInput("array byte count overflows Int")
            }
            let (newTotal, totalOverflow) = totalBytes.addingReportingOverflow(byteCount)
            guard !totalOverflow else {
                throw AHCError.invalidInput("total bookkeeping byte count overflows Int")
            }
            totalBytes = newTotal
        }

        try includeStorage(count: coordinateCount, stride: MemoryLayout<Double>.stride)
        try includeStorage(count: pointCount, stride: MemoryLayout<Double>.stride) // row norms
        try includeStorage(count: nodeCount, stride: MemoryLayout<Int>.stride) // member counts
        try includeStorage(count: nodeCount, stride: MemoryLayout<Int>.stride) // linked-list successors
        try includeStorage(count: nodeCount, stride: MemoryLayout<Int>.stride) // linked-list predecessors
        try includeStorage(count: nodeCount, stride: MemoryLayout<Int>.stride) // nearest neighbors
        try includeStorage(count: nodeCount, stride: MemoryLayout<Double>.stride) // heap keys
        try includeStorage(count: nodeCount, stride: MemoryLayout<Int>.stride) // heap rows
        try includeStorage(count: nodeCount, stride: MemoryLayout<Int>.stride) // heap positions
        try includeStorage(count: mergeCount, stride: MemoryLayout<Community1AHCMerge>.stride)
        try includeStorage(count: pointCount, stride: MemoryLayout<Int>.stride) // assignments / final labels
        try includeStorage(count: nodeCount, stride: MemoryLayout<Int>.stride) // traversal nodes
        try includeStorage(count: nodeCount, stride: MemoryLayout<Int>.stride) // traversal labels
        try includeStorage(count: pointCount, stride: MemoryLayout<Int>.stride) // first-occurrence remap

        return (nodeCount: nodeCount, coordinateCount: coordinateCount)
    }

    static func cluster(embeddingFeatures: [[Double]]) throws -> Community1AHCResult {
        let pointCount = embeddingFeatures.count
        guard pointCount > 0 else {
            throw AHCError.invalidInput("embedding input must not be empty")
        }
        guard let firstDimension = embeddingFeatures.first?.count, firstDimension > 0 else {
            throw AHCError.invalidInput("embedding dimension must be positive")
        }
        try Task.checkCancellation()

        let shape = try checkedShape(pointCount: pointCount, dimension: firstDimension)
        var rowNorms = [Double](repeating: 0, count: pointCount)
        for rowIndex in 0..<pointCount {
            try Task.checkCancellation()
            let row = embeddingFeatures[rowIndex]
            guard row.count == firstDimension else {
                throw AHCError.invalidInput("embedding row \(rowIndex) has a ragged dimension")
            }

            var squaredNorm = 0.0
            for coordinate in row {
                guard coordinate.isFinite else {
                    throw AHCError.invalidInput("embedding row \(rowIndex) contains a nonfinite coordinate")
                }
                let squaredCoordinate = coordinate * coordinate
                guard squaredCoordinate.isFinite else {
                    throw AHCError.numericalFailure("squared norm overflow in row \(rowIndex)")
                }
                squaredNorm = squaredNorm + squaredCoordinate
                guard squaredNorm.isFinite else {
                    throw AHCError.numericalFailure("squared norm overflow in row \(rowIndex)")
                }
            }
            let scale = squaredNorm > 0 ? 1.0 / sqrt(squaredNorm) : 0.0
            guard scale.isFinite else {
                throw AHCError.numericalFailure("normalization scale is nonfinite in row \(rowIndex)")
            }
            rowNorms[rowIndex] = squaredNorm
        }

        if pointCount == 1 {
            return Community1AHCResult(linkage: [], labels: [0])
        }

        var coordinates = [Double](repeating: 0, count: shape.coordinateCount)
        for rowIndex in 0..<pointCount {
            try Task.checkCancellation()
            let scale = rowNorms[rowIndex] > 0 ? 1.0 / sqrt(rowNorms[rowIndex]) : 0.0
            guard scale.isFinite else {
                throw AHCError.numericalFailure("normalization scale is nonfinite in row \(rowIndex)")
            }
            let rowOffset = rowIndex * firstDimension
            for coordinateIndex in 0..<firstDimension {
                let value = embeddingFeatures[rowIndex][coordinateIndex] * scale
                guard value.isFinite else {
                    throw AHCError.numericalFailure("normalized coordinate is nonfinite in row \(rowIndex)")
                }
                coordinates[rowOffset + coordinateIndex] = value
            }
        }

        let nodeCount = shape.nodeCount
        var memberCounts = [Int](repeating: 0, count: nodeCount)
        for node in 0..<pointCount {
            memberCounts[node] = 1
        }

        // This ordered list mirrors fastcluster's preinitialized list over all
        // 2N-1 node IDs. Future IDs remain linked but are beyond each current scan.
        var nextNode = [Int](repeating: 0, count: nodeCount)
        var previousNode = [Int](repeating: 0, count: nodeCount)
        for node in 0..<nodeCount {
            nextNode[node] = node + 1
            previousNode[node] = node - 1
        }
        var activeStart = 0

        var nearestNeighbor = [Int](repeating: -1, count: nodeCount)
        var heapKeys = [Double](repeating: 0, count: nodeCount)
        var heapRows = [Int](repeating: 0, count: nodeCount)
        var heapPositions = [Int](repeating: 0, count: nodeCount)

        func squaredDistance(_ firstNode: Int, _ secondNode: Int) throws -> Double {
            let firstOffset = firstNode * firstDimension
            let secondOffset = secondNode * firstDimension
            var sum = 0.0
            for coordinateIndex in 0..<firstDimension {
                let difference = coordinates[firstOffset + coordinateIndex] - coordinates[secondOffset + coordinateIndex]
                let squaredDifference = difference * difference
                guard difference.isFinite, squaredDifference.isFinite else {
                    throw AHCError.numericalFailure("nonfinite squared-distance intermediate")
                }
                sum = sum + squaredDifference
                guard sum.isFinite else {
                    throw AHCError.numericalFailure("squared distance is nonfinite")
                }
            }
            return sum
        }

        // fastcluster initializes row i from lower IDs in ascending order and
        // replaces only on strict improvement, preserving its source tie behavior.
        for row in 1..<pointCount {
            try Task.checkCancellation()
            var minimum = Double.infinity
            var nearest = -1
            for candidate in 0..<row {
                let distance = try squaredDistance(row, candidate)
                if distance < minimum {
                    minimum = distance
                    nearest = candidate
                }
            }
            guard nearest >= 0, minimum.isFinite else {
                throw AHCError.numericalFailure("initial nearest-neighbor row is invalid")
            }
            nearestNeighbor[row] = nearest
            heapKeys[row] = minimum
        }

        var heapSize = pointCount - 1
        for slot in 0..<heapSize {
            let row = slot + 1
            heapRows[slot] = row
            heapPositions[row] = slot
        }
        if heapSize > 1 {
            var index = heapSize >> 1
            while index > 0 {
                index -= 1
                siftDown(
                    row: heapRows[index],
                    heapSize: heapSize,
                    heapRows: &heapRows,
                    heapPositions: &heapPositions,
                    keys: heapKeys
                )
            }
        }

        var linkage = [Community1AHCMerge](repeating: Community1AHCMerge(left: -1, right: -1, height: 0, size: 0), count: pointCount - 1)
        for newNode in pointCount..<nodeCount {
            try Task.checkCancellation()
            guard heapSize > 0 else {
                throw AHCError.numericalFailure("nearest-neighbor heap became empty before the final merge")
            }
            var selectedRow = heapRows[0]
            while true {
                guard selectedRow >= 0, selectedRow < nodeCount else {
                    throw AHCError.numericalFailure("nearest-neighbor heap selected an invalid row")
                }
                let storedNeighbor = nearestNeighbor[selectedRow]
                guard storedNeighbor >= 0, storedNeighbor < nodeCount else {
                    throw AHCError.numericalFailure("nearest-neighbor row has no valid neighbor")
                }
                if nextNode[storedNeighbor] != 0 {
                    break
                }
                var candidate = activeStart
                guard candidate >= 0, candidate < selectedRow else {
                    throw AHCError.numericalFailure("stale nearest-neighbor row has no active lower candidate")
                }
                var nearest = candidate
                var minimum = try squaredDistance(selectedRow, candidate)
                candidate = nextNode[candidate]
                while candidate < selectedRow {
                    guard candidate >= 0, nextNode[candidate] != 0 else {
                        throw AHCError.numericalFailure("active-node list is inconsistent")
                    }
                    let distance = try squaredDistance(selectedRow, candidate)
                    if distance < minimum {
                        minimum = distance
                        nearest = candidate
                    }
                    candidate = nextNode[candidate]
                }
                nearestNeighbor[selectedRow] = nearest
                heapUpdateGeq(
                    selectedRow,
                    value: minimum,
                    heapSize: heapSize,
                    heapRows: &heapRows,
                    heapPositions: &heapPositions,
                    keys: &heapKeys
                )
                selectedRow = heapRows[0]
            }

            let partner = nearestNeighbor[selectedRow]
            guard selectedRow != partner,
                  selectedRow >= 0, selectedRow < nodeCount,
                  partner >= 0, partner < nodeCount,
                  nextNode[selectedRow] != 0,
                  nextNode[partner] != 0 else {
                throw AHCError.numericalFailure("selected merge contains an inactive or invalid node")
            }
            let mergeSquaredDistance = heapKeys[selectedRow]
            guard mergeSquaredDistance.isFinite, mergeSquaredDistance >= 0 else {
                throw AHCError.numericalFailure("selected merge distance is invalid")
            }
            let mergeHeight = sqrt(mergeSquaredDistance)
            guard mergeHeight.isFinite else {
                throw AHCError.numericalFailure("selected merge height is nonfinite")
            }

            // The list and heap operations correspond to fastcluster's vector
            // alternative: remove both child IDs; the heap row for selectedRow is
            // replaced by newNode. Each active higher row stores a minimum over
            // lower active IDs or a stale lower bound; only an inactive NN is
            // recomputed by scanning active lower IDs in list order.
            removeActiveNode(selectedRow, activeStart: &activeStart, nextNode: &nextNode, previousNode: &previousNode)
            removeActiveNode(partner, activeStart: &activeStart, nextNode: &nextNode, previousNode: &previousNode)

            let left = min(selectedRow, partner)
            let right = max(selectedRow, partner)
            let (mergedSize, sizeOverflow) = memberCounts[selectedRow].addingReportingOverflow(memberCounts[partner])
            guard !sizeOverflow else {
                throw AHCError.numericalFailure("merged member count overflows Int")
            }
            linkage[newNode - pointCount] = Community1AHCMerge(
                left: left,
                right: right,
                height: mergeHeight,
                size: mergedSize
            )
            memberCounts[newNode] = mergedSize

            if newNode < nodeCount - 1 {
                let leftCount = Double(memberCounts[selectedRow])
                let rightCount = Double(memberCounts[partner])
                let denominator = leftCount + rightCount
                guard denominator.isFinite, denominator > 0 else {
                    throw AHCError.numericalFailure("centroid weight is nonfinite or nonpositive")
                }
                let firstOffset = selectedRow * firstDimension
                let secondOffset = partner * firstDimension
                let mergedOffset = newNode * firstDimension
                for coordinateIndex in 0..<firstDimension {
                    let firstProduct = coordinates[firstOffset + coordinateIndex] * leftCount
                    let secondProduct = coordinates[secondOffset + coordinateIndex] * rightCount
                    let numerator = firstProduct + secondProduct
                    let centroid = numerator / denominator
                    guard firstProduct.isFinite, secondProduct.isFinite,
                          numerator.isFinite, centroid.isFinite else {
                        throw AHCError.numericalFailure("centroid coordinate is nonfinite")
                    }
                    coordinates[mergedOffset + coordinateIndex] = centroid
                }

                var nearest = activeStart
                guard nearest >= 0, nearest < newNode else {
                    throw AHCError.numericalFailure("new centroid has no active lower neighbor")
                }
                var minimum = try squaredDistance(newNode, nearest)
                var candidate = nextNode[nearest]
                while candidate < newNode {
                    guard candidate >= 0, nextNode[candidate] != 0 else {
                        throw AHCError.numericalFailure("active-node list is inconsistent during centroid scan")
                    }
                    let distance = try squaredDistance(newNode, candidate)
                    if distance < minimum {
                        minimum = distance
                        nearest = candidate
                    }
                    candidate = nextNode[candidate]
                }
                nearestNeighbor[newNode] = nearest

                if partner < activeStart {
                    heapRemove(
                        activeStart,
                        heapSize: &heapSize,
                        heapRows: &heapRows,
                        heapPositions: &heapPositions,
                        keys: heapKeys
                    )
                } else {
                    heapRemove(
                        partner,
                        heapSize: &heapSize,
                        heapRows: &heapRows,
                        heapPositions: &heapPositions,
                        keys: heapKeys
                    )
                }
                heapReplace(
                    oldRow: selectedRow,
                    newRow: newNode,
                    value: minimum,
                    heapSize: heapSize,
                    heapRows: &heapRows,
                    heapPositions: &heapPositions,
                    keys: &heapKeys
                )
            }
        }

        // Cut by testing each visited subtree root only. If accepted, all leaves
        // inherit that cluster even when a descendant's merge height is higher.
        var assignments = [Int](repeating: -1, count: pointCount)
        var traversalNodes = [Int](repeating: 0, count: nodeCount)
        var traversalLabels = [Int](repeating: -1, count: nodeCount)
        var stackCount = 1
        traversalNodes[0] = nodeCount - 1
        var nextLabel = 0
        while stackCount > 0 {
            stackCount -= 1
            let node = traversalNodes[stackCount]
            let inheritedLabel = traversalLabels[stackCount]
            guard node >= 0, node < nodeCount else {
                throw AHCError.numericalFailure("cut traversal encountered an invalid node")
            }
            if node < pointCount {
                let leafLabel: Int
                if inheritedLabel >= 0 {
                    leafLabel = inheritedLabel
                } else {
                    leafLabel = nextLabel
                    nextLabel += 1
                }
                assignments[node] = leafLabel
                continue
            }

            let mergeIndex = node - pointCount
            guard mergeIndex >= 0, mergeIndex < linkage.count else {
                throw AHCError.numericalFailure("cut traversal encountered a missing merge")
            }
            let merge = linkage[mergeIndex]
            var clusterLabel = inheritedLabel
            if clusterLabel < 0, merge.height <= Community1Profile.ahcThreshold {
                clusterLabel = nextLabel
                nextLabel += 1
            }
            if stackCount + 2 > nodeCount {
                throw AHCError.numericalFailure("cut traversal stack capacity was exceeded")
            }
            // Push left before right, matching AHCClustering's LIFO traversal.
            traversalNodes[stackCount] = merge.left
            traversalLabels[stackCount] = clusterLabel
            traversalNodes[stackCount + 1] = merge.right
            traversalLabels[stackCount + 1] = clusterLabel
            stackCount += 2
        }

        var firstOccurrenceLabels = [Int](repeating: -1, count: pointCount)
        var remappedCount = 0
        for point in 0..<pointCount {
            let oldLabel = assignments[point]
            guard oldLabel >= 0, oldLabel < pointCount else {
                throw AHCError.numericalFailure("cut did not assign a valid label to every point")
            }
            if firstOccurrenceLabels[oldLabel] < 0 {
                firstOccurrenceLabels[oldLabel] = remappedCount
                remappedCount += 1
            }
            assignments[point] = firstOccurrenceLabels[oldLabel]
        }

        return Community1AHCResult(linkage: linkage, labels: assignments)
    }

    private static func removeActiveNode(
        _ node: Int,
        activeStart: inout Int,
        nextNode: inout [Int],
        previousNode: inout [Int]
    ) {
        let successor = nextNode[node]
        let predecessor = previousNode[node]
        if node == activeStart {
            activeStart = successor
        } else {
            nextNode[predecessor] = successor
            if successor < nextNode.count {
                previousNode[successor] = predecessor
            }
        }
        nextNode[node] = 0
    }

    private static func heapUpdateGeq(
        _ row: Int,
        value: Double,
        heapSize: Int,
        heapRows: inout [Int],
        heapPositions: inout [Int],
        keys: inout [Double]
    ) {
        keys[row] = value
        siftDown(row: row, heapSize: heapSize, heapRows: &heapRows, heapPositions: &heapPositions, keys: keys)
    }

    private static func heapRemove(
        _ row: Int,
        heapSize: inout Int,
        heapRows: inout [Int],
        heapPositions: inout [Int],
        keys: [Double]
    ) {
        heapSize -= 1
        let removedPosition = heapPositions[row]
        let lastRow = heapRows[heapSize]
        heapRows[removedPosition] = lastRow
        heapPositions[lastRow] = removedPosition
        if keys[lastRow] <= keys[row] {
            siftUp(row: lastRow, heapRows: &heapRows, heapPositions: &heapPositions, keys: keys)
        } else {
            siftDown(row: lastRow, heapSize: heapSize, heapRows: &heapRows, heapPositions: &heapPositions, keys: keys)
        }
    }

    private static func heapReplace(
        oldRow: Int,
        newRow: Int,
        value: Double,
        heapSize: Int,
        heapRows: inout [Int],
        heapPositions: inout [Int],
        keys: inout [Double]
    ) {
        let position = heapPositions[oldRow]
        heapPositions[newRow] = position
        heapRows[position] = newRow
        if value <= keys[oldRow] {
            keys[newRow] = value
            siftUp(row: newRow, heapRows: &heapRows, heapPositions: &heapPositions, keys: keys)
        } else {
            keys[newRow] = value
            siftDown(row: newRow, heapSize: heapSize, heapRows: &heapRows, heapPositions: &heapPositions, keys: keys)
        }
    }

    private static func siftUp(
        row: Int,
        heapRows: inout [Int],
        heapPositions: inout [Int],
        keys: [Double]
    ) {
        var index = heapPositions[row]
        while index > 0 {
            let parent = (index - 1) >> 1
            if keys[heapRows[index]] < keys[heapRows[parent]] {
                swapHeapRows(index, parent, heapRows: &heapRows, heapPositions: &heapPositions)
                index = parent
            } else {
                break
            }
        }
    }

    private static func siftDown(
        row: Int,
        heapSize: Int,
        heapRows: inout [Int],
        heapPositions: inout [Int],
        keys: [Double]
    ) {
        var index = heapPositions[row]
        var child = 2 * index + 1
        while child < heapSize {
            if keys[heapRows[child]] >= keys[heapRows[index]] {
                child += 1
                if child >= heapSize || keys[heapRows[child]] >= keys[heapRows[index]] {
                    break
                }
            } else if child + 1 < heapSize, keys[heapRows[child + 1]] < keys[heapRows[child]] {
                child += 1
            }
            swapHeapRows(index, child, heapRows: &heapRows, heapPositions: &heapPositions)
            index = child
            child = 2 * index + 1
        }
    }

    private static func swapHeapRows(
        _ first: Int,
        _ second: Int,
        heapRows: inout [Int],
        heapPositions: inout [Int]
    ) {
        let temporary = heapRows[first]
        heapRows[first] = heapRows[second]
        heapRows[second] = temporary
        heapPositions[heapRows[first]] = first
        heapPositions[heapRows[second]] = second
    }
}
