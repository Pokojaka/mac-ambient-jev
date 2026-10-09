import Testing
@testable import MacAmbientJevCore

@Test
func priorityPolicyStylesLowTextAndCollapsesOnlyResolvedAllLowContent() throws {
    let cleaned = try TranscriptTextProjector(detector: FillerTextSpanDetector()).project(sourceText: "えー、低本文")
    let range = try TextUTF16Range(start: 0, end: cleaned.sourceUTF16Length)
    let result = try TranscriptPriorityPresentationPolicy().present(
        text: cleaned,
        slices: [TranscriptPrioritySlice(sourceRange: range, priority: .lowPriority, needsRetry: false)],
        hasUnresolvedBoundary: false
    )
    #expect(result.text == "低本文")
    #expect(result.fragments == [TranscriptTextFragment(text: "低本文", style: .lowPriority)])
    #expect(result.shouldCollapseRow)
}

@Test
func priorityPolicyDoesNotCollapseEmptyPendingOrMixedContent() throws {
    let projector = TranscriptTextProjector(detector: FillerTextSpanDetector())
    let policy = TranscriptPriorityPresentationPolicy()
    let source = try projector.project(sourceText: "本文")
    let full = try TextUTF16Range(start: 0, end: source.text.utf16.count)
    let low = TranscriptPrioritySlice(sourceRange: full, priority: .lowPriority, needsRetry: false)
    #expect(try policy.present(text: source, slices: [low], hasUnresolvedBoundary: true).shouldCollapseRow == false)
    let retry = TranscriptPrioritySlice(sourceRange: full, priority: .lowPriority, needsRetry: true)
    let unavailable = try policy.present(text: source, slices: [retry], hasUnresolvedBoundary: false)
    #expect(!unavailable.shouldCollapseRow)
    #expect(unavailable.fragments == [TranscriptTextFragment(text: "本文", style: .normal)])
    let empty = try projector.project(sourceText: "えー")
    #expect(try policy.present(text: empty, slices: [], hasUnresolvedBoundary: false).shouldCollapseRow == false)
}

@Test
func priorityPolicyPreservesMixedStylesAcrossRemovedFillersAndUnclassifiedText() throws {
    let cleaned = try TranscriptTextProjector(detector: FillerTextSpanDetector())
        .project(sourceText: "えー、低。えー、😀本文")
    let slices = [
        TranscriptPrioritySlice(sourceRange: try TextUTF16Range(start: 0, end: 5), priority: .lowPriority, needsRetry: false),
        TranscriptPrioritySlice(sourceRange: try TextUTF16Range(start: 5, end: 8), priority: nil, needsRetry: true),
        TranscriptPrioritySlice(sourceRange: try TextUTF16Range(start: 8, end: 12), priority: .primary, needsRetry: false)
    ]
    let result = try TranscriptPriorityPresentationPolicy().present(
        text: cleaned, slices: slices, hasUnresolvedBoundary: false
    )
    #expect(result.text == "低。😀本文")
    #expect(result.fragments == [
        TranscriptTextFragment(text: "低。", style: .lowPriority),
        TranscriptTextFragment(text: "😀本文", style: .normal)
    ])
    #expect(!result.shouldCollapseRow)

    let unclassified = try TranscriptPriorityPresentationPolicy().present(
        text: cleaned, slices: [], hasUnresolvedBoundary: true
    )
    #expect(unclassified.fragments == [TranscriptTextFragment(text: "低。😀本文", style: .normal)])
    #expect(!unclassified.shouldCollapseRow)
}

@Test
func lowClosedSliceAndAwaitingTailRemainVisibleWithOnlyTheClosedSliceDimmed() throws {
    let cleaned = try TranscriptTextProjector(detector: FillerTextSpanDetector())
        .project(sourceText: "うん。続き")
    let result = try TranscriptPriorityPresentationPolicy().present(
        text: cleaned,
        slices: [
            TranscriptPrioritySlice(
                sourceRange: try TextUTF16Range(start: 0, end: 3),
                priority: .lowPriority, needsRetry: false
            ),
            TranscriptPrioritySlice(
                sourceRange: try TextUTF16Range(start: 3, end: 5),
                priority: nil, needsRetry: false
            )
        ],
        hasUnresolvedBoundary: true
    )
    #expect(result.text == "うん。続き")
    #expect(result.fragments == [
        TranscriptTextFragment(text: "うん。", style: .lowPriority),
        TranscriptTextFragment(text: "続き", style: .normal)
    ])
    #expect(!result.shouldCollapseRow)
}

@Test
func priorityPolicyRejectsMissingOrOverlappingCoverageInsteadOfDroppingVisibleText() throws {
    let cleaned = try TranscriptTextProjector(detector: FillerTextSpanDetector()).project(sourceText: "本文")
    let first = TranscriptPrioritySlice(
        sourceRange: try TextUTF16Range(start: 0, end: 1), priority: .lowPriority, needsRetry: false
    )
    let last = TranscriptPrioritySlice(
        sourceRange: try TextUTF16Range(start: 1, end: 2), priority: .primary, needsRetry: false
    )
    let policy = TranscriptPriorityPresentationPolicy()
    for slices in [[first], [last]] {
        #expect(throws: TranscriptPriorityPresentationError.incompleteSliceCoverage) {
            try policy.present(text: cleaned, slices: slices, hasUnresolvedBoundary: false)
        }
    }
    #expect(throws: TranscriptPriorityPresentationError.invalidSliceOrder) {
        try policy.present(text: cleaned, slices: [first, first, last], hasUnresolvedBoundary: false)
    }
}
