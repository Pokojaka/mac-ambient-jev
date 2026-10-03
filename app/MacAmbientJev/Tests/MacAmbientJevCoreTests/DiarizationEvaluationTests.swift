import Testing
@testable import MacAmbientJevCore

@Test
func trackedSpeakerRejectsIndexAboveSeven() {
    #expect(
        throws: SpeakerIdentityError.invalidTrackedIndex(8)
    ) {
        _ = try SpeakerIdentity.tracked(8)
    }
}

@Test
func arrivalCollapserMapsEighthThroughTenthToOther() throws {
    var source: [SourceSpeakerSpan] = []
    for index in 1...10 {
        source.append(
            SourceSpeakerSpan(
                startMilliseconds: Int64((index - 1) * 1_000),
                endMilliseconds: Int64(index * 1_000),
                speakerLabel: "person-\(index)"
            )
        )
    }

    let collapsed = try SpeakerArrivalCollapser.collapse(
        source,
        minCleanSpeechMilliseconds: 500
    )

    for index in 0..<7 {
        #expect(
            collapsed[index].speaker
                == (try SpeakerIdentity.tracked(index + 1))
        )
    }
    #expect(collapsed[7].speaker == .other)
    #expect(collapsed[8].speaker == .other)
    #expect(collapsed[9].speaker == .other)
}

@Test
func arrivalCollapserCountsArrivalFromFirstCleanUtterance() throws {
    // A backchannels inside B's turn before speaking cleanly, so B
    // arrives first even though A's first span starts earlier.
    let source = [
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 3_000,
            speakerLabel: "B"
        ),
        SourceSpeakerSpan(
            startMilliseconds: 200,
            endMilliseconds: 600,
            speakerLabel: "A"
        ),
        SourceSpeakerSpan(
            startMilliseconds: 4_000,
            endMilliseconds: 5_000,
            speakerLabel: "A"
        ),
    ]

    let collapsed = try SpeakerArrivalCollapser.collapse(
        source,
        minCleanSpeechMilliseconds: 500
    )

    #expect(collapsed.map(\.speaker) == [
        try .tracked(1),
        try .tracked(2),
        try .tracked(2),
    ])
}

@Test
func arrivalCollapserUsesCleanPartOfPartiallyOverlappedSpan() throws {
    // A's only span overlaps B for its first 400 ms, then continues
    // cleanly for 600 ms, which is enough to register A.
    let source = [
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_400,
            speakerLabel: "B"
        ),
        SourceSpeakerSpan(
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            speakerLabel: "A"
        ),
    ]

    let collapsed = try SpeakerArrivalCollapser.collapse(
        source,
        minCleanSpeechMilliseconds: 500
    )

    #expect(collapsed.map(\.speaker) == [
        try .tracked(1),
        try .tracked(2),
    ])
}

@Test
func arrivalCollapserMarksSpeakerWithoutCleanSpeechUnknown() throws {
    let source = [
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 2_000,
            speakerLabel: "A"
        ),
        SourceSpeakerSpan(
            startMilliseconds: 500,
            endMilliseconds: 900,
            speakerLabel: "B"
        ),
    ]

    let collapsed = try SpeakerArrivalCollapser.collapse(
        source,
        minCleanSpeechMilliseconds: 500
    )

    #expect(collapsed.map(\.speaker) == [try .tracked(1), .unknown])
}

@Test
func collapsedMetricsCountOtherToTrackedLeakage() throws {
    let reference = [
        SpeakerEvaluationSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speaker: .other
        )
    ]
    let hypothesis = [
        SpeakerEvaluationSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speaker: try .tracked(3)
        )
    ]

    let result = CollapsedDiarizationEvaluator.evaluate(
        reference: reference,
        hypothesis: hypothesis
    )

    #expect(result.confusionMilliseconds == 1_000)
    #expect(
        result.otherToTrackedLeakageMilliseconds == 1_000
    )
    #expect(result.otherRecall == 0)
    #expect(result.der == 1)
}

@Test
func unknownRemainsDistinctFromOther() {
    let reference = [
        SpeakerEvaluationSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speaker: .other
        )
    ]
    let hypothesis = [
        SpeakerEvaluationSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speaker: .unknown
        )
    ]

    let result = CollapsedDiarizationEvaluator.evaluate(
        reference: reference,
        hypothesis: hypothesis
    )

    #expect(result.unknownMilliseconds == 1_000)
    #expect(
        result.otherToTrackedLeakageMilliseconds == 0
    )
}

