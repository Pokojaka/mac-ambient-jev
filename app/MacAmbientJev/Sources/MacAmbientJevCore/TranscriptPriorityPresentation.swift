import Foundation

public struct TranscriptPrioritySlice: Sendable, Equatable {
    public let sourceRange: TextUTF16Range
    public let priority: ContentPriority?
    public let needsRetry: Bool
    public init(sourceRange: TextUTF16Range, priority: ContentPriority?, needsRetry: Bool) {
        self.sourceRange = sourceRange
        self.priority = priority
        self.needsRetry = needsRetry
    }
}

public enum TranscriptTextStyle: Sendable, Equatable { case normal, lowPriority }
public struct TranscriptTextFragment: Sendable, Equatable {
    public let text: String
    public let style: TranscriptTextStyle
    public init(text: String, style: TranscriptTextStyle) { self.text = text; self.style = style }
}
public struct TranscriptPriorityPresentation: Sendable, Equatable {
    public let text: String
    public let fragments: [TranscriptTextFragment]
    public let shouldCollapseRow: Bool
}

public enum TranscriptPriorityPresentationError: Error, Sendable, Equatable {
    case invalidSliceOrder
    case incompleteSliceCoverage
}

public struct TranscriptPriorityPresentationPolicy: Sendable {
    public init() {}
    public func present(text: CleanedTranscriptText, slices: [TranscriptPrioritySlice],
                        hasUnresolvedBoundary: Bool) throws -> TranscriptPriorityPresentation {
        guard !slices.isEmpty else {
            let fragments = text.text.isEmpty ? [] : [TranscriptTextFragment(text: text.text, style: .normal)]
            return TranscriptPriorityPresentation(text: text.text, fragments: fragments, shouldCollapseRow: false)
        }
        var priorEnd = 0
        for slice in slices {
            try text.validateSourceRange(slice.sourceRange)
            guard slice.sourceRange.start >= priorEnd else {
                throw TranscriptPriorityPresentationError.invalidSliceOrder
            }
            guard slice.sourceRange.start == priorEnd else {
                throw TranscriptPriorityPresentationError.incompleteSliceCoverage
            }
            priorEnd = slice.sourceRange.end
        }
        guard priorEnd == text.sourceUTF16Length else {
            throw TranscriptPriorityPresentationError.incompleteSliceCoverage
        }

        var fragments: [TranscriptTextFragment] = []
        let displayUTF16 = text.text.utf16
        var displayIndex = displayUTF16.startIndex
        var displayOffset = 0
        func appendFragment(end: Int, style: TranscriptTextStyle) throws {
            let upper16 = displayUTF16.index(displayIndex, offsetBy: end - displayOffset)
            guard let lower = String.Index(displayIndex, within: text.text),
                  let upper = String.Index(upper16, within: text.text) else {
                throw TextUTF16RangeError.invalidCharacterBoundary(start: displayOffset, end: end)
            }
            fragments.append(TranscriptTextFragment(text: String(text.text[lower..<upper]), style: style))
            displayIndex = upper16
            displayOffset = end
        }

        func hasVisibleText(from start: Int, to end: Int) throws -> Bool {
            let range = try TextUTF16Range(start: start, end: end)
            return !ClauseTextComposer.isBlank(String(try range.substring(in: text.text)))
        }

        var runIndex = 0
        var pendingStyle: TranscriptTextStyle?
        var pendingEnd = 0
        var allLow = true
        for slice in slices {
            guard slice.sourceRange.start < slice.sourceRange.end else { continue }
            let low = slice.priority == .lowPriority && !slice.needsRetry
            let style: TranscriptTextStyle = low ? .lowPriority : .normal
            while runIndex < text.retainedRuns.count {
                let run = text.retainedRuns[runIndex]
                if run.sourceRange.end <= slice.sourceRange.start {
                    runIndex += 1
                    continue
                }
                guard run.sourceRange.start < slice.sourceRange.end else { break }
                let start = max(slice.sourceRange.start, run.sourceRange.start)
                let end = min(slice.sourceRange.end, run.sourceRange.end)
                if let previousStyle = pendingStyle, previousStyle != style {
                    try appendFragment(end: pendingEnd, style: previousStyle)
                }
                pendingStyle = style
                pendingEnd = run.displayRange.start + end - run.sourceRange.start
                // Whitespace left between removed fillers is not content that keeps a row open.
                if !low, try hasVisibleText(
                    from: run.displayRange.start + start - run.sourceRange.start, to: pendingEnd
                ) {
                    allLow = false
                }
                if run.sourceRange.end > slice.sourceRange.end { break }
                runIndex += 1
            }
        }
        if let style = pendingStyle {
            try appendFragment(end: pendingEnd, style: style)
        }
        let hasVisibleText = text.text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
        let collapse = hasVisibleText && allLow
            && !hasUnresolvedBoundary && !slices.contains(where: \.needsRetry)
        return TranscriptPriorityPresentation(text: text.text, fragments: fragments, shouldCollapseRow: collapse)
    }
}
