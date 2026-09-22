import Testing
@testable import MacAmbientJevCore

@Test
func lectureNeverMarksSpeechBackgroundFromDistanceAlone() {
    let classifier = ScopeClassifier()
    let result = classifier.classify(
        evidence: .distant,
        scene: .lecture
    )

    #expect(result.scope != .background)
}

@Test
func insufficientProximityEvidenceStaysUnknown() {
    let result = ScopeClassifier().classify(
        evidence: .unknown,
        scene: .discussion
    )

    #expect(result.scope == .unknown)
}

@Test
func discussionCanMarkStrongDistantEvidenceAsBackground() {
    let result = ScopeClassifier().classify(
        evidence: ProximityEvidence(
            distanceHint: .distant,
            levelConfidence: 0.9,
            spectralConfidence: 0.8
        ),
        scene: .discussion
    )

    #expect(result.scope == .background)
    #expect(result.confidence >= 0.8)
}

@Test
func acousticEvidenceCanEnterDiscussionWithoutJev() {
    var machine = SceneStateMachine(config: .test)

    for _ in 0..<6 {
        _ = machine.observe(
            AcousticSceneFeatures(
                activeSpeakerCount: 4,
                turnRate: 0.8,
                overlapRatio: 0.25,
                dominantSpeakerRatio: 0.25,
                voicedDurationRatio: 0.75
            )
        )
    }

    #expect(machine.state == .discussion)
}

@Test
func acousticEvidenceCanReturnToLectureWithoutJev() {
    var machine = SceneStateMachine(config: .test)

    for _ in 0..<6 {
        _ = machine.observe(
            AcousticSceneFeatures(
                activeSpeakerCount: 4,
                turnRate: 0.8,
                overlapRatio: 0.25,
                dominantSpeakerRatio: 0.25,
                voicedDurationRatio: 0.75
            )
        )
    }
    #expect(machine.state == .discussion)

    for _ in 0..<6 {
        _ = machine.observe(
            AcousticSceneFeatures(
                activeSpeakerCount: 1,
                turnRate: 0.05,
                overlapRatio: 0.01,
                dominantSpeakerRatio: 0.9,
                voicedDurationRatio: 0.8
            )
        )
    }

    #expect(machine.state == .lecture)
}

@Test
func featureExtractorMeasuresMultiSpeakerWindow() {
    let spans = [
        SpeakerSpan(speakerID: "a", startFrame: 0, endFrame: 10, confidence: 0.9),
        SpeakerSpan(speakerID: "b", startFrame: 5, endFrame: 15, confidence: 0.8),
        SpeakerSpan(speakerID: "a", startFrame: 15, endFrame: 20, confidence: 0.9)
    ]

    let features = AcousticSceneFeatureExtractor().extract(
        speakerSpans: spans,
        window: 0..<20,
        sampleRate: 1
    )

    #expect(features.activeSpeakerCount == 2)
    #expect(features.overlapRatio > 0)
    #expect(features.voicedDurationRatio == 1)
    #expect(features.turnRate > 0)
}

@Test
func semanticDiscussionCueOnlyEntersCandidateUntilAcousticConfirmation() {
    var machine = SceneStateMachine(config: .test)

    _ = machine.observeSemanticCue(.discussionStart)
    _ = machine.observeSemanticCue(.discussionStart)

    #expect(machine.state == .discussionCandidate)

    for _ in 0..<3 {
        _ = machine.observe(
            AcousticSceneFeatures(
                activeSpeakerCount: 4,
                turnRate: 0.8,
                overlapRatio: 0.25,
                dominantSpeakerRatio: 0.25,
                voicedDurationRatio: 0.75
            )
        )
    }

    #expect(machine.state == .discussion)
}

@Test
func semanticDiscussionEndOnlyEntersLectureCandidateUntilAcousticConfirmation() {
    var machine = SceneStateMachine(state: .discussion, config: .test)

    _ = machine.observeSemanticCue(.discussionEnd)

    #expect(machine.state == .lectureCandidate)

    for _ in 0..<3 {
        _ = machine.observe(
            AcousticSceneFeatures(
                activeSpeakerCount: 1,
                turnRate: 0.05,
                overlapRatio: 0.01,
                dominantSpeakerRatio: 0.9,
                voicedDurationRatio: 0.8
            )
        )
    }

    #expect(machine.state == .lecture)
}