@Test
func collapsedMetricsReportOtherPrecisionUnknownRateAndOverflowRecall() throws {
    let tracked = try SpeakerIdentity.tracked(1)
    let reference = [
        SpeakerEvaluationSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speaker: .other
        ),
        SpeakerEvaluationSpan(
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            speaker: tracked
        ),
    ]
    let hypothesis = [
        SpeakerEvaluationSpan(
            startMilliseconds: 0,
            endMilliseconds: 500,
            speaker: .other
        ),
        SpeakerEvaluationSpan(
            startMilliseconds: 500,
            endMilliseconds: 1_000,
            speaker: .unknown
        ),
        SpeakerEvaluationSpan(
            startMilliseconds: 1_000,
            endMilliseconds: 1_500,
            speaker: .other
        ),
        SpeakerEvaluationSpan(
            startMilliseconds: 1_500,
            endMilliseconds: 2_000,
            speaker: tracked
        ),
    ]

    let result = CollapsedDiarizationEvaluator.evaluate(
        reference: reference,
        hypothesis: hypothesis
    )

    #expect(result.otherPrecision == 0.5)
    #expect(result.otherRecall == 0.5)
    #expect(result.overflowDetectionRecall == 1.0)
    #expect(result.unknownRate == 0.25)
    #expect(result.trackedToOtherLeakageMilliseconds == 500)
}

@Test
func collapsedMetricsSeparateTrackedSpeakerConfusion() throws {
    let reference = [
        SpeakerEvaluationSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speaker: try .tracked(1)
        ),
        SpeakerEvaluationSpan(
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            speaker: .other
        ),
    ]
    let hypothesis = [
        SpeakerEvaluationSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speaker: try .tracked(2)
        ),
        SpeakerEvaluationSpan(
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            speaker: try .tracked(3)
        ),
    ]

    let result = CollapsedDiarizationEvaluator.evaluate(
        reference: reference,
        hypothesis: hypothesis
    )

    #expect(result.confusionMilliseconds == 2_000)
    #expect(
        result.trackedSpeakerConfusionMilliseconds == 1_000
    )
    #expect(
        result.otherToTrackedLeakageMilliseconds == 1_000
    )
}

@Test
func collapsedMetricsReportOverlapRecall() throws {
    let one = try SpeakerIdentity.tracked(1)
    let two = try SpeakerIdentity.tracked(2)
    let reference = [
        SpeakerEvaluationSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speaker: one
        ),
        SpeakerEvaluationSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speaker: two
        ),
    ]
    let hypothesis = [
        SpeakerEvaluationSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speaker: one
        ),
        SpeakerEvaluationSpan(
            startMilliseconds: 0,
            endMilliseconds: 500,
            speaker: two
        ),
    ]

    let result = CollapsedDiarizationEvaluator.evaluate(
        reference: reference,
        hypothesis: hypothesis
    )

    #expect(result.referenceOverlapMilliseconds == 1_000)
    #expect(result.detectedOverlapMilliseconds == 500)
    #expect(result.overlapRecall == 0.5)
}

@Test
func standardDiarizationIsPermutationInvariant() {
    let reference = [
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speakerLabel: "A"
        ),
        SourceSpeakerSpan(
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            speakerLabel: "B"
        ),
    ]
    let hypothesis = [
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speakerLabel: "X"
        ),
        SourceSpeakerSpan(
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            speakerLabel: "Y"
        ),
    ]

    let result = StandardDiarizationEvaluator.evaluate(
        reference: reference,
        hypothesis: hypothesis
    )

    #expect(result.confusionMilliseconds == 0)
    #expect(result.der == 0)
}

@Test
func standardDiarizationCountsGlobalSpeakerConfusion() {
    let reference = [
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speakerLabel: "A"
        ),
        SourceSpeakerSpan(
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            speakerLabel: "B"
        ),
    ]
    let hypothesis = [
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 2_000,
            speakerLabel: "X"
        ),
    ]

    let result = StandardDiarizationEvaluator.evaluate(
        reference: reference,
        hypothesis: hypothesis
    )

    #expect(result.confusionMilliseconds == 1_000)
    #expect(result.der == 0.5)
}

@Test
func standardDiarizationReportsOverlapRecall() {
    let reference = [
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speakerLabel: "A"
        ),
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speakerLabel: "B"
        ),
    ]
    let hypothesis = [
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speakerLabel: "X"
        ),
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 500,
            speakerLabel: "Y"
        ),
    ]

    let result = StandardDiarizationEvaluator.evaluate(
        reference: reference,
        hypothesis: hypothesis
    )

    #expect(result.referenceOverlapMilliseconds == 1_000)
    #expect(result.detectedOverlapMilliseconds == 500)
    #expect(result.overlapRecall == 0.5)
}

@Test
func standardDiarizationReportsSpeakerSwitchBoundaryError() {
    let reference = [
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            speakerLabel: "A"
        ),
        SourceSpeakerSpan(
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            speakerLabel: "B"
        ),
    ]
    let hypothesis = [
        SourceSpeakerSpan(
            startMilliseconds: 0,
            endMilliseconds: 1_100,
            speakerLabel: "X"
        ),
        SourceSpeakerSpan(
            startMilliseconds: 1_100,
            endMilliseconds: 2_000,
            speakerLabel: "Y"
        ),
    ]

    let result = StandardDiarizationEvaluator.evaluate(
        reference: reference,
        hypothesis: hypothesis
    )

    #expect(
        result.speakerSwitchBoundaryMAEMilliseconds == 100
    )
}

