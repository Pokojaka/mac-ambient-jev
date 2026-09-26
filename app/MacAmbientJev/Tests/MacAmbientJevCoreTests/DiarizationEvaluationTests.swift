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

    let collapsed = try SpeakerArrivalCollapser.collapse(source)

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
